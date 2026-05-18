import subprocess
from pathlib import Path

from backup_server import preflight
from backup_server.discovery import HostSpec, Mount
from backup_server.index import BackupRecord, HostIndex, save
from backup_server.preflight import (
    _fmt_bytes,
    _worst,
    run_all,
    stage_discover,
    stage_index_lookup,
    stage_resolve_reach,
    stage_space_estimate,
    stage_trigger_mounts,
)
from backup_server.report import Status


def _cp(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr=stderr)


def _spec(**kw) -> HostSpec:
    defaults = dict(
        name="saratoga",
        private_ip="192.168.0.60",
        lan_ip="192.168.1.60",
        mounts=[],
        autofs_root=Path("/saratoga-01"),
        source="autofs",
    )
    defaults.update(kw)
    return HostSpec(**defaults)


def _mount(name="photography", source="autofs") -> Mount:
    return Mount(
        name=name,
        local_path=Path(f"/saratoga-01/{name}"),
        remote_export=f"192.168.0.60:/mnt/saratoga-01/{name}",
        protocol="nfs",
        source=source,
    )


# --- stage 1: resolve & reach -------------------------------------------

def test_resolve_reach_private_pings_clean():
    def runner(cmd):
        assert "ping" in cmd[0]
        return _cp(returncode=0)
    r = stage_resolve_reach(_spec(), runner)
    assert r.status == Status.PASS
    assert "192.168.0.60" in r.detail


def test_resolve_reach_falls_back_to_lan_warn():
    def runner(cmd):
        ip = cmd[-1]
        return _cp(returncode=0 if ip == "192.168.1.60" else 1)
    r = stage_resolve_reach(_spec(), runner)
    assert r.status == Status.WARN
    assert "192.168.1.60" in r.detail


def test_resolve_reach_fails_when_both_dead():
    def runner(cmd):
        return _cp(returncode=1)
    r = stage_resolve_reach(_spec(), runner)
    assert r.status == Status.FAIL


def test_resolve_reach_fails_with_no_ips():
    def runner(cmd):
        return _cp(returncode=0)  # would PASS if asked
    r = stage_resolve_reach(_spec(private_ip=None, lan_ip=None), runner)
    assert r.status == Status.FAIL
    assert "(none)" in r.detail


def test_resolve_reach_handles_missing_ping():
    def runner(cmd):
        raise FileNotFoundError(cmd[0])
    r = stage_resolve_reach(_spec(), runner)
    assert r.status == Status.FAIL


# --- stage 2: discover ---------------------------------------------------

def test_stage_discover_autofs_passes():
    spec = _spec(source="autofs", mounts=[_mount("a"), _mount("b")])
    r = stage_discover(spec)
    assert r.status == Status.PASS
    assert "2 mount" in r.detail


def test_stage_discover_probe_warns():
    spec = _spec(source="probe", mounts=[_mount("a", source="probe")])
    r = stage_discover(spec)
    assert r.status == Status.WARN


# --- stage 3: trigger auto-mounts ---------------------------------------

def test_trigger_mounts_all_ok():
    """stat returns 0, mountpoint -q returns 0 → PASS."""
    def runner(cmd):
        return _cp(returncode=0)
    spec = _spec(mounts=[_mount("a"), _mount("b")])
    r = stage_trigger_mounts(spec, runner)
    assert r.status == Status.PASS
    assert len(r.sub_results) == 2
    assert all(s.status == Status.PASS for s in r.sub_results)


def test_trigger_mounts_mountpoint_check_fails():
    """stat succeeds but mountpoint -q returns nonzero → FAIL on that share."""
    def runner(cmd):
        if cmd[0] == "stat":
            return _cp(returncode=0)
        if cmd[0] == "mountpoint":
            return _cp(returncode=1)
        return _cp(returncode=0)
    spec = _spec(mounts=[_mount("a")])
    r = stage_trigger_mounts(spec, runner)
    assert r.status == Status.FAIL
    assert "not a mountpoint" in r.sub_results[0].detail


def test_trigger_mounts_skips_probe_sourced():
    def runner(cmd):
        return _cp(returncode=0)
    spec = _spec(source="probe", mounts=[_mount("a", source="probe")])
    r = stage_trigger_mounts(spec, runner)
    assert r.sub_results[0].status == Status.WARN
    assert "probe-sourced" in r.sub_results[0].detail


def test_trigger_mounts_mixed_status():
    """Some pass, some fail → overall FAIL, sub_results capture both."""
    def runner(cmd):
        if cmd[0] == "stat":
            return _cp(returncode=0)
        if cmd[0] == "mountpoint":
            # fail only for the 'b' mount
            return _cp(returncode=1 if "b" in cmd[-1] else 0)
        return _cp(returncode=0)
    spec = _spec(mounts=[_mount("a"), _mount("b")])
    r = stage_trigger_mounts(spec, runner)
    assert r.status == Status.FAIL
    statuses = [s.status for s in r.sub_results]
    assert Status.PASS in statuses
    assert Status.FAIL in statuses


# --- stage 4: index lookup ----------------------------------------------

def test_index_lookup_no_prior_backup(tmp_path):
    r = stage_index_lookup(_spec(), tmp_path)
    assert r.status == Status.PASS
    assert "first run" in r.detail


def test_index_lookup_reports_last_backup(tmp_path):
    save(HostIndex(
        host="saratoga",
        backups=[BackupRecord(
            date="2026-05-17", duration_sec=100, bytes_transferred=1000,
            shares={"photography": "ok"}, log_path="x.log", rsync_exit=0,
        )],
    ), tmp_path)
    r = stage_index_lookup(_spec(), tmp_path)
    assert r.status == Status.PASS
    assert "2026-05-17" in r.detail


# --- stage 5: space estimate --------------------------------------------

def test_space_estimate_fits(tmp_path):
    def runner(cmd):
        if cmd[0] == "rsync":
            return _cp(
                returncode=0,
                stdout="Total transferred file size: 1,048,576 bytes\n",
            )
        return _cp(returncode=0)
    spec = _spec(mounts=[_mount("a"), _mount("b")])
    r = stage_space_estimate(spec, tmp_path, runner)
    assert r.status == Status.PASS
    # 2 mounts × ~1 MB; tmp_path has plenty of free space


def test_space_estimate_target_missing(tmp_path):
    def runner(cmd):
        return _cp(returncode=0)
    r = stage_space_estimate(_spec(), tmp_path / "nope", runner)
    assert r.status == Status.FAIL
    assert "does not exist" in r.detail


def test_space_estimate_parse_failure_marks_share_fail(tmp_path):
    def runner(cmd):
        if cmd[0] == "rsync":
            return _cp(returncode=1, stderr="mount stale")
        return _cp(returncode=0)
    spec = _spec(mounts=[_mount("a")])
    r = stage_space_estimate(spec, tmp_path, runner)
    assert r.sub_results[0].status == Status.FAIL
    assert "rsync exit 1" in r.sub_results[0].detail


# --- helpers -------------------------------------------------------------

def test_fmt_bytes_ranges():
    assert _fmt_bytes(0) == "0 B"
    assert _fmt_bytes(512) == "512 B"
    assert _fmt_bytes(1024) == "1.0 KB"
    assert _fmt_bytes(1024 * 1024) == "1.0 MB"
    assert _fmt_bytes(1.5 * 1024**3) == "1.5 GB"
    assert _fmt_bytes(4 * 1024**4) == "4.0 TB"


def test_worst_picks_fail_over_warn_over_pass():
    assert _worst([Status.PASS, Status.WARN, Status.FAIL]) == Status.FAIL
    assert _worst([Status.PASS, Status.WARN]) == Status.WARN
    assert _worst([Status.PASS, Status.PASS]) == Status.PASS
    assert _worst([]) == Status.PASS


# --- orchestrator --------------------------------------------------------

def test_run_all_invokes_five_stages(tmp_path):
    def runner(cmd):
        if cmd[0] == "rsync":
            return _cp(returncode=0, stdout="Total transferred file size: 0 bytes\n")
        return _cp(returncode=0)
    target = tmp_path / "host-backups"
    target.mkdir()
    spec = _spec(mounts=[_mount("photography")])
    results = run_all(spec, target, tmp_path / "index", runner)
    assert len(results) == 5
    assert [r.name for r in results] == [
        "resolve & reach",
        "discover mounts",
        "trigger auto-mounts",
        "master index lookup",
        "space estimate",
    ]
    assert all(r.status != Status.FAIL for r in results)


# Silence unused-import noise (preflight imported at top for module-level access).
assert preflight

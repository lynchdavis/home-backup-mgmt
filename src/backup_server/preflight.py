"""Five preflight stages — all run, all report PASS/WARN/FAIL."""
import shutil
import subprocess
from collections.abc import Callable
from pathlib import Path

from backup_server import index
from backup_server.discovery import HostSpec, Mount
from backup_server.report import StageResult, Status

Runner = Callable[[list[str]], subprocess.CompletedProcess]


def run_all(
    host: HostSpec,
    target_root: Path,
    index_dir: Path,
    runner: Runner | None = None,
) -> list[StageResult]:
    runner = runner or _run
    return [
        stage_resolve_reach(host, runner=runner),
        stage_discover(host),
        stage_trigger_mounts(host, runner=runner),
        stage_index_lookup(host, index_dir),
        stage_space_estimate(host, target_root, runner=runner),
    ]


def stage_resolve_reach(host: HostSpec, runner: Runner) -> StageResult:
    """Prefer private IP. LAN fallback = WARN. Neither responds = FAIL."""
    if host.private_ip and _ping(host.private_ip, runner):
        return StageResult(
            "resolve & reach", Status.PASS,
            f"private 10 GbE ({host.private_ip}) reachable",
        )
    if host.lan_ip and _ping(host.lan_ip, runner):
        return StageResult(
            "resolve & reach", Status.WARN,
            f"LAN ({host.lan_ip}) reachable; private link down or unconfigured",
        )
    candidates = ", ".join(filter(None, [host.private_ip, host.lan_ip])) or "(none)"
    return StageResult("resolve & reach", Status.FAIL, f"no response from {candidates}")


def stage_discover(host: HostSpec) -> StageResult:
    """Report what discovery found. probe-only is WARN (no usable local mount paths)."""
    n = len(host.mounts)
    if host.source == "probe":
        return StageResult(
            "discover mounts", Status.WARN,
            f"probe-only: {n} share(s) detected, no local mount paths. "
            "Add an autofs map or tier-1 config to back these up.",
        )
    return StageResult("discover mounts", Status.PASS, f"{n} mount(s) via {host.source}")


def stage_trigger_mounts(host: HostSpec, runner: Runner) -> StageResult:
    """stat each local_path (triggers autofs), then verify with mountpoint -q."""
    subs: list[StageResult] = []
    for m in host.mounts:
        if m.source == "probe":
            subs.append(StageResult(m.name, Status.WARN, "probe-sourced; no local path"))
            continue
        subs.append(_check_mount(m, runner))
    overall = _worst([s.status for s in subs]) if subs else Status.PASS
    ok = sum(1 for s in subs if s.status == Status.PASS)
    return StageResult(
        "trigger auto-mounts", overall, f"{ok}/{len(subs)} mounts ready", sub_results=subs,
    )


def stage_index_lookup(host: HostSpec, index_dir: Path) -> StageResult:
    """Read the per-host index, report last-backup state."""
    idx = index.load(host.name, index_dir)
    if idx is None or not idx.backups:
        return StageResult(
            "master index lookup", Status.PASS,
            "no prior backup recorded — this would be the first run",
        )
    last = idx.backups[-1]
    return StageResult(
        "master index lookup", Status.PASS,
        f"last backup {last.date} ({len(idx.backups)} run(s) recorded)",
    )


def stage_space_estimate(host: HostSpec, target_root: Path, runner: Runner) -> StageResult:
    """rsync -an --stats per mount, summed, compared to free space on target_root."""
    if not target_root.exists():
        return StageResult(
            "space estimate", Status.FAIL,
            f"target root {target_root} does not exist",
        )

    subs: list[StageResult] = []
    total_bytes = 0
    for m in host.mounts:
        if m.source == "probe":
            subs.append(StageResult(m.name, Status.WARN, "probe-sourced; no estimate"))
            continue
        dst = target_root / host.name / m.name
        try:
            n = _rsync_dry_run_size(m.local_path, dst, runner)
        except (RuntimeError, OSError) as e:
            subs.append(StageResult(m.name, Status.FAIL, f"rsync probe failed: {e}"))
            continue
        total_bytes += n
        subs.append(StageResult(m.name, Status.PASS, f"~{_fmt_bytes(n)}"))

    free = _df_free(target_root)
    if free is None:
        return StageResult(
            "space estimate", Status.FAIL,
            f"could not stat free space on {target_root}", sub_results=subs,
        )

    if total_bytes > free:
        status = Status.FAIL
        detail = f"need ~{_fmt_bytes(total_bytes)}, only {_fmt_bytes(free)} free"
    elif total_bytes > free * 0.8:
        status = Status.WARN
        detail = f"tight: ~{_fmt_bytes(total_bytes)} of {_fmt_bytes(free)} free (>80%)"
    else:
        status = Status.PASS
        detail = f"~{_fmt_bytes(total_bytes)} of {_fmt_bytes(free)} free"
    return StageResult("space estimate", status, detail, sub_results=subs)


# --- helpers -------------------------------------------------------------

_STATUS_ORDER = {Status.PASS: 0, Status.WARN: 1, Status.FAIL: 2}


def _worst(statuses: list[Status]) -> Status:
    return max(statuses, key=lambda s: _STATUS_ORDER[s]) if statuses else Status.PASS


def _ping(addr: str, runner: Runner) -> bool:
    try:
        r = runner(["ping", "-c", "1", "-W", "2", addr])
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def _check_mount(m: Mount, runner: Runner) -> StageResult:
    try:
        r = runner(["stat", str(m.local_path)])
    except FileNotFoundError:
        return StageResult(m.name, Status.FAIL, "stat command missing")
    except subprocess.TimeoutExpired:
        return StageResult(m.name, Status.FAIL, f"stat timed out for {m.local_path}")
    if r.returncode != 0:
        return StageResult(m.name, Status.FAIL, f"stat failed for {m.local_path}")
    r = runner(["mountpoint", "-q", str(m.local_path)])
    if r.returncode == 0:
        return StageResult(m.name, Status.PASS, str(m.local_path))
    return StageResult(m.name, Status.FAIL, f"{m.local_path} not a mountpoint after trigger")


def _rsync_dry_run_size(src: Path, dst: Path, runner: Runner) -> int:
    r = runner(["rsync", "-an", "--stats", f"{src}/", f"{dst}/"])
    if r.returncode != 0:
        raise RuntimeError(f"rsync exit {r.returncode}: {r.stderr.strip()[:200]}")
    for line in r.stdout.splitlines():
        if line.startswith("Total transferred file size:"):
            digits = "".join(c for c in line if c.isdigit())
            return int(digits) if digits else 0
    return 0


def _df_free(path: Path) -> int | None:
    try:
        return shutil.disk_usage(path).free
    except OSError:
        return None


def _fmt_bytes(n: float) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    for i, unit in enumerate(units):
        if n < 1024 or i == len(units) - 1:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n} B"


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    """Default runner. Captures output; does NOT raise on non-zero exit."""
    return subprocess.run(cmd, capture_output=True, text=True, timeout=300)  # noqa: S603

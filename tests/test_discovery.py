from pathlib import Path

import pytest

from backup_server import discovery
from backup_server.discovery import (
    DiscoveryError,
    HostSpec,
    Mount,
    _host_aliases,
    _hosts_ips_for,
    _parse_autofs_map,
    _parse_autofs_master,
    discover,
    from_autofs,
    from_config,
    from_probe,
)

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def autofs_dir(tmp_path):
    """Copy of the autofs fixtures, with the master pointing at the local .nfs map."""
    autofs = tmp_path / "autofs"
    autofs.mkdir()
    nfs = autofs / "saratoga-01.nfs"
    nfs.write_text((FIXTURES / "autofs" / "saratoga-01.nfs").read_text())
    master = autofs / "saratoga-01.autofs"
    master_text = (FIXTURES / "autofs" / "saratoga-01.autofs").read_text()
    master.write_text(master_text.replace("__MAP__", str(nfs)))
    return autofs


# --- tier 1: config ------------------------------------------------------

def test_from_config_missing_returns_none(tmp_path):
    assert from_config("saratoga", tmp_path) is None


def test_from_config_full_toml(tmp_path):
    (tmp_path / "saratoga.toml").write_text(
        'private_ip = "192.168.0.60"\n'
        'lan_ip = "192.168.1.60"\n'
        'autofs_root = "/saratoga-01"\n'
        'mounts = ["photography", "videos"]\n'
    )
    spec = from_config("saratoga", tmp_path)
    assert spec is not None
    assert spec.private_ip == "192.168.0.60"
    assert spec.lan_ip == "192.168.1.60"
    assert spec.autofs_root == Path("/saratoga-01")
    assert [m.name for m in spec.mounts] == ["photography", "videos"]
    assert spec.mounts[0].local_path == Path("/saratoga-01/photography")
    assert spec.mounts[0].source == "config"


def test_from_config_partial_no_mounts(tmp_path):
    """IPs but no mounts list — returns spec with empty mounts so caller falls through."""
    (tmp_path / "saratoga.toml").write_text(
        'private_ip = "192.168.0.60"\n'
        'autofs_root = "/saratoga-01"\n'
    )
    spec = from_config("saratoga", tmp_path)
    assert spec is not None
    assert spec.mounts == []
    assert spec.private_ip == "192.168.0.60"


# --- tier 2: autofs ------------------------------------------------------

def test_parse_autofs_master(autofs_dir):
    entries = _parse_autofs_master(autofs_dir)
    assert len(entries) == 1
    mount_root, map_file = entries[0]
    assert mount_root == Path("/saratoga-01")
    assert map_file.name == "saratoga-01.nfs"


def test_parse_autofs_map_skips_comments(autofs_dir):
    entries = _parse_autofs_map(autofs_dir / "saratoga-01.nfs")
    shares = [e[0] for e in entries]
    assert "applications" in shares
    assert "PhotoArchive_2020_2029" in shares
    assert "##" not in shares  # comment line not parsed as a share
    # Last entry should have the saratoga-02 path
    photo_entry = next(e for e in entries if e[0] == "PhotoArchive_2020_2029")
    assert photo_entry[1] == "192.168.0.60"
    assert photo_entry[2] == "/mnt/saratoga-02/PhotoArchive/PhotoArchive_2020_2029"


def test_from_autofs_matches_by_filename(autofs_dir, tmp_path):
    """The realistic saratoga case: /etc/hosts has the wrong IP but filename hints
    the map belongs to this host."""
    hosts = tmp_path / "hosts"
    hosts.write_text((FIXTURES / "hosts_saratoga_lan_only").read_text())
    spec = from_autofs("saratoga", autofs_dir=autofs_dir, hosts_file=hosts)
    assert spec is not None
    assert spec.source == "autofs"
    assert spec.private_ip == "192.168.0.60"  # picked up from autofs entry
    assert spec.lan_ip == "192.168.7.60"      # from /etc/hosts
    assert spec.autofs_root == Path("/saratoga-01")
    names = {m.name for m in spec.mounts}
    assert "applications" in names
    assert "PhotoArchive_2020_2029" in names


def test_from_autofs_matches_by_known_ip(autofs_dir, tmp_path):
    """When tier-1 config gave us the private IP, match without /etc/hosts help."""
    empty_hosts = tmp_path / "empty_hosts"
    empty_hosts.write_text("")
    spec = from_autofs(
        "newhost",  # unrelated name — must match by IP alone
        autofs_dir=autofs_dir,
        hosts_file=empty_hosts,
        known_ips={"192.168.0.60"},
    )
    assert spec is not None
    assert spec.private_ip == "192.168.0.60"
    assert {m.name for m in spec.mounts} >= {"applications", "photography"}


def test_from_autofs_no_match(autofs_dir, tmp_path):
    """Different host with no IP or filename overlap returns None."""
    empty_hosts = tmp_path / "empty_hosts"
    empty_hosts.write_text("")
    spec = from_autofs("nasbox", autofs_dir=autofs_dir, hosts_file=empty_hosts)
    assert spec is None


def test_from_autofs_missing_dir(tmp_path):
    assert from_autofs("saratoga", autofs_dir=tmp_path / "does-not-exist") is None


# --- tier 3: probe -------------------------------------------------------

def test_from_probe_nfs_only():
    def fake_runner(cmd):
        if "showmount" in cmd[0]:
            return (
                "/mnt/saratoga-01/NetworkShares01/applications  *\n"
                "/mnt/saratoga-01/NetworkShares01/photography   *\n"
            )
        raise FileNotFoundError(cmd[0])
    spec = from_probe("saratoga", "192.168.0.60", runner=fake_runner)
    assert spec is not None
    assert spec.source == "probe"
    assert [m.name for m in spec.mounts] == ["applications", "photography"]
    assert all(m.protocol == "nfs" for m in spec.mounts)


def test_from_probe_smb_only():
    def fake_runner(cmd):
        if "smbclient" in cmd[0]:
            return (
                "Anonymous login successful\n"
                "Disk|Public|Public files\n"
                "Disk|Backups|\n"
                "Disk|print$|Printer Drivers\n"
                "IPC|IPC$|IPC Service\n"
            )
        raise FileNotFoundError(cmd[0])
    spec = from_probe("nasbox", "10.0.0.5", runner=fake_runner)
    assert spec is not None
    shares = {m.name: m.protocol for m in spec.mounts}
    assert shares == {"Public": "smb", "Backups": "smb"}  # print$/IPC$ filtered


def test_from_probe_both_protocols():
    def fake_runner(cmd):
        if "showmount" in cmd[0]:
            return "/srv/nfs/data  *\n"
        if "smbclient" in cmd[0]:
            return "Disk|files|\n"
        raise FileNotFoundError(cmd[0])
    spec = from_probe("box", "10.0.0.5", runner=fake_runner)
    assert spec is not None
    protocols = {m.protocol for m in spec.mounts}
    assert protocols == {"nfs", "smb"}


def test_from_probe_nothing_returns_none():
    def fake_runner(cmd):
        raise FileNotFoundError(cmd[0])
    assert from_probe("nope", "10.0.0.99", runner=fake_runner) is None


# --- discover orchestrator -----------------------------------------------

def test_discover_uses_tier1_when_complete(tmp_path):
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    (cfg / "saratoga.toml").write_text(
        'private_ip = "192.168.0.60"\n'
        'autofs_root = "/saratoga-01"\n'
        'mounts = ["photography"]\n'
    )
    spec = discover("saratoga", cfg, autofs_dir=tmp_path / "nope")
    assert spec.source == "config"
    assert [m.name for m in spec.mounts] == ["photography"]


def test_discover_falls_through_to_autofs(tmp_path, autofs_dir):
    """Tier-1 config has IPs but no mounts list; tier-2 fills in mounts."""
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    (cfg / "saratoga.toml").write_text(
        'private_ip = "192.168.0.60"\n'
        'lan_ip = "10.10.10.10"\n'
    )
    empty_hosts = tmp_path / "empty_hosts"
    empty_hosts.write_text("")
    spec = discover("saratoga", cfg, autofs_dir=autofs_dir, hosts_file=empty_hosts)
    assert spec.source == "autofs"
    assert spec.lan_ip == "10.10.10.10"  # carried forward from tier 1
    assert spec.private_ip == "192.168.0.60"
    assert spec.mounts


def test_discover_raises_when_nothing_found(tmp_path):
    def fake_runner(cmd):
        raise FileNotFoundError(cmd[0])
    with pytest.raises(DiscoveryError):
        discover(
            "ghost",
            tmp_path,
            autofs_dir=tmp_path / "no-autofs",
            hosts_file=tmp_path / "no-hosts",
            runner=fake_runner,
        )


# --- /etc/hosts helpers --------------------------------------------------

def test_host_aliases_picks_up_etc_hosts(tmp_path):
    hosts = tmp_path / "hosts"
    hosts.write_text((FIXTURES / "hosts_saratoga_lan_only").read_text())
    aliases = _host_aliases("saratoga", hosts)
    assert "saratoga-01" in aliases
    assert "saratoga-02" in aliases
    assert "freenas-01" in aliases


def test_hosts_ips_for_skips_ipv6(tmp_path):
    hosts = tmp_path / "hosts"
    hosts.write_text(
        "::1 saratoga\n"
        "192.168.7.60 saratoga saratoga-01\n"
    )
    ips = _hosts_ips_for("saratoga", hosts)
    assert ips == {"192.168.7.60"}


def test_hosts_ips_for_ignores_commented_lines(tmp_path):
    hosts = tmp_path / "hosts"
    hosts.write_text(
        "192.168.7.60 saratoga\n"
        "## 192.168.0.60 saratoga\n"
    )
    ips = _hosts_ips_for("saratoga", hosts)
    assert ips == {"192.168.7.60"}


# Reach into module to silence unused-import noise if any helper imports drift.
assert all(o for o in (HostSpec, Mount, discovery))

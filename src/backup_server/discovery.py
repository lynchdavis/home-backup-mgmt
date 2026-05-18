"""Layered discovery: config file → autofs → live probe."""
import socket
import subprocess
import tomllib
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Mount:
    name: str                # logical share name, e.g. "photography"
    local_path: Path         # e.g. /saratoga-01/photography
    remote_export: str       # e.g. 192.168.0.60:/mnt/saratoga-01/.../photography
    protocol: str            # "nfs" | "smb"
    source: str              # "config" | "autofs" | "probe"


@dataclass
class HostSpec:
    name: str
    private_ip: str | None
    lan_ip: str | None
    mounts: list[Mount]
    autofs_root: Path | None
    source: str              # which tier resolved the mount list


class DiscoveryError(Exception):
    pass


def discover(
    host: str,
    config_dir: Path,
    autofs_dir: Path = Path("/etc/auto.master.d"),
    hosts_file: Path = Path("/etc/hosts"),
    runner: Callable[[list[str]], str] | None = None,
) -> HostSpec:
    """Try tier 1 (config) → tier 2 (autofs) → tier 3 (probe). Raise if all fail."""
    partial = from_config(host, config_dir)
    if partial and partial.mounts:
        return partial

    known_ips: set[str] = set()
    if partial:
        if partial.private_ip:
            known_ips.add(partial.private_ip)
        if partial.lan_ip:
            known_ips.add(partial.lan_ip)

    spec = from_autofs(host, autofs_dir=autofs_dir, hosts_file=hosts_file, known_ips=known_ips)
    if spec:
        return _merge_partial(spec, partial)

    probe_ip = (partial.private_ip if partial else None) or _resolve(host)
    spec = from_probe(host, probe_ip, runner=runner)
    if spec:
        return _merge_partial(spec, partial)

    raise DiscoveryError(f"could not discover any shares for {host!r}")


# --- tier 1 --------------------------------------------------------------

def from_config(host: str, config_dir: Path) -> HostSpec | None:
    """Read /kodiak00/etc/servers/<host>.toml if present."""
    path = config_dir / f"{host}.toml"
    if not path.exists():
        return None
    with path.open("rb") as f:
        data = tomllib.load(f)

    autofs_root_str = data.get("autofs_root")
    autofs_root = Path(autofs_root_str) if autofs_root_str else None

    mounts: list[Mount] = []
    if autofs_root:
        for name in data.get("mounts") or []:
            mounts.append(Mount(
                name=name,
                local_path=autofs_root / name,
                remote_export="",  # config alone doesn't pin the remote path
                protocol="nfs",
                source="config",
            ))

    return HostSpec(
        name=host,
        private_ip=data.get("private_ip"),
        lan_ip=data.get("lan_ip"),
        mounts=mounts,
        autofs_root=autofs_root,
        source="config",
    )


# --- tier 2 --------------------------------------------------------------

def from_autofs(
    host: str,
    autofs_dir: Path = Path("/etc/auto.master.d"),
    hosts_file: Path = Path("/etc/hosts"),
    known_ips: set[str] | None = None,
) -> HostSpec | None:
    """Scan autofs maps for indirect mounts pointing at host. None if nothing matches."""
    if not autofs_dir.exists():
        return None

    aliases = _host_aliases(host, hosts_file)
    ips = (known_ips or set()) | _resolve_all(host) | _hosts_ips_for(host, hosts_file)

    matched: list[Mount] = []
    autofs_root: Path | None = None

    for mount_root, map_file in _parse_autofs_master(autofs_dir):
        if not map_file.exists():
            continue
        # Filename heuristic: catches the case where /etc/hosts disagrees with
        # the autofs IP (which is exactly saratoga's setup right now).
        filename_match = any(a and a in map_file.name for a in aliases | {host})

        for share, server, remote_path in _parse_autofs_map(map_file):
            if server in ips or server in aliases or filename_match:
                matched.append(Mount(
                    name=share,
                    local_path=mount_root / share,
                    remote_export=f"{server}:{remote_path}",
                    protocol="nfs",
                    source="autofs",
                ))
                if autofs_root is None:
                    autofs_root = mount_root

    if not matched:
        return None

    autofs_ips = {m.remote_export.split(":", 1)[0] for m in matched}
    private_ip = next(iter(autofs_ips), None)
    lan_candidates = ips - autofs_ips
    lan_ip = next(iter(lan_candidates), None)

    return HostSpec(
        name=host,
        private_ip=private_ip,
        lan_ip=lan_ip,
        mounts=matched,
        autofs_root=autofs_root,
        source="autofs",
    )


# --- tier 3 --------------------------------------------------------------

def from_probe(
    host: str,
    ip: str | None,
    runner: Callable[[list[str]], str] | None = None,
) -> HostSpec | None:
    """Live probe: showmount -e for NFS exports, smbclient -L for SMB shares (detect-only).

    For probed mounts we use a synthetic local_path under /tmp/backup-server/<host>/.
    These are not directly executable in v1 — they exist for the preflight report
    so the user can promote them to a tier-1 config or autofs entry.
    """
    runner = runner or _run
    target = ip or host
    mounts: list[Mount] = []

    try:
        out = runner(["/usr/sbin/showmount", "-e", "--no-headers", target])
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("/"):
                continue
            remote_path = line.split()[0]
            share = Path(remote_path).name
            mounts.append(Mount(
                name=share,
                local_path=Path("/tmp/backup-server") / host / share,
                remote_export=f"{target}:{remote_path}",
                protocol="nfs",
                source="probe",
            ))
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass

    try:
        out = runner(["/usr/bin/smbclient", "-L", f"//{target}", "-N", "-g"])
        for line in out.splitlines():
            if not line.startswith("Disk|"):
                continue
            parts = line.split("|")
            if len(parts) < 2:
                continue
            share = parts[1]
            if share.endswith("$"):  # skip print$, IPC$, etc.
                continue
            mounts.append(Mount(
                name=share,
                local_path=Path("/tmp/backup-server") / host / share,
                remote_export=f"//{target}/{share}",
                protocol="smb",
                source="probe",
            ))
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass

    if not mounts:
        return None

    return HostSpec(
        name=host,
        private_ip=ip,
        lan_ip=None,
        mounts=mounts,
        autofs_root=None,
        source="probe",
    )


# --- helpers -------------------------------------------------------------

def _merge_partial(spec: HostSpec, partial: HostSpec | None) -> HostSpec:
    """Tier-1 explicit values win; tier-2/3 fill in gaps the config left blank."""
    if partial is None:
        return spec
    spec.private_ip = partial.private_ip or spec.private_ip
    spec.lan_ip = partial.lan_ip or spec.lan_ip
    spec.autofs_root = partial.autofs_root or spec.autofs_root
    return spec


def _host_aliases(host: str, hosts_file: Path) -> set[str]:
    """Names by which `host` is known: input + DNS aliases + /etc/hosts aliases."""
    names = {host}
    try:
        canonical, aliases, _ = socket.gethostbyname_ex(host)
        names.add(canonical)
        names.update(aliases)
    except OSError:
        pass
    if hosts_file.exists():
        for line in hosts_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            _ip, *names_in_line = parts
            if host in names_in_line:
                names.update(names_in_line)
    return names


def _hosts_ips_for(host: str, hosts_file: Path) -> set[str]:
    """IPv4 addresses from /etc/hosts lines whose names include `host`."""
    if not hosts_file.exists():
        return set()
    ips: set[str] = set()
    for line in hosts_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        ip, *names = parts
        if host in names and ":" not in ip:  # skip IPv6 for now
            ips.add(ip)
    return ips


def _resolve_all(host: str) -> set[str]:
    try:
        _, _, addrs = socket.gethostbyname_ex(host)
        return {a for a in addrs if ":" not in a}
    except OSError:
        return set()


def _resolve(host: str) -> str | None:
    try:
        return socket.gethostbyname(host)
    except OSError:
        return None


def _parse_autofs_master(autofs_dir: Path) -> list[tuple[Path, Path]]:
    """Parse *.autofs files. Returns (mount_root, map_file) pairs."""
    entries: list[tuple[Path, Path]] = []
    for f in sorted(autofs_dir.glob("*.autofs")):
        for line in f.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            mount_root = Path(parts[0])
            map_path = parts[1].removeprefix("file:")
            entries.append((mount_root, Path(map_path)))
    return entries


def _parse_autofs_map(map_file: Path) -> list[tuple[str, str, str]]:
    """Parse an autofs map file. Returns (share, server, remote_path) tuples."""
    results: list[tuple[str, str, str]] = []
    for line in map_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        tokens = line.split()
        if len(tokens) < 2:
            continue
        share = tokens[0]
        server_path = tokens[-1]
        if ":" not in server_path:
            continue
        server, remote_path = server_path.split(":", 1)
        results.append((share, server, remote_path))
    return results


def _run(cmd: list[str]) -> str:
    return subprocess.run(
        cmd, capture_output=True, text=True, check=True, timeout=30,
    ).stdout

"""Per-host JSON index at <index_dir>/<host>.json."""
import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path


@dataclass
class BackupRecord:
    date: str                # ISO date, e.g. "2026-05-17"
    duration_sec: int
    bytes_transferred: int
    shares: dict[str, str]   # share name -> "ok" | "partial" | "fail"
    log_path: str
    rsync_exit: int


@dataclass
class HostIndex:
    host: str
    private_ip: str | None = None
    lan_ip: str | None = None
    backups: list[BackupRecord] = field(default_factory=list)


def _path(host: str, index_dir: Path) -> Path:
    return index_dir / f"{host}.json"


def load(host: str, index_dir: Path) -> HostIndex | None:
    """Return the host's index, or None if no file exists yet."""
    path = _path(host, index_dir)
    if not path.exists():
        return None
    raw = json.loads(path.read_text())
    backups = [
        BackupRecord(
            date=r["date"],
            duration_sec=r["duration_sec"],
            bytes_transferred=r["bytes_transferred"],
            shares=r["shares"],
            log_path=r["log_path"],
            rsync_exit=r["rsync_exit"],
        )
        for r in raw.get("backups", [])
    ]
    return HostIndex(
        host=raw["host"],
        private_ip=raw.get("private_ip"),
        lan_ip=raw.get("lan_ip"),
        backups=backups,
    )


def save(idx: HostIndex, index_dir: Path) -> None:
    """Atomic write via tmp file + os.replace. Creates index_dir if missing."""
    index_dir.mkdir(parents=True, exist_ok=True)
    path = _path(idx.host, index_dir)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    tmp.write_text(json.dumps(asdict(idx), indent=2) + "\n")
    os.replace(tmp, path)


def append_backup(host: str, index_dir: Path, record: BackupRecord) -> None:
    """Load existing index (or create a fresh one), append the record, save."""
    idx = load(host, index_dir) or HostIndex(host=host)
    idx.backups.append(record)
    save(idx, index_dir)

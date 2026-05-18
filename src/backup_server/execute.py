"""Rsync runner for the actual backup pass."""
from dataclasses import dataclass
from pathlib import Path

from backup_server.discovery import HostSpec


@dataclass
class ShareResult:
    share: str
    status: str              # "ok" | "partial" | "fail"
    bytes_transferred: int
    rsync_exit: int
    log_path: Path


@dataclass
class RunResult:
    host: str
    duration_sec: int
    shares: list[ShareResult]


def run(host: HostSpec, target_root: Path, log_dir: Path) -> RunResult:
    """For each mount: rsync -rlptDv --stats --log-file=... src/ dst/."""
    raise NotImplementedError("execute not yet implemented")

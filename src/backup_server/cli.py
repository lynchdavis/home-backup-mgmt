import argparse
import sys
from pathlib import Path

from backup_server import __version__, discovery, execute, index, preflight, report
from backup_server.report import Status

DEFAULT_CONFIG_DIR = Path("/kodiak00/etc/servers")
DEFAULT_INDEX_DIR = Path("/kodiak00/data-00/backups/index")
DEFAULT_TARGET_ROOT = Path("/kodiak00/data-00/backups/host-backups")
DEFAULT_LOG_DIR = Path("/kodiak00/data-00/backups/logs")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="backup-server",
        description="Pull NFS-exported shares from a remote server onto this host.",
    )
    p.add_argument("host", help="Server name to back up (e.g. saratoga)")
    p.add_argument("--execute", action="store_true",
                   help="Actually run rsync. Default is preflight-only.")
    p.add_argument("--config-dir", type=Path, default=DEFAULT_CONFIG_DIR,
                   help=f"Per-server config dir (default: {DEFAULT_CONFIG_DIR})")
    p.add_argument("--index-dir", type=Path, default=DEFAULT_INDEX_DIR,
                   help=f"Per-host index dir (default: {DEFAULT_INDEX_DIR})")
    p.add_argument("--target-root", type=Path, default=DEFAULT_TARGET_ROOT,
                   help=f"Backup destination root (default: {DEFAULT_TARGET_ROOT})")
    p.add_argument("--log-dir", type=Path, default=DEFAULT_LOG_DIR,
                   help=f"rsync log dir (default: {DEFAULT_LOG_DIR})")
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        host = discovery.discover(args.host, args.config_dir)
    except discovery.DiscoveryError as e:
        print(f"discovery: {e}", file=sys.stderr)
        return 2

    results = preflight.run_all(host, args.target_root, args.index_dir)
    print(report.render(results))
    summary = report.overall(results)
    print(f"\nPreflight: {summary.value}")

    if not args.execute:
        return 0 if summary != Status.FAIL else 1

    if summary == Status.FAIL:
        print("Preflight FAILED, refusing to execute.", file=sys.stderr)
        return 1

    run_result = execute.run(host, args.target_root, args.log_dir)
    index.append_backup(host.name, args.index_dir,
                        index.BackupRecord(
                            date="",  # filled by execute
                            duration_sec=run_result.duration_sec,
                            bytes_transferred=sum(s.bytes_transferred for s in run_result.shares),
                            shares={s.share: s.status for s in run_result.shares},
                            log_path="",
                            rsync_exit=0,
                        ))
    return 0

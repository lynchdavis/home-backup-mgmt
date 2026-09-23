"""Subprocess wrapper around `tourbillon <cmd> --json`.

The dashboard never re-implements backup-state logic — it shells out to the
same CLI a human would run, exactly like `weekly-summary.sh` already does
for the weekly email. A short TTL cache keeps browser polling from
re-running zfs/ssh probes on every request.
"""
import json
import subprocess
import time
import tomllib
from pathlib import Path

DASHBOARD_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = DASHBOARD_DIR.parent
TOURBILLON_BIN = REPO_ROOT / "bin" / "tourbillon"

_config_path = DASHBOARD_DIR / "config.toml"
_config = tomllib.loads(_config_path.read_text()) if _config_path.exists() else {}
CACHE_TTL = _config.get("cache", {}).get("ttl_seconds", 30)

_cache: dict[str, tuple[float, object]] = {}


class TourbillonError(RuntimeError):
    pass


def run_json(*args: str):
    """Run `tourbillon <args> --json`, cached per distinct argument tuple.

    hosts/repos `issues` and `status` all exit non-zero to mean "there are
    issues", not "the command failed" — the only real failure mode here is
    the output not being valid JSON.
    """
    key = " ".join(args)
    now = time.time()
    cached = _cache.get(key)
    if cached and now - cached[0] < CACHE_TTL:
        return cached[1]

    proc = subprocess.run(
        [str(TOURBILLON_BIN), *args, "--json"],
        capture_output=True, text=True, timeout=60,
    )
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise TourbillonError(
            f"tourbillon {' '.join(args)} produced invalid JSON: "
            f"{proc.stderr.strip() or e}"
        ) from e

    _cache[key] = (now, data)
    return data


def get_status():
    return run_json("status")


def get_hosts():
    return run_json("hosts", "status")


def get_repos():
    return run_json("repos", "status")

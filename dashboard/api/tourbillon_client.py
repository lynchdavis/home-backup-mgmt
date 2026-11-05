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


def set_host_mail(name: str, enabled: bool) -> None:
    """Write path -- shells out to `tourbillon hosts set-mail`, the actual
    config writer (see bin/tourbillon's set_host_toml_bool()), never edits
    configs/hosts/*.toml directly. Invalidates the cached `hosts status`
    result so the /config page's own re-fetch reflects the change
    immediately instead of waiting out CACHE_TTL."""
    proc = subprocess.run(
        [str(TOURBILLON_BIN), "hosts", "set-mail", name, "on" if enabled else "off"],
        capture_output=True, text=True, timeout=10,
    )
    if proc.returncode != 0:
        raise TourbillonError(
            f"tourbillon hosts set-mail {name} {'on' if enabled else 'off'} "
            f"failed: {proc.stderr.strip() or proc.stdout.strip()}"
        )
    _cache.pop("hosts status", None)


def discover_repos() -> dict:
    """Write path -- shells out to `tourbillon repos discover`. Network
    calls to GitHub/Bitbucket, so a longer timeout than the read routes.
    Always commits (matches the CLI's own default) -- invalidates the
    cached `repos status` result so newly-discovered repos show up
    immediately instead of waiting out CACHE_TTL."""
    proc = subprocess.run(
        [str(TOURBILLON_BIN), "repos", "discover", "--json"],
        capture_output=True, text=True, timeout=60,
    )
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise TourbillonError(
            f"tourbillon repos discover produced invalid JSON: {proc.stderr.strip() or e}"
        ) from e
    _cache.pop("repos status", None)
    return data


def add_repo(slug: str, clone_url: str) -> str:
    """Write path -- shells out to `tourbillon repos add`. That command has
    no --json mode (a single human-readable confirmation line is all there
    is), so this just returns stdout on success and raises on failure."""
    proc = subprocess.run(
        [str(TOURBILLON_BIN), "repos", "add", slug, clone_url],
        capture_output=True, text=True, timeout=20,
    )
    if proc.returncode != 0:
        raise TourbillonError(proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}")
    _cache.pop("repos status", None)
    return proc.stdout.strip()


# ---------- Manual backups (ADR-010) ----------
# The dashboard never runs a sync itself: its unit has NoNewPrivileges=true,
# which blocks the `sudo -n rsync` a host sync needs. These only queue a
# request (`tourbillon hosts request` / `repos request`) for
# tourbillon-requests.service to drain, and read back its status files.

def _run_cli(*args: str, timeout: int = 20) -> str:
    proc = subprocess.run(
        [str(TOURBILLON_BIN), *args], capture_output=True, text=True, timeout=timeout,
    )
    if proc.returncode != 0:
        raise TourbillonError(proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}")
    return proc.stdout


def request_host_backup(name: str, label: str) -> dict:
    """Queue a forced sync + manual snapshot for one host. Idempotent while
    one is already queued/running (the result says `already_active`)."""
    data = json.loads(_run_cli("hosts", "request", name, "--label", label, "--json"))
    _cache.pop("hosts status", None)
    return data


def request_repos_sync(slug: str | None) -> dict:
    args = ["repos", "request", "--json"] + (["--name", slug] if slug else [])
    return json.loads(_run_cli(*args))


def get_request_status(kind: str, target: str | None):
    """Uncached -- it's a small state-file read, and the polling cells need
    to see a status change within one poll, not one CACHE_TTL."""
    args = ["requests", "status", "--kind", kind, "--json"]
    args += ["--target", target] if target else ["--all"]
    return json.loads(_run_cli(*args))


def get_latest_repos_request():
    rows = json.loads(_run_cli("requests", "status", "--kind", "repos", "--json"))
    return rows[0] if rows else None


def get_manual_snapshots() -> list:
    return json.loads(_run_cli("hosts", "snapshots", "--json"))


def delete_manual_snapshot(name: str, snapshot: str) -> None:
    _run_cli("hosts", "snapshot-rm", name, snapshot, timeout=60)

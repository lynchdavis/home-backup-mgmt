#!/usr/bin/env python3
"""dump-saratoga-config.py — pull current TrueNAS replication config to configs/.

Replaces the old REST-based dump-saratoga-config.sh (see CHANGELOG.md
2026-09-19 / GAPS.md §4.4): TrueNAS is dropping the /api/v2.0 REST
translation layer in 26.04 in favor of JSON-RPC 2.0 over WebSocket. This
uses the official `truenas_api_client` library instead of hand-rolled
JSON-RPC/websocket code.

Writes the same four files the old script did:
    configs/replication-tasks.json
    configs/snapshot-tasks.json
    configs/ssh-connections.json
    configs/ssh-keypairs.sanitized.json   (private keys redacted)

Requires: TRUENAS_API_TOKEN env var, and bin/.venv (see bin/requirements.txt
— truenas_api_client isn't on PyPI, installed from GitHub, pinned to the
tag matching saratoga's TrueNAS version).

Usage (the shebang's system python3 does NOT have truenas_api_client —
always invoke via this script's own venv):
    source ~/.config/saratoga/env
    bin/.venv/bin/python3 bin/dump-saratoga-config.py

Auth note: this client is pinned to tag TS-25.10.3.1, matching saratoga's
current TrueNAS SCALE version, which predates the SCRAM/PLAIN auth-
mechanism split introduced for TrueNAS 26+ (see api_client's own
auth_api_key.py on master, absent in this older tag). It authenticates via
the simpler pre-26 `auth.login_with_api_key` — one positional argument, no
username, no mechanism choice. When saratoga is eventually upgraded to
26.04+, re-pin bin/requirements.txt to the matching tag and this will very
likely need the newer login_with_api_key(username, key,
auth_mechanism=...) call shape instead. Check api_client's CHANGELOG at
that time rather than assuming this still works as-is.
"""
import json
import os
import sys
from pathlib import Path

from truenas_api_client import Client

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIGS = REPO_ROOT / "configs"
URI = os.environ.get("SARATOGA_WS_URI", "wss://192.168.0.60/api/current")


def _json_default(obj):
    """The client deserializes some TrueNAS date/time fields into native
    datetime objects (see truenas_api_client.ejson); the old REST+jq
    version saw them pre-serialized as ISO strings. Match that on-disk
    format rather than introducing unrelated diff noise."""
    if hasattr(obj, "isoformat"):
        return obj.isoformat()
    raise TypeError(f"Object of type {type(obj).__name__} is not JSON serializable")


def dump_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, indent=2, default=_json_default))


def main() -> int:
    token = os.environ.get("TRUENAS_API_TOKEN")
    if not token:
        print(
            "ERROR: Set TRUENAS_API_TOKEN env var first "
            "(Credentials -> Local Users -> root -> API Keys).",
            file=sys.stderr,
        )
        return 1

    CONFIGS.mkdir(parents=True, exist_ok=True)

    with Client(uri=URI, verify_ssl=False) as c:
        if not c.call("auth.login_with_api_key", token):
            print("ERROR: TrueNAS rejected the API key.", file=sys.stderr)
            return 1

        print("==> replication tasks")
        dump_json(CONFIGS / "replication-tasks.json", c.call("replication.query"))

        print("==> snapshot tasks")
        dump_json(CONFIGS / "snapshot-tasks.json", c.call("pool.snapshottask.query"))

        print("==> SSH connections")
        ssh_connections = c.call(
            "keychaincredential.query", [["type", "=", "SSH_CREDENTIALS"]]
        )
        dump_json(CONFIGS / "ssh-connections.json", ssh_connections)

        print("==> SSH keypairs (private keys redacted)")
        ssh_keypairs = c.call(
            "keychaincredential.query", [["type", "=", "SSH_KEY_PAIR"]]
        )
        for entry in ssh_keypairs:
            entry["attributes"]["private_key"] = "<REDACTED - regenerable in TrueNAS UI>"
        dump_json(CONFIGS / "ssh-keypairs.sanitized.json", ssh_keypairs)

    print()
    print("Done. Diff with git to see what changed:")
    print(f"  git -C {REPO_ROOT} diff configs/")
    return 0


if __name__ == "__main__":
    sys.exit(main())

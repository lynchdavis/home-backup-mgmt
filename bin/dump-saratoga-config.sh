#!/usr/bin/env bash
# dump-saratoga-config.sh — pull current TrueNAS replication config to configs/.
#
# Writes:
#   configs/replication-tasks.json
#   configs/snapshot-tasks.json
#   configs/ssh-connections.json
#   configs/ssh-keypairs.sanitized.json   (private keys redacted)
#
# Requires: TRUENAS_API_TOKEN env var, jq + curl.

set -euo pipefail

: "${TRUENAS_API_TOKEN:?Set TRUENAS_API_TOKEN env var first (Credentials -> Local Users -> root -> API Keys).}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGS="${REPO_ROOT}/configs"
URL="${SARATOGA_API_URL:-https://192.168.0.60/api/v2.0}"

mkdir -p "$CONFIGS"

auth() {
  curl -sk -H "Authorization: Bearer $TRUENAS_API_TOKEN" "$@"
}

echo "==> replication tasks"
auth "$URL/replication" | jq '.' > "$CONFIGS/replication-tasks.json"

echo "==> snapshot tasks"
auth "$URL/pool/snapshottask" | jq '.' > "$CONFIGS/snapshot-tasks.json"

echo "==> SSH connections"
auth "$URL/keychaincredential?type=SSH_CREDENTIALS" | jq '.' > "$CONFIGS/ssh-connections.json"

echo "==> SSH keypairs (private keys redacted)"
auth "$URL/keychaincredential?type=SSH_KEY_PAIR" \
  | jq '[.[] | .attributes.private_key = "<REDACTED - regenerable in TrueNAS UI>"]' \
  > "$CONFIGS/ssh-keypairs.sanitized.json"

echo
echo "Done. Diff with git to see what changed:"
echo "  git -C $REPO_ROOT diff configs/"

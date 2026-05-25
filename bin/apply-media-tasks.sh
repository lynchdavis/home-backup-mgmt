#!/usr/bin/env bash
# apply-media-tasks.sh — create the media snapshot + replication tasks on
# saratoga via TrueNAS API. Mirrors the tank task pattern.
#
# Requires:
#   - TRUENAS_API_TOKEN env var (Credentials -> Local Users -> root -> API Keys)
#   - jq + curl on this host (kodiak)
#   - configs/templates/snapshot-task-media.json
#   - configs/templates/replication-task-media.json
#
# Idempotency: NOT idempotent. Re-running creates duplicate tasks. Use
# dump-saratoga-config.sh afterward to see current state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="${REPO_ROOT}/configs/templates"
URL="https://192.168.0.60/api/v2.0"

: "${TRUENAS_API_TOKEN:?Set TRUENAS_API_TOKEN env var first.}"

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sk -X "$method" \
      -H "Authorization: Bearer $TRUENAS_API_TOKEN" \
      -H 'Content-Type: application/json' \
      -d "$body" "${URL}${path}"
  else
    curl -sk -X "$method" \
      -H "Authorization: Bearer $TRUENAS_API_TOKEN" \
      "${URL}${path}"
  fi
}

echo "=== 1. Create media periodic snapshot task ==="
SNAP_RESPONSE=$(api POST /pool/snapshottask "$(cat ${TEMPLATES}/snapshot-task-media.json)")
echo "$SNAP_RESPONSE" | jq '.'

SNAP_ID=$(echo "$SNAP_RESPONSE" | jq -r '.id // empty')
if [ -z "$SNAP_ID" ]; then
  echo "FAIL: could not extract snapshot-task id; aborting before creating replication task."
  exit 1
fi
echo "  -> snapshot task id: $SNAP_ID"

echo
echo "=== 2. Create media replication task (referencing snapshot task id $SNAP_ID) ==="
REPL_BODY=$(sed "s/SNAPSHOT_TASK_ID/${SNAP_ID}/" ${TEMPLATES}/replication-task-media.json)
REPL_RESPONSE=$(api POST /replication "$REPL_BODY")
echo "$REPL_RESPONSE" | jq '.'

REPL_ID=$(echo "$REPL_RESPONSE" | jq -r '.id // empty')
if [ -z "$REPL_ID" ]; then
  echo "FAIL: could not extract replication-task id."
  exit 1
fi

echo
echo "================ done ================"
echo "snapshot task id: $SNAP_ID  (media, recursive, 2-week lifetime, daily @ 02:00)"
echo "replication task id: $REPL_ID  (media -> backups-00/saratoga/media)"
echo
echo "Replication will run automatically with the snapshot task."
echo "To kick off the first seed manually:"
echo "  curl -sk -X POST -H \"Authorization: Bearer \$TRUENAS_API_TOKEN\" \\"
echo "    ${URL}/replication/id/${REPL_ID}/run"

#!/usr/bin/env bash
# restructure-snapshot-naming.sh — one-shot structural fix for the
# snapshot-task naming collision documented in PLAYBOOK.md
# ("Snapshot-task scope/schedule collisions").
#
# What it does:
#   - Renames snapshot task 6 (tank recursive)  schema -> auto-tank-%Y-%m-%d_%H-%M
#     and moves its minute back to 0 (the 02:05 offset was the original workaround).
#   - Renames snapshot task 7 (media recursive) schema -> auto-media-%Y-%m-%d_%H-%M.
#   - Adds also_include_naming_schema=["auto-%Y-%m-%d_%H-%M"] to replication tasks
#     1 (tank) and 2 (media) so they can match the existing old-schema snapshots
#     during the transition. Once the old snapshots prune (longest applicable
#     retention = 2 weeks), drop the also_include entries in a follow-up commit.
#
# Idempotent: re-running after success is a no-op.
#
# Requires: TRUENAS_API_TOKEN env var, SARATOGA_API_URL env var, jq, curl.
#   Source ~/.config/saratoga/env first.

set -euo pipefail

: "${TRUENAS_API_TOKEN:?source ~/.config/saratoga/env first}"
: "${SARATOGA_API_URL:?source ~/.config/saratoga/env first}"

auth() {
  curl -sk \
    -H "Authorization: Bearer $TRUENAS_API_TOKEN" \
    -H 'Content-Type: application/json' \
    "$@"
}

OLD_SCHEMA='auto-%Y-%m-%d_%H-%M'
TANK_NEW_SCHEMA='auto-tank-%Y-%m-%d_%H-%M'
MEDIA_NEW_SCHEMA='auto-media-%Y-%m-%d_%H-%M'

patch_if_needed() {
  local resource="$1" id="$2" field="$3" want="$4"
  local current
  current=$(auth "${SARATOGA_API_URL}/${resource}/id/${id}" | jq -r ".${field}")
  if [ "$current" = "$want" ]; then
    echo "  [$resource id=$id] $field already = '$want' (skip)"
    return 0
  fi
  echo "  [$resource id=$id] $field: '$current' -> '$want'"
  auth -X PUT "${SARATOGA_API_URL}/${resource}/id/${id}" \
    -d "$(jq -n --arg val "$want" "{$field: \$val}")" \
    | jq -r ".${field} // .error // \"<unexpected response>\""
}

patch_field_raw() {
  # Same as patch_if_needed but for non-string fields (arrays, etc.).
  local resource="$1" id="$2" field="$3" want_json="$4"
  local current_json
  current_json=$(auth "${SARATOGA_API_URL}/${resource}/id/${id}" | jq ".${field}")
  if [ "$current_json" = "$want_json" ]; then
    echo "  [$resource id=$id] $field already = $want_json (skip)"
    return 0
  fi
  echo "  [$resource id=$id] $field: $current_json -> $want_json"
  auth -X PUT "${SARATOGA_API_URL}/${resource}/id/${id}" \
    -d "$(jq -n --argjson val "$want_json" "{$field: \$val}")" \
    | jq ".${field}"
}

patch_minute() {
  # Schedule is nested: schedule.minute. Need to send the whole schedule object.
  local id="$1" want_minute="$2"
  local cur
  cur=$(auth "${SARATOGA_API_URL}/pool/snapshottask/id/${id}" | jq '.schedule')
  local cur_min
  cur_min=$(echo "$cur" | jq -r '.minute')
  if [ "$cur_min" = "$want_minute" ]; then
    echo "  [pool/snapshottask id=$id] schedule.minute already = '$want_minute' (skip)"
    return 0
  fi
  local new
  new=$(echo "$cur" | jq --arg m "$want_minute" '.minute = $m')
  echo "  [pool/snapshottask id=$id] schedule.minute: '$cur_min' -> '$want_minute'"
  auth -X PUT "${SARATOGA_API_URL}/pool/snapshottask/id/${id}" \
    -d "$(jq -n --argjson sched "$new" '{schedule: $sched}')" \
    | jq '.schedule'
}

echo "================ before ================"
auth "${SARATOGA_API_URL}/pool/snapshottask" \
  | jq '.[] | select(.id==6 or .id==7) | {id, dataset, naming_schema, minute: .schedule.minute, hour: .schedule.hour}'
auth "${SARATOGA_API_URL}/replication" \
  | jq '.[] | {id, name, also_include_naming_schema}'
echo

echo "================ applying changes ================"
echo "1. Rename snapshot task 6 (tank recursive) schema:"
patch_if_needed pool/snapshottask 6 naming_schema "$TANK_NEW_SCHEMA"

echo "2. Reset snapshot task 6 minute to 0 (was 5 as the collision workaround):"
patch_minute 6 0

echo "3. Rename snapshot task 7 (media recursive) schema:"
patch_if_needed pool/snapshottask 7 naming_schema "$MEDIA_NEW_SCHEMA"

echo "4. Add also_include_naming_schema to replication task 1 (tank):"
patch_field_raw replication 1 also_include_naming_schema "[\"${OLD_SCHEMA}\"]"

echo "5. Add also_include_naming_schema to replication task 2 (media):"
patch_field_raw replication 2 also_include_naming_schema "[\"${OLD_SCHEMA}\"]"
echo

echo "================ after ================"
auth "${SARATOGA_API_URL}/pool/snapshottask" \
  | jq '.[] | select(.id==6 or .id==7) | {id, dataset, naming_schema, minute: .schedule.minute, hour: .schedule.hour}'
auth "${SARATOGA_API_URL}/replication" \
  | jq '.[] | {id, name, also_include_naming_schema}'

echo
echo "================ done ================"
echo "Reminder: drop the also_include_naming_schema entries in a follow-up commit"
echo "after 2026-06-08 (longest applicable retention = 2 weeks). At that point,"
echo "all old auto-* snapshots from tasks 6/7 will have aged out via natural"
echo "retention; no more incremental-basis lookup will need the old schema."

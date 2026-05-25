#!/usr/bin/env bash
# check-saratoga-replication.sh — passive monitor: did a saratoga snapshot
# land on kodiak in the last 26 hours? Recovers the "kodiak owns backup
# health" property that the push architecture structurally gives up.
#
# Exit 0 = OK (fresh snapshots present).
# Exit 1 = stale (no fresh snapshot on at least one expected tree).
# Exit 2 = ZFS or pool error.
#
# Wire as a cron entry on kodiak for periodic heartbeat:
#   0 8 * * * /home/ldavis/development/server-backups/bin/check-saratoga-replication.sh
#   (cron mails any output / non-zero exit to MAILTO)

set -uo pipefail

POOL=backups-00
TREES=(
  "${POOL}/saratoga/tank"
  "${POOL}/saratoga/media"
)
STALE_HOURS=26                   # tolerance: one missed daily run + slack
STALE_SECONDS=$((STALE_HOURS * 3600))
NOW=$(date +%s)
STALE_FOUND=0

# Pool sanity first.
if ! zpool list "$POOL" >/dev/null 2>&1; then
  echo "ERROR: pool $POOL not imported"
  exit 2
fi

for tree in "${TREES[@]}"; do
  # Find newest snapshot under this tree (any depth).
  latest=$(zfs list -t snapshot -o name,creation -p -r "$tree" 2>/dev/null \
    | awk 'NR>1 {if ($NF > max) {max=$NF; name=$1}} END {if (name) print name, max}')

  if [ -z "$latest" ]; then
    echo "STALE: $tree — no snapshots at all"
    STALE_FOUND=1
    continue
  fi

  name=$(echo "$latest" | awk '{print $1}')
  ts=$(echo "$latest" | awk '{print $2}')
  age=$((NOW - ts))
  age_h=$((age / 3600))

  if [ $age -gt $STALE_SECONDS ]; then
    echo "STALE: $tree — newest snapshot is ${age_h}h old: $name"
    STALE_FOUND=1
  fi
done

if [ $STALE_FOUND -eq 0 ]; then
  # Quiet on success — cron only mails non-empty output by default.
  exit 0
fi
exit 1

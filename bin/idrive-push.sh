#!/usr/bin/env bash
# idrive-push.sh — STUB. Daily wrapper around iDrive Personal's CLI
# (idevsutil_dedup) to push each configured backup set.
#
# This script is a placeholder created BEFORE iDrive is installed.
# The exact CLI flags (`--backup`, `--setname`, etc.) must be
# calibrated against `/opt/idrive/idevsutil_dedup --help` AFTER
# install. Don't wire to cron until verified — placeholder will
# exit non-zero so cron mail surfaces the misconfiguration.
#
# Per ADR-005, the cron entry will be:
#   0 3 * * *  bin/idrive-push.sh
#
# Operator runs as themselves; the iDrive client is installed system-wide
# (typically /opt/idrive) and its registered account/encryption key
# is the relevant credential — not OS-level user.

set -uo pipefail

if [ ! -x /opt/idrive/idevsutil_dedup ]; then
    echo "ERROR: /opt/idrive/idevsutil_dedup not found." >&2
    echo "Run bin/install-idrive-on-kodiak.sh first, then calibrate this script." >&2
    exit 2
fi

# ── PLACEHOLDER — replace each SETNAME with the real --setname value
#    once `idevsutil_dedup --list-backupset` confirms the registered
#    names. Per ADR-005 backup-set scope:

SETS=(
    "photos"      # /kodiak00/backups-00/saratoga/tank/archive/photography
    "documents"   # /kodiak00/backups-00/saratoga/tank/archive/{books,…,software}
    "active"      # /kodiak00/backups-00/saratoga/tank/active
    "hosts"       # /kodiak00/backups-00/hosts
)

# Daily push of all sets. Hard-failure on any set bubbles up to cron mail.
# Soft warnings (partial transfer, slow link) are noted but don't fail
# the whole run.
for SET in "${SETS[@]}"; do
    echo "================ iDrive push: $SET — $(date) ================"
    # PLACEHOLDER — real flags TBD after install:
    #   sudo /opt/idrive/idevsutil_dedup --backup --setname "$SET" --quiet
    echo "STUB: would run idevsutil_dedup --backup --setname $SET"
    # exit 1 deliberately so this stub fails if accidentally cron-wired
done

echo "idrive-push.sh stub — calibrate against `idevsutil_dedup --help` then" >&2
echo "remove the deliberate non-zero exit at the bottom of this script." >&2
exit 1

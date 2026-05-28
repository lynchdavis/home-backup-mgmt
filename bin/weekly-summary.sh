#!/usr/bin/env bash
# weekly-summary.sh — kodiak backup health digest, Sunday-morning delivery.
#
# Two-stage pipeline:
#   1. `tourbillon status --json`     — gathers structured data
#   2. `weekly-summary-build.py`      — renders multipart MIME email
#                                       (text/plain + text/html with real
#                                       tables, color-coded status badges)
# Output piped to msmtp for delivery to the operator's external gmail.
#
# Subject is meaningful by default ("kodiak weekly backup summary
# YYYY-MM-DD") with a "— ATTENTION" suffix if any subsystem reports
# hard failures, or "— caveats" for soft warnings (e.g., a host is
# overdue but cron will catch it on the next firing).
#
# Companion to the on-failure cron mails: those tell you "something just
# broke." This is a heartbeat — absence is itself a signal that cron or
# msmtp is down.
#
# Wire as a cron entry on ldavis:
#   0 8 * * 0  /home/ldavis/development/server-backups/bin/weekly-summary.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SARATOGA_ENV="$HOME/.config/saratoga/env"
RECIPIENT="lynchdavis0@gmail.com"

if [ -f "$SARATOGA_ENV" ]; then
    # shellcheck source=/dev/null
    . "$SARATOGA_ENV"
fi

# Two-stage pipeline. tourbillon emits JSON; the Python helper renders
# it into a complete MIME email; msmtp ships it. Each stage is
# independently testable.
"$REPO_ROOT/bin/tourbillon" status --json \
    | "$REPO_ROOT/bin/weekly-summary-build.py" \
    | msmtp "$RECIPIENT"

exit $?

#!/usr/bin/env bash
# weekly-summary.sh — kodiak backup health digest, delivered Sunday mornings.
#
# Companion to the on-failure cron mails (sync errors, restore-drill
# failures, saratoga staleness): those tell you "something broke now";
# this tells you "everything is still alive on the cadence I expect."
# Most weeks the digest is reassurance; the failure mode it specifically
# addresses is "you haven't heard from cron in 3 weeks because cron
# itself is dead and the on-failure mails never fired."
#
# Self-mails via msmtp so the Subject line is meaningful (not cron's
# default "Cron <ldavis@kodiak> ...").  Cron should just invoke this
# script and produce no output of its own.
#
# Run by the operator (ldavis). Needs ~/.config/saratoga/env to source
# the TrueNAS API token so the saratoga section of `tourbillon status`
# isn't blank.
#
# Wire as a cron entry on ldavis for Sunday 08:00:
#   0 8 * * 0  /home/ldavis/development/server-backups/bin/weekly-summary.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SARATOGA_ENV="$HOME/.config/saratoga/env"
RECIPIENT="lynchdavis0@gmail.com"
SUBJECT="kodiak weekly backup summary $(date +%Y-%m-%d)"

if [ -f "$SARATOGA_ENV" ]; then
    # shellcheck source=/dev/null
    . "$SARATOGA_ENV"
fi

{
    echo "From: kodiak <ldavis@kodiak.davis.home.org>"
    echo "To: $RECIPIENT"
    echo "Subject: $SUBJECT"
    echo ""
    echo "Weekly heartbeat from kodiak. If you got this, cron + msmtp are alive."
    echo ""

    # ---- one-screen status rollup ----
    echo "================ tourbillon status ================"
    "$REPO_ROOT/bin/tourbillon" status
    echo ""

    # ---- only the unhealthy bits ----
    echo "================ recent issues (only non-ok subsystems) ================"
    echo "--- hosts ---"
    "$REPO_ROOT/bin/tourbillon" hosts issues || true
    echo ""
    echo "--- repos ---"
    "$REPO_ROOT/bin/tourbillon" repos issues || true
    echo ""

    # ---- outbound mail health ----
    echo "================ msmtp log tail (proves outbound mail is flowing) ================"
    if [ -f "$HOME/.msmtp.log" ]; then
        tail -5 "$HOME/.msmtp.log"
    else
        echo "(no ~/.msmtp.log yet — msmtp may not have sent anything)"
    fi
    echo ""

    echo "================ end of weekly summary ================"
} | msmtp "$RECIPIENT"

# If msmtp failed, surface the exit code via cron mail (cron will email
# whatever stderr we leave behind).
exit $?

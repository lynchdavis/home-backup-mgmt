#!/usr/bin/env bash
# mail-on-output.sh — run a cron command, send a useful-Subject email
# via msmtp if the command produces any output OR exits non-zero.
# Silent otherwise (cron-friendly).
#
# Replaces cron's default "Cron <user@host> command_text..." subject
# with something readable like "kodiak: hosts sync FAILED (exit 1)" or
# "kodiak: hosts sync — output captured (exit 0)".
#
# Usage in a crontab:
#   <schedule>  <env-setup if any> && /path/to/mail-on-output.sh "<tag>" <cmd> [args...]
#
# Example:
#   */30 * * * * . $HOME/.config/tourbillon/env && \
#       /home/ldavis/development/server-backups/bin/mail-on-output.sh \
#       "repos sync" \
#       /home/ldavis/development/server-backups/bin/tourbillon repos sync --quiet
#
# The wrapper:
#   - Captures combined stdout+stderr.
#   - Mails ONLY if the command produced output or exited non-zero.
#   - Preserves the wrapped command's exit code (so cron still sees the
#     real result and `set -e` callers see real failures).
#
# Sends FROM kodiak's hostname TO a hard-coded operator address.

set -uo pipefail

if [ $# -lt 2 ]; then
    cat >&2 <<USAGE
usage: $0 <tag> <command> [args...]

  <tag>     short label for the Subject line ("repos sync", "saratoga check", …)
  <command> + args  the actual cron command to run

The wrapper silently runs <command> and only sends mail if it produces
output or exits non-zero.
USAGE
    exit 2
fi

TAG="$1"
shift

RECIPIENT="lynchdavis0@gmail.com"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"

# Run the wrapped command, capture combined output + exit code.
OUTPUT=$("$@" 2>&1)
RC=$?

# Silent if exit 0 AND no output (the cron-friendly "nothing to say" case).
if [ "$RC" -eq 0 ] && [ -z "$OUTPUT" ]; then
    exit 0
fi

# Decide subject. Failure beats "merely produced output."
if [ "$RC" -ne 0 ]; then
    SUBJECT="${HOST_SHORT}: ${TAG} FAILED (exit ${RC})"
else
    SUBJECT="${HOST_SHORT}: ${TAG} — output captured (exit 0)"
fi

{
    echo "From: ${HOST_SHORT} <${USER:-ldavis}@${HOST_SHORT}.davis.home.org>"
    echo "To: ${RECIPIENT}"
    echo "Subject: ${SUBJECT}"
    echo ""
    echo "Command: $*"
    echo "Tag:     ${TAG}"
    echo "Exit:    ${RC}"
    echo "Host:    $(hostname)"
    echo "User:    $(whoami)"
    echo "When:    $(date)"
    echo ""
    echo "---- output ----"
    echo "${OUTPUT}"
} | msmtp "${RECIPIENT}"

exit $RC

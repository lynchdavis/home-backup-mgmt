#!/usr/bin/env bash
# mail-on-output.sh — run a cron command, send a useful-Subject email
# via msmtp ONLY ON FAILURE (non-zero exit). Silent on success even when
# the wrapped command produces informational output.
#
# Replaces cron's default "Cron <user@host> command_text..." subject
# with a readable Subject like "kodiak: hosts sync FAILED (exit 1)".
#
# Default behavior (the right default for "I just want to know when
# something breaks"):
#   exit 0 → silent. ANY output is discarded.
#   exit non-zero → mail with the full output captured.
#
# Opt-in verbose mode with --mail-on-output (or -V) BEFORE the tag:
#   exit 0 + output present → mail with subject "... — output captured (exit 0)"
#   Useful when you DO want a confirming email per cron firing.
#
# Usage in a crontab:
#   <schedule>  <env-setup> && /path/to/mail-on-output.sh "<tag>" <cmd> [args...]
# Or verbose:
#   <schedule>  <env-setup> && /path/to/mail-on-output.sh -V "<tag>" <cmd> [args...]
#
# Example:
#   */30 * * * * . $HOME/.config/tourbillon/env && \
#       /home/ldavis/development/server-backups/bin/mail-on-output.sh \
#       "repos sync" \
#       /home/ldavis/development/server-backups/bin/tourbillon repos sync --quiet
#
# The wrapper:
#   - Captures combined stdout+stderr.
#   - Decides whether to mail based on exit code (+ --mail-on-output flag).
#   - Preserves the wrapped command's exit code (so cron still sees the
#     real result and `set -e` callers see real failures).
#
# Sends FROM kodiak's hostname TO a hard-coded operator address.

set -uo pipefail

# Parse optional --mail-on-output / -V flag
MAIL_ON_OUTPUT=0
if [ "${1:-}" = "--mail-on-output" ] || [ "${1:-}" = "-V" ]; then
    MAIL_ON_OUTPUT=1
    shift
fi

if [ $# -lt 2 ]; then
    cat >&2 <<USAGE
usage: $0 [--mail-on-output | -V] <tag> <command> [args...]

  --mail-on-output   (or -V) opt-in to verbose mode — mail even on exit 0
                     when the command produced output. Default: silent on
                     exit 0 regardless of output.

  <tag>     short label for the Subject line ("repos sync", "saratoga check", …)
  <command> + args  the actual cron command to run

The wrapper runs <command>, captures combined stdout+stderr, and:
  - mails ALWAYS on non-zero exit (failure)
  - mails only on success-with-output if --mail-on-output was passed
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

# Decide whether to mail.
SHOULD_MAIL=0
if [ "$RC" -ne 0 ]; then
    SHOULD_MAIL=1   # failure — always mail
elif [ "$MAIL_ON_OUTPUT" -eq 1 ] && [ -n "$OUTPUT" ]; then
    SHOULD_MAIL=1   # opt-in verbose — mail success-with-output
fi

if [ "$SHOULD_MAIL" -eq 0 ]; then
    exit "$RC"
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

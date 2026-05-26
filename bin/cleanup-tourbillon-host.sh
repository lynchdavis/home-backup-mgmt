#!/usr/bin/env bash
# cleanup-tourbillon-host.sh — undo what bootstrap-tourbillon-user.sh did
# on a linux target. Returns the host to its pre-bootstrap state so the
# bootstrap scripts can be re-run cleanly.
#
# Removes (in order):
#   1. /etc/sudoers.d/tourbillon      (removed FIRST — see comment below)
#   2. any running processes owned by `tourbillon`
#   3. the tourbillon user account
#   4. /var/lib/tourbillon (leftover home dir, if userdel -r didn't catch it)
#   5. /tmp/bootstrap-tourbillon-user.sh (the operator's scp'd copy)
#
# Does NOT touch the operator's authorized_keys, /etc/hosts, or any
# file outside what bootstrap-tourbillon-user.sh installed. Idempotent —
# safe to run on a host that's already partly clean.
#
# Usage:
#   sudo bash cleanup-tourbillon-host.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0)" >&2
    exit 2
fi

USER_NAME="tourbillon"
SUDOERS_FILE="/etc/sudoers.d/tourbillon"
HOME_DIR="/var/lib/tourbillon"

echo "================ cleanup-tourbillon-host.sh — $(date) ================"

# 1. Sudoers drop-in goes FIRST. If anything below fails, the privileged
#    rsync entry pointing at a (possibly removed) user shouldn't be left
#    sitting in /etc/sudoers.d/.
if [ -f "$SUDOERS_FILE" ]; then
    rm -f "$SUDOERS_FILE"
    echo "  removed $SUDOERS_FILE"
else
    echo "  $SUDOERS_FILE not present (nothing to remove)"
fi

# 2. Kill any active tourbillon processes (rsync mid-flight, idle login shells)
if id "$USER_NAME" >/dev/null 2>&1; then
    if pgrep -u "$USER_NAME" >/dev/null 2>&1; then
        echo "  killing active processes owned by $USER_NAME ..."
        pkill -u "$USER_NAME" 2>/dev/null || true
        sleep 1
    fi
fi

# 3. Remove the user. Try -r first (also removes home + mail spool); fall
#    back to plain userdel if home removal fails (we clean up home below).
if id "$USER_NAME" >/dev/null 2>&1; then
    userdel -r "$USER_NAME" 2>/dev/null \
        || userdel -f "$USER_NAME" 2>/dev/null \
        || userdel "$USER_NAME"
    echo "  removed user $USER_NAME"
else
    echo "  user $USER_NAME does not exist (nothing to remove)"
fi

# 4. Belt-and-suspenders: nuke any leftover home dir (userdel -r can fail
#    silently on some systems if files are open or mtab is weird).
if [ -d "$HOME_DIR" ]; then
    rm -rf "$HOME_DIR"
    echo "  removed leftover $HOME_DIR"
fi

# 5. The operator's scp'd copy of the bootstrap script
if [ -f /tmp/bootstrap-tourbillon-user.sh ]; then
    rm -f /tmp/bootstrap-tourbillon-user.sh
    echo "  removed /tmp/bootstrap-tourbillon-user.sh"
fi

echo
echo "================ done — host clean ================"
echo
echo "The host is back to its pre-bootstrap state. When the refactored"
echo "bootstrap scripts are ready, run bootstrap-tourbillon-user.sh"
echo "from scratch — no manual cleanup needed first."

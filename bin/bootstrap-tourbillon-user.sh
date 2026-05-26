#!/usr/bin/env bash
# bootstrap-tourbillon-user.sh — run on a LINUX TARGET HOST as root.
#
# Creates the `tourbillon` system user with a fresh random password
# and the narrow sudoers entry needed for kodiak to pull rsync
# backups. Prints the password so the operator can use it ONCE with
# ssh-copy-id from kodiak (it gets locked immediately after).
#
# After this script:
#   On kodiak, run:  bin/bootstrap-from-kodiak.sh <this-hostname>
#
# Idempotent. Re-running:
#   - leaves an existing user alone (doesn't change shell/home)
#   - generates a fresh password
#   - refreshes the sudoers entry
#
# Usage:
#   sudo bash bootstrap-tourbillon-user.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0)" >&2
    exit 2
fi

USER_NAME="tourbillon"
HOME_DIR="/var/lib/tourbillon"
SHELL_PATH="/bin/bash"

echo "================ bootstrap-tourbillon-user.sh — $(date) ================"

# 1. Create the user (or leave an existing identity alone)
if id "$USER_NAME" >/dev/null 2>&1; then
    echo "user '$USER_NAME' already exists — identity unchanged"
else
    echo "creating user '$USER_NAME' (home=$HOME_DIR shell=$SHELL_PATH) ..."
    useradd -r -m -d "$HOME_DIR" -s "$SHELL_PATH" \
        -c 'kodiak pulls rsync backups as this user (tourbillon)' "$USER_NAME"
fi

# 2. Generate a fresh random password (32 chars alphanumeric)
PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
echo "${USER_NAME}:${PASS}" | chpasswd
# `passwd -u` ensures the account is unlocked in case it was previously locked.
passwd -u "$USER_NAME" >/dev/null 2>&1 || true

# 3. Sudoers drop-in: narrow, NOPASSWD on just what tourbillon needs.
#    - /usr/bin/rsync --server *   for the actual backup pulls
#    - /usr/bin/passwd -l tourbillon  so kodiak can lock the password
#      after key-auth is verified working
SUDOERS_FILE="/etc/sudoers.d/tourbillon"
SUDOERS_TMP="$(mktemp)"
trap 'rm -f "$SUDOERS_TMP"' EXIT

cat > "$SUDOERS_TMP" <<'EOF'
# tourbillon backup user — runs rsync --server on this host when kodiak
# pulls. Also allows passwd -l on itself so kodiak can lock the password
# after key-based auth is verified working.
tourbillon ALL=(root) NOPASSWD: /usr/bin/rsync --server *
tourbillon ALL=(root) NOPASSWD: /usr/bin/passwd -l tourbillon
EOF

if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
    echo "sudoers installed: $SUDOERS_FILE"
else
    echo "ERROR: sudoers entry failed visudo validation — not installed" >&2
    visudo -cf "$SUDOERS_TMP" >&2 || true
    exit 1
fi

cat <<EOF

================ done ================

Next, on kodiak:

    bin/bootstrap-from-kodiak.sh $(hostname -s 2>/dev/null || hostname)

When ssh-copy-id prompts for the tourbillon password, paste:

    $PASS

(this is a one-time bootstrap credential — it gets locked right after
ssh-copy-id verifies key-based auth works).
EOF

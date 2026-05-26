#!/usr/bin/env bash
# bootstrap-backup-user.sh — set up the dedicated `backup` user on a
# LINUX TARGET HOST so kodiak can pull rsync backups via SSH.
#
# Run THIS ON THE TARGET, not on kodiak. Idempotent (re-run safely).
#
# Usage (paste the pubkey from kodiak: cat ~/.ssh/id_ed25519_backup.pub):
#
#   sudo bash bootstrap-backup-user.sh 'ssh-ed25519 AAAA...kodiak-backup'
#
# Or, from kodiak in one shot (requires root SSH to the target first):
#
#   ssh root@<target> 'bash -s' \
#     -- "$(cat ~/.ssh/id_ed25519_backup.pub)" \
#     < bin/bootstrap-backup-user.sh
#
# What it does:
#   1. Creates `backup` system user (home /var/lib/backup, shell /bin/bash).
#   2. Installs the supplied pubkey into ~backup/.ssh/authorized_keys.
#   3. Drops /etc/sudoers.d/backup with NOPASSWD on `rsync --server *` only.
#   4. Validates the sudoers entry via `visudo -cf` before activating it.
#
# After it succeeds, from kodiak:
#   ssh -i ~/.ssh/id_ed25519_backup backup@<target> true
# should succeed without prompting.

set -euo pipefail

PUBKEY="${1:-}"
if [ -z "$PUBKEY" ]; then
    cat >&2 <<EOF
usage: $0 '<ssh-ed25519 ... or ssh-rsa ...>'
       pass the pubkey from kodiak's ~/.ssh/id_ed25519_backup.pub
EOF
    exit 2
fi

# Defensive: the pubkey should start with a recognized type prefix.
case "$PUBKEY" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
    *)
        echo "ERROR: pubkey doesn't start with a recognized type prefix" >&2
        echo "       (expected ssh-ed25519, ssh-rsa, or ecdsa-sha2-*)" >&2
        exit 2
        ;;
esac

# Must be root.
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0 '<pubkey>')" >&2
    exit 2
fi

USER_NAME="backup"
HOME_DIR="/var/lib/backup"
SHELL_PATH="/bin/bash"

echo "================ bootstrap-backup-user.sh — $(date) ================"
echo "  target user:    $USER_NAME"
echo "  home dir:       $HOME_DIR"
echo

# 1. Create user (or note it already exists; we DO NOT change an existing
#    user's shell/home — too disruptive if something already depends on it).
if id "$USER_NAME" >/dev/null 2>&1; then
    echo "user '$USER_NAME' already exists — leaving identity unchanged"
else
    echo "creating user '$USER_NAME' ..."
    useradd -r -m -d "$HOME_DIR" -s "$SHELL_PATH" \
        -c 'kodiak pulls rsync backups as this user' "$USER_NAME"
fi

# 2. ~/.ssh + authorized_keys
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$SSH_DIR"
touch "$AUTH_KEYS"
chown "$USER_NAME:$USER_NAME" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# Idempotent insert: skip if the pubkey is already there.
if grep -qFx "$PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "pubkey already present in $AUTH_KEYS — no-op"
else
    echo "appending pubkey to $AUTH_KEYS"
    echo "$PUBKEY" >> "$AUTH_KEYS"
fi

# 3. Sudoers drop-in: narrow, NOPASSWD, validate before activating.
SUDOERS_FILE="/etc/sudoers.d/backup"
SUDOERS_TMP="$(mktemp)"
trap 'rm -f "$SUDOERS_TMP"' EXIT

cat > "$SUDOERS_TMP" <<'EOF'
# Allow `backup` user to invoke rsync --server with NOPASSWD.
# This is the only command rsync runs on the remote side when kodiak
# pulls. The wildcard on the argument is required because rsync embeds
# the source path. Restricted to --server form — the key can't be
# repurposed to clone code, drop a shell, etc.
backup ALL=(root) NOPASSWD: /usr/bin/rsync --server *
EOF

if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
    echo "sudoers entry installed: $SUDOERS_FILE"
else
    echo "ERROR: sudoers entry failed visudo validation — not installed" >&2
    visudo -cf "$SUDOERS_TMP" >&2 || true
    exit 1
fi

echo
echo "================ done — $(date) ================"
echo
echo "Verify from kodiak:"
echo "    ssh -i ~/.ssh/id_ed25519_backup backup@$(hostname) true"
echo "(should succeed silently, with no password prompt)"

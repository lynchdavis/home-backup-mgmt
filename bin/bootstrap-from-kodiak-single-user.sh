#!/usr/bin/env bash
# bootstrap-from-kodiak-single-user.sh — set up a SINGLE-USER host
# (macOS, Windows, single-user linux) for tourbillon pulls.
#
# Unlike the multi-user flow (bootstrap-from-kodiak.sh + the target-side
# bootstrap-tourbillon-user.sh), there's no dedicated `tourbillon` service
# account on the target. Backups run as the operator's existing user
# account. See doc/ADR-003-host-backups-single-user-mode.md.
#
# Usage:
#   bin/bootstrap-from-kodiak-single-user.sh <hostname-or-ip> <existing-user>
#
# Pre-reqs on the target:
#   - SSH server running and reachable from kodiak.
#   - The <existing-user> account exists (typically the operator's own).
#   - rsync installed (macOS: built-in; Windows: cwRsync or WSL2 rsync).
#
# What this script does:
#   1. Generate a per-host ed25519 keypair on kodiak (no passphrase) at
#      ~/.ssh/id_ed25519_tourbillon_<hostname>.
#   2. ssh-copy-id pushes the public key to <user>@<host>. Interactive:
#      prompts once for the user's existing password.
#   3. Verifies key-based auth works (BatchMode=yes).
#   4. Prints a templated per-host config the operator should drop into
#      configs/hosts/<hostname>.toml.
#
# Idempotent: re-running with an existing key reuses it. ssh-copy-id
# dedupes the pubkey on the target.

set -euo pipefail

HOSTNAME="${1:-}"
USER_ON_TARGET="${2:-}"
if [ -z "$HOSTNAME" ] || [ -z "$USER_ON_TARGET" ]; then
    cat >&2 <<EOF
usage: $0 <hostname-or-ip> <existing-user>

  hostname-or-ip   target host (e.g. mac-mini.local, 192.168.1.42)
  existing-user    user account on the target whose home we'll back up
                   (no service account is created)
EOF
    exit 2
fi

KEY="$HOME/.ssh/id_ed25519_tourbillon_${HOSTNAME}"

echo "================ bootstrap-from-kodiak-single-user.sh — $(date) ================"
echo "  target:  ${USER_ON_TARGET}@${HOSTNAME}"
echo "  key:     ${KEY}"
echo

# 1. Per-host keypair
if [ -f "$KEY" ]; then
    echo "key already exists; reusing"
else
    echo "generating per-host keypair ..."
    ssh-keygen -t ed25519 -f "$KEY" -N '' \
        -C "kodiak -> ${HOSTNAME} single-user pull-key (no passphrase)"
fi
chmod 600 "$KEY"

# 2. ssh-copy-id — interactive password prompt (operator's existing pw)
echo
echo "→ ssh-copy-id will prompt for ${USER_ON_TARGET}@${HOSTNAME}'s existing password."
if ! ssh-copy-id -i "${KEY}.pub" "${USER_ON_TARGET}@${HOSTNAME}"; then
    echo "ERROR: ssh-copy-id failed; key not deployed" >&2
    exit 1
fi

# 3. Verify key-based auth
echo
echo "→ verifying key-based auth (BatchMode=yes) ..."
if ! ssh -i "$KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "${USER_ON_TARGET}@${HOSTNAME}" 'true'; then
    cat >&2 <<EOF

ERROR: key-based auth verification failed. The pubkey may not have landed
correctly. Try manually:

  ssh -i $KEY ${USER_ON_TARGET}@${HOSTNAME} true

If that prompts for a password, check ~${USER_ON_TARGET}/.ssh/authorized_keys
on the target — the pubkey should be there.
EOF
    exit 1
fi
echo "  ✓ key auth works"

cat <<EOF

================ done ================

Per-host key:  $KEY
Verified:      ssh -i \$KEY ${USER_ON_TARGET}@${HOSTNAME} true (works)

NEXT: drop a per-host config at configs/hosts/${HOSTNAME}.toml.
Template (macOS, single-user):

    host = "${HOSTNAME}"
    ssh_user = "${USER_ON_TARGET}"
    sudo_required = false                 # single-user mode
    paths = ["/Users/${USER_ON_TARGET}"]
    excludes_file = "configs/hosts/excludes/mac-user.txt"

For Windows targets, swap paths to:
    paths = ["/cygdrive/c/Users/${USER_ON_TARGET}"]   # cwRsync
        # or ["/mnt/c/Users/${USER_ON_TARGET}"]        # WSL2 rsync
And excludes_file to configs/hosts/excludes/windows-user.txt.

Then from kodiak:
  bin/tourbillon hosts ping ${HOSTNAME}
  bin/tourbillon hosts sync --force --name ${HOSTNAME}    # first seed

Note: this host's password is the operator's own — NOT locked, NOT
disturbed. Unlike the multi-user flow there's no service-account
password to manage.
EOF

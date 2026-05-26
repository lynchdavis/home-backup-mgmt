#!/usr/bin/env bash
# bootstrap-from-kodiak.sh — finish bootstrapping a linux host into tourbillon's
# host-backup fleet. Run on kodiak after bootstrap-tourbillon-user.sh on the
# target.
#
# 1. Generate a per-host ed25519 keypair (no passphrase) on kodiak.
# 2. ssh-copy-id pushes the public half. Interactive: prompts for the
#    target's tourbillon password (printed by the target-side script).
# 3. Verify key-based auth works.
# 4. Lock the target's tourbillon password (key-only thereafter).
#
# Usage:
#   bin/bootstrap-from-kodiak.sh <hostname-or-ip>
#
# Idempotent: re-running with an existing key reuses it. ssh-copy-id
# dedupes the pubkey on the target. Lock is no-op if already locked.

set -euo pipefail

HOSTNAME="${1:-}"
if [ -z "$HOSTNAME" ]; then
    echo "usage: $0 <hostname-or-ip>" >&2
    exit 2
fi

USER_NAME="tourbillon"
KEY="$HOME/.ssh/id_ed25519_tourbillon_${HOSTNAME}"

echo "================ bootstrap-from-kodiak.sh — $(date) ================"
echo "  target: ${USER_NAME}@${HOSTNAME}"
echo "  key:    ${KEY}"
echo

# 1. Per-host keypair
if [ -f "$KEY" ]; then
    echo "key already exists; reusing"
else
    echo "generating per-host keypair ..."
    ssh-keygen -t ed25519 -f "$KEY" -N '' \
        -C "kodiak -> $HOSTNAME tourbillon pull-key (no passphrase)"
fi
chmod 600 "$KEY"

# 2. ssh-copy-id (interactive — will prompt for the temp password)
echo
echo "→ ssh-copy-id will prompt for the password printed by the target-side script."
if ! ssh-copy-id -i "${KEY}.pub" "${USER_NAME}@${HOSTNAME}"; then
    echo "ERROR: ssh-copy-id failed; not proceeding to verify or lock" >&2
    exit 1
fi

# 3. Verify key-based auth works (must succeed before we lock the password)
echo
echo "→ verifying key-based auth (BatchMode=yes, no password fallback) ..."
if ! ssh -i "$KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "${USER_NAME}@${HOSTNAME}" 'true'; then
    cat >&2 <<EOF

ERROR: key-based auth verification failed. Not locking the password
yet — that would lock you out if the key isn't working.

Try manually:
  ssh -i $KEY ${USER_NAME}@${HOSTNAME} true

If that works, lock by hand:
  ssh -i $KEY ${USER_NAME}@${HOSTNAME} 'sudo passwd -l tourbillon'
EOF
    exit 1
fi
echo "  ✓ key auth works"

# 4. Lock the password — key-only thereafter
echo
echo "→ locking target's tourbillon password (key-only thereafter) ..."
ssh -i "$KEY" \
    -o BatchMode=yes \
    "${USER_NAME}@${HOSTNAME}" 'sudo passwd -l tourbillon' >/dev/null
echo "  ✓ password locked"

cat <<EOF

================ done ================

Per-host key:  $KEY
Verified:      ssh -i \$KEY ${USER_NAME}@${HOSTNAME} true (works)
Password:      locked on target (key-only)

Quick test from kodiak:

    bin/tourbillon hosts ping ${HOSTNAME}

(should print "reachable")
EOF

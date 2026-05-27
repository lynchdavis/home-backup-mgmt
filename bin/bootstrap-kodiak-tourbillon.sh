#!/usr/bin/env bash
# bootstrap-kodiak-tourbillon.sh — one-shot kodiak-side setup of the
# `tourbillon` service user (kodiak A2 runtime, per ADR-004).
#
# Run ONCE per kodiak rebuild. Idempotent — safe to re-run any time.
#
# This script captures everything that's needed kodiak-side so a future
# operator (or a future-you) can stand up the backup machinery on a
# fresh kodiak without having to read every commit message that
# touched things along the way:
#
#   1. Create the `tourbillon` system user (locked password, /var/lib home)
#   2. Install /etc/sudoers.d/tourbillon with narrow NOPASSWD entries
#      for zfs create, chown of dataset mountpoints, and rsync
#   3. Flip ownership of /kodiak00/backups-00/{repos,hosts} to
#      tourbillon — if those datasets exist (PLAYBOOK section 3
#      creates them).
#
# Things this script intentionally does NOT do:
#   - install the per-user crontab (operator decision; see PLAYBOOK)
#   - create ~tourbillon/.config/tourbillon/env (token file; see CREDENTIALS.md)
#   - generate any SSH keys (per-host, via bin/bootstrap-from-kodiak.sh)
#
# Usage:
#   bash bin/bootstrap-kodiak-tourbillon.sh
#
# Run as the operator (ldavis). Uses sudo for the privileged steps.

set -euo pipefail

USER_NAME="tourbillon"
HOME_DIR="/var/lib/tourbillon"
SHELL_PATH="/bin/bash"
SUDOERS_FILE="/etc/sudoers.d/tourbillon"

echo "================ bootstrap-kodiak-tourbillon.sh — $(date) ================"

# ---- 1. Create the system user (idempotent) ---------------------------------
if id "$USER_NAME" >/dev/null 2>&1; then
    echo "  ✓ user '$USER_NAME' already exists (uid $(id -u $USER_NAME))"
else
    echo "→ creating user '$USER_NAME' (system, $HOME_DIR) ..."
    sudo useradd -r -m -d "$HOME_DIR" -s "$SHELL_PATH" \
        -c 'kodiak A2 runtime (repos + host pulls)' "$USER_NAME"
    sudo passwd -l "$USER_NAME" >/dev/null
    echo "  ✓ user created (uid $(id -u $USER_NAME)), password locked"
fi

# Open traversal on the home dir + pre-create the state subtree at 755 so
# the operator (ldavis) can read tourbillon's state files for read-only
# CLI commands (`tourbillon status`, `tourbillon hosts status`, etc.)
# without escalating. Secret subdirs (.ssh/, .config/tourbillon/) get
# created at 700 by bootstrap-from-kodiak.sh and the operator respectively.
echo "→ opening read-traversal on $HOME_DIR for state-subtree visibility ..."
sudo chmod 755 "$HOME_DIR"
sudo install -d -m 755 -o "$USER_NAME" -g "$USER_NAME" \
    "$HOME_DIR/.local" \
    "$HOME_DIR/.local/state" \
    "$HOME_DIR/.local/state/tourbillon" \
    "$HOME_DIR/.local/state/tourbillon/repos" \
    "$HOME_DIR/.local/state/tourbillon/hosts"
echo "  ✓ $HOME_DIR mode 755 (secrets in .ssh/ and .config/ stay 700)"

# ---- 2. Install sudoers drop-in ---------------------------------------------
echo "→ installing $SUDOERS_FILE ..."
SUDOERS_TMP="$(mktemp)"
trap 'rm -f "$SUDOERS_TMP"' EXIT

cat > "$SUDOERS_TMP" <<'EOF'
# tourbillon (kodiak A2 runtime, per ADR-004) needs three privileged
# operations during host backups:
#
#   1. zfs create backups-00/hosts/<host>  — first-seed: child dataset per host
#   2. chown tourbillon:tourbillon <mp>    — first-seed: flip ownership so
#                                            subsequent rsync writes don't
#                                            need further escalation
#   3. rsync                                — every sync: preserve numeric uids
#                                            on the local mirror (rsync
#                                            --numeric-ids needs root to set
#                                            arbitrary owners)
#
# Operations 1 and 2 are narrow to the backups-00/hosts subtree.
# Operation 3 is unrestricted; tourbillon is a service user whose blast
# radius is already bounded by what it's designed to do (move backup data).
tourbillon ALL=(root) NOPASSWD: /usr/sbin/zfs create backups-00/hosts/*
tourbillon ALL=(root) NOPASSWD: /usr/bin/chown tourbillon\:tourbillon /kodiak00/backups-00/hosts/*
tourbillon ALL=(root) NOPASSWD: /usr/bin/rsync
EOF

if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
    echo "  ✓ sudoers installed and parsed OK"
else
    echo "  ERROR: sudoers entry failed validation — not installed" >&2
    sudo visudo -cf "$SUDOERS_TMP" >&2 || true
    exit 1
fi

# ---- 3. Flip ownership of A2 dataset paths to tourbillon --------------------
echo "→ flipping A2 dataset ownership to $USER_NAME ..."
for path in /kodiak00/backups-00/repos /kodiak00/backups-00/hosts; do
    if [ -d "$path" ]; then
        sudo chown -R "$USER_NAME:$USER_NAME" "$path"
        echo "  ✓ $path -> $USER_NAME:$USER_NAME (recursive)"
    else
        echo "  - $path doesn't exist yet (create via PLAYBOOK section 3)"
    fi
done

# ---- done -------------------------------------------------------------------
cat <<EOF

================ done ================

Kodiak-side tourbillon service user ready:
  uid:        $(id -u "$USER_NAME") ($USER_NAME)
  home:       $HOME_DIR
  shell:      $SHELL_PATH  (access via 'sudo -u $USER_NAME -s')
  sudoers:    $SUDOERS_FILE
  datasets:   /kodiak00/backups-00/{repos,hosts} (if present, chowned)

NOT done here — operator's next steps:
  1. Drop ~$USER_NAME/.config/tourbillon/env with GITHUB_TOKEN /
     BITBUCKET_TOKEN entries (see doc/CREDENTIALS.md).
  2. Install tourbillon's crontab:  sudo crontab -u $USER_NAME -
     with the A2 entries (see PLAYBOOK / CHANGELOG for the canonical pair).
  3. For each host you want to back up:
       on the target:  sudo bash bootstrap-tourbillon-user.sh
       on kodiak:      bin/bootstrap-from-kodiak.sh <host> [<ip>]
EOF

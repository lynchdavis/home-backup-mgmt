#!/usr/bin/env bash
# bootstrap-from-kodiak-single-user.sh — set up a SINGLE-USER host
# (macOS, Windows, single-user linux) for tourbillon pulls.
#
# Unlike the multi-user flow (bootstrap-from-kodiak.sh + the target-side
# bootstrap-tourbillon-user.sh), there's no dedicated `tourbillon` service
# account on the target. Backups run as the operator's existing user
# account. See doc/ADR-003-host-backups-single-user-mode.md.
#
# Run on kodiak AS THE OPERATOR (ldavis). Per ADR-004 the per-host SSH key
# lives under the kodiak-side `tourbillon` service user's home, not under
# ldavis — this script uses `sudo` to put it there.
#
# Usage:
#   bin/bootstrap-from-kodiak-single-user.sh <hostname> <existing-user> [<ip>]
#
#   <hostname>      short name (matches configs/hosts/<hostname>.toml)
#   <existing-user> user account on the target whose home we'll back up
#                   (no service account is created)
#   <ip>            optional IPv4. If given and <hostname> doesn't resolve,
#                   '<ip> <hostname>' is appended to kodiak's /etc/hosts.
#
# Pre-reqs on the target:
#   - SSH server running and reachable from kodiak.
#   - The <existing-user> account exists (typically the operator's own).
#   - rsync installed (macOS: built-in; Windows: cwRsync or WSL2 rsync).
#
# What this script does:
#   0. Resolve <hostname>. If it doesn't resolve and <ip> was provided,
#      add the mapping to kodiak's /etc/hosts.
#   1. Generate a per-host ed25519 keypair under ~tourbillon/.ssh/
#      (no passphrase). Owned by the kodiak `tourbillon` user.
#   2. ssh-copy-id pushes the public key to <user>@<host>, auto-accepting
#      the target's host key on first sight. Interactive — prompts once
#      for the user's existing password.
#   3. Verifies key-based auth works (BatchMode=yes).
#   4. Prints a templated per-host config to drop into
#      configs/hosts/<hostname>.toml.
#
# Idempotent: re-running with an existing key reuses it; ssh-copy-id
# dedupes the pubkey; /etc/hosts entry added only if missing.

set -euo pipefail

HOSTNAME="${1:-}"
USER_ON_TARGET="${2:-}"
IP="${3:-}"

if [ -z "$HOSTNAME" ] || [ -z "$USER_ON_TARGET" ]; then
    cat >&2 <<USAGE
usage: $0 <hostname> <existing-user> [<ip>]

  <hostname>       short name (matches configs/hosts/<hostname>.toml)
  <existing-user>  user account on the target whose home we'll back up
                   (no service account is created)
  <ip>             IPv4 (optional). If given and <hostname> doesn't
                   resolve, kodiak's /etc/hosts will be updated.

Example:
  $0 lynchmbp ldavis 192.168.1.42
USAGE
    exit 2
fi

KODIAK_SVC_USER="tourbillon"
TB_HOME="/var/lib/tourbillon"
KEY="${TB_HOME}/.ssh/id_ed25519_tourbillon_${HOSTNAME}"

# accept-new = TOFU done right: auto-trust on first sight, reject on
# change. Applied to every SSH this script issues.
SSH_OPTS=( -o "StrictHostKeyChecking=accept-new" )

echo "================ bootstrap-from-kodiak-single-user.sh — $(date) ================"
echo "  target:  ${USER_ON_TARGET}@${HOSTNAME}"
echo "  key:     ${KEY}"
echo "  ip arg:  ${IP:-(none)}"
echo

# Repo root — used by preflight to find configs/hosts/<host>.toml
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- preflight ---------------------------------------------------------------
# Verify every precondition BEFORE we touch the system or the target.
preflight() {
    local failed=0
    echo "→ preflight checks..."

    # 1. Per-host config exists in the repo
    if [ -f "$REPO_ROOT/configs/hosts/$HOSTNAME.toml" ]; then
        echo "  ✓ configs/hosts/$HOSTNAME.toml present"
    else
        echo "  ⚠ configs/hosts/$HOSTNAME.toml not present yet — will print template at end" >&2
        # not a hard fail in single-user mode; the script prints a starter config
    fi

    # 2. Kodiak-side tourbillon user exists (script needs to sudo -u as it)
    if id "$KODIAK_SVC_USER" >/dev/null 2>&1; then
        echo "  ✓ kodiak '$KODIAK_SVC_USER' service user exists"
    else
        echo "  ✗ kodiak '$KODIAK_SVC_USER' service user MISSING — run bin/bootstrap-kodiak-tourbillon.sh first." >&2
        failed=$((failed+1))
    fi

    # 3. Hostname resolves OR can be added given the <ip> arg
    if getent hosts "$HOSTNAME" >/dev/null 2>&1; then
        local resolved
        resolved=$(getent hosts "$HOSTNAME" | awk '{print $1; exit}')
        echo "  ✓ $HOSTNAME resolves to $resolved"
        if [ -n "$IP" ] && [ "$IP" != "$resolved" ]; then
            echo "  ⚠ <ip> arg ($IP) differs from current resolution ($resolved). Existing resolution wins." >&2
        fi
    elif [ -n "$IP" ]; then
        echo "  ⚠ $HOSTNAME does not resolve yet; /etc/hosts entry will be added (step 0)"
    else
        echo "  ✗ $HOSTNAME does not resolve and no <ip> arg given." >&2
        echo "    Either supply the IP:  $0 $HOSTNAME $USER_ON_TARGET <ip>" >&2
        echo "    Or add manually first: echo '<ip> $HOSTNAME' | sudo tee -a /etc/hosts" >&2
        failed=$((failed+1))
    fi

    # 4. Target reachable on port 22 (use IP if hostname not resolving yet)
    local probe_host="$HOSTNAME"
    if ! getent hosts "$HOSTNAME" >/dev/null 2>&1 && [ -n "$IP" ]; then
        probe_host="$IP"
    fi
    if timeout 5 bash -c "echo > /dev/tcp/$probe_host/22" 2>/dev/null; then
        echo "  ✓ $probe_host port 22 reachable (sshd is up)"
    else
        echo "  ✗ $probe_host port 22 UNREACHABLE — is sshd running on the target?" >&2
        echo "    On macOS: System Settings → General → Sharing → Remote Login = ON" >&2
        echo "    On Windows: install + start the OpenSSH Server feature" >&2
        echo "    On linux:   sudo systemctl status ssh  /  sudo systemctl start ssh" >&2
        failed=$((failed+1))
    fi

    if [ "$failed" -gt 0 ]; then
        echo "" >&2
        echo "  $failed preflight check(s) failed; not proceeding." >&2
        exit 1
    fi
    echo "  ✓ all preflight checks passed"
    echo
}

preflight

# 0. Resolve / /etc/hosts handling
if getent hosts "$HOSTNAME" >/dev/null 2>&1; then
    resolved=$(getent hosts "$HOSTNAME" | awk '{print $1; exit}')
    echo "  ✓ $HOSTNAME already resolves to $resolved"
    if [ -n "$IP" ] && [ "$IP" != "$resolved" ]; then
        echo "  WARNING: <ip> argument ($IP) differs from current resolution ($resolved)." >&2
        echo "  Using existing resolution. Edit /etc/hosts manually if you want $IP." >&2
    fi
elif [ -n "$IP" ]; then
    echo "  $HOSTNAME does not resolve; adding '$IP $HOSTNAME' to /etc/hosts ..."
    echo "$IP $HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
    if ! getent hosts "$HOSTNAME" >/dev/null 2>&1; then
        echo "  ERROR: /etc/hosts updated but $HOSTNAME still doesn't resolve. Check NSS config (/etc/nsswitch.conf)." >&2
        exit 1
    fi
    echo "  ✓ $HOSTNAME now resolves to $IP"
else
    cat >&2 <<EOF
  ERROR: $HOSTNAME does not resolve, and no <ip> argument was given.

  Either supply the IP:    $0 $HOSTNAME $USER_ON_TARGET <ip>
  Or add it manually:      echo '<ip> $HOSTNAME' | sudo tee -a /etc/hosts
EOF
    exit 1
fi
echo

# 1. Per-host keypair under ~tourbillon/.ssh/
sudo install -d -m 700 -o "$KODIAK_SVC_USER" -g "$KODIAK_SVC_USER" "${TB_HOME}/.ssh"
if sudo test -f "$KEY"; then
    echo "  key already exists; reusing"
else
    echo "  generating per-host keypair under ~${KODIAK_SVC_USER}/ ..."
    sudo -u "$KODIAK_SVC_USER" ssh-keygen -t ed25519 -f "$KEY" -N '' \
        -C "kodiak -> ${HOSTNAME} single-user pull-key (no passphrase)"
fi
echo

# 2. ssh-copy-id — interactive password prompt (operator's existing pw)
echo "→ ssh-copy-id (will prompt for ${USER_ON_TARGET}@${HOSTNAME}'s existing password)"
if ! sudo -u "$KODIAK_SVC_USER" -H ssh-copy-id "${SSH_OPTS[@]}" \
        -i "${KEY}.pub" "${USER_ON_TARGET}@${HOSTNAME}"; then
    echo "ERROR: ssh-copy-id failed; key not deployed" >&2
    exit 1
fi

# 3. Verify key-based auth
echo
echo "→ verifying key-based auth (BatchMode=yes) ..."
if ! sudo -u "$KODIAK_SVC_USER" -H ssh "${SSH_OPTS[@]}" -i "$KEY" \
        -o BatchMode=yes \
        "${USER_ON_TARGET}@${HOSTNAME}" 'true'; then
    cat >&2 <<EOF

ERROR: key-based auth verification failed. The pubkey may not have landed
correctly. Try manually:

  sudo -u $KODIAK_SVC_USER ssh -i $KEY ${USER_ON_TARGET}@${HOSTNAME} true

If that prompts for a password, check ~${USER_ON_TARGET}/.ssh/authorized_keys
on the target — the pubkey should be there.
EOF
    exit 1
fi
echo "  ✓ key auth works"

cat <<EOF

================ done ================

Per-host key:  $KEY  (owned by $KODIAK_SVC_USER)
Verified:      sudo -u $KODIAK_SVC_USER ssh -i \$KEY ${USER_ON_TARGET}@${HOSTNAME} true (works)

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

    sudo -u $KODIAK_SVC_USER /home/ldavis/development/server-backups/bin/tourbillon hosts ping ${HOSTNAME}
    sudo -u $KODIAK_SVC_USER /home/ldavis/development/server-backups/bin/tourbillon hosts sync --force --name ${HOSTNAME}

Note: this host's password is the operator's own — NOT locked, NOT
disturbed. Unlike the multi-user flow there's no service-account
password to manage.
EOF

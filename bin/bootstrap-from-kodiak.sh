#!/usr/bin/env bash
# bootstrap-from-kodiak.sh — finish bootstrapping a linux host into
# tourbillon's host-backup fleet. Run on kodiak, AS THE OPERATOR (ldavis),
# after `bootstrap-tourbillon-user.sh` has been run on the target.
#
# Per ADR-004 the per-host SSH key lives under the kodiak-side `tourbillon`
# service user's home (~tourbillon/.ssh/), not under ldavis. This script
# uses `sudo` to do the right things as the right user.
#
# Usage:
#   bin/bootstrap-from-kodiak.sh <hostname> [<ip>]
#
#   <hostname>  short name; matches configs/hosts/<hostname>.toml
#   <ip>        optional IPv4. If given AND <hostname> doesn't resolve,
#               '<ip> <hostname>' is appended to kodiak's /etc/hosts.
#
# What this script does:
#   0. Resolve <hostname>. If it doesn't resolve and <ip> was provided,
#      add the mapping to /etc/hosts (one sudo prompt).
#   1. Generate a per-host ed25519 keypair under ~tourbillon/.ssh/.
#   2. ssh-copy-id pushes the public half. StrictHostKeyChecking=accept-new
#      so the target's host key is auto-trusted on first sight (no manual
#      ssh-keyscan needed). Interactive: prompts for the target's
#      tourbillon password (printed by the target-side bootstrap script).
#   3. Verify key-based auth works.
#   4. Lock the target's tourbillon password (key-only thereafter).
#
# Idempotent: re-running with an existing key reuses it; ssh-copy-id
# dedupes the pubkey; the /etc/hosts line is added only if missing; the
# password lock is a no-op if already locked.

set -euo pipefail

HOSTNAME="${1:-}"
IP="${2:-}"

if [ -z "$HOSTNAME" ]; then
    cat >&2 <<USAGE
usage: $0 <hostname> [<ip>]

  <hostname>  short name (matches configs/hosts/<hostname>.toml)
  <ip>        IPv4 (optional). If given and <hostname> doesn't resolve,
              kodiak's /etc/hosts will be updated automatically.

Example:
  $0 arrow-iii 192.168.1.65
USAGE
    exit 2
fi

KODIAK_SVC_USER="tourbillon"
TB_HOME="/var/lib/tourbillon"
KEY="${TB_HOME}/.ssh/id_ed25519_tourbillon_${HOSTNAME}"

# SSH options applied to every connection this script makes. accept-new
# auto-trusts the host key on first sight but still rejects changed keys
# on subsequent visits (TOFU done right).
SSH_OPTS=( -o "StrictHostKeyChecking=accept-new" )

echo "================ bootstrap-from-kodiak.sh — $(date) ================"
echo "  target:  ${KODIAK_SVC_USER}@${HOSTNAME}"
echo "  key:     ${KEY}"
echo "  ip arg:  ${IP:-(none)}"
echo

# Repo root — used by preflight to find configs/hosts/<host>.toml
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- preflight ---------------------------------------------------------------
# Verify every precondition BEFORE we touch the system or the target.
# Each check is independent; we tally all failures and bail with the
# full list so the operator doesn't fix-and-retry one issue at a time.
preflight() {
    local failed=0
    echo "→ preflight checks..."

    # 1. Per-host config exists in the repo
    if [ -f "$REPO_ROOT/configs/hosts/$HOSTNAME.toml" ]; then
        echo "  ✓ configs/hosts/$HOSTNAME.toml present"
    else
        echo "  ✗ configs/hosts/$HOSTNAME.toml MISSING — create it before continuing." >&2
        failed=$((failed+1))
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
        echo "    Either supply the IP:  $0 $HOSTNAME <ip>" >&2
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
        echo "    On the target: sudo systemctl status ssh  /  sudo systemctl start ssh" >&2
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

  Either supply the IP:    $0 $HOSTNAME <ip>
  Or add it manually:      echo '<ip> $HOSTNAME' | sudo tee -a /etc/hosts
EOF
    exit 1
fi
echo

# 1. Per-host keypair under ~tourbillon/.ssh/. Generated AS tourbillon,
#    so ownership and permissions land correctly without later chowns.
sudo install -d -m 700 -o "$KODIAK_SVC_USER" -g "$KODIAK_SVC_USER" "${TB_HOME}/.ssh"
if sudo test -f "$KEY"; then
    echo "  key already exists; reusing"
else
    echo "  generating per-host keypair under ~${KODIAK_SVC_USER}/ ..."
    sudo -u "$KODIAK_SVC_USER" ssh-keygen -t ed25519 -f "$KEY" -N '' \
        -C "kodiak -> $HOSTNAME tourbillon pull-key (no passphrase)"
fi
echo

# 2. ssh-copy-id — interactive, prompts for the temp password from the
#    target-side bootstrap script.
echo "→ ssh-copy-id (will prompt for the password printed by the target-side script)"
if ! sudo -u "$KODIAK_SVC_USER" -H ssh-copy-id "${SSH_OPTS[@]}" \
        -i "${KEY}.pub" "${KODIAK_SVC_USER}@${HOSTNAME}"; then
    echo "ERROR: ssh-copy-id failed; not proceeding to verify or lock" >&2
    exit 1
fi

# 3. Verify key-based auth (BatchMode prevents any password fallback)
echo
echo "→ verifying key-based auth (BatchMode=yes, no password fallback) ..."
if ! sudo -u "$KODIAK_SVC_USER" -H ssh "${SSH_OPTS[@]}" -i "$KEY" \
        -o BatchMode=yes \
        "${KODIAK_SVC_USER}@${HOSTNAME}" 'true'; then
    cat >&2 <<EOF

ERROR: key-based auth verification failed. Not locking the password
yet — that would lock you out if the key isn't working.

Try manually:
  sudo -u $KODIAK_SVC_USER ssh -i $KEY ${KODIAK_SVC_USER}@${HOSTNAME} true

If that works, lock by hand:
  sudo -u $KODIAK_SVC_USER ssh -i $KEY ${KODIAK_SVC_USER}@${HOSTNAME} 'sudo passwd -l tourbillon'
EOF
    exit 1
fi
echo "  ✓ key auth works"

# 4. Lock the password — key-only thereafter
echo
echo "→ locking target's tourbillon password (key-only thereafter) ..."
sudo -u "$KODIAK_SVC_USER" -H ssh "${SSH_OPTS[@]}" -i "$KEY" \
    -o BatchMode=yes \
    "${KODIAK_SVC_USER}@${HOSTNAME}" 'sudo passwd -l tourbillon' >/dev/null
echo "  ✓ password locked"

cat <<EOF

================ done ================

Per-host key:  $KEY  (owned by $KODIAK_SVC_USER)
Verified:      sudo -u $KODIAK_SVC_USER ssh -i \$KEY ${KODIAK_SVC_USER}@${HOSTNAME} true (works)
Password:      locked on target (key-only)

Quick test from kodiak:

    sudo -u $KODIAK_SVC_USER /home/ldavis/development/server-backups/bin/tourbillon hosts ping ${HOSTNAME}

(should print "reachable")

First seed (warning: may be large):

    sudo -u $KODIAK_SVC_USER /home/ldavis/development/server-backups/bin/tourbillon hosts sync --force --name ${HOSTNAME}
EOF

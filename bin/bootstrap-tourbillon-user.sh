#!/usr/bin/env bash
# bootstrap-tourbillon-user.sh — run on a LINUX TARGET HOST as root.
#
# Sets up everything kodiak's tourbillon needs to pull rsync backups
# from this host. Plus prereq checks so the operator isn't surprised
# by missing dependencies mid-bootstrap.
#
#   prereq: rsync (auto-installs via apt if missing; ports/dnf etc. error out)
#   prereq: openssl, visudo, useradd, usermod, passwd (base toolchain)
#   1. Creates the `tourbillon` system user (locked password, /var/lib home)
#   2. Sets a fresh random 128-bit password using `usermod -p` + an
#      openssl-precomputed sha512crypt hash. We deliberately avoid
#      `chpasswd` here — it hangs indefinitely on some Debian PAM stacks
#      (sssd, fingerprint readers, network home dir hooks), turning a
#      one-second step into a "did the bootstrap die?" mystery. usermod
#      writes /etc/shadow directly with no PAM detour.
#   3. Installs sudoers drop-in at /etc/sudoers.d/tourbillon with the
#      narrow NOPASSWD entries kodiak needs.
#
# After this script:
#   On kodiak, run:  bin/bootstrap-from-kodiak.sh <this-hostname> [<ip>]
#   When ssh-copy-id prompts for the tourbillon password, paste the
#   one this script prints.
#
# Idempotent. Re-running:
#   - leaves an existing user alone (doesn't change shell/home/uid)
#   - generates a FRESH password (replaces the old one — fine, since
#     the kodiak script locks it as soon as key auth is verified)
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
SUDOERS_FILE="/etc/sudoers.d/tourbillon"

echo "================ bootstrap-tourbillon-user.sh — $(date) ================"

# ---- 0. Pre-flight: required tools -------------------------------------------
echo "→ pre-flight checks..."
MISSING=()
for cmd in openssl visudo useradd usermod passwd; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "  ERROR: required tools missing: ${MISSING[*]}" >&2
    echo "  these should be part of any base Debian install — investigate." >&2
    exit 1
fi

# rsync is the one thing actually-missing on some minimal installs. Install
# rather than fail — the whole point of this host is to be rsync-able.
if ! command -v rsync >/dev/null 2>&1; then
    echo "  rsync not installed — installing..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y rsync >/dev/null
        echo "  ✓ rsync installed via apt"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y rsync >/dev/null
        echo "  ✓ rsync installed via dnf"
    else
        echo "  ERROR: rsync missing and no known package manager available." >&2
        echo "  Install rsync by hand and re-run this script." >&2
        exit 1
    fi
else
    echo "  ✓ rsync present at $(command -v rsync)"
fi
echo "  ✓ all required tools available"

# ---- 1. Create the user (idempotent) ----------------------------------------
if id "$USER_NAME" >/dev/null 2>&1; then
    echo "→ user '$USER_NAME' already exists; identity unchanged"
else
    echo "→ creating user '$USER_NAME' (home=$HOME_DIR shell=$SHELL_PATH) ..."
    useradd -r -m -d "$HOME_DIR" -s "$SHELL_PATH" \
        -c 'kodiak pulls rsync backups as this user (tourbillon)' "$USER_NAME"
    echo "  ✓ user created"
fi

# ---- 2. Set a fresh random password (PAM-bypass via usermod -p) -------------
PASS=$(openssl rand -hex 16)             # 128 bits, all alphanumeric (0-9a-f)
HASH=$(openssl passwd -6 "$PASS")        # sha512crypt
usermod -p "$HASH" "$USER_NAME"
# usermod -p sets the hash but doesn't touch the lock bit. useradd -r leaves
# the account locked by default; unlock it so ssh-copy-id can authenticate.
passwd -u "$USER_NAME" >/dev/null 2>&1 || true
echo "→ password set (128-bit random, hashed via openssl, bypasses PAM)"

# ---- 3. Sudoers drop-in (narrow NOPASSWD) -----------------------------------
SUDOERS_TMP="$(mktemp)"
trap 'rm -f "$SUDOERS_TMP"' EXIT

cat > "$SUDOERS_TMP" <<'EOF'
# tourbillon backup user — kodiak pulls rsync as this user, and gets to
# lock its password after key-auth is verified. Narrow NOPASSWD.
tourbillon ALL=(root) NOPASSWD: /usr/bin/rsync --server *
tourbillon ALL=(root) NOPASSWD: /usr/bin/passwd -l tourbillon
EOF

if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
    echo "→ sudoers installed at $SUDOERS_FILE"
else
    echo "  ERROR: sudoers entry failed visudo validation — not installed" >&2
    visudo -cf "$SUDOERS_TMP" >&2 || true
    exit 1
fi

# ---- done -------------------------------------------------------------------
cat <<EOF

================ done ================

Host:      $(hostname -s 2>/dev/null || hostname)
User:      $USER_NAME  (uid $(id -u $USER_NAME))
Sudoers:   $SUDOERS_FILE  (parsed OK)
Rsync:     $(command -v rsync) ($(rsync --version 2>/dev/null | head -1))

Next, on kodiak:

    bin/bootstrap-from-kodiak.sh $(hostname -s 2>/dev/null || hostname) [<ip>]

When ssh-copy-id prompts for the tourbillon password, paste:

    $PASS

(One-time bootstrap credential. The kodiak script locks the password
immediately after verifying key-based auth works, so this string
becomes useless to anyone right after that.)
EOF

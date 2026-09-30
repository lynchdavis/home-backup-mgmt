#!/usr/bin/env bash
# dashboard-set-password.sh — one-time (or rotation) setup for the
# dashboard's single shared password (ADR-008). Run on kodiak as root.
#
# postinst never runs this itself -- it never has access to a real
# password value (same reasoning as the saratoga API token, see
# ADR-004 / CREDENTIALS.md). Until this has been run once, /config
# shows "no password has been set up yet" instead of a login form.
#
# Writes ~tourbillon/.config/dashboard/env (bcrypt hash + a session-
# signing key, never the plaintext password) and restarts the dashboard
# service so it takes effect immediately.
#
# Usage:
#   sudo bin/dashboard-set-password.sh
#
# Idempotent: re-running rotates the password but keeps the existing
# signing key (changing it would silently log out any open session —
# harmless, but no reason to do it on every password rotation).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0)" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../dashboard/.venv/bin/python3"
if [ ! -x "$VENV_PY" ]; then
    echo "ERROR: $VENV_PY not found — is the dashboard installed? (postinst builds this venv)" >&2
    exit 1
fi

ENV_DIR="/var/lib/tourbillon/.config/dashboard"
ENV_FILE="$ENV_DIR/env"

read -r -s -p "New dashboard password: " PASSWORD
echo
read -r -s -p "Confirm: " PASSWORD_CONFIRM
echo
if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    echo "ERROR: passwords didn't match." >&2
    exit 1
fi
if [ -z "$PASSWORD" ]; then
    echo "ERROR: empty password." >&2
    exit 1
fi

HASH="$("$VENV_PY" -c "
import bcrypt, sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())
" "$PASSWORD")"

# Keep the existing signing key on a rotation; generate one if this is
# the first run (no env file yet, or the key is missing from it).
KEY=""
if [ -f "$ENV_FILE" ]; then
    KEY="$(grep -oP '(?<=^DASHBOARD_SECRET_KEY=).*' "$ENV_FILE" || true)"
fi
if [ -z "$KEY" ]; then
    KEY="$("$VENV_PY" -c "import secrets; print(secrets.token_urlsafe(32))")"
fi

mkdir -p "$ENV_DIR"
cat > "$ENV_FILE" <<EOF
DASHBOARD_PASSWORD_HASH=$HASH
DASHBOARD_SECRET_KEY=$KEY
EOF
chown -R tourbillon:tourbillon "/var/lib/tourbillon/.config"
chmod 700 "$ENV_DIR"
chmod 600 "$ENV_FILE"

systemctl restart tourbillon-dashboard
echo "Password set. Dashboard restarted — sign in at /config."

"""Single shared-password auth for Phase 2's write routes.

Phase 1's read-only routes (/, /api/*, /partials/status|hosts|repos) stay
unauthenticated per ADR-007 -- this module only gates the new write-capable
/config* routes added in ADR-008. A single shared password (not per-user
accounts) matches this tool's actual shape: one operator, one LAN dashboard.

Secret storage follows the existing ~tourbillon/.config/<name>/env pattern
(see ADR-004, the saratoga token) -- DASHBOARD_PASSWORD_HASH (a bcrypt hash,
never the plaintext password) and DASHBOARD_SECRET_KEY (session-signing key)
are sourced from ~tourbillon/.config/dashboard/env via the systemd unit's
EnvironmentFile=. postinst never generates these (it never has access to a
real password) -- see bin/dashboard-set-password.sh for one-time setup.
"""
import os

import bcrypt
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

SESSION_COOKIE = "tourbillon_session"
SESSION_MAX_AGE = 12 * 60 * 60  # 12h

_password_hash = os.environ.get("DASHBOARD_PASSWORD_HASH", "")
_secret_key = os.environ.get("DASHBOARD_SECRET_KEY", "")


def configured() -> bool:
    """False until bin/dashboard-set-password.sh has been run once."""
    return bool(_password_hash and _secret_key)


def _serializer() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(_secret_key, salt="tourbillon-dashboard-session")


def verify_password(password: str) -> bool:
    if not configured():
        return False
    try:
        return bcrypt.checkpw(password.encode(), _password_hash.encode())
    except ValueError:
        return False  # malformed stored hash


def make_session_cookie() -> str:
    return _serializer().dumps({"authenticated": True})


def is_authenticated(token: str | None) -> bool:
    if not token or not configured():
        return False
    try:
        _serializer().loads(token, max_age=SESSION_MAX_AGE)
        return True
    except (BadSignature, SignatureExpired):
        return False

# ADR-008: Dashboard Phase 2, step 1 — auth + per-host mail toggle

**Status:** Accepted, 2026-09-30.
**Builds on:** ADR-007 (the read-only Phase 1 dashboard this extends).
**Scope:** the first Phase 2 write capability (per-host mail on/off) plus
the auth foundation every future write route needs. Not the full Phase 2
backlog (schedule/retry/exclude editing, credential-age indicator) —
those remain deferred, now unblocked by this ADR's auth work.

---

## Context

ADR-007 explicitly deferred all write endpoints behind "basic password
auth, required before any of the above ships." The operator picked the
per-host mail toggle as the first write capability to build (smallest
surface, good exercise for the auth + write-endpoint pattern before
tackling the more involved config knobs).

Building it surfaced a real design gap: `hosts sync` runs every
configured host in one shot per cron firing, and `mail-on-output.sh`
mails based on that single process's exit code — there was no per-host
granularity to toggle in the first place. ADR-007's phrasing ("a config
field `mail-on-output.sh` or the calling cron entry would respect")
didn't specify which; the calling cron entry can't do it (one line covers
all hosts), so the field has to live inside `tourbillon` itself.

## Decision

**Auth: single shared password**, not per-user accounts — matches this
tool's actual shape (one operator, one LAN dashboard). Bcrypt hash +
random signing key stored in `~tourbillon/.config/dashboard/env`, the
same secret-storage pattern ADR-004 established for the saratoga/GitHub/
Bitbucket tokens. `bin/dashboard-set-password.sh` is the one-time setup
script (postinst never generates it — same reasoning as every other
secret in this codebase: it never has access to a real value). Session
is a signed cookie (`itsdangerous`, 12h expiry, `httponly` + `samesite=strict`),
not a server-side session store — no database, no extra moving part.

**`mail_enabled` lives on the host, not the cron line.** New
`configs/hosts/defaults.toml` field (default `true`), settable per-host.
`cmd_hosts_sync` now tracks `failed_alerting` (only counts a host's
failure if `mail_enabled` is true) separately from `failed` (all
failures, unchanged). **The exit code — what `mail-on-output.sh` actually
keys off of — uses `failed_alerting`.** A muted host's failure still
writes to its own state file and still shows as `FAILED` in
`tourbillon status` / the dashboard; it just doesn't trigger the shared
cron alert. This is a real behavior change to the sync command, not a
cosmetic UI toggle.

**The write path is a new CLI subcommand, not direct file editing from
the dashboard.** `tourbillon hosts set-mail <name> <on|off>` does a
targeted line replace/append on the host's own TOML file
(`set_host_toml_bool()`) — never touches `defaults.toml`, never pulls in
a full TOML-writing library (these files are simple, flat, and
hand-commented; a round-trip through a generic writer risks mangling
comments the operator wrote). The dashboard's `POST /api/hosts/{name}/mail`
just shells out to this command, exactly like every read route already
shells out to `tourbillon <cmd> --json` — same architectural principle
ADR-007 established, extended to writes.

**New routes, zero changes to Phase 1's.** `/login`, `/logout`, `/config`,
`/partials/config-hosts`, `POST /api/hosts/{name}/mail` — all new, all
gated by the session cookie. `/`, `/api/status`, `/api/hosts`,
`/api/repos`, `/partials/status|hosts|repos` are byte-for-byte unchanged
and still fully unauthenticated, exactly as ADR-007's `/api/*` namespacing
was designed to allow.

## Consequences

**Good**
- The auth foundation (password check, session cookie, `require`-style
  gate) is now in place for every future Phase 2 write route — adding the
  next one (excludes, schedule, retries) is "add a route + a CLI
  subcommand," not "design auth again."
- `mail_enabled`'s exit-code semantics generalize: any future per-host
  alerting nuance (e.g. a different threshold) has an obvious home.

**Costs**
- Two new Python dependencies (`bcrypt`, `itsdangerous`) plus
  `python-multipart` (FastAPI's form-parsing requirement) — modest, pure-
  Python-adjacent, no system packages needed beyond what pip installs into
  the existing venv.
- `NoNewPrivileges=true` + `AmbientCapabilities=CAP_SYS_RAWIO` (v0.1.1)
  and this auth addition both now live in the same systemd unit — still
  one service, but its config surface is growing. Acceptable; revisit if
  it keeps growing.
- No CSRF token beyond `samesite=strict` — judged sufficient for a
  single-operator LAN tool with no third-party content ever loaded
  alongside it; would need real CSRF protection if this ever left the LAN
  or gained multiple trusted origins.
- Verification is structural, not exhaustive: the full round-trip (login,
  toggle persists to the TOML file, unauthenticated write correctly
  rejected, logout clears the session) was tested live against a local
  instance. Inducing an actual host sync failure to confirm the exit-code
  suppression end-to-end (not just reading the code path) wasn't done —
  noted as a gap, not silently assumed solid.

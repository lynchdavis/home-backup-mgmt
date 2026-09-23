# ADR-007: Backup status dashboard — FastAPI + htmx, read-only

**Status:** Accepted, 2026-09-23.
**Builds on:** ADR-006 (packaging — the dashboard is deployed through it,
not as a separate ad hoc install).
**Scope:** backups only. Data-organizer (`data-organizer/` — organization +
flow) is explicitly excluded from this dashboard.

---

## Context

The only way to check backup health today is SSH + `tourbillon status` /
`hosts status` / `repos status`, or wait for the weekly summary email. The
operator wants a live, LAN-served view instead — explicitly not a
static/cron-generated page, since a real client-server app better fits how
they want to work with this system, and they want room to grow it (Phase 2:
editable configuration — cron timing, retries, include/exclude, a per-host
mail on/off toggle).

## Decision

**Stack: FastAPI + htmx**, server-rendered HTML fragments over polling, no
JS build step or npm/node toolchain on kodiak. Chosen over a FastAPI +
SPA (React/Vue) split specifically to keep kodiak's footprint to "one Python
venv," not "one Python venv plus a JS build pipeline," while still being a
live, queried app rather than a static dump.

**Three tiers, cleanly separated:**
1. **Scripts** (`bin/tourbillon`, unchanged in role) — the single source of
   truth for backup state. Extended with `--json` on `hosts status`,
   `hosts issues`, `repos status`, `repos issues` (the four commands that
   didn't already have it — `status --json` existed before this ADR),
   following the exact idiom `cmd_status` already used.
2. **Interfaces** (`dashboard/api/`) — a FastAPI app that never
   re-implements state logic. Every route shells out to
   `tourbillon <cmd> --json` via `subprocess` (`tourbillon_client.py`),
   exactly as a human would from the CLI, with a short TTL cache (default
   30s, `dashboard/config.toml`) so browser polling doesn't hammer
   `zfs`/`ssh` on every request.
3. **UI** (`dashboard/web/`) — Jinja2 templates + vendored htmx (no CDN
   dependency — this should work even with no LAN internet egress). Panels
   mirror the CLI's own groupings (saratoga replication + pool/scrub/drive;
   hosts table; repos summary) so the dashboard reads as "the CLI you
   already know, in a browser," not a new mental model.

**Read-only, LAN-only, no auth — for Phase 1 only.** Routes are namespaced
under `/api/*` and `/partials/*` specifically so Phase 2 can add `POST`/`PUT`
write routes and an auth middleware gating them by path prefix, without
touching any Phase 1 route. Basic password auth is required *before* any
write endpoint ships — not before these read-only ones.

**Deployed via ADR-006's packaging**, not a bespoke install: runs as the
existing `tourbillon` service user (not the operator's own account, per this
codebase's documented service-user principle), under a systemd unit
(`tourbillon-dashboard.service`) whose venv is built by the package's
`postinst`, bound to kodiak's LAN IP.

## Explicitly deferred to Phase 2

- `POST`/`PUT` endpoints: editing `schedule_when_up`, retry counts,
  include/exclude exclude-file entries, cron timing.
- A per-host mail on/off toggle (a config field `mail-on-output.sh` or the
  calling cron entry would respect) — same bucket as the config knobs above.
- Basic password auth, required before any of the above ships.
- Crontab-reinstall logic for any write endpoint that changes cron timing —
  reusing the `crontab | sed | crontab -` pattern used manually during the
  2026-09-23 incident, wrapped properly instead of ad hoc.

## Consequences

**Good**
- New endpoints/panels are additive — the existing ones don't change shape
  as the CLI's own JSON surface grows.
- No new failure mode for the *backup system itself*: the dashboard is a
  read-only observer: if it crashes or is stopped, nothing it observes is
  affected.

**Costs**
- A second thing to keep running on kodiak (one more systemd unit, one more
  venv) — modest, but real, compared to "cron + a CLI you SSH in to run."

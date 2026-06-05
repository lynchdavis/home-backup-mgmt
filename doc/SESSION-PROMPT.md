# Next backup-session prompt — dev-01, staleness alarm, flow off-site confirm

Paste this into a fresh session opened in `~/development/server-backups`. It
bundles three related tasks that all live in the tourbillon / cron / state /
mail-on-failure world. Design-then-build; read state and confirm before changing
anything.

---

We're working in ~/development/server-backups (the A2 host-backup system —
`tourbillon` service user, rsync-over-SSH, ZFS backups-00/hosts/<host>). Three
related tasks. Read the state and confirm the plan before changing anything.

== Task 1: wire up a new host, ldavis-dev-01 ==

A second Linux box, hostname `ldavis-dev-01`, POWERED ON ONLY OCCASIONALLY. Its
~/ has assorted learning/POC files and possibly ex-employer (CyFIR) code. Same
profile as the existing `arrow-iii` host (mirror /home + /etc).

- Model on configs/hosts/arrow-iii.toml; create configs/hosts/ldavis-dev-01.toml
  (host = its LAN IP — operator provides; paths = ["/home","/etc"]; inherit
  defaults.toml; schedule_when_up 24h; generous stale_after, ~30d — see Task 2).
- Write an exclude file (configs/hosts/excludes/) for the obvious cruft (build
  artifacts, caches, VM images, large datasets). ASK before finalizing whether
  any CyFIR/ex-employer code should be excluded WHOLESALE — operator's call.
- Bootstrap is the arrow-iii pair (target-side bootstrap-tourbillon-user.sh as
  root; kodiak-side bootstrap-from-kodiak.sh). Interactive (root + one password
  paste) — give the operator the commands to run; don't drive headless. (A first
  dump already ran once and was restarted — confirm it completes clean.)

== Task 2: per-host "stale_after" staleness alarm ==

Already confirmed in bin/tourbillon: an off host is handled SILENTLY (ssh_probe
never raises, `unreachable` is first-class separate from FAILED, schedule_when_up
makes syncs opportunistic, hosts-sync cron is silent on host-offline). The GAP:
a host off/broken for weeks just sits `unreachable` with an aging
last_success_at and NOTHING actively alerts.

Add a per-host `stale_after` threshold (e.g. "21d"), defaulted in defaults.toml,
overridable per host. Logic: stay silent while unreachable UNTIL
(now - last_success_at) > stale_after, then escalate to an alert. Key off
last_success_at AGE, not consecutive-skip count. Surface via weekly-summary.sh
and/or a `hosts issues --stale` path that can drive a mail. ADR + CHANGELOG +
test + config-as-code.

== Task 3: automate promote's off-site confirmation ==

The data-organizer flow tool `promote` (on saratoga) files new content into the
photo archive and appends rows to `/mnt/tank/system/scripts/promote-log.tsv` with
an `offsite` column = `pending`. A batch is "off-site safe" once it's in a
`tank/archive` snapshot that has replicated to kodiak's `backups-00`. Today the
operator stamps that by hand (`promote --confirm-replicated "<batch>"`) — tedious
and easy to forget. Automate it away.

Goal: a scheduled reconciliation job (tourbillon pattern: cron, right service
user, mail-on-failure-only, idempotent, self-correcting) that scans
promote-log.tsv for `pending` rows and, for each, checks whether its `dest` path
exists in a snapshot that has ACTUALLY replicated to kodiak, then stamps the row
off-site (date or snapshot id). Removes the manual step.

Design questions to settle (don't over-build — this is the backups↔flow seam,
not a v2 unification):
- WHERE it runs. kodiak can see the replicated backups-00/saratoga/tank/archive
  snapshots directly (authoritative "it's off-site"), but the manifest lives on
  saratoga. saratoga sees local snapshots but not kodiak's replication state.
  Pick the simplest path that HONESTLY means off-site, and state what the stamp
  guarantees.
- Manifest as shared state. promote-log.tsv is written by `promote` (as ldavis
  on saratoga). If the reconciler also writes it, mind races/ownership — consider
  append-only events + a derived view, or a lock.
- Cadence: after nightly A1 replication lands (once/day).

ADR if it's a real decision; CHANGELOG; test; config-as-code.

== Start by reading ==

bin/tourbillon (ssh_probe, host_status_row, cmd_hosts_sync, is_due),
configs/hosts/{defaults,arrow-iii}.toml, bin/mail-on-output.sh,
bin/weekly-summary.sh, configs/cron/tourbillon-crontab, the relevant ADRs
(002/003/004), and doc/GAPS.md. For Task 3, also skim
~/development/data-organizer/FLOW-DESIGN.md §3/§5 and the `promote` script's
manifest format. Then propose each design for the operator to react to before
building.

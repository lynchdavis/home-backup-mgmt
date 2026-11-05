# ADR-010: Dashboard manual backups — "Back up now", repo "Sync now", package-list capture

**Status:** Accepted, 2026-11-05.
**Builds on:** ADR-008 (auth + write-route pattern), ADR-009 (permission
model as actually exercised by `tourbillon`, not `ldavis`), ADR-002 (A2
host mirrors), ADR-007 (dashboard tiers).

---

## Context

The operator updated a host and wanted a backup captured *now* — and
would have wanted one *before* the distro upgrade even more. Today the
only options are waiting for the next due cron firing (up to
`schedule_when_up`, default 24h) or SSHing to kodiak and running
`tourbillon hosts sync --name X --force` by hand as `tourbillon`.

Three things in the existing system shape the design:

1. **The dashboard process can't run a host sync.** `rsync_one_path()`
   runs `sudo -n rsync` kodiak-side (needed for `--numeric-ids` owner
   preservation), and `tourbillon-dashboard.service` sets
   `NoNewPrivileges=true`, which blocks the setuid escalation at the
   kernel level (same constraint `_run_smartctl()` already works around).
   The ADR-008 pattern — route shells out to the CLI — would fail as
   `tourbillon` even though it would *appear* to work from an `ldavis`
   dev server: exactly ADR-009's trap. A first-real-sync can also run for
   hours; tying it to a web worker's lifetime is wrong regardless.
2. **A sync alone is not a checkpoint.** Host backups are `rsync
   --delete` mirrors. If an upgrade breaks a host and the next cron sync
   mirrors the broken state, the only fallback is sanoid's daily snapshot
   — up to 24h stale, and pruned after 30 days. A pre-upgrade backup only
   protects anything if it's pinned with its own snapshot.
3. **`/etc` + `/home` don't say what was installed.** Linux hosts are
   documented as "rebuildable from a fresh install," but after a bad
   upgrade the rebuild needs the package list, which nothing captures.

## Decision

### A request queue, drained outside the dashboard

- The dashboard never runs a sync. An authenticated POST shells out to
  `tourbillon hosts request <name> [--label L]` /
  `tourbillon repos request [--name SLUG]`, which validates the target
  (configured host / known slug — also the path-injection guard, since the
  target becomes part of a filename) and atomically writes
  `$STATE/requests/<kind>--<key>.json` plus a `queued` status file at
  `$STATE/manual/<kind>--<key>.json`.
- `tourbillon-requests.path` (systemd, `DirectoryNotEmpty=` on the
  requests dir) starts `tourbillon-requests.service`, a oneshot running
  `tourbillon requests run` as `tourbillon` **without**
  `NoNewPrivileges`, so the existing narrow sudoers rules work exactly as
  they do from cron. The web process gains no privilege.
- The runner claims requests (reads + unlinks), loops until the queue is
  empty (requests arriving mid-run are picked up), and holds a runner-wide
  lock so only one drains at a time.
- **Locking reuses `acquire_host_lock()`.** A host that cron is mid-sync on
  is marked `waiting` and retried every 20s rather than dropped or
  stacked — the 2026-09-23 concurrent-rsync incident's guard stays the
  single source of truth. Repos gain the same per-repo lock (cron
  `repos sync` now skips a repo a manual sync holds, and vice versa) so two
  `git remote update`s never race on one mirror.
- A manual request is always `--force` (ignores due-ness); state is
  recorded through the same code path cron uses (refactored into
  `record_host_sync()` / `record_repo_sync()`), so the HUD, `hosts status`
  and the weekly summary see a manual run exactly like a scheduled one.

### Manual host runs pin a named snapshot

- After a successful manual host sync the runner snapshots
  `backups-00/hosts/<name>@manual-<UTC YYYYMMDDTHHMMSSZ>[-<label>]`.
  Also available from the CLI: `hosts sync --name X --force --snapshot L`.
- **Kept until explicitly deleted** (operator decision). Sanoid's
  autoprune only touches its own `autosnap_*` names, so these survive
  indefinitely; `tourbillon hosts snapshots [--name X]` lists them and
  `hosts snapshot-rm <name> <snap>` (and a dashboard button) deletes one.
- **Privilege: a root-owned validating helper, not a sudoers wildcard.**
  `sudo zfs destroy backups-00/hosts/*@manual-*` would look narrow but
  isn't — sudoers `*` in arguments matches spaces, so extra arguments
  (`-R`, a second target) ride along. Instead the package ships
  `/usr/lib/server-backups/zfs-manual-snapshot` (root-owned, outside the
  tourbillon-owned `/opt/server-backups`), which accepts only
  `create|destroy <host> <manual-…>` with strict regexes and the fixed
  `backups-00/hosts/` parent, and `/etc/sudoers.d/server-backups` grants
  tourbillon exactly that one path. A sync failure never snapshots;
  a snapshot failure marks the request `failed` (the mirror is updated
  but the checkpoint the operator asked for doesn't exist — that must not
  read as success).

### Package-list capture on every host sync

- After the rsync paths, `capture_packages()` runs one POSIX-sh probe over
  the host's existing SSH key and writes what it finds to
  `<mountpoint>/_packages/` (`apt-manual.txt`, `dpkg-selections.txt`,
  `dpkg-versions.txt`, `rpm.txt`, `pacman-explicit.txt`,
  `brew-formulae.txt`, `brew-casks.txt`, `brew-leaves.txt`,
  `flatpak.txt`, `snap.txt`, `os-release.txt`, `sw-vers.txt`,
  `uname.txt` — whichever exist on that host).
- **Every sync, not just manual ones** — it's a few KB, and it means every
  sanoid daily *and* every manual snapshot carries the matching package
  list. `_packages` can't collide with a mirrored path (those land under
  `<mountpoint>/<basename>/`, `/` as `_root_`).
- No root needed on the target (`dpkg-query`, `apt-mark showmanual`,
  `brew list` all run unprivileged), so no target-side sudoers change and
  no host re-bootstrap. Brew is probed at `/opt/homebrew/bin` and
  `/usr/local/bin` explicitly since a non-interactive SSH session doesn't
  load the user's shell profile.
- **Best-effort:** a capture failure is a sync *warning*, never a sync
  failure — the mirror is what matters. Per-host opt-out:
  `capture_packages = false`.

### Alerting

- The runner service runs under `mail-on-output.sh "manual backup"`, so
  it mails **only on failure** (operator decision — the UI shows the
  result live). A host's failure counts toward the exit code only if its
  `mail_enabled` is true, same semantics as ADR-008. `unreachable` is
  reported in the UI but isn't a failure (same as cron).

### Dashboard

- `/config` hosts table gains a **Back up now** cell (optional label,
  `hx-confirm`). While a request is active the cell alone polls
  `/partials/host-backup/{name}` every 3s and swaps itself, so other
  rows' label inputs aren't clobbered; it stops polling when done and
  emits an `HX-Trigger` that refreshes a new **Manual snapshots** panel
  (list + delete).
- Repos panel gains **Sync now** (all repos, or one picked from a list),
  same polling cell.
- The read-only HUD shows a `syncing` / `queued` badge per host. The
  buttons exist only behind auth; all new routes use ADR-008's
  `_page_authenticated()` gate, and Phase 1 routes are unchanged.
- Status reads (`tourbillon requests status --json`) are uncached — they
  only read small state files — and stale `running` statuses (runner pid
  gone) are reported as `failed (runner exited)` rather than spinning
  forever.

## Consequences

**Good**
- A pre-upgrade checkpoint is one click (or one CLI line), survives
  dashboard restarts, and can't collide with cron.
- Every host backup now carries a restorable package list.
- The privilege boundary is clearer than before: the web process still
  has no sudo; the only new root grant is a single validating helper.

**Costs**
- Two more systemd units (`.path` + `.service`) and a root-owned helper
  plus sudoers drop-in shipped by the package — the first files this
  package installs outside `/opt/server-backups` and `/etc/systemd`.
- Manual snapshots accumulate until deleted; their space is reported in
  the snapshots panel but nothing prunes them.
- The runner processes requests sequentially; a long host sync delays a
  queued repo sync behind it (acceptable for one operator).
- `hosts status` now takes a momentary shared lock per host (to report
  `running`) — a cron sync starting in that exact instant would skip the
  host as "in progress" until the next firing. Negligible, but real.
  Snapshot listing is its own command (`hosts snapshots`), not part of
  `hosts status`, so the status path gained no `zfs` calls.

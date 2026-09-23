# Roadmap

Living execution plan, built 2026-09-23 from `GAPS.md` + `data-organizer/HOST-HYGIENE.md`
+ the two new ADRs. Ordered top-to-bottom by the priority the operator set:
bugs first, then Tier 1 (could lose data), then Active (in-progress threads
from the 2026-09-23 session), then Coverage gaps. Everything else is in the
**Backlog** at the bottom, unordered, for later triage.

Update this doc as items move — check them off, add dates, don't let it go
stale the way `GAPS.md` §2.1 did.

---

## Bugs (address first)

- [x] **rsync `--delete` semantics confirmed** (`data-organizer/HOST-HYGIENE.md`)
      — closed 2026-09-23, confirmed live via the captured process command line.
- [ ] **hondajet sync still fails solo** (`GAPS.md` §2.1) — moved to *Active*
      below since it's an open, in-progress thread, not a one-shot fix.

---

## Tier 1 — could lose data

1. - [x] **Saratoga-side restore drill** (`GAPS.md` §1.3) — done 2026-09-23,
       manual pass against `tank/archive/writing`. Send/recv clean, restored
       file valid + correct mtime. Didn't mount the live `noauto` source
       (May 31 lesson) — verified via the stream's own checksums instead.
       - [ ] **Follow-up**: script it as `tests/saratoga-restore-drill.sh`
             (mirrors `restore-drill.sh`'s shape) and add to the monthly
             cron alongside the two host drills — this run was manual only.

2. - [ ] **Mirror the pool** (`GAPS.md` §1.1). Single biggest reduction in
       catastrophic-loss probability — `backups-00` is one drive at ~88%
       full. **Needs the operator**: buy a second ~4TB drive (~$80-120);
       I can run `zpool attach` and monitor the resilver once it's
       physically installed, but can't purchase/install hardware.

3. - [ ] **Off-site copy execution** (`GAPS.md` §1.2, ADR-005). Design is
       done; execution stalled because iDrive's `.deb`-installed client is
       an Electron GUI app that rejects headless invocation, and the older
       CLI installer (`idevsutil_dedup`) appears deprecated. **Needs a
       decision**: keep chasing iDrive headless support, or pivot to
       GAPS.md's own suggested alternative (`restic` → Backblaze B2 or
       iDrive e2, ~$1.50/mo for the irreplaceable subset). Worth a short
       research spike before committing either way.

---

## Active (in-progress threads from 2026-09-23)

- [ ] **hondajet ("lynchmbp") sync reliability** (`GAPS.md` §2.1). The
      concurrency pile-up is fixed (per-host lock shipped); the host itself
      still fails solo with `rsync: [generator] write error: Broken pipe
      (32)`, almost certainly the dual-network routing gap
      (`192.168.1.x` ↔ `192.168.68.x`, no route between them). Options, not
      yet chosen between:
      - Add `--timeout=N` to `rsync_one_path()` — fails fast/clean instead
        of whatever `Broken pipe` currently resolves to; doesn't fix the
        underlying flakiness.
      - Investigate the routing gap directly, if the laptop's regularly on
        the second network during sync windows.
      - Do nothing — `--partial` + the lock fix means it should eventually
        converge over enough stable 30-min windows on its own. Monitor via
        the dashboard's hosts panel.
- [x] ~~Concurrent-rsync pile-up~~ — fixed 2026-09-23, `acquire_host_lock()`.

---

## Coverage gaps (planned, not urgent)

- [ ] **`/kodiak00/data-00`'s ~50GB irreplaceable subset unbacked up**
      (`GAPS.md` §2.4). Fix: move into a new `backups-00/historical/`
      dataset — cheap, brings it under sanoid snapshots + future off-site.
- [ ] **TrueNAS REST API deprecation** (`GAPS.md` §4.4, found 2026-09-19).
      `bin/dump-saratoga-config.sh` + `bin/apply-media-tasks.sh` need
      porting from REST to JSON-RPC 2.0/WebSocket before any saratoga
      upgrade to 26.04+. Bounded, real work — schedule ahead of that
      upgrade, not during it.
- [ ] **Kodiak itself isn't backed up** (`GAPS.md` §2.3). Low severity
      (recoverable from GitHub + PLAYBOOK). Natural fix once a second
      always-on target exists.
- [ ] **Windows host not bootstrapped** (`GAPS.md` §2.2). Blocked on an
      actual Windows machine joining the fleet — no action until then.
- [ ] **First host triage pass** (`data-organizer/HOST-HYGIENE.md`):
      `ldavis-dev-01` or hondajet. Feeds the exclude files from the
      organization side; heaviest payoff on hondajet given its size
      (526GB mirrored) but coupled to the sync-reliability work above.

---

## Backlog (unordered, lower priority — triage later)

**Small / monitoring** (`GAPS.md` Tier 3-4):
- No capacity-trending alarm (pool at ~88%, no proactive alert)
- No stale-mirror detection on the repo side (`tourbillon repos audit`)
- Token rotation reminders/automation (Bitbucket expires 2027-05-24)
- `last_size_bytes` cosmetic display bug (sums only the last path, not cumulative)
- No host-retirement procedure (`bin/retire-host.sh`)
- ZFS not encrypted at rest (pool-create-time property; would need a rebuild)
- TrueNAS API token rotation (`GAPS.md` §4.5) — **explicitly deferred by
  operator decision**, not just unprioritized. Revisit if the network's
  trust model ever changes.

**Dashboard Phase 2** (`doc/ADR-007-backup-dashboard.md`):
- Editable config: `schedule_when_up`, retry counts, include/exclude
  exclude-file entries, cron timing
- Per-host mail on/off toggle
- Basic password auth (prerequisite for the above two)
- Crontab-reinstall logic for any write endpoint that changes cron timing
- (Discussed, not committed) a read-only "credential age" indicator
  surfacing `doc/CREDENTIALS.md`'s rotation-date table — safe, no secret
  handling, could jump the queue since it's small

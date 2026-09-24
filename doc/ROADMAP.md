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

2. - [x] **Off-site copy — "is anything reaching iDrive" is closed** (`GAPS.md`
       §1.2, ADR-005) — closed 2026-09-24. Initial worry (a truncated log
       tail suggesting daily failures) was **wrong** — full per-run logs
       show 99/99 daily runs `Success` since the initial
       1.63TB/142,374-file upload completed 2026-06-01, current as of today
       (0 new files needed — steady state). The `FileNotFoundError` that
       looked alarming is iDrive's own client logging a harmless warning
       when there's no error-detail file to open (because there were no
       errors). Nothing to fix here.
       - [ ] **Follow-up, found same day**: the *scope* actually configured
             is narrower than believed. Covers `tank/active/*` +
             `tank/archive/*` (~1.65TB) only. `media/*` (~547GB) is
             excluded by design (reproducible content, matches ADR-005).
             But `backups-00/hosts/*` (arrow-iii, pilatus, lynchmbp,
             ldavis-dev-01) is **also** excluded — despite ADR-005's own
             design explicitly including hosts (~17GB estimated at design
             time). Never wired into the live backup-set config. Either
             add it, or consciously re-scope ADR-005 to document the
             exclusion as intentional.
       - [ ] **Follow-up**: restore drill from iDrive has never been
             exercised (backing up ≠ restorable) — see `GAPS.md` §1.3.
       - [ ] **Follow-up**: confirm the old workstation iDrive device was
             actually decommissioned per ADR-005's transition plan.

(Pool mirroring — moved to Backlog, 2026-09-24: operator wants to hold off on the drive-purchase decision for now.)

---

## Active (in-progress threads from 2026-09-23)

- [x] **hondajet ("lynchmbp") sync reliability** (`GAPS.md` §2.1) — resolved
      2026-09-23:
      - Concurrency pile-up: fixed, `acquire_host_lock()`.
      - Routing gap investigated: ruled out — kodiak's gateway ICMP-redirects
        toward `192.168.1.5` for the second subnet, but that path returns
        "Destination Host Unreachable." No visibility/access from kodiak to
        fix further; this is a home-router config matter, not code.
      - Added `--timeout` (`rsync_timeout`, default 300s) — closes a
        correctness gap the lock fix introduced (a truly-hung transfer would
        otherwise hold its lock forever).
      - **Result**: next sync attempt succeeded — `lynchmbp: ok`, 994.3 GB,
        caught up after over a month behind. Monitor for recurrence; no
        further action queued unless it comes back.

---

## Coverage gaps (planned, not urgent)

- [~] **`/kodiak00/data-00`'s irreplaceable subset unbacked up**
      (`GAPS.md` §2.4) — **partially fixed 2026-09-24.** Turned out the
      original plan (move into `backups-00/historical/`, blocked by the
      pool's 95% capacity) wasn't actually needed for most of this: `videos/`
      (99GB, real family footage) and `archive/` (79GB, personal document
      archives) were miscategorized in earlier reviews as "replaceable
      bulk" — corrected, and **added directly to the live iDrive backup
      set** (`data-00` is plain ext4, no `canmount=noauto` restriction, so
      no ZFS/pool-capacity involvement at all — walked through the
      interactive `./idrive` config wizard via tmux, confirmed persisted,
      "Backupset is updated"). 5TB iDrive quota, only 1.68TB used at the
      time — plenty of headroom.
      - [x] `videos/` + `archive/` (178GB) — done, added to iDrive.
      - [ ] **Follow-up**: `backups/{Alex Backup, Leigh Backup, 2018-05-06,
            ldavis-FP-mbp, saratoga-pre-migration-state, logs}` (~50GB
            old-machine backups) — same fix applies, small enough to just
            add, not yet done.
      - [ ] **Follow-up, larger**: `backups/host-backups/{2024-02-07-LynchMBP
            313G, 2026-05-19-LynchMBP 695G}` (~1TB) — needs a scope
            decision (full inclusion vs. curated subset vs. accept-as-is)
            before adding, given the size relative to the 5TB quota.
      **Context (not an open item):** the *original* pre-migration local
      copy of saratoga's mounts (12 NFS exports, ~2.67TB, at the old
      `backups-00/saratoga/`) no longer exists — that pool was wiped
      2026-05-23 to build the current TrueNAS-replication architecture.
      Only a small OS-side reference capture (`saratoga-pre-migration-state/`)
      survives; the current `backups-00/saratoga/{tank,media}` datasets are
      the sole surviving copy of saratoga's data on kodiak. Full history in
      `GAPS.md`'s "Adjacent storage" section.
- [x] **TrueNAS REST API deprecation** (`GAPS.md` §4.4, found 2026-09-19) —
      `bin/dump-saratoga-config.py` migrated to the official
      `truenas_api_client` (JSON-RPC/WebSocket), verified against live
      saratoga. `apply-media-tasks.sh` deliberately deferred — one-shot,
      non-idempotent task-creation script, no safe way to test blind, no
      current need. Revisit at the next new task of this shape, or before
      any actual 26.04 upgrade.
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

**Mirror the pool** (`GAPS.md` §1.1) — paused 2026-09-24 at the operator's
request; drive-purchase decision on hold. `backups-00` is one drive, now at
**95% full (181GB free)**, up from 88% two days ago (hondajet's 468GB
catch-up sync landing, not a leak). Confirmed via `lsblk`/`dmesg`: no spare
drive exists anywhere on kodiak (`sdb` is the live OS boot disk — HDD, not
SSD, contrary to a hallway-memory check that turned out stale; `sdc` is the
already-in-use `data-00`/`media-00` MegaRAID array) and there's free SATA
controller headroom for a new one whenever this is picked back up. Decision
still open when revisited: same-size 4TB (redundancy only, ~$80-120) vs.
larger e.g. 8TB (redundancy now + a future capacity-upgrade path via a
later `zpool replace` of the original drive).

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

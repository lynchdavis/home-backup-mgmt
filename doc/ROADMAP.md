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
       - [x] **Follow-up: scripted + cron'd, 2026-09-26.**
             `tests/saratoga-restore-drill.sh` — same 4 steps, plus
             auto-pick with retry-across-candidates (skips a technically
             non-empty but file-less dataset rather than failing on it).
             Cron entry `40 6 1 * *`, pinned to `tank/archive/writing`.
             Caught and fixed a real bash gotcha along the way: splitting
             `${PIPESTATUS[0]}`/`${PIPESTATUS[1]}` across two assignment
             statements loses index 1 under `set -u` (the first assignment
             resets PIPESTATUS to its own result) — fixed by capturing the
             array atomically (`pipe_rc=("${PIPESTATUS[@]}")`). Verified
             against the packaged install and the exact cron invocation.

2. - [x] **Off-site copy — "is anything reaching iDrive" is closed** (`GAPS.md`
       §1.2, ADR-005) — closed 2026-09-24. Initial worry (a truncated log
       tail suggesting daily failures) was **wrong** — full per-run logs
       show 99/99 daily runs `Success` since the initial
       1.63TB/142,374-file upload completed 2026-06-01, current as of today
       (0 new files needed — steady state). The `FileNotFoundError` that
       looked alarming is iDrive's own client logging a harmless warning
       when there's no error-detail file to open (because there were no
       errors). Nothing to fix here.
       - [x] **Follow-up, found same day, closed 2026-09-27**: the *scope*
             actually configured was narrower than believed. `media/*`
             (~547GB) stays excluded by design (reproducible, matches
             ADR-005). `backups-00/hosts/*` (arrow-iii, pilatus, lynchmbp,
             ldavis-dev-01) was **also** excluded despite ADR-005's design
             explicitly including hosts — fixed: all 4 added directly
             (normally-mounted `canmount=on` datasets, no ZFS workaround
             needed), confirmed persisted ("Backupset is updated").
             A manually-triggered initial run hit a "CDP client server"
             conflict with idrivecron's own already-running background
             services and stalled (0 real progress after 3.5 minutes) —
             cancelled rather than fight it. Letting tonight's regular
             03:30 cron pick up the new paths instead, same mechanism with
             a 99+ run unbroken success record. **Confirmed landed
             2026-09-29**: that night's/the following nights' scheduled
             runs picked up the new host paths and fully uploaded them —
             the 2026-09-29 run report shows 1,346,363 files already
             present (up from 195,325 before this fix), confirming the
             ~1TB host bulk upload completed. **2 files failed, both runs
             (Sep 28 initial + Sep 29 incremental), same 2 files both
             times** — macOS's own regenerable icon cache
             (`~/Library/Group Containers/group.com.apple.chronod/chronod/icons/...heic`,
             unusual `::`-containing filenames iDrive's client can't
             handle). Stable and narrow, not spreading. Not user data, not
             worth chasing further — closed as a known, accepted
             limitation.
             **Related operator decision**: the two migration-era LynchMBP
             snapshots in `data-00` (~1TB, see the coverage-gap entry
             below) will *not* be added — the live host mirror above is
             sufficient.
       - [x] **Follow-up: iDrive restore drill done, 2026-09-29.**
             No scriptable CLI exists (`idrive --help` is minimal) — drove
             the interactive menu via `tmux` (same technique as the
             backup-set edits): `7` Edit restore set → added the path,
             `8` Restore now → 1 file, 0 failures. sha256-verified an
             exact match against the known-good hash (reused the same
             file as the saratoga ZFS drill — matching hashes across two
             independent restore mechanisms is stronger proof than
             either alone). Test artifact deleted after. Walk-thru doc
             written: [`IDRIVE_RESTORE.md`](../IDRIVE_RESTORE.md).
       - [x] **Sub-follow-up: bulk/directory restore verified, 2026-09-30.**
             Restored `hosts/lynchmbp/ldavis/.gk6xplus/` (160 files, 4
             levels deep) via the restore-set editor with a directory path
             instead of a single file. 160/160 restored, 0 failed, every
             file's sha256 matched the live copy exactly, and the full
             nested structure was preserved on disk (not flattened like
             the single-file case). Confirms the *mechanism* recurses
             correctly — scale (multi-hundred-GB) remains untested but
             is a throughput question, not a correctness one. Test
             artifacts deleted after. `IDRIVE_RESTORE.md` updated.
       - [x] **Follow-up: confirmed 2026-09-29.** The old pre-kodiak
             "workstation" device (the operator's own Mac, which ran the
             iDrive Personal desktop client directly — SMB-mounted
             saratoga's shares, pushed to iDrive from the Mac itself,
             before kodiak/tourbillon existed) is gone. Checked the live
             account's device list (`13) Restore settings` → item 1):
             **only `kodiak` (Linux) is registered.** Decommissioned per
             ADR-005 step 8, nothing left to clean up. This closes out
             Tier 1 item #2 entirely — every follow-up under the off-site
             copy is now done.

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
            Initial upload triggered manually 2026-09-24 (rather than
            waiting for the next 03:30 cron) — **completed same day**:
            52,781 files, 177.07GB, 0 failures. Fully landed.
      - [x] **Reviewed + curated subset added, 2026-09-29.** The
            "~50GB irreplaceable" label was substantially wrong — actual
            breakdown:
            - **`Leigh Backup 2015-08-16` (33GB) — 99.7% is a single
              16-year-old Windows Acronis full-system-image**
              (`System__8_5_2010.tib`). Every folder that would hold real
              content (Pictures, Documents, Quicken, Outlook, Personal) is
              completely empty — this "backup" never actually captured
              personal data. **Excluded entirely** — both because it's
              junk and because it's a former family member's data the
              operator doesn't want in cloud storage regardless of
              content value.
            - **`Alex Backup` (14GB)** — 8.2GB is `Downloads/`, pure
              software installers (Steam, Chrome, GIMP, antivirus, etc.),
              0 personal value, excluded. The real content —
              `OneDrive/` (4.5GB, school papers/essays) and
              `Videos`/`3D Objects` (~650MB, personal video projects) —
              **added to iDrive**.
            - **`ldavis-FP-mbp` (822MB)** — only 20 of ~3300 files in
              `Downloads/` are real personal photos (54MB); the rest is
              AppleDouble (`._`) metadata junk plus a duplicate public
              `iTerm2-Color-Schemes` GitHub-repo clone (29MB, also found
              duplicated in `2018-05-06`). **The 20 real photos added
              individually** (iDrive's backup-set format has no
              exclude/filter syntax, so precise file-level entries were
              the only way to include just the real content).
            - **`2018-05-06` (1.1GB, operator's own old machine)** —
              dominated by a `learn-react` tutorial project (596MB) and
              the same duplicate `iTerm2-Color-Schemes` clone (62MB). The
              handful of possibly-original scraps (~1.5MB) are 8-year-old
              scratch work, likely superseded/already mirrored elsewhere.
              **Not added** — not worth the noise for that little content.
            - **`logs` (320MB)** — not personal data at all; these are
              `data-organizer`'s own migration operational logs
              (misclassified). **Not added.**
            - **`saratoga-pre-migration-state` (1.1MB)** — already known,
              OS/config reference material, not personal data. **Not
              added** (trivial either way).
            Net: added ~5.2GB of genuinely irreplaceable content out of
            the ~50GB bucket; confirmed persisted ("Backupset is
            updated," 42 total paths). Letting tonight's 03:30 cron
            handle the upload (learned from the hosts-add: manual
            triggers conflict with idrivecron's background CDP services).
      - [x] **Decided against, 2026-09-27**: `backups/host-backups/{2024-02-07-LynchMBP
            313G, 2026-05-19-LynchMBP 695G}` (~1TB) — operator's call: the
            live `backups-00/hosts/lynchmbp` mirror (added to iDrive the
            same day, see Tier 1 #2 above) is sufficient; these old
            point-in-time snapshots aren't worth the extra ~1TB. Closed
            with a decision, not left parked.
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
- [x] **First host triage pass: hondajet/lynchmbp, done 2026-09-30**
      (`data-organizer/HOST-HYGIENE.md`, `GAPS.md` §2.5). Inventoried the
      989GB mirror (`du --max-depth=2`) — found `Library/Application
      Support/` was 79% of the total, and that a real bug (not cruft) was
      the cause: three exclude patterns in `mac-user.txt`/`lynchmbp.txt`
      had trailing inline comments that rsync's `--exclude-from` never
      treats as comments, so they silently matched nothing since May
      2026. `MobileSync/` (iOS device backups, 767GB — 5 generations of
      the operator's phone + 2 copies of a family member's, one an exact
      duplicate) was the big one; `**/target/` (~8.4GB Rust build dirs)
      and `.Trashes/` (0 actual impact) the other two. Fixed in both the
      shared template and the deployed copy.
      **Operator decisions on the content**: keep `MobileSync/` syncing
      to kodiak locally (disk headroom is fine) but block it from iDrive
      via iDrive's own `15) Exclude options` (a real exclude mechanism,
      separate from the backup-set include list — not previously known
      to exist). Deleted the duplicate "Alex Copy" folder from kodiak
      outright (239GB, reclaims from the pool gradually as the ~9 days of
      snapshots already covering it age out over the sanoid dataset's
      30-day retention). Full triage note:
      [`data-organizer/manifests/lynchmbp-host-triage-2026-09-30.md`](../../data-organizer/manifests/lynchmbp-host-triage-2026-09-30.md).
      **This bug is almost certainly the real driver of `backups-00`
      sitting at 95% full** (see Backlog's "Mirror the pool" entry) —
      worth re-checking actual pool usage once the snapshot-retention
      window clears, before spending money on a second drive.
      `ldavis-dev-01`'s triage pass remains untouched — lower priority,
      not blocked on anything.

---

## Backlog (unordered, lower priority — triage later)

**Clean up `data-00`'s non-backed-up junk** — operator's stated intent
(2026-09-29), not yet actioned. Now that the old-machine-backups bucket has
been reviewed (see the Coverage gaps entry above), the junk is precisely
identified and safe to delete locally whenever convenient, reclaiming real
disk space:
- `Leigh Backup 2015-08-16/AcronisBackups/System__8_5_2010.tib` — 33GB,
  16-year-old Windows system image, unrestorable in practice.
- `Alex Backup/Downloads/` — 8.2GB of software installers.
- `ldavis-FP-mbp/Downloads/mbadolato-iTerm2-Color-Schemes-d6098c7/` +
  `2018-05-06/.../iTerm2-Color-Schemes/` — a public GitHub repo cloned
  twice, ~91MB combined, trivially re-clonable if ever wanted.
- `2018-05-06/ldavis/development/learn-react/` — 596MB tutorial project.
This is a deletion, not an exclude — see `data-organizer/HOST-HYGIENE.md`'s
own bias-to-exclude-over-delete principle; low risk here since none of it
is going anywhere valuable, but still the operator's call on timing.

**Mirror the pool** (`GAPS.md` §1.1) — paused 2026-09-24 at the operator's
request; drive-purchase decision on hold. `backups-00` is one drive, now at
**95% full (181GB free)**, up from 88% two days ago (hondajet's 468GB
catch-up sync landing — **update 2026-09-30: substantially explained by
the MobileSync exclude bug, see `GAPS.md` §2.5, not organic growth**).
239GB of that (a duplicate iPhone backup) has since been deleted, though
it reclaims gradually as sanoid snapshots age out over ~3 weeks, not
immediately. **Worth re-checking actual capacity pressure once that
settles, before committing to a drive purchase** — the real headroom
picture may look meaningfully better than 95%. Confirmed via `lsblk`/`dmesg`: no spare
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

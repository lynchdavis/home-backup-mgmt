# GAPS

What this backup system doesn't (yet) do, and why each gap matters. Living doc — review periodically (suggested cadence: once after each major change, plus a forced look every ~6 months).

**Last reviewed:** 2026-09-24.
**Reviewer:** ldavis (with Claude).
**State at review:** A1 saratoga DR + A2 repos (40) + A2 hosts (arrow-iii, pilatus, lynchmbp) all operational; tnreplicate + tourbillon kodiak-side service users in place; refactored bootstrap scripts captured. Pool `backups-00` is one drive (`WDC_WD40EFRX`), **95% full (181GB free)**. Off-site copy (§1.2) confirmed operational since 2026-06-01 — was misdocumented as open/failing until today — but covers a narrower scope than believed: `tank/*` (~1.65TB) only, not `media/*` (~547GB, by design) or `hosts/*` (a real gap against ADR-005's own design). New since May: versioned `.deb` packaging to a stable `/opt/server-backups` (ADR-006), a read-only status dashboard (ADR-007), and `dump-saratoga-config` migrated off the deprecated TrueNAS REST API — see `CHANGELOG.md`.

**Adjacent storage on kodiak** (informational, not part of the backup system):

- `/kodiak00/data-00` (sdc, ext4 LVM, 4 TB partition): historical bulk storage. **As of 2026-09-24, 1.4 TB used / 2.5 TB free.** Current top-level + `backups/` inventory, verified directly (`du -sh`):
  - **`videos/` (99GB)** and **`archive/` (79GB)** — **corrected 2026-09-24**: previous reviews lumped these into "reproducible bulk." They're not. `videos/` is real family footage (birthdays, dance recitals, dated 2004-2007); `archive/` is per-person personal document archives (`Davis_Michelle`, `Davis_Cindy`, `Davis_Lynch`, medical/aviation-related folders). **Fixed same day** — added directly to the live iDrive backup set (`/kodiak00/data-00/videos/`, `/kodiak00/data-00/archive/`), no ZFS snapshot-clone workaround needed since `data-00` is a plain always-mounted ext4 path, unlike saratoga's `canmount=noauto` datasets. iDrive account had 5TB headroom (1.68TB used of 5TB at the time), plenty of room.
  - `backups/Alex Backup` (14G), `backups/Leigh Backup 2015-08-16` (33G), `backups/2018-05-06` (1.1G), `backups/ldavis-FP-mbp` (822M), `backups/logs` (320M), `backups/saratoga-pre-migration-state` (1.1M) — the ~50GB "irreplaceable old-machine backups" bucket from earlier reviews. **Still not backed up anywhere** — smaller and lower-profile than videos/archive, not yet added to iDrive.
  - `backups/host-backups/2024-02-07-LynchMBP` (313G) and `backups/host-backups/2026-05-19-LynchMBP` (695G) — two migration-era laptop snapshots, not previously itemized in this doc — together over 1TB. **Still not backed up anywhere** — not yet evaluated for iDrive inclusion (large; worth a deliberate scope decision, not an automatic add).
  - `backups/host-backups/saratoga/` — now just an empty stub (4.0K); the 1.5TB photography copy that lived here was reclaimed 2026-05-28 (see below) after hash-verification.
  - `backups/host-backups/dev-01-cyfir` (12G) — reference pattern, see `HOST-HYGIENE.md`.
  - Genuinely reproducible, lower-priority: `iso/` (31GB) + `G1000_sim_130-002.iso` (2.2GB), `virtualbox/` (108GB), `applications/` (1.6GB). Not backed up anywhere, and reasonably so.
  `data-00` is otherwise not part of any backup mechanism (no ZFS snapshots, no sanoid, not part of A1/A2) — only the two now-added iDrive paths have any off-site coverage.

**History — the original pre-migration local copy of saratoga's mounts** (surfaced 2026-09-24, answering an operator question; not an open gap, purely for the record): before the FreeNAS/TrueNAS-CORE → TrueNAS SCALE rebuild, a full ad hoc local backup of saratoga's live NFS exports was made at `/kodiak00/backups-00/saratoga/` (12 exports, ~2.67TB, via since-removed `scripts/backup-saratoga.sh` + `backup-photography-parallel.sh`) plus a small OS-side reference capture at `saratoga-pre-migration-state/` (autofs maps, `rpcinfo`/`showmount` dumps, a TrueNAS-13.0 OS tarball). **The bulk 2.67TB copy no longer exists** — confirmed via ZFS dataset creation timestamps: the current `backups-00` pool was created 2026-05-23 21:47 ("freshly wiped" per the 2026-05-24 CHANGELOG entry), one day after the pre-migration-state capture (dated 2026-05-19) — that pool/drive was wiped to build today's TrueNAS-replication architecture. Only the small reference-state capture survives (on the separate `data-00` volume, unaffected by the wipe). **Practical consequence:** there is no way back to a pre-migration snapshot of saratoga — the current `backups-00/saratoga/{tank,media}` datasets (kept current by TrueNAS Replication Tasks, A1) are the sole surviving copy on kodiak. This was the intended outcome of the migration (per ADR-001), not an accidental loss, but worth having on record.

The point of this doc is to be honest about what could go wrong, not to chase zero risk. Personal infra; pragmatic tradeoffs are the goal. For each gap: what it is, what it costs, whether a fix is queued.

---

## Tier 1 — single points of failure

These are the gaps where one bad day = significant data loss.

### 1.1 Pool is a single disk, no parity

`backups-00` is one `WDC_WD40EFRX-68WT0N0` SATA drive. ZFS provides checksum-based corruption *detection*, but with no redundancy there's no self-repair. If `sdb` dies (mechanical, controller, firmware brick), we lose:

- 2.41 TB saratoga DR (kodiak's copy)
- 17 GB host backup mirrors (arrow-iii, pilatus, future)
- 284 MB repo mirrors (40 github + bitbucket)
- 30 days of sanoid snapshot history

The *sources* are recoverable in this scenario — saratoga is the live NAS, github/bitbucket are live, host machines are live. But the *fact of having backups* is gone, and so is point-in-time recovery (e.g., "I deleted this file 2 weeks ago" — gone).

SMART says zero errors and ~20,000 power-on hours. Reliable today; mechanical drives don't always announce themselves.

**Fix options:**

- **Mirror it**: add a second 4 TB drive, `zpool attach backups-00 <existing-by-id> <new-by-id>`. ZFS resilvers in the background, then the pool tolerates one drive loss without data loss. ~$80-120, ~3-6h resilver wall clock. This is the standard answer.
- **Accept it** and lean on the off-site tier (§1.2 below) as the second copy. Harder to do well, larger latency window.

**Queued?** No. Will be reviewed during 2026 H2.

---

### 1.2 Off-site copy — ~~zero~~ → **operational since 2026-06-01**, closed

**Update 2026-05-27**: design + transition plan now exist as ADR-005 (off-site tier via iDrive Personal on kodiak). `bin/install-idrive-on-kodiak.sh` written as a helper (download + extract + hand-off to interactive iDrive install). Still gap-open until execution completes: initial sync (~24-72h upload) + restore drill from iDrive + workstation device decommissioned.



Acknowledged in `ADR-001` and `PLAYBOOK.md` ("next architectural layer when motivated"). Today the entire data set lives in one physical location.

Fire / flood / theft / ransomware at home = everything gone except what's still on github/bitbucket/saratoga and external services.

The migration project's `MIGRATION-CHECKLIST.md` mentions an iDrive integration that needs re-pointing post-migration. Status unclear — verify whether iDrive currently has any subset of saratoga.

**Severity:** catastrophic outcome, low probability — but the kind of low probability that makes people regret not having an off-site copy *exactly once*.

**Fix options (in increasing order of effort):**

- **Smallest viable scope**: cloud cold storage (B2, Glacier, iDrive) for the irreplaceable subset only — photos + documents. ~250 GB at B2 = ~$1.50/mo storage + restore costs only when needed. Tool candidate: `restic` (encrypted, incremental, supports cold-storage targets).
- **Larger scope**: extend to all of `tank/active` (~520 MB) and `tank/finance` (small) — still tiny next to media.
- **Full off-site**: everything. 2.4 TB at B2 = ~$15/mo. Tractable but big jump.

**Update 2026-09-24, corrected same day:** an operator question ("is
backups-00 backed up to iDrive?") led to checking live state, and an
initial pass (a truncated `dashboard.log` tail showing
`IOError: getfilecontent... FileNotFoundError` at the daily 03:30 run)
was **wrongly read as evidence of daily failure** — the actual conclusion
was the opposite. Digging into the full per-run logs
(`Backup/DefaultBackupSet/LOGS/*_Success_*`) instead of the summary trace:

- **99 total daily runs since 2026-06-01. Every single one is named
  `_Success_` — zero failures, ever**, including every day this doc
  previously (wrongly) said was failing.
- **Initial full upload completed 2026-06-01**: 142,374 files, **1.63 TB**,
  0 failures.
- Every day since, the incremental run correctly finds ~0 new/modified
  files (steady state — the staging clones barely change day to day) and
  reports success. Today: 142,544 files considered, 142,544 already
  present, 0 failed, 0 newly transferred.
- The `FileNotFoundError` on `error.txt` is iDrive's own client trying to
  open a per-run error-detail file that's only created *when there are
  failures*. Since there are none, the open fails, logs a harmless
  warning, and the run completes successfully anyway — cosmetic log noise
  in iDrive's closed-source client, nothing to fix on our side.
- The "GUI rejects headless invocation" blocker this section previously
  described is also stale — resolved at some point without a doc update;
  `idrivecron.service` runs fine as a systemd daemon.

**This Tier-1 catastrophic gap is closed for the scope actually
configured.** But that scope is narrower than "the complete TrueNAS
replica" and even narrower than ADR-005's own original design — checked
2026-09-24 by diffing the live iDrive backup-set content list against the
full `backups-00/saratoga` structure:

- **Covered** (`tank/active/*` + `tank/archive/*`, ~1.65TB): aviation,
  finance-current, flightclub-personal, personal (active); books,
  employers, finance, legal, medical, personal, photography, software,
  writing (archive). The genuinely irreplaceable, non-reproducible
  material — this part is solid.
- **Not covered — `media/*` entirely** (audiobooks, movies, music flac+aac,
  tv, staging — **~547GB**): by design, per ADR-005's "irreplaceable
  subset only" scoping — reproducible/re-rippable content, reasonably
  excluded.
- **Not covered — `tank/scratch` + `tank/staging`**: transient, reasonably
  excluded.
- **Not covered — `backups-00/hosts/*`** (arrow-iii, pilatus, lynchmbp,
  ldavis-dev-01 — lynchmbp alone is 994GB): **this contradicts ADR-005's
  own documented scope**, which explicitly included "hosts (~17GB
  estimated at design time)." Never actually added to the live iDrive
  backup-set config — a real drift between design and what's running, not
  a deliberate exclusion like the two above.
- Not covered — `backups-00/repos` (308MB): absent, but trivially
  recoverable from GitHub/Bitbucket regardless — doesn't matter in
  practice.

**Still open:** wiring `backups-00/hosts/*` into the iDrive backup set (to
actually match ADR-005's design) or consciously re-scoping ADR-005 to
document the exclusion as intentional. The restore drill from iDrive
(§1.3) has also never been exercised — backing up is verified, restoring
is not. The "decommission the workstation device" step from ADR-005's
transition plan hasn't been explicitly confirmed done either.

**Queued?** The "is anything reaching iDrive at all" catastrophic gap:
closed 2026-09-24. The hosts-not-included scope gap, and the restore
drill: not started, tracked in `doc/ROADMAP.md`.

---

### 1.3 No restore drill has ever been done ~~(open)~~ → addressed for hosts and saratoga; iDrive still TODO

**Update 2026-05-27:** host-side restore drill is now a script + cron job.

- **`tests/restore-drill.sh <host> [<file>]`** — does the three checks (mirror hash, source hash, reverse-rsync-back hash) and exits non-zero on any mismatch. Refuses symlinks (they cross-path; the backup is scoped). Silent on success; cron-mail-friendly. `--verbose` shows all three hashes.
- **Cron entries on ldavis** at `30 6 1 * *` (arrow-iii) and `35 6 1 * *` (pilatus) — monthly drill, silent on success, cron mails any failure. Captured in `configs/cron/ldavis-crontab`.
- **First-ever drill executed 2026-05-27** against arrow-iii (`/etc/hostname`) and pilatus (`/etc/hostname`) — both passed with three matching hashes.

**Update 2026-09-23:** saratoga-side drill executed manually, passed.

- Ran the exact four steps below against `backups-00/saratoga/tank/archive/writing@auto-tank-2026-09-23_02-00` (chosen for being small — a `zfs list -r` size check, not a random pick).
- `zfs send | zfs recv` completed clean (exit 0) — ZFS's own embedded stream checksums are the real integrity proof here: a corrupted stream fails the receive, it doesn't silently succeed.
- Spot-checked one restored file (a PDF): valid per `file`, correct original mtime preserved, sha256 recorded for the record.
- **Did not** mount the live `backups-00/saratoga/tank/archive/writing` dataset to compare directly — it's deliberately `canmount=noauto` (the May 31 incident's hard-learned lesson), so verification used the send/recv stream's own guarantees plus a file-validity spot-check instead of a live-mount comparison.
- **Not yet scripted/cron'd** — this was a manual, one-off run. Worth turning into a `tests/saratoga-restore-drill.sh` mirroring `restore-drill.sh`'s shape (pick smallest dataset, or a configured one; run the 4 steps; verify + report; exit non-zero on failure) and adding to the monthly cron alongside the two host drills.

```
1. sudo zfs create backups-00/restore-test
2. sudo zfs send <source>@<snapshot> | sudo zfs recv backups-00/restore-test/<dataset>
3. Spot-check a file: `file <path>` + sha256 (don't mount the live source — see above)
4. sudo zfs destroy -r backups-00/restore-test
```

**Still open for iDrive (off-site tier) side:** ADR-005 wires the off-site backup but no restore has been exercised. The eventual shape: an automated CLI-driven test (`idrive` CLI is the operational interface for restoration — that's the reality) that pulls a known file from the off-site copy and verifies it, PLUS a generated walk-thru doc the operator can actually follow in a real DR (fire / theft / ransomware) when they're not thinking clearly. Automation proves the path still works; the doc is what gets used at 2 AM. Until both exist, the off-site tier is unverified. Blocked on off-site execution itself (§1.2) happening first.

**Queued?** Saratoga drill: manual pass done 2026-09-23; scripting it is a follow-up. iDrive drill + walk-thru doc: blocked on §1.2.

---

## Tier 2 — coverage holes (planned, not done)

### 2.1 LynchMBP ("hondajet") bootstrapped, but sync reliability is unresolved

**Update 2026-09-23**: bootstrapped and operational — closing the original
"not yet bootstrapped" gap — but two problems surfaced the same day:

- **Concurrency pile-up (fixed).** No per-host lock meant a sync that
  outlasted one 30-min cron interval got a second, fully independent
  `rsync --delete` launched on top of it at the next firing. By the time
  this was caught, 11 concurrent rsyncs were racing the same destination —
  a real corruption risk (concurrent `--delete` passes), not just wasted
  bandwidth. Fixed: `acquire_host_lock()` in `bin/tourbillon` (per-host
  `flock`, non-blocking, held for the sync's full duration).
- **Still open: the host itself is flaky.** Even a single, uncontested sync
  attempt has twice failed with `rsync: [generator] write error: Broken
  pipe (32)` — the laptop roams between two networks (`192.168.1.x` home,
  `192.168.68.x` other) with no routing between them, and the connection
  appears to drop mid-transfer rather than cleanly closing. `host` now
  accepts multiple candidate IPs (tries each, uses whichever answers — see
  `lynchmbp.toml`), which fixed *finding* the host but not the mid-transfer
  drops. `--partial` means each attempt keeps whatever progress it made, so
  this should eventually converge over enough 30-min cycles, but it hasn't
  yet (`last_success_at` is still over a month old as of this review).

**Update 2026-09-23 (later same day):** investigated the routing option
first — kodiak's gateway (`192.168.1.1`) actually returns an ICMP redirect
toward `192.168.1.5` for `192.168.68.x` traffic, suggesting a second
router/AP bridges that segment, but pinging through it returns
"Destination Host Unreachable." That's a home-router configuration matter
with zero visibility or access from kodiak — ruled out as something fixable
in this codebase.

Added `--timeout` instead (`rsync_timeout`, default `300s`, new field in
`configs/hosts/defaults.toml`) — this turned out to matter more than
originally scoped: the per-host lock above means a *truly hung* (not just
broken-pipe-terminated) transfer would now hold its lock forever and lock
the host out of every future attempt, with nothing previously bounding
that. `--timeout` closes that gap regardless of what caused hondajet's
specific flakiness.

**Result:** the very next sync attempt succeeded outright — `hosts status`
now shows `lynchmbp: ok`, last success 3.8h ago, 994.3 GB (up from 526.6 GB,
reflecting over a month of accumulated changes finally landing). Whether
that was the lock fix removing contention, a stable network window, or
both, is unclear — but the host is caught up as of this review.

**Queued?** Concurrency + timeout fixes shipped. Monitor via the
dashboard's hosts panel or `tourbillon hosts status` for recurrence; no
further action unless it does.

---

### 2.2 Windows host not yet bootstrapped

Per `ADR-003`, prereq checklist on the target:

1. Install OpenSSH Server (Windows feature)
2. Install cwRsync (or WSL2 rsync)
3. Confirm `C:\Users\<user>\.ssh\authorized_keys` exists with correct ACLs

Then on kodiak: same `bootstrap-from-kodiak-single-user.sh`, just with Windows path conventions (`/cygdrive/c/Users/...` or `/mnt/c/Users/...`) in the per-host config.

**When:** when an actual Windows machine surfaces in the fleet.

---

### 2.3 Kodiak itself isn't backed up

Kodiak holds:

- The `server-backups` repo at `/home/ldavis/development/systems-tools/server-backups/` (recoverable from github)
- Other home-dir state (shell history, settings)
- `/etc` drift (some manual config from the PLAYBOOK steps)
- The crontabs (captured in `configs/cron/`)
- `~tourbillon/.config/tourbillon/env` (the ONLY copy of the github + bitbucket tokens — these are also in 1Password or similar, right?)

Kodiak's *system* is rebuildable from PLAYBOOK. Anything *uncommitted* in `~ldavis` would be lost if kodiak dies.

**Fix options:**

- Once LynchMBP joins the fleet, treat kodiak as another linux target (`paths = ["/home/ldavis", "/etc"]`). Use a SECOND kodiak — i.e., the user's mac — as the backup destination. Symmetrical to how kodiak backs up arrow-iii.
- Or just keep using `git push` discipline + a personal-password-manager copy of the tokens.

**Severity:** low. Mostly recoverable from github + a fresh OS install.

---

### 2.4 `/kodiak00/data-00/` historical bulk storage — mostly still unbacked up, corrected + partially fixed 2026-09-24

Surfaced 2026-05-27 during the LynchMBP onboarding discussion. Kodiak has 21.8 TB of LVM-ext4 on `sdc` (`/kodiak00/data-00` + `/kodiak00/media-00`, the latter confirmed 2026-09-24 to be completely empty). As of 2026-09-24, `data-00` holds ~1.4 TB:

- **`videos/` (99GB) + `archive/` (79GB) — irreplaceable, previously miscategorized as "replaceable bulk."** `videos/` is real family footage; `archive/` is per-person personal document archives. **Fixed 2026-09-24**: both added directly to the live iDrive backup set (no ZFS workaround needed — `data-00` is plain ext4, not subject to the `canmount=noauto` restriction saratoga's datasets have).
- **~50GB irreplaceable, still unbacked up**: `backups/{Alex Backup, Leigh Backup 2015-08-16, 2018-05-06, ldavis-FP-mbp, saratoga-pre-migration-state, logs}`. Old-machine backups; those machines are gone. **Single copy on a single disk.**
- **~1TB irreplaceable, still unbacked up, found 2026-09-24**: `backups/host-backups/{2024-02-07-LynchMBP, 2026-05-19-LynchMBP}` — two migration-era laptop snapshots. Larger than the other two buckets combined; needs a deliberate scope/cost decision before adding to iDrive (unlike videos/archive, which were small enough to just add).
- **Genuinely reproducible, lower priority**: `applications/` (1.6GB), `iso/` + `G1000_sim_130-002.iso` (~33GB), `virtualbox/` (108GB). Not backed up, reasonably so.

**Severity:** medium-high for the two still-unbacked-up irreplaceable buckets (~1TB+, not ~50GB as this section said until today) — if `sdc` dies, those bytes are gone permanently.

**Fix options:**

- **For the ~50GB old-machine-backups bucket**: same approach as videos/archive — just add the paths to the iDrive backup set directly. Small enough not to need a scope discussion.
- **For the two LynchMBP snapshots (~1TB)**: needs a decision first — full inclusion, a curated subset, or accept as-is — before adding, given the size.
- **Move into `backups-00/historical/`** (a new ZFS dataset under the managed pool) was the original fix idea here — now less relevant for videos/archive/old-machine-backups since direct iDrive inclusion is simpler and doesn't touch the already-95%-full `backups-00` pool at all.

**Queued?** videos/archive: done 2026-09-24 (initial upload run triggered manually same day). Old-machine-backups (~50GB) and the LynchMBP snapshots (~1TB): parked — operator wants to personally review contents before either is added, not a technical blocker.

### 3.1 No capacity-trending alarm

`tourbillon status` reports `capacity_pct` (today 66%). No proactive alert when it crosses, say, 80% or 90%. Saratoga DR dominates and grows with your live data — if you take a lot of new photos, this number moves.

**Fix:** add a tiny cron job (operator-side) that runs `tourbillon status` and, when `capacity_pct >= 80`, mails. Easy.

---

### 3.2 No stale-mirror detection on the repo side

If you delete or archive a repo on github (or transfer ownership, or just stop pushing), the local mirror keeps existing. `tourbillon repos issues` would catch *sync failures*, not *gone-from-source*.

Today this is low priority — you have ~40 repos and probably remember them all. As the fleet grows, drift compounds.

**Fix:** add a `tourbillon repos audit` subcommand that compares the configured repo list against what the github + bitbucket APIs say still exists.

---

### 3.3 Token rotation reminders

Documented in `CHANGELOG.md`:

- Bitbucket token expires **2027-05-24**
- GitHub PAT has no expiry (rotate at will)

Both are in `~tourbillon/.config/tourbillon/env` (mode 600, ADR-004). When the Bitbucket one expires, the repos cron will start mailing failures — so it won't pass silently. But proactive is better than reactive.

**Fix:** a calendar entry on 2027-04-24 ("Bitbucket token expires in 30 days"). Even cleaner: a small cron job that decodes the JWT expiry and alarms at T-30d. Probably overkill.

---

### 3.4 `last_size_bytes` cosmetic gap

Host state file's `last_size_bytes` only captures the *last* rsync-path's transferred bytes, not the cumulative. So `tourbillon status` shows e.g. 14.5 GB for pilatus when ZFS knows the real total is 16.3 GB.

Real data on disk is fine. Display is misleading. Easy fix: sum across paths in `sync_one_host`.

---

## Tier 4 — small / latent

### 4.1 No host-retirement procedure

If a machine is decommissioned permanently, leaving `configs/hosts/<name>.toml` in place will cause cron to keep firing `unreachable` probes forever. No `bin/retire-host.sh` exists.

**Fix when needed:** small script — delete the config, destroy the ZFS child dataset (with snapshot retention), remove the per-host SSH key. Could be a checklist in HOSTS_RESTORE.md or its own doc.

---

### 4.2 ZFS not encrypted at rest

`backups-00` was created without `encryption=on`. If kodiak is physically stolen, `/dev/sdb` reads cleartext.

For a locked house, single-user threat model: usually fine. But irrecoverable to retrofit — encryption is a pool-create property. Would require a new pool + send/recv.

**Severity:** low for current threat model. Worth a one-line note in any future "pool rebuild" event.

---

### 4.3 Cron mail delivery — ~~unconfirmed~~ → closed (2026-05-27): msmtp → gmail

Closed today. msmtp + gmail SMTP forwarder set up; tested end-to-end from both ldavis and tourbillon; both messages landed in the operator's gmail inbox.

- `msmtp` + `msmtp-mta` installed. `/usr/sbin/sendmail` now → `/usr/bin/msmtp`. exim4 stopped + disabled (still installed for quick rollback if needed).
- `~ldavis/.msmtprc` and `~tourbillon/.msmtprc` written (mode 600, gmail app password embedded). See `doc/CREDENTIALS.md` → "Gmail app password (`kodiak msmtp`)" for rotation path.
- `MAILTO=lynchdavis0@gmail.com` in both crontabs (was `MAILTO=ldavis`). Cron now hands the message directly to msmtp with an external recipient — no local-delivery / alias-resolution stops along the way.
- Verified: three test sends (ldavis manual, tourbillon manual, tourbillon cron-style) — all three accepted by gmail with `250 2.0.0 OK`; both emails confirmed received by the operator.

**New failure mode to be aware of**: if the gmail app password gets revoked or the gmail account password changes, msmtp will fail to send and the cron mail is **lost** (msmtp doesn't queue or retry). Visible in `~/.msmtp.log` as a `535-5.7.8` auth error. Future improvement: wire a tiny check that greps the log for recent auth failures, alerts via some other path.

---

### 4.4 Saratoga REST API deprecated — `dump-saratoga-config` migrated; `apply-media-tasks.sh` deliberately deferred

Surfaced 2026-09-19 via a saratoga UI notification: the deprecated TrueNAS REST API was used to authenticate once in the prior 24h from `192.168.0.61` (kodiak's private 10GbE IP) — that's our own tooling, not an external caller. TrueNAS is removing the REST API in **26.04** in favor of JSON-RPC 2.0 over WebSocket.

**Update 2026-09-24: `bin/dump-saratoga-config.py` migrated and verified
live.** Rewritten from bash+curl+jq to Python using the official
`truenas_api_client` library (installed from GitHub — not on PyPI — into
its own `bin/.venv`, pinned to tag `TS-25.10.3.1` matching saratoga's
actual TrueNAS version). Notes for whoever touches this next:

- The pinned-tag client's `auth.login_with_api_key(token)` is a single
  positional call — no username, no mechanism choice. **This will very
  likely change** when saratoga is eventually upgraded to 26+: the
  library's `master` branch already has a SCRAM/PLAIN auth-mechanism split
  (`login_with_api_key(username, key, auth_mechanism=...)`) that this
  older pinned version predates. Re-pin `bin/requirements.txt` to the
  matching tag at upgrade time and expect to update the auth call, not
  just the pin.
- Verified against the live server: all four `.query` calls (`replication`,
  `pool.snapshottask`, `keychaincredential` ×2) return identical data to
  the old REST version (diff was 100% legitimate content drift — different
  job IDs/timestamps between the stale dump and today's live state, not a
  format regression) except one deliberate improvement: TrueNAS date
  fields now serialize as ISO-8601 strings instead of the old
  `{"$date": <epoch-ms>}` extended-JSON wrapper the REST+jq path produced
  verbatim — more readable for the git-diff-driven review workflow these
  files exist for, and nothing else in the repo parses them.
- Packaging updated: `bin/.venv` is built by `postinst` alongside the
  dashboard's, from `bin/requirements.txt`. `PLAYBOOK.md`'s invocations now
  show the explicit `bin/.venv/bin/python3 bin/dump-saratoga-config.py`
  form — the script's own shebang's system python3 does **not** have the
  dependency installed.

**`bin/apply-media-tasks.sh` — deliberately deferred, not forgotten.**
Unlike the read-only, periodically-rerun `dump-saratoga-config`, this is a
one-shot, **non-idempotent** script that *creates* replication/snapshot
tasks — re-running it (even to test a migrated version) would create
duplicate tasks on live saratoga config. It already did its one job (the
media task it creates exists and runs). Porting it blind, with no safe way
to test the write path without side effects, isn't worth doing before
there's an actual reason to (a new task following this same pattern, or
the 26.04 upgrade actually being scheduled) — at which point it should be
ported using the same `truenas_api_client` approach, tested against
whatever new task is actually being created.

**Queued?** `dump-saratoga-config`: done 2026-09-24. `apply-media-tasks.sh`:
not started, deliberately — before any saratoga upgrade to 26.04, or when
a new task needs creating, whichever comes first.

---

### 4.5 TrueNAS API token was exposed in kodiak's systemd journal (rotation deferred)

2026-09-23: while wiring the dashboard's `EnvironmentFile=` for
`~tourbillon/.config/saratoga/env`, a malformed line caused systemd to log
the offending line — including the literal `TRUENAS_API_TOKEN` value —
into its own journal, and a debugging `journalctl | grep` echoed it into
that session's output. Fixed the file format so it can't recur, but the
old value is still sitting in plaintext in kodiak's journal (no
`MaxRetentionSec` configured, so it ages out by disk pressure, not time —
could be weeks).

**Operator decision (2026-09-23):** rotation deferred — closed home
network, not considered a realistic target. Documented here rather than
silently dropped, per `doc/CREDENTIALS.md`'s existing rotation-path
convention.

**Fix, whenever convenient:** TrueNAS UI → Credentials → Local Users →
root → API Keys → Add, then delete the old key in the same screen, then
update `~/.config/saratoga/env` directly (not pasted through a chat
session) and re-sync `~tourbillon`'s copy.

**Queued?** No — accepted risk per operator.

---

## Recommended next moves, in priority order

1. ~~**Restore drill (host side)** (§1.3).~~ ✓ done 2026-05-27 — scripted + wired to monthly cron.
2. ~~**Confirm cron mail works** (§4.3).~~ ✓ done 2026-05-27 — msmtp → gmail.
3. ~~**Bootstrap LynchMBP** (§2.1).~~ ✓ done, but see §2.1's 2026-09-23 update — sync reliability is the new open thread there.
4. **hondajet sync reliability** (§2.1) — the most recently active gap; monitor via the dashboard, consider `rsync --timeout` or the routing investigation if it doesn't self-resolve over the next several cycles.
5. **Saratoga restore drill** (§1.3 follow-up). `zfs send | zfs recv` into a `restore-test` dataset; sha256 a file; destroy. Same five minutes.
6. **Mirror the pool** (§1.1, ~$100/half-day) — single biggest reduction in catastrophic-loss probability; pool is at ~88% capacity, worth pairing with a capacity conversation.
7. **Off-site tier execution** (§1.2) — design exists (ADR-005), execution stalled on iDrive's headless-client issue.
8. **TrueNAS REST API migration** (§4.4) — no urgency until a saratoga upgrade to 26.04 is planned, but bounded real work, worth scheduling ahead of that upgrade rather than during it.

Everything else can wait until something forces it.

---

## How to use this doc

- Open it after every major architectural change to see if a gap closed or opened.
- Date the "Last reviewed" line each time.
- Move items from one tier to another as severity changes (e.g., once we add the mirror, §1.1 retires).
- Cross-link to ADRs when a gap becomes a decision: §1.2 will get its own ADR when the off-site tier is designed.

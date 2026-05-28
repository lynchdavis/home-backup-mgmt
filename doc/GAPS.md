# GAPS

What this backup system doesn't (yet) do, and why each gap matters. Living doc — review periodically (suggested cadence: once after each major change, plus a forced look every ~6 months).

**Last reviewed:** 2026-05-28.
**Reviewer:** ldavis (with [[Claude]]).
**State at review:** A1 saratoga DR + A2 repos (40) + A2 hosts (arrow-iii, pilatus) all operational; tnreplicate + tourbillon kodiak-side service users in place; refactored bootstrap scripts captured. Pool `backups-00` is one drive (`WDC_WD40EFRX`), 2.43 TB used of 3.5 TB raw.

**Adjacent storage on kodiak** (informational, not part of the backup system):

- `/kodiak00/data-00` (sdc, ext4 LVM, 4 TB partition): historical bulk storage. **As of 2026-05-28, 1.4 TB used / 2.5 TB free** (was 3.5 TB used / 331 GB free before reclamation). The reclaim removed `host-backups/saratoga/photography` (1.5 TB, verified redundant per migration checklist) and `data-00/photography` staging (625 GB, same provenance). What's left is ~50 GB of irreplaceable old-machine backups (Alex/Leigh/2018/FP-mbp/saratoga-pre-migration) plus ~1 TB of bulk content (videos, ISOs, virtualbox images, applications). None of `data-00` is backed up anywhere — see §2.4 below.

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

### 1.2 Zero off-site copy ~~(open)~~ → design committed 2026-05-27 via [ADR-005](ADR-005-off-site-tier-idrive.md); execution pending

**Update 2026-05-27**: design + transition plan now exist as ADR-005 (off-site tier via iDrive Personal on kodiak). `bin/install-idrive-on-kodiak.sh` written as a helper (download + extract + hand-off to interactive iDrive install). Still gap-open until execution completes: initial sync (~24-72h upload) + restore drill from iDrive + workstation device decommissioned.



Acknowledged in `ADR-001` and `PLAYBOOK.md` ("next architectural layer when motivated"). Today the entire data set lives in one physical location.

Fire / flood / theft / ransomware at home = everything gone except what's still on github/bitbucket/saratoga and external services.

The migration project's `MIGRATION-CHECKLIST.md` mentions an iDrive integration that needs re-pointing post-migration. Status unclear — verify whether iDrive currently has any subset of saratoga.

**Severity:** catastrophic outcome, low probability — but the kind of low probability that makes people regret not having an off-site copy *exactly once*.

**Fix options (in increasing order of effort):**

- **Smallest viable scope**: cloud cold storage (B2, Glacier, iDrive) for the irreplaceable subset only — photos + documents. ~250 GB at B2 = ~$1.50/mo storage + restore costs only when needed. Tool candidate: `restic` (encrypted, incremental, supports cold-storage targets).
- **Larger scope**: extend to all of `tank/active` (~520 MB) and `tank/finance` (small) — still tiny next to media.
- **Full off-site**: everything. 2.4 TB at B2 = ~$15/mo. Tractable but big jump.

**Queued?** Separate ADR pending. Most-irreplaceable subset first.

---

### 1.3 No restore drill has ever been done ~~(open)~~ → addressed for hosts, still TODO for saratoga

**Update 2026-05-27:** host-side restore drill is now a script + cron job.

- **`tests/restore-drill.sh <host> [<file>]`** — does the three checks (mirror hash, source hash, reverse-rsync-back hash) and exits non-zero on any mismatch. Refuses symlinks (they cross-path; the backup is scoped). Silent on success; cron-mail-friendly. `--verbose` shows all three hashes.
- **Cron entries on ldavis** at `30 6 1 * *` (arrow-iii) and `35 6 1 * *` (pilatus) — monthly drill, silent on success, cron mails any failure. Captured in `configs/cron/ldavis-crontab`.
- **First-ever drill executed 2026-05-27** against arrow-iii (`/etc/hostname`) and pilatus (`/etc/hostname`) — both passed with three matching hashes.

**Still open for saratoga side:** `SARATOGA_RESTORE.md` has the `zfs send | zfs recv` test command, but it hasn't been executed and isn't on a cron. Different shape — ZFS-native, not rsync. Worth scripting similarly:

1. `sudo zfs create backups-00/restore-test`
2. `sudo zfs send backups-00/saratoga/tank/<small-dataset>@<snapshot> | sudo zfs recv backups-00/restore-test/<dataset>`
3. Spot-check a file via `zfs list -r` + sha256
4. `sudo zfs destroy -r backups-00/restore-test`

**Queued?** Saratoga drill: yes, follow-up. Tracked here.

---

## Tier 2 — coverage holes (planned, not done)

### 2.1 Mac (LynchMBP) not yet bootstrapped

Single-user flow per `ADR-003` is ready:

- `bin/bootstrap-from-kodiak-single-user.sh` (refactored: IP arg, `accept-new`, preflight)
- `configs/hosts/excludes/mac-user.txt` ported from `data-organizer/excludes/lynchmbp.txt`
- Per-host config template printed at end of the bootstrap script

Just hasn't been run.

**When:** convenient. The scripts are warm; while you remember the flow is the cheap moment.

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

- The `server-backups` repo at `/home/ldavis/development/server-backups/` (recoverable from github)
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

### 2.4 `/kodiak00/data-00/` historical bulk storage isn't backed up

Surfaced 2026-05-27 during the LynchMBP onboarding discussion. Kodiak has 21.8 TB of LVM-ext4 on `sdc` (`/kodiak00/data-00` + `/kodiak00/media-00`). As of the 2026-05-28 reclamation, `data-00` holds ~1.4 TB:

- **~50 GB irreplaceable**: `data-00/backups/{Alex Backup, Leigh Backup 2015-08-16, 2018-05-06, ldavis-FP-mbp, saratoga-pre-migration-state, logs}`. Old-machine backups; those machines are gone. **Single copy on a single disk.**
- **~1 TB replaceable bulk**: `data-00/{applications, archive, iso, videos, virtualbox}` + leftover `data-00/backups/host-backups/`. Re-downloadable / re-buildable, mostly.

The irreplaceable ~50 GB is the real concern: if sdc dies, those bytes are gone permanently and the original machines no longer exist to reconstitute them.

**Severity:** medium. Low probability (drive failure) × catastrophic outcome (irrecoverable) × small subset (50 GB).

**Fix options:**

- **Move the irreplaceable subset into `backups-00/historical/`** — a new ZFS dataset under the managed pool. 50 GB doesn't move the needle on `backups-00` capacity, and it brings the bytes under sanoid snapshots + (eventually) iDrive off-site. Cheapest, biggest reduction in loss-probability.
- **Accept as-is** — recognize that those 50 GB live on one disk and will be gone if it dies.

**Queued?** Not started. Worth doing alongside the next operational pass.

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

## Recommended next moves, in priority order

1. ~~**Restore drill (host side)** (§1.3).~~ ✓ done 2026-05-27 — scripted + wired to monthly cron.
2. **Today / this week — confirm cron mail works** (§4.3). The restore-drill cron will silently swallow failures if mail doesn't actually deliver. Verify before relying on it.
3. **This week — saratoga restore drill** (§1.3 follow-up). `zfs send | zfs recv` into a `restore-test` dataset; sha256 a file; destroy. Same five minutes.
4. **Next opportunity (~$100, ~half a day) — mirror the pool** (§1.1). Single biggest reduction in catastrophic-loss probability.
5. **While the scripts are warm — bootstrap LynchMBP** (§2.1).
6. **Separate ADR — off-site tier** (§1.2). Most-irreplaceable subset first.

Everything else can wait until something forces it.

---

## How to use this doc

- Open it after every major architectural change to see if a gap closed or opened.
- Date the "Last reviewed" line each time.
- Move items from one tier to another as severity changes (e.g., once we add the mirror, §1.1 retires).
- Cross-link to ADRs when a gap becomes a decision: §1.2 will get its own ADR when the off-site tier is designed.

# Changelog

Pragmatic record of functional changes to this backup system. Conceptual
material (name origins, design rationale) lives in `doc/`. Operational
how-to lives in `PLAYBOOK.md`.

Most-recent first.

## 2026-05-26

### Added — `bin/idrive-refresh-clones.sh` (snapshot-clone mount strategy)

The script that lets iDrive scan saratoga data without breaking A1 replication. Per the 2026-05-31 incident: live `backups-00/saratoga/*` datasets MUST stay unmounted, but iDrive needs files on a filesystem. Solution: clone the latest sanoid autosnap of each saratoga child dataset, mount the clones under `backups-00/idrive-staging/*`, point iDrive at the clones. Refresh daily.

- **`bin/idrive-refresh-clones.sh`**:
  - Source list of saratoga children to clone (photography + 8 archive subdirs + 4 active subdirs).
  - For each: destroy yesterday's clone (best-effort unmount first), clone the latest snapshot to `backups-00/idrive-staging/tank-archive-photography` (etc.), mount at `/kodiak00/backups-00/idrive-staging/tank-archive-photography`.
  - `--dry-run` flag prints all the zfs operations without doing them. `--verbose` reports per-dataset progress. Default is cron-friendly silent on full success.
  - Designed for daily cron at ~02:30 (after A1 lands fresh snapshots at 02:00, before `idrivecron.service` fires).
  - Exit non-zero if any dataset failed (cron mail will surface via mail-on-output wrapper).
  - Tested with `--dry-run` against current state — found expected snapshots, planned correct clone + mount commands. Real first run waits for the live iDrive setup.

The cron entry to add (when iDrive is ready):

```
30 2 * * *  /home/ldavis/development/server-backups/bin/idrive-refresh-clones.sh
```

(Runs as root since zfs ops need it. Either /etc/cron.d/ entry or root's crontab.)

### Incident — A1 saratoga replication broke (2026-05-31 02:00), recovered

The "just mount the saratoga datasets so iDrive can scan them" approach from ADR-005 finally bit. Replication worked for ~3 days after we mounted them (kodiak-side, in prep for iDrive setup), then today's 02:00 run hit `zfs recv -F` trying to unmount the destinations and failing (tnreplicate isn't root; can't unmount on Linux). Both tank + media replication tasks went to ERROR state in TrueNAS.

Recovery:
- Recursively unmounted every saratoga dataset on kodiak (deepest-first; ZFS-on-Linux has no `unmount -R`, so iterated `zfs list | tac | xargs zfs unmount`).
- Set `canmount=noauto` on all saratoga children (was only on the parent before). Prevents accidental future remount via `zfs mount -a` or boot.
- A1 will run normally at tonight's 02:00; TrueNAS state will reset to FINISHED.

Lessons:
- PLAYBOOK §3's "canmount=noauto everywhere on saratoga" rule is load-bearing. The "exception for iDrive" in ADR-005's mount strategy was wrong.
- iDrive integration when resumed must use the snapshot-clone fallback (clone a sanoid autosnap → mount the clone → iDrive reads from clone → rotate). Documented in ADR-005's mount section.

**iDrive setup itself is on pause** for a different reason: the `.deb`-installed iDrive 1.7.0 is an Electron GUI app and rejects headless invocation ("No graphical display detected"). The older `.bin.gz` installer with `idevsutil_dedup` CLI that ADR-005 was designed around appears deprecated. Web search for current iDrive headless support is the next step. If no good answer, ADR-005 may need to pivot to iDrive e2 + rclone (or Backblaze B2 + restic).

### Polished — cron-mail subject lines + HTML weekly summary

Two related quality-of-life upgrades for the mail notification stack:

- **`bin/mail-on-output.sh`** — generic wrapper for cron entries. Runs the wrapped command, silently exits if there's no output AND exit code is 0 (cron-friendly), otherwise self-mails via msmtp with a meaningful subject:
  - `kodiak: <tag> FAILED (exit N)` on non-zero exit
  - `kodiak: <tag> — output captured (exit 0)` when the command produces output but succeeds (e.g., `tourbillon repos sync --quiet` reporting that a repo actually got synced)
  Preserves the wrapped command's exit code so `set -e` callers see the real result. Tested across all three cases (silent, success-with-output, failure).
- **Both crontabs updated** to invoke their existing commands via `mail-on-output.sh`. Cron's default `Cron <user@host> command_text...` subject no longer ends up in gmail — every alert now has a useful Subject line scannable at-a-glance.
- **`bin/weekly-summary.sh` rewritten as multipart/alternative** (text/plain + text/html). Gmail and modern clients render the HTML version (status badge with green/red color cue, formatted blocks for the status rollup and issues section, footer noting "heartbeat — absence is itself a signal"). Text-only readers (mutt, plain SMTP, etc.) see a cleaned-up ASCII version that mirrors the same structure with less visual clutter than the previous all-ASCII version. The Subject line gains a "— ATTENTION" suffix when any subsystem reports issues (visible at-a-glance in the inbox list).

The on-failure cron mails still fire immediately. The weekly heartbeat still arrives Sunday morning. Difference is that everything now lands with a Subject line the reader can act on without opening the message.

### Reclaimed — 2.1 TB on `/kodiak00/data-00/` (migration-staging photography)

Cleaned up the two photography subtrees that the `data-organizer` migration checklist had marked verified-redundant since 2026-05-22 but never deleted:

- `/kodiak00/data-00/backups/host-backups/saratoga/photography/` — 1.5 TB, 108,051 files. Pre-migration working copy. 99.97% hash-verified redundant per checklist; the 1 truly-unique file (`2019 Stephen Davis school.png`) was rescued into the canonical `PhotoArchive` during the original verification.
- `/kodiak00/data-00/photography/` — 625 GB, 12,592 files. Staging tree from the same migration; verified fully redundant.

Pre-reclamation safety checks (in addition to the original 2026-05-22 hash verification):

- Confirmed A1 replica `backups-00/saratoga/tank/archive/photography` has 1.61 TB live (untouched).
- Confirmed the rescued unique file is present at the reorganized A1 path.
- Sample staging file sha256-matches its byte-identical copy in A1 under reorganized path structure (`2002/.../DSC00083_edited-2.JPG` → `PhotoArchive_0000_2009/2002/.../same`).

Results: data-00 went from 92% full (331 GB free) to 36% full (2.5 TB free). A1 photo replica untouched. Both `MIGRATION-CHECKLIST.md` items marked complete.

`doc/GAPS.md` updated:
- "State at review" notes the new data-00 layout
- New §2.4 captures the remaining `data-00/` exposure — ~50 GB of irreplaceable old-machine backups (Alex/Leigh/2018/FP-mbp/saratoga-pre-migration) still live on a single unbacked-up disk. Worth migrating into `backups-00/historical/` to fold under the same snapshot + future-iDrive coverage as the rest.

### Polished — cron mail subjects + HTML-tabular weekly summary

Two related quality-of-life upgrades to the notification stack.

**Subject lines (mail-on-output wrapper):**
- **`bin/mail-on-output.sh`** — generic wrapper for cron entries. Captures stdout+stderr, silently exits if there's no output AND rc=0 (cron-friendly). Otherwise self-mails via msmtp with a meaningful subject:
  - `kodiak: <tag> FAILED (exit N)` on non-zero exit
  - `kodiak: <tag> — output captured (exit 0)` on success-with-output
  Preserves the wrapped command's exit code.
- Both crontabs updated to wrap every entry: `saratoga check`, `restore drill arrow-iii`, `restore drill pilatus` (ldavis); `repos sync`, `hosts sync` (tourbillon). `weekly-summary.sh` stays self-mailing (would double-send otherwise).
- Tested across silent / success-with-output / failure paths.

**Weekly summary now uses real HTML tables (not pre-formatted text):**
- **`tourbillon status --json`** — new flag on the existing status command. Emits the same data as the text version but as structured JSON (saratoga tasks, repo counts, **per-host rows**, pool, drive). Internal `gather_status_data()` helper assembles the dict; both `--json` and the formatted-text path call the same underlying summary functions, so output never drifts.
- **`bin/weekly-summary-build.py`** (new) — reads JSON on stdin, emits a complete multipart/alternative MIME envelope on stdout. The HTML side uses real `<table>` elements with inline styles (Gmail-safe), color-coded status badges (green/amber/red pills), proper section headings, key-value cards for pool + drive. The text/plain side mirrors the same structure with monospace-friendly layout for terminal-only readers.
- **`bin/weekly-summary.sh`** rewritten as a three-stage pipeline: `tourbillon status --json | weekly-summary-build.py | msmtp`. Each stage independently testable.
- Subject modulates by health: default suffix for `OK`, `— caveats` for `WARN` (e.g., a host's interval has elapsed but cron will catch it next firing), `— ATTENTION` for `FAIL` (real errors).
- Verified: 16 KB MIME message accepted by Gmail (vs ~5 KB of the previous all-`<pre>` version) — extra bytes are the table markup, not bloat.

The on-failure cron mails still fire immediately. The weekly heartbeat still arrives Sunday morning. Difference: every alert now has a Subject line you can act on without opening the email, and the heartbeat itself is readable at a glance instead of dumped as a 1990-line-printer scroll.

### Added — `bin/weekly-summary.sh` Sunday-morning heartbeat email

The on-failure cron mails tell you "something just broke." Missing from that pattern: a positive heartbeat that confirms the alerting chain itself is still functioning. Without it, "I haven't heard anything in 3 weeks" is ambiguous — everything's fine, or cron/msmtp died.

- **`bin/weekly-summary.sh`** — self-mails via msmtp to lynchdavis0@gmail.com with subject `kodiak weekly backup summary YYYY-MM-DD`. Body = `tourbillon status` + `hosts issues` + `repos issues` + msmtp log tail (so the digest itself is evidence of msmtp's continued health).
- **`configs/cron/ldavis-crontab`** — new entry `0 8 * * 0` (Sundays 08:00). Self-mailing means cron's awkward "Cron <ldavis@kodiak> ..." subject doesn't land in gmail; useful Subject does.
- **Verified** with a manual run today — `msmtp` accepted with `250 OK`, summary email delivered.
- Existing on-failure cron mails (sync errors, restore-drill failures, saratoga staleness) are unchanged — those still fire immediately. The weekly summary is purely additive.

### Added — ADR-005 + install helper for off-site tier (iDrive Personal on kodiak)

Captures the design + transition plan for closing GAPS.md §1.2 (zero off-site copy). Execution is queued — this commit is documentation + helper script only.

- **`doc/ADR-005-off-site-tier-idrive.md`** — full architecture:
  - Why iDrive Personal vs e2 / Glacier / B2 (already-paid 5 TB; free retrieval; competitive total cost for this volume).
  - Why kodiak-only push (not also saratoga): kodiak already has full A1 replica; TrueNAS doesn't speak iDrive Personal natively.
  - Backup-set scope: photography (1.61 TB) + non-photo archive (~10 GB) + active (~520 MB) + hosts (~17 GB). ~1.65 TB total — fits in 5 TB plan with 3 TB headroom.
  - Mount strategy for the canmount=noauto saratoga datasets, with snapshot-clone fallback documented.
  - Transition plan: keep workstation device alive on iDrive during kodiak's initial sync, decommission after; avoids the "no off-site during cutover" failure mode.
  - Alternatives + future scope (e2 migration, multi-cloud, freshness drill).
- **`bin/install-idrive-on-kodiak.sh`** — helper:
  - Pre-flight (curl/gzip/perl present, /opt has space, ZFS mount status of saratoga subtree printed).
  - Downloads iDrive Linux client.
  - Extracts + chmods.
  - Hands off to iDrive's interactive installer.
  - Prints the post-install configuration template (backup sets, manual first-push command, cron entry shape, what's NOT yet done).
  - Explicitly NOT scripting iDrive's interactive prompts — those will change, and we'd rather type them than guess wrong.
- **`doc/GAPS.md` §1.2** updated to reflect "design committed, execution pending."

Implementation slices still to do (per ADR-005):
1. Mount saratoga archive subtree (`zfs set canmount=on` + `zfs mount`).
2. Run interactive installer; configure backup sets.
3. First manual push (~24-72h).
4. Restore drill from iDrive.
5. Daily cron entry.
6. Decommission workstation device on iDrive.
7. Reclaim `/kodiak00/data-00/` redundant subtrees (~2.1 TB) per `data-organizer/MIGRATION-CHECKLIST.md`.
8. CREDENTIALS.md update for iDrive account + private encryption key.

### Added — msmtp + gmail forwarder for cron mail (closes GAPS.md §4.3)

Cron mail now reaches the operator's external inbox instead of piling up at `/var/mail/ldavis` for nobody to read.

- **`msmtp` + `msmtp-mta`** installed. `/usr/sbin/sendmail` symlink now points at `/usr/bin/msmtp`. exim4 stopped + disabled (still installed for quick rollback).
- **`~ldavis/.msmtprc` + `~tourbillon/.msmtprc`** — per-user msmtp configs (mode 600). Per-user keeps the gmail app password's exposure narrow (each user reads only their own .msmtprc). Configured for `smtp.gmail.com:587` with TLS + auth.
- **Gmail app password** (16-char, generated at https://myaccount.google.com/apppasswords, labeled "kodiak msmtp"). Documented in `doc/CREDENTIALS.md` with rotation path.
- **Crontabs updated**: `MAILTO=lynchdavis0@gmail.com` in both `configs/cron/ldavis-crontab` and `configs/cron/tourbillon-crontab`. Cron hands the message directly to msmtp with an external recipient — no `.forward` or alias-resolution needed.
- **Verified**: three test sends (ldavis manual, tourbillon manual, tourbillon cron-style) all accepted by gmail with `250 2.0.0 OK`; both operator-side emails arrived.
- **New failure mode flagged in GAPS.md**: if the app password is revoked, msmtp logs a 535 auth error and the cron mail is lost (no queue/retry). Future-improvement: a check that greps `~/.msmtp.log` for recent auth failures.

### Reorganized — verification scripts moved to `tests/`

Verification scripts (the ones that run on a schedule and produce yes/no health verdicts) were sharing `bin/` with operator-facing CLI / setup / teardown / apply scripts. Two different categories living in one place; now split.

- **`tests/`** (new directory): scripts that *verify* the backup system is healthy. Silent on success, alarms on failure. Cron-friendly.
- **`bin/`** (unchanged in role): scripts the operator runs to *do* something — invoke the CLI, bootstrap a host, apply config.
- **Moved**:
  - `bin/check-saratoga-replication.sh` → `tests/check-saratoga-replication.sh`
  - `bin/restore-drill.sh` → `tests/restore-drill.sh`
- **Added — `tests/test-restore-drill.sh`** — self-test of the restore drill. Runs the drill in four shapes (happy verbose, happy silent, nonexistent host, symlink file) and confirms each behaves correctly. Captures the four ad-hoc test cases that surfaced during the original drill development. Not on cron (hits live hosts); run manually after changing the drill script.
- **Added — `tests/README.md`** — table of what's in tests/, exit-code contracts, conventions (silent on success, `--verbose` flag, `set -uo pipefail`, no side effects).
- **Crontab** (ldavis) updated to point at the new paths; `configs/cron/ldavis-crontab` likewise. PLAYBOOK + GAPS + ADR-004 references updated.

### Added — `bin/restore-drill.sh` + monthly cron (closes GAPS.md §1.3 for hosts)

GAPS.md §1.3 flagged that no actual restore drill had ever been performed — the docs described it but nobody ran it. Fixed: scripted the drill end-to-end and wired it to cron so it runs without anyone remembering.

- **`bin/restore-drill.sh <host> [<file>]`** — three checks anchored on sha256:
  1. Mirror copy on kodiak hashes to X.
  2. Live source on the target hashes to X (mirror == source as of last sync).
  3. Reverse-rsync the mirror to /tmp on the target → hashes to X (the restore-direction pipeline works).
  Refuses symlinks (they can cross-path outside the backed-up subtree — found this the hard way during the first manual drill against `/etc/os-release` → `../usr/lib/os-release`, where `/usr` isn't in the backup). Silent on success (cron-friendly); `--verbose` shows all three hashes.
- **`configs/cron/ldavis-crontab`** — new monthly entries: `30 6 1 * *` (arrow-iii) and `35 6 1 * *` (pilatus). Silent on success; cron mails any failure via `MAILTO=ldavis`.
- **First drills executed 2026-05-27** against both hosts — both passed with matching three-way hashes.
- **GAPS.md** updated to reflect §1.3 closed for hosts; saratoga-side drill (zfs send|recv test) still open as a follow-up.

### Fixed — `tourbillon status` works for the operator without sudo

After the ADR-004 migration, `tourbillon status` as the operator (ldavis) reported "40 never / 2 never" for everything because the CLI was reading state from `$HOME/.local/state/tourbillon` — i.e., ldavis's empty home, not tourbillon's where state actually lives. Running as tourbillon got correct A2 state but missed the saratoga env (still in ldavis's home, used by A1). Neither user produced a complete view in one invocation.

- **`bin/tourbillon`**: state path no longer derived from `Path.home()`. New constant `TOURBILLON_STATE_DIR` defaults to `/var/lib/tourbillon/.local/state/tourbillon` regardless of which user is running the CLI (env var override available for testing). Read-only commands (`status`, `*_issues`, etc.) now work for any user with read access to the state subtree.
- **Filesystem perms**: `/var/lib/tourbillon` opened from `700` to `755`; the state subtree pre-created at `755`. Secrets (`~tourbillon/.ssh/` at `700`, `~tourbillon/.config/tourbillon/env` at `600`) stay tight. State files contain timestamps + sizes + repo names — no secrets, safe to be operator-readable.
- **`bin/bootstrap-kodiak-tourbillon.sh`**: now does the perm-opening + pre-creates the state subtree at the right modes, so a kodiak rebuild gets this for free.

Operator can now run a full status check as themselves with one command:
```
source ~/.config/saratoga/env && bin/tourbillon status
```
Shows saratoga DR, repos, hosts, pool, and drive in one screen.

### Added — `pilatus` (linux, 192.168.1.59) bootstrapped + first-seeded; preflight checks in bootstrap-from-kodiak scripts

Second host onboarded under the post-ADR-004 model, and the validation of the hardening work from earlier today. Where arrow-iii's bootstrap took ~an hour of debugging (chpasswd hang, missing rsync, missing kodiak sudoers, stale chown), pilatus's took ~5 minutes including the 18 GB first seed.

- **`configs/hosts/pilatus.toml`** — `host = "192.168.1.59"`, `paths = ["/home", "/etc"]` (same shape as arrow-iii; everything else inherited from `defaults.toml`).
- **`/etc/hosts`** on kodiak updated: `pilatus` now points at the LAN IP `192.168.1.59`. The previous `192.168.7.50 pilatus tbm930` line was split — pilatus moved to the LAN IP; `tbm930` kept at `192.168.7.50` (different host, same VPN/subnet).
- **First seed**: 18.0 GB transferred in 2.7 minutes (~110 MB/s, gigabit saturated). 83,376 files under `/home` (three user homes: ldavis, cyfirdev, stephen — numeric uids preserved), 1,269 under `/etc`. ZFS dataset auto-created and chowned to tourbillon via the sudoers entries from earlier today.
- **`bin/bootstrap-from-kodiak.sh` + `-single-user.sh`** — added a `preflight()` function that runs before any state-changing step. Checks: (a) per-host `configs/hosts/<host>.toml` present, (b) kodiak `tourbillon` service user exists, (c) hostname resolves OR `<ip>` arg given, (d) target port 22 reachable. All checks run; failures accumulate; script bails with the full list (no fix-one-retry-fix-next dance). Surfaced by the operator during pilatus setup: "shouldn't all of these tests, pre-flight be scripted?" — yes, fixed.

Host backup fleet now:
```
HOST        STATE   SIZE       NOTE
arrow-iii   ok      628.0 MB   minimal-use linux
pilatus     ok      14.5 GB    /home with 3 users
```

Cron will sync each at their `5,35`-of-an-hour window once their 24h interval elapses; both currently fresh.

### Added — canonical crontabs checked in under `configs/cron/`

Following the ADR-004 refactor and arrow-iii first-seed, the two live crontabs (ldavis's saratoga monitoring entry; tourbillon's A2 sync entries) only existed in the running cron daemon — not in the repo. A kodiak rebuild would have meant retyping them from CHANGELOG archaeology.

- **`configs/cron/ldavis-crontab`** — the operator's crontab. One entry: daily `0 8` saratoga replication freshness check.
- **`configs/cron/tourbillon-crontab`** — the service user's crontab. Two entries: `*/30` repos sync (sources env file), `5,35` hosts sync.
- **PLAYBOOK section 9b** (new) — install commands: `crontab configs/cron/ldavis-crontab` and `sudo crontab -u tourbillon configs/cron/tourbillon-crontab`. One operation each, no per-line retyping.

Both files are the exact `crontab -l` output at commit time, including comment headers, so reading the file is the same experience as reading the live crontab. No drift.

### Hardened — bootstrap scripts capture every gap surfaced by arrow-iii's first seed

While attempting to re-bootstrap arrow-iii under the ADR-004 model, hit four undocumented gotchas in a row. Captured each one into the setup scripts so a kodiak rebuild (or any subsequent host onboarding) doesn't repeat the dance:

- **`bin/bootstrap-tourbillon-user.sh`** — major hardening:
  - **Pre-flight checks** for required tools (openssl, visudo, useradd, usermod, passwd). If any is missing, fail with a clear message rather than hang halfway.
  - **rsync auto-install** if missing. Minimal Debian installs don't ship rsync — without it the backup pulls just fail with cryptic "command not found" inside the rsync protocol stream. Now installed via apt-get (or dnf) before anything else proceeds.
  - **Replaced `chpasswd` with `usermod -p` + openssl-precomputed sha512crypt hash.** chpasswd goes through PAM and hangs indefinitely on some Debian stacks (sssd, fingerprint helpers, etc.) — caught us twice during arrow-iii bootstrap, each time freezing the script after the "creating user" message. usermod writes /etc/shadow directly with no PAM detour. Sentinel "→ password set" log line makes the milestone visible.
  - **Final summary** now prints sudoers path, rsync binary path + version, and the one-time password block — separate from the rest of the output so it's easy to copy.

- **`bin/bootstrap-kodiak-tourbillon.sh`** (new) — one-shot kodiak-side setup. Idempotent. Captures everything that *was* done by hand during the ADR-004 migration session so a fresh kodiak can stand up A2 without reading the changelog archaeology:
  - Creates the `tourbillon` system user (locked password).
  - Installs `/etc/sudoers.d/tourbillon` with the three narrow NOPASSWD entries the runtime needs: `zfs create backups-00/hosts/*`, `chown tourbillon:tourbillon /kodiak00/backups-00/hosts/*`, `rsync`.
  - `chown -R tourbillon:tourbillon` on `/kodiak00/backups-00/{repos,hosts}` if those datasets exist (PLAYBOOK section 3 creates them).
  - Final summary lists what the script did NOT do (env file, crontab, per-host keys) so the operator can complete those steps.

- **`bin/tourbillon`** (`ensure_host_dataset`) — fixed a latent bug: after `sudo zfs create` of a child dataset, the mountpoint was being chowned to `ldavis:ldavis`. Pre-ADR-004 that was correct; now it should be `tourbillon:tourbillon`. The chown command is in the sudoers added by `bootstrap-kodiak-tourbillon.sh`. The bug was latent because the host-sync code path had never actually been exercised end-to-end before — arrow-iii is the first host to actually first-seed.

- **PLAYBOOK section 3** — now references `bin/bootstrap-kodiak-tourbillon.sh` as the one-shot prereq for the dataset creation steps. Removes the inline useradd / sudoers / chown commands (now lived in the script). Operator-readable; less drift potential.

The four gotchas, in order of how we hit them on arrow-iii:
1. Bootstrap script hangs at `chpasswd` after `useradd` — PAM-related, indistinguishable from a deadlock.
2. Operator pastes a recovery chain into the wrong terminal (Mac instead of arrow-iii ssh) — chain's `usermod` silently fails on macOS but the rest of the chain runs, producing a misleading "PASSWORD: ..." output. (Not a script bug per se but documented as a cautionary tale.)
3. rsync not installed on arrow-iii — Debian minimal install doesn't include it.
4. `sudo: a password is required` for both `zfs create` and `rsync` on kodiak — tourbillon's sudoers on kodiak hadn't been provisioned (was implied but never installed as part of the migration).

### Refactor — kodiak-side service user (ADR-004): A2 stops running as `ldavis`

Architectural drift correction surfaced during the bumpy arrow-iii bootstrap: A1 had an explicit "service user, not the operator" design (`tnreplicate`), but A2 implementation drifted into running as `ldavis` (cron entries, SSH keys, dataset ownership, token env all on the operator's interactive account). The operator caught it; this refactor brings A2 in line with A1.

- **`doc/ADR-004-kodiak-side-service-user.md`** — captures the decision: dedicated `tourbillon` system user on kodiak owns all A2 runtime state. Same name as the CLI binary and the target-side service account (one concept, three manifestations). Pairs with `tnreplicate` for A1.
- **Created `tourbillon` system user on kodiak** (uid 996, home `/var/lib/tourbillon`, password locked). Access via `sudo -u tourbillon` from ldavis; no interactive SSH login enabled.
- **Migrated runtime state**: `~ldavis/.config/tourbillon/env` (github + bitbucket tokens) → `~tourbillon/.config/tourbillon/env`; `~ldavis/.local/state/tourbillon/` (42 state files: 40 repos + arrow-iii host) → `~tourbillon/.local/state/tourbillon/`. Verified env-readable + sample state-readable as the new user before deleting originals.
- **Reassigned ZFS dataset ownership**: `/kodiak00/backups-00/repos` (40 repo mirrors, ~278 MB) and `/kodiak00/backups-00/hosts` are now owned by `tourbillon:tourbillon`. Repo data untouched in content; only ownership flipped.
- **Migrated cron entries**: removed the A2 `*/30` repos-sync and `5,35` hosts-sync from ldavis's crontab; installed equivalents on `tourbillon`'s crontab (MAILTO=ldavis preserved so failure mails still reach the operator). The A1 monitoring entry (`0 8` `check-saratoga-replication.sh`) stays on ldavis — it's monitoring, not running backups.
- **Refactored bootstrap scripts** (slice 6 in ADR-004) — both flows now accept an optional `<ip>` argument and auto-add `<ip> <hostname>` to kodiak's `/etc/hosts` if hostname doesn't resolve yet. Eliminates the manual "edit /etc/hosts first" step the operator hit during the arrow-iii session. Both scripts also pass `-o StrictHostKeyChecking=accept-new` to `ssh-copy-id` and every subsequent `ssh` call — auto-trusts the target's host key on first sight (TOFU done right), eliminating the manual `ssh-keyscan` dance. Keygen + ssh-copy-id + verify + lock all happen as the kodiak `tourbillon` user via `sudo -u tourbillon -H`.
- **Discarded orphan**: `~ldavis/.ssh/id_ed25519_tourbillon_arrow-iii{,.pub}` — the target side had been cleaned via the new `bin/cleanup-tourbillon-host.sh`, making this kodiak-side keypair dead. Fresh keypair will be generated under `~tourbillon/.ssh/` when arrow-iii is re-bootstrapped.
- **Docs updated**: CREDENTIALS.md (env + key paths now point at `~tourbillon/`), PLAYBOOK.md (dataset setup section now creates `tourbillon` user and chowns datasets to it), ADR-002 + ADR-003 (cross-references added pointing at ADR-004 since both ADRs were written assuming ldavis was the runtime user).
- **New utility**: `bin/cleanup-tourbillon-host.sh` (committed earlier today, 85d5b87) — undoes everything `bootstrap-tourbillon-user.sh` installs on a target. Used to wipe arrow-iii so it can be re-bootstrapped cleanly under the new model.

This refactor was triggered by the operator's question during the arrow-iii bootstrap:

> we made a decision that ldavis is NOT the user of the backups, didn't we? i thought we created a user backups since backup was taken.

They were right. The principle from A1 had never been carried over to A2.

Smoke tests after migration: `sudo -u tourbillon bin/tourbillon repos sync --quiet` and `sudo -u tourbillon bin/tourbillon hosts sync --quiet` both exit 0. Cron crontab `-l -u tourbillon` shows expected entries. arrow-iii bootstrap under the new model still pending (clean target + refactored scripts ready).

### Added — A2 host backups, slice 5d (`tourbillon status` Hosts rollup)

- **`bin/tourbillon`**: new `hosts_summary_dict()` parallel to `repos_summary_dict()`. One-pass walk over per-host configs + state. Returns counts (with `unreachable` as its own slot — powered-off ≠ failed), total mirror size, oldest/newest sync ages.
- New `== Host backups (backups-00/hosts) ==` section in `print_status()`, between Repos and Pool. Output style matches Repos: one-line tally, oldest/newest if any. Friendly "(no hosts configured)" line when the directory is empty.
- Top-level `tourbillon status` now covers all three subsystems (saratoga DR, repos, hosts) on one screen.

### Added — A2 host backups, slice 5a (HOSTS_RESTORE.md)

- **`HOSTS_RESTORE.md`** — restore companion to `SARATOGA_RESTORE.md`. Covers single-file recovery, directory tree restore, full host rebuild for both multi-user and single-user modes. Mac and Windows path variants documented. Includes a quick-reference table at the bottom. Named `HOSTS_RESTORE` (not `LINUX_RESTORE`) since it covers all OS variants.
- README pointer updated to include the new doc.

### Added — A2 host backups, slice 5b + 5c (sanoid policy + cron wiring)

- **Sanoid policy for `backups-00/hosts`** — recursive snapshot retention (30 daily / no hourly/monthly), same template shape as `backups-00/repos`. Recursive so each per-host child dataset (created at first-seed time) gets its own snapshot timeline automatically. Config in `configs/sanoid/sanoid.conf` and deployed to `/etc/sanoid/sanoid.conf`.
- **Cron entry on `ldavis`** at `5,35 * * * *` — `tourbillon hosts sync --quiet`. 5-minute offset from the repos sync (`*/30`) so they don't fire at the same minute. Silent on the normal "host offline / nothing due" case; one-line summary when work happens; failures to stderr → cron mail.

The host-backup subsystem now runs autonomously the moment a host gets bootstrapped + first-seeded. Until arrow-iii is bootstrapped, the half-hour cron firings silently record "unreachable" and exit clean. Sanoid will start producing per-host snapshots automatically when each host's child dataset comes online.

### Added — A2 host backups, slice 4 (single-user mode + declarative defaults)

- **`doc/ADR-003-host-backups-single-user-mode.md`** — captures the multi-user-vs-single-user architectural fork. One config knob (`sudo_required`) distinguishes the two modes. Includes Windows readiness checklist (OpenSSH Server + cwRsync) for the day a Windows target arrives.
- **`configs/hosts/defaults.toml` rewritten as declarative**: every settable field appears in the file with its default value + a one-line comment. No defaults hidden in code. `ssh_key` is now a templated default `~/.ssh/id_ed25519_tourbillon_{host}` (the `{host}` placeholder is substituted with the per-host config's basename at runtime).
- **`configs/hosts/excludes/mac-user.txt`** — new exclude file for single-user macOS targets. Ported wholesale from `~/development/data-organizer/excludes/lynchmbp.txt` (battle-tested during the migration). Trash (`~/.Trash/`) is INCLUDED per the `safety-nets-for-scratch` policy; 30-day kodiak-side snapshot retention covers the recovery case.
- **`configs/hosts/excludes/linux-user.txt`** — minor additions caught during the diff against lynchmbp.txt: `*.egg-info/` (Python build artifacts), `.cargo/git/` (Rust git checkout cache).
- **`bin/tourbillon` updates**:
  - `resolve_ssh_key()` reads the templated `ssh_key` value from config and substitutes `{host}`. No more code-only fallback (the default is now in `defaults.toml`).
  - `rsync_one_path()` honors `sudo_required`: omits `--rsync-path='sudo /usr/bin/rsync'` when false. Single-user hosts get a plain `rsync --server` invocation as their existing user.
- **`bin/bootstrap-from-kodiak-single-user.sh`** — wrapper script for single-user host onboarding. Generates per-host keypair → ssh-copy-id to the operator's existing user → verify → print per-host config template. No target-side script needed; no password-lock dance (the user's password stays the operator's own).
- **`doc/CREDENTIALS.md`** — updated to cover both bootstrap flows (multi-user vs single-user) under the per-host keypair entry.

### Revised — slice 1 backup-user model (per-host keys, ssh-copy-id flow)

Slice 1 originally landed with a single shared SSH key (`~/.ssh/id_ed25519_backup`) authorized on every host's `backup` user. Reviewed and revised to a per-host key model — compromise of one host's key opens only that one host. Same files / same patterns; the only "structural" change is one-key → key-per-host plus the username choice.

- **`tourbillon` is the target-side user** (replaces the `backup` placeholder, which collided with Debian's default `backup` user uid=34 anyway).
- **Per-host SSH keypair**, kodiak-side, at `~/.ssh/id_ed25519_tourbillon_<hostname>`. Generated at bootstrap; one keypair per target host.
- **`bin/bootstrap-tourbillon-user.sh`** (target-side, replaces the old `bootstrap-backup-user.sh`) — creates the `tourbillon` user with a randomly-generated temporary password + the narrow sudoers entry (NOPASSWD on `rsync --server *` and `passwd -l tourbillon`). Prints the password for one-time use by ssh-copy-id.
- **`bin/bootstrap-from-kodiak.sh`** (new, kodiak-side) — generates the per-host keypair, runs `ssh-copy-id` (interactive paste of the temp password once), verifies key-auth works, then locks the target's tourbillon password (key-only thereafter). One-shot per host.
- **`configs/hosts/defaults.toml`**: `ssh_user = "tourbillon"`. `ssh_key` is no longer in the file — tourbillon derives it as `~/.ssh/id_ed25519_tourbillon_<config-basename>` automatically. Per-host configs can override if a non-default path is wanted.
- **`bin/tourbillon`**: new `resolve_ssh_key(host_cfg)` helper does the convention-based lookup. `hosts ping` already uses it.
- **Deleted the slice-1 `~/.ssh/id_ed25519_backup`** (had never been distributed) and removed `bin/bootstrap-backup-user.sh` from the repo.
- **`doc/CREDENTIALS.md`** updated: per-host keypair model with the new bootstrap flow.

### Added — A2 host backups, slice 3 (tourbillon hosts sync — real rsync)

- **`tourbillon hosts sync`** — full implementation. SSH-probes each candidate host first; on reachable hosts, ensures the per-host ZFS dataset (`backups-00/hosts/<name>`) exists (auto-creates if missing, chowns to ldavis), then rsync-pulls each configured `paths` entry from the target.
  - rsync flags: `-avHAX --delete --numeric-ids --partial --stats` with `--exclude-from=configs/hosts/excludes/linux-user.txt`.
  - Target-side runs as root via `--rsync-path='sudo /usr/bin/rsync'` matching the narrow sudoers entry the bootstrap installs.
  - Kodiak-side rsync runs via `sudo -n` so file ownership on the mirror reflects source uids/gids.
  - Per-path subdir on kodiak: `/kodiak00/backups-00/hosts/<host>/<basename(path)>/` (e.g., `/home/` → `.../arrow-iii/home/`).
  - Exit codes 23 (partial: permission-on-one-file) and 24 (file-vanished-during-walk) treated as soft warnings, not failures.
  - Flags: `--name HOST` `--force` (skip interval check) `--dry-run` (probe only) `--quiet` (cron-friendly silence on no-op).
  - State writes: `last_attempt_at` / `last_reachable_at` or `last_unreachable_at` / `last_success_at` / `last_size_bytes` (from `zfs list -p -o used`) / `last_duration_s` / `last_error`.

### Note — bin/tourbillon at 1762 lines (refactor candidate)

After slice 3 the single-file CLI is past the "consider splitting" threshold I'd flagged at ~1200. Still readable (well-sectioned with `# ----------` headers), but worth refactoring into `src/tourbillon/{repos,hosts,status,providers,...}.py` modules when the next big chunk lands. Not blocking; on-deck.

### Added — A2 host backups, slice 2 (tourbillon hosts CLI plumbing)

- **`tourbillon hosts ping <host>`** — SSH-probe a configured host's reachability right now. Exits 0 if reachable, 1 otherwise. The probe uses `BatchMode=yes` + short ConnectTimeout so it can't hang.
- **`tourbillon hosts status [--name HOST]`** — read-only table of every configured host. Columns: HOST, STATE (ok/due/unreachable/FAILED/NEVER), LAST OK, LAST SEEN, SIZE, NOTE. Pure state-file read; no SSH probes inline.
- **`tourbillon hosts issues [--quiet]`** — filtered to non-ok hosts. Cron-friendly with --quiet (silent when all clean).
- **`tourbillon hosts sync`** — stubbed; lands in slice 3.
- **`configs/hosts/arrow-iii.toml`** — first per-host config. `host = "192.168.1.65"`, `paths = ["/home", "/etc"]`, defaults inherited. Active immediately (status shows it as NEVER state pending bootstrap + first seed).

### Added — A2 host backups, slice 1 (foundations)

- **`doc/ADR-002-host-backups-linux.md`** — design for the linux host backup subsystem. Builds on ADR-001's patterns; per-host TOML configs + state files; rsync over SSH with intermittent-reachability handling; dedicated `backup` user on each target. Five decisions resolved during initial review.
- **`bin/bootstrap-backup-user.sh`** — run-on-target script that creates the `backup` user, installs the kodiak-side pubkey into `authorized_keys`, and drops a narrow sudoers entry (`NOPASSWD: /usr/bin/rsync --server *`). Idempotent.
- **`configs/hosts/defaults.toml`** — system-wide defaults (`paths = ["/home"]`, `schedule_when_up = "24h"`, ssh user/key, target dataset).
- **`configs/hosts/excludes/linux-user.txt`** — shared rsync excludes for user home backups. Skips language toolchain caches, browser data, IDE state, VM/container disks, build artifacts. Trash is INCLUDED per the `safety-nets-for-scratch` policy.
- **SSH keypair `kodiak-backup`** (outbound) at `~/.ssh/id_ed25519_backup`. ed25519, no passphrase. Single key across all hosts. Documented in `doc/CREDENTIALS.md`.
- **ZFS dataset `backups-00/hosts`** (canmount=on, recordsize=128K, ldavis-owned). Each linux host gets a child dataset created at first-seed time.

## 2026-05-25

### Added
- `bin/tourbillon status` — top-level rollup, one-screen "is everything OK?" view. Four sections: Saratoga DR (replication state via TrueNAS API), Repo mirrors (counts + oldest/newest sync age), Pool health (`zpool list` + `zpool status` summary, next-scrub timer firing), Drive health (`smartctl` key attrs + last self-test). Each section degrades gracefully (prints `(unavailable) …` with the reason) if its data source isn't reachable.
- `bin/tourbillon repos status` — per-repo table (state, age of last success, size, error/interval). `--name SLUG` / `--provider {github,bitbucket}` filters; summary line at the bottom (`N ok | N due | N failed | N never | total MB`).
- `bin/tourbillon repos issues` — filtered view that only shows repos NOT in `ok` state. Exits non-zero when issues exist. `--quiet` for cron-style "silent on healthy" use.
- **Monthly `zpool scrub` on `backups-00`** — enabled via the shipped `zfs-scrub-monthly@backups-00.timer` (systemd, ships with `zfsutils-linux`). Fires on the 1st of each month with up to 1h jitter, uses `zpool scrub -w` so the unit blocks until completion. ~7-8h wall clock per run on the 4 TB drive. Next fire: 2026-06-01. Catches silent corruption proactively, even though single-disk pool can't self-repair.
- **Sanoid policy on `backups-00/repos`** — 30 days of daily snapshots, no hourly/monthly. Config at `configs/sanoid/sanoid.conf` in the repo, deployed to `/etc/sanoid/sanoid.conf`. `sanoid.timer` (every 15 min) handles the rest. First snapshot taken on install. Closes the time-machine loop on the repo data; the saratoga-side datasets keep their TrueNAS-replication-task retention as before.
- `bin/tourbillon repos sync` — clones (first-time) or updates (incremental, `--prune`) mirrors for every repo in `configs/repos/`. `--name SLUG`, `--provider`, `--force`, `--dry-run`, `--quiet` supported. State written per-repo at `~/.local/state/tourbillon/repos/{provider}/{owner}/{name}.json`. Default cadence 24h via `interval` field on the per-repo config (overrideable for active dev).
- `tourbillon repos sync --quiet` — for cron use. Silent on the normal "nothing due" case so cron sends no mail; one-line summary to stdout when work happens; failure lines + summary to stderr.
- Cron entry on `ldavis` (kodiak): `*/30 * * * *  . $HOME/.config/tourbillon/env && tourbillon repos sync --quiet`. Sync now runs autonomously.
- `bin/tourbillon repos discover` — enumerates upstream repos via the GitHub + Bitbucket REST APIs, auto-creates per-repo TOML configs under `configs/repos/`, auto-commits the new configs (local-only, never pushed). Orphan detection (config present, no upstream) reported in output.
- `bin/tourbillon` — argparse-driven CLI skeleton; other subcommands (`status`, `health`, `logs`, `perf`, `repos status/prune`) stubbed.
- ZFS dataset `backups-00/repos` (recordsize 128K, canmount=on, owned by `ldavis`) — destination for bare-repo mirrors.
- `configs/repos/` populated by first `discover` run: 40 repos catalogued (16 GitHub + 24 Bitbucket).
- `bin/restructure-snapshot-naming.sh` — idempotent API-driven fix for the snapshot-task naming collision. Renames parent-scope task schemas to distinct values (`auto-tank-*`, `auto-media-*`).
- `~/.config/saratoga/env` — persisted location for `TRUENAS_API_TOKEN` (mode 600, kodiak-local, not git-tracked) so future shells and cron find the API token.
- `~/.config/tourbillon/env` — persisted location for GitHub + Bitbucket credentials (mode 600, kodiak-local). Atlassian API tokens (ATAT-prefixed) are the migration path off deprecated Bitbucket app passwords.
- `doc/` directory — name origins and explanations. `doc/NAMING.md` covers tourbillon, backups-00, tnreplicate. `doc/CREDENTIALS.md` lists every secret + rotation paths. `doc/ADR-001-repo-mirror.md` records the design decision for the repo-mirror subsystem.
- Tourbillon chosen as the name for the operator CLI (rationale in `doc/NAMING.md`).

### Changed
- Snapshot task 6 (`tank` recursive): `naming_schema` from `auto-%Y-%m-%d_%H-%M` to `auto-tank-%Y-%m-%d_%H-%M`; `schedule.minute` returned to `0` (the 02:05 offset workaround dropped).
- Snapshot task 7 (`media` recursive): `naming_schema` to `auto-media-%Y-%m-%d_%H-%M`.
- Replication tasks 1 and 2: `also_include_naming_schema` adds the legacy `auto-%Y-%m-%d_%H-%M` for the 2-week transition.

### Documented
- Step 6 of PLAYBOOK setup section now specifies `~/.config/saratoga/env` as the canonical token storage location.
- (Parallel-session commit `f98328c`) Snapshot-task scope/schedule collision gotcha — wired into Final-Shape, Adding-a-new-target step 2, and the dead-ends table.

### Operational reminders
- **2026-06-08**: drop `also_include_naming_schema` entries from replication tasks 1 and 2 once the old `auto-%Y-%m-%d_%H-%M` snapshots have aged out via 2-week retention. The calendar entry exists for a reason; future-us is encouraged to use it.
- **2027-05-24**: rotate the Bitbucket/Atlassian API token before it expires. Path + details in `doc/CREDENTIALS.md`. Aim for at least a week of overlap.

## 2026-05-24

### Added — A1 saratoga DR backup operational
- `backups-00` ZFS pool on `/dev/sdb` (WD Red 4TB, freshly wiped): `ashift=12`, `compression=lz4`, mountpoint `/kodiak00/backups-00`.
- Destination datasets `backups-00/saratoga{,/tank,/media}` with `canmount=noauto` (sidesteps the Linux kernel mount-permission gate on `zfs recv`).
- `tnreplicate` system user (uid 997) on kodiak. Sudoers entry granting NOPASSWD on `/usr/sbin/zfs` and `/usr/sbin/zpool`.
- TrueNAS-side: SSH keypair `kodiak-tnreplicate`, SSH connection `kodiak`, replication tasks `tank → backups-00/saratoga/tank` and `media → backups-00/saratoga/media`.
- **First seed completed:** tank 1.99 TiB + media 425 GiB.
- `PLAYBOOK.md` — operational record + four dead-ends from the failed pull-via-syncoid attempt.
- `SARATOGA_RESTORE.md` — restore scenarios from single-file to full DR.
- `bin/apply-media-tasks.sh` — API-driven template-based task creation.
- `bin/dump-saratoga-config.sh` — refreshes `configs/` from the TrueNAS REST API.
- `bin/check-saratoga-replication.sh` — kodiak-side stale-snapshot monitor; wired as `ldavis` crontab daily 08:00.
- `configs/` — live JSON dumps + JSON templates for new tasks.

### Removed
- `src/backup_server/`, `tests/`, `servers/`, `pyproject.toml`, `Taskfile.yml`, `backup-use-cases.txt`, `.pytest_cache/`, `.ruff_cache/` — the NFS-era Python tool (obsolete since the migration; framework design out of scope for targeted personal infra).
- `scripts/backup-saratoga.sh`, `scripts/backup-photography-parallel.sh`, `scripts/collect-saratoga-state.sh` — pre-migration NFS rsync scripts (one-shot, mission accomplished).
- `scripts/replicate-saratoga.sh` — abandoned pull-via-syncoid attempt.
- `USE_CASES.md`, `TODO.md`, prior `CLAUDE.md`, `POST-MIGRATION-PROMPT.md` — obsolete docs (superseded by `PLAYBOOK.md`).
- `.gitignore` trimmed of Python-specific entries.

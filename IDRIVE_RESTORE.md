# IDRIVE_RESTORE

How to get data back from the off-site (cloud) tier when the on-site copies
are gone too. Companion to [SARATOGA_RESTORE.md](SARATOGA_RESTORE.md) and
[HOSTS_RESTORE.md](HOSTS_RESTORE.md) — this is the *last* safety net, not
the first one to reach for.

**Scope — what's actually up there** (see `doc/ADR-005-off-site-tier-idrive.md`
and `doc/GAPS.md` §1.2 for the full history):

- `backups-00/saratoga/tank/{active,archive}/*` (~1.65TB) — via the
  `backups-00/idrive-staging/*` ZFS-clone mirrors of saratoga's canonical
  archive.
- `/kodiak00/data-00/{videos,archive}` (178GB) — real family footage +
  personal document archives.
- `backups-00/hosts/*` (arrow-iii, pilatus, lynchmbp, ldavis-dev-01 — ~1TB).

**Not up there, deliberately:** `backups-00/saratoga/media/*` (music/movies/
tv/audiobooks — reproducible), `tank/scratch` + `tank/staging` (transient),
`backups-00/repos` (recoverable from GitHub/Bitbucket), the two migration-era
`data-00/backups/host-backups/*-LynchMBP` snapshots (operator decision,
2026-09-27 — the live `hosts/lynchmbp` mirror above is sufficient), and the
~50GB `data-00/backups/{Alex Backup, Leigh Backup, ...}` old-machine-backups
bucket (parked, pending operator review).

---

## Mental model — this is the last resort

```
saratoga (source)
  → kodiak's backups-00 pool (A1 replication + A2 host rsync)
      → iDrive (this doc)
```

iDrive is fed *from* kodiak's already-replicated data, not from saratoga
directly. In normal operation it's redundant with what's already on
`backups-00` — reach for [SARATOGA_RESTORE.md](SARATOGA_RESTORE.md) or
[HOSTS_RESTORE.md](HOSTS_RESTORE.md) first. This doc only matters when
**both** saratoga and kodiak's local pool are gone — fire, theft, or kodiak
hardware failure with no working `backups-00` to restore from.

---

## How restore actually works

There is **no scriptable CLI** for this (checked 2026-09-29 —
`/opt/IDriveForLinux/bin/idrive --help` only exposes `--about`/`--speed-test`).
Everything goes through `/opt/IDriveForLinux/bin/idrive`'s interactive
terminal menu, run as root (`sudo`, since its state files are root-owned,
mode 600). If driving it via an automated session (not a human at a
terminal), `tmux` works well — `send-keys` + `capture-pane` — since the
tool won't accept piped stdin cleanly.

Relevant main-menu options:
- **7) Edit restore set** — opens a plain-text file
  (`Restore/DefaultRestoreSet/RestoresetFile.txt`) in `vi`. One path per
  line, exactly like the backup-set editor (`Esc` then `:wq!` to save).
  Accepts individual files (tested) — an untested assumption is that it
  also accepts directory paths for bulk restores, matching the backup-set
  editor's own directory-path convention. **Don't assume an *empty*
  restore set means "restore everything"** — verify that specifically
  (in a way that can't accidentally trigger a multi-TB pull) before ever
  relying on it in a real DR.
- **8) Restore now** — restores whatever's in the restore set to the
  configured restore location (see `13) Restore settings` — default
  `/opt/IDriveForLinux/idriveIt/user_profile/root/lynchdavis0@gmail.com/Restore_Data/`).
  Does **not** restore in place — always lands in the restore location
  first; move/verify from there.
- **13) Restore settings** — change the restore location, or the source
  device if more than one is ever registered to this account.

---

## Scenario 1 — single-file restore (verified working, 2026-09-29)

Cost: minutes. Risk: none (restores to a staging location, doesn't
overwrite anything in place).

1. Know the exact path as it exists on kodiak (iDrive paths mirror the
   kodiak filesystem paths in the backup set, e.g.
   `/kodiak00/backups-00/hosts/lynchmbp/ldavis/Documents/foo.pdf`).
2. `sudo /opt/IDriveForLinux/bin/idrive` → `7` (Edit restore set) → clear
   any stale entries, add the one path → `Esc` `:wq!`.
3. `p` back to main menu → `8` (Restore now). Watch it complete
   (`[SUMMARY:] Files restored now: 1 ... Files failed to restore: 0`).
4. Find it under the restore location + the file's basename (iDrive drops
   the directory structure by default — `2020-08-JLD-Journal.pdf` landed
   at `Restore_Data/2020-08-JLD-Journal.pdf`, not nested under its original
   path).
5. **Verify**: `sha256sum` the restored copy, compare against a known-good
   hash of the source. Delete the restored copy afterward — it's a test
   artifact, not something to leave lying around.

Verified 2026-09-29 against `tank/archive/writing/Personal/2020-08-JLD-Journal.pdf`
(the same file already used for the saratoga ZFS restore drill — a nice
property: matching hashes across *both* restore mechanisms is stronger
proof than either alone). Exact hash match, 0 failures.

---

## Scenario 2 — bulk restore (host, or the whole archive) — directory recursion verified, scale untested

For an actual DR where a full host mirror or the whole saratoga archive
needs pulling back:

1. Same flow as Scenario 1, but populate the restore set with a directory
   path (e.g. `/kodiak00/backups-00/hosts/lynchmbp/`) instead of one file.
   **Directory-path recursion confirmed working, 2026-09-30**: restored
   `/kodiak00/backups-00/hosts/lynchmbp/ldavis/.gk6xplus/` (160 files, 4
   levels deep) — all 160 restored, 0 failed, every file's `sha256sum`
   matched the live copy exactly, and the full nested directory structure
   (`Account/0/Devices/<id>/*.cmf`, etc.) was preserved under
   `Restore_Data/.gk6xplus/` — not flattened like the single-file case in
   Scenario 1. What's still unverified is only **scale**: this proves the
   *mechanism* recurses correctly, not that a multi-hundred-GB directory
   behaves identically (throughput, memory, whether the restore-set editor
   or restore engine has a practical size ceiling).
2. Expect this to take a long time at real DR scale — the equivalent
   upload of `lynchmbp` alone was ~994GB; a full download back is bound by
   your downlink, not iDrive's upload throttle setting.
3. Restore location fills up fast at this scale — make sure wherever
   `13) Restore settings` points has room (check `df -h` on that
   filesystem first), or change it to a dataset with headroom before
   starting.
4. Once restored to the staging location, `rsync` or `zfs recv` it into
   place following the same pattern as [HOSTS_RESTORE.md](HOSTS_RESTORE.md)
   or [SARATOGA_RESTORE.md](SARATOGA_RESTORE.md)'s scenarios — iDrive gets
   the bytes back onto kodiak; getting them from there into their final
   home is the same mechanics either doc already covers.

---

## Restore confidence-builder — run periodically (annually, or after any backup-set scope change)

A backup you've never restored from is theoretical — this is the same
discipline [SARATOGA_RESTORE.md](SARATOGA_RESTORE.md) already applies to
the ZFS side.

1. Pick any file currently in the iDrive backup set (check
   `Backup/DefaultBackupSet/LOGS/<latest>_Success*` for what was actually
   uploaded, or just pick something you know is in scope per this doc's
   "Scope" section above).
2. `sha256sum` it at its live kodiak path.
3. Run Scenario 1 above.
4. Confirm the hash matches. Delete the restored copy.

Re-run this whenever the backup set's scope changes materially (a new
top-level path added, e.g.) — it's cheap, and it's the only thing that
actually proves the *restore* direction still works, not just the upload
direction.

---

## Known limitations

- **2 files permanently fail to back up** (and therefore can't be restored
  from iDrive): macOS's own regenerable app-icon cache under
  `backups-00/hosts/lynchmbp/ldavis/Library/Group Containers/group.com.apple.chronod/chronod/icons/`
  — unusual `::`-containing filenames iDrive's client can't parse. Not
  user data; if this specific path is ever needed, it only exists on
  `backups-00/hosts/lynchmbp` itself (or the live Mac), not in the
  off-site tier. See `doc/GAPS.md` §1.2.
- **The old workstation's iDrive device** (pre-dating the kodiak-driven
  setup) — confirmed decommissioned (checked 2026-09-29, reconfirmed
  2026-09-30 via `13) Restore settings` → item 1: "Data will be restored
  from" lists only `kodiak`). If this ever shows more than one device
  name, re-check before assuming `kodiak` is the only source.

---

## Quick reference

| Need | Path |
|---|---|
| Restore one known file | `./idrive` → `7` (add the path) → `8` (Restore now) |
| Change where restores land | `./idrive` → `13` → item 3 |
| Confirm what's actually backed up | `Backup/DefaultBackupSet/LOGS/<latest>_Success*` |
| Confirm 0 failures on the last run | same log, `Files failed to backup` line |
| This doc doesn't apply | saratoga or kodiak's `backups-00` still exists — use [SARATOGA_RESTORE.md](SARATOGA_RESTORE.md) / [HOSTS_RESTORE.md](HOSTS_RESTORE.md) instead |

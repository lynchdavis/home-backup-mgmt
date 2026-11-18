# ADR-012: Backup storage allocation — backups live on the RAID-10, the Reds are scratch

**Status:** Accepted, 2026-11-17.
**Builds on:** ADR-005 (iDrive off-site tier), ADR-010 (manual snapshots),
ADR-011 (storage health alert).
**Supersedes:** the 2026-05-23 placement of `backups-00` on a single WD Red
(PLAYBOOK "Final shape"; GAPS §1.1).

---

## Context

From 2026-05-23 to 2026-11-17, every kodiak-side backup lived on one 4 TB
WD Red (`WD40EFRX`, S/N WD-WCC4E1DKPPNP) as the ZFS pool `backups-00`:

| Dataset | Size (2026-11-17) | What |
|---|---|---|
| `saratoga/{tank,media}` | 2.39 TB | TrueNAS ZFS push of saratoga's pools |
| `hosts/*` | 1.07 TB | tourbillon rsync mirrors (lynchmbp 1.04 TB) |
| `repos` | 0.3 GB | GitHub/Bitbucket bare mirrors |
| `idrive-staging/*` | ~0 | clones of saratoga snapshots for iDrive (ADR-005) |

Two problems surfaced together in November 2026:

- **No redundancy.** One disk failure loses every backup at once: saratoga's
  only local copy, all host history, all snapshot history (GAPS §1.1).
- **Out of space.** The pool hit ZFS's slop reserve on 2026-11-06 (ADR-011),
  writes failed with ENOSPC, and growth (~6 GB/day, mostly lynchmbp) left
  about a week of headroom.

Meanwhile the main array, `KodiakArray01` (RAID 10 over six 8 TB SAS drives
on the MegaRAID 9361-8i, LVM VG `kodiak-datapool-00`), had **16.7 TB
unallocated**, with redundancy, after its slot-3 rebuild completed on
2026-11-16.

A second WD Red (S/N WD-WCC4E2TJ6UVU) was installed in bay 4 on 2026-11-17,
freed by moving the boot drive to an SSD in the old DVD bay.

## Decision

### 1. Where backups live: the RAID-10, as ZFS on an LVM volume

- An LV `kodiak-datapool-00/backups-00` (6 TB to start) carries a ZFS pool
  named **`backups-00`**, mounted at `/kodiak00/backups-00`.
- **Every** backup dataset lives there: `saratoga/*`, `hosts/*`, `repos`,
  `idrive-staging/*`.
- Rule: **a backup copy must sit on redundant storage, and on different
  hardware from the data it protects.** The RAID-10 is redundant, and it is
  the source of none of these backups (saratoga, the laptops and GitHub are
  all other machines).
- Not on the Reds: they share kodiak's chassis and controller with the
  RAID-10 (JBOD on the same MegaRAID), so placing backups there gains no
  failure isolation, only a lack of redundancy.

### 2. The pool keeps the name `backups-00`

The new pool took over the old pool's name and mountpoint (built as
`backups-new`, data moved with `zfs send -R`, then both pools renamed by
export/import in a short maintenance window). Everything that names the
pool or its paths is unchanged:

- saratoga's TrueNAS replication tasks (target `backups-00/saratoga/*`), and
  the copied snapshots keep incremental replication going with no re-seed;
- iDrive's backup set (paths under `/kodiak00/backups-00/`); new paths would
  have meant re-uploading ~2.8 TB off-site;
- tourbillon config, sudoers grants, the manual-snapshot helper, sanoid,
  `idrive-refresh-clones.sh`, the restore runbooks.

`backups-00` therefore names **the backup pool**, wherever it lives, not a
particular disk. Its history is in this ADR and the CHANGELOG.

### 3. The Reds become `scratch-00`

- The two WD Reds form a striped pool, **`scratch-00`**, about 7.25 TB,
  mounted at `/kodiak00/scratch-00`. It has no redundancy, by choice.
- For data that is cheap to lose and can be re-created: build space,
  staging, temporary copies. **Never the only copy of anything, and never a
  backup destination.**
- Future option, not done here: a nightly `syncoid` second copy of
  `backups-00` onto `scratch-00`, which would put two copies on separate
  disks.

### 4. Destinations come from config, not code

- Hosts: `target_dataset` in `configs/hosts/defaults.toml`, overridable per
  host (this already existed).
- Repos: `target_dataset` in `configs/repos/defaults.toml` is now honored.
  tourbillon resolves the dataset's mountpoint (`repos_target_root()`)
  instead of hardcoding `/kodiak00/backups-00/repos`.
- The privileged paths remain pinned to `backups-00/hosts` on purpose: the
  `zfs create` and `chown` sudoers grants, and the manual-snapshot helper
  (ADR-010). They are a security boundary. Moving hosts to a different
  parent is a deliberate change to those files, not a config edit.

### 5. How space is allocated and grown

- **Allocate per pool, grow on demand.** The LV starts at 6 TB (3.5 TB
  used), leaving ~10.7 TB unallocated in the VG for `data-00`, `media-00`
  and future growth. The pool has `autoexpand=on`.
- **Grow:** `lvextend -L +<n>T kodiak-datapool-00/backups-00`, then
  `zpool online -e backups-00 <vdev>`. Both are online operations.
- **When:** ADR-011's alert mails at ≥ 95% and warns at ≥ 90%. Grow at the
  90% warning; don't wait for the mail.
- **Don't shrink.** ZFS can't shrink a vdev. Size up in modest steps.
- Retention stays the tool for controlling growth: sanoid for hosts/repos,
  TrueNAS `retention_policy=SOURCE` for saratoga.

### 6. Boot ordering

`zfs-import-cache.service` only waits for udev to settle, which doesn't
guarantee LVM has activated the LV. The package ships the drop-in
`/etc/systemd/system/zfs-import-cache.service.d/server-backups-lvm.conf`,
which makes the import `Wants=`/`After=` the LV's device unit. `Wants=`
rather than `Requires=`, so a missing LV costs at most the device timeout
and other pools still import.

## Consequences

**Good**
- Every backup now survives a disk failure (RAID-10), and the pool went
  from 95% full to ~58%, with room to grow online.
- Nothing downstream changed name or path: no TrueNAS re-seed, no iDrive
  re-upload, no runbook edits.
- The Reds' 7.25 TB stay useful as scratch.

**Costs**
- ZFS on a hardware-RAID volume sees a single vdev, so it **detects**
  corruption (checksums, scrubs) but can't self-repair it. The RAID
  controller handles disk failures and patrol reads. Accepted for a backup
  tier.
- Backups and `data-00`/`media-00` now share one array and controller. A
  controller or chassis loss takes both, as it already would have with the
  Reds on the same controller. iDrive (off-site) remains the answer to
  site and controller loss.
- One more boot-ordering dependency (ZFS after LVM), shipped in the
  package.
- "backups-00" no longer means "the WD Red". Older docs and CHANGELOG
  entries describe the previous layout as history.

## Alternatives considered

- **Mirror the two Reds.** 4 TB usable: solves redundancy but not space,
  and buying two larger drives wasn't in the budget.
- **Stripe the Reds and keep backups on them.** 7.25 TB, but one disk
  failure loses every backup. Rejected once the RAID-10 option was clear.
- **New pool name `backups-01`.** Would have required retargeting both
  TrueNAS replication tasks, editing iDrive's backup set (and likely
  re-uploading ~2.8 TB), and changing sudoers, the helper, sanoid and the
  scripts. Rejected for the rename-at-swap approach.
- **A separate NAS.** Real isolation from kodiak, but money. Revisit with a
  10G link; kodiak's SFP+ ports are free.

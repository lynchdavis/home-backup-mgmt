# ADR-011: Storage health — alert on a degraded array, failed drive, or full pool

**Status:** Accepted, 2026-11-05.
**Builds on:** ADR-004 (tourbillon service user), ADR-007 (dashboard),
ADR-010 (root-owned validating helper + sudoers drop-in pattern).

---

## Context

On 2026-11-05, while sizing a Black Friday disk purchase, `storcli` showed
that kodiak's main array — `KodiakArray01`, RAID 10 over six 8 TB HGST
SAS drives on the MegaRAID 9361-8i, backing LVM `kodiak-datapool-00`
(`data-00`, `media-00`) — had been **degraded since 2026-07-25 16:55**.
The drive in slot 252:3 (S/N `2EGLRHKV`) had failed with a run of
unrecoverable read errors (sense 3/11). Its mirror partner in slot 252:5
has been the only copy of that third of the array ever since, with no hot
spare configured.

Nothing noticed for 3½ months, because nothing was looking at the right
layer:

- The OS sees one virtual disk (`/dev/sdc`, model `MR9361-8i`). SMART on
  it says nothing about the member drives.
- Tourbillon's "drive health" (`smart_attrs_dict`) watches `/dev/sdb`
  (the boot disk, a controller JBOD) — the physical drive, not the array.
- `pool_status_dict` watches ZFS `backups-00`, a single JBOD disk that is
  not on the RAID volume at all.
- The controller's own alarm only reaches the console/beeper.

A day later (2026-11-06) a second blind spot surfaced the same way: a
`repos sync` failure mail, `No space left on device`. `backups-00` had sat
at 96% for weeks — visible in `tourbillon status` and the weekly summary,
but nothing alerted — and had crossed ZFS's reserved slop space (1/32 of
the pool, ~116 GB, `spa_slop_shift=5`), leaving `zfs get available` at 0 on
every dataset while `zpool list` still showed 115 GB FREE. Every write to
the pool — repo mirrors, host backups, saratoga replication — then fails.

## Decision

### A root-owned helper wraps storcli

- `storcli64` needs root (the `megaraid_sas` ioctl node). Same shape as
  ADR-010: the package ships `/usr/lib/server-backups/raid-status`
  (root-owned, outside the tourbillon-owned `/opt/server-backups`), which
  accepts exactly `summary` or `rebuild` and maps each to one fixed,
  **read-only** storcli command (`/call show J`,
  `/call/eall/sall show rebuild J`, both with `nolog` so storcli doesn't drop root-owned `storcli.log` files into the caller's cwd). `/etc/sudoers.d/server-backups`
  grants tourbillon that one path. No argument tourbillon passes reaches
  storcli, so no controller-modifying command is reachable.
- storcli itself is **not** a package dependency: Broadcom doesn't publish
  it to an apt repo, so it's installed by hand from Broadcom's zip (a
  single binary at `/opt/MegaRAID/storcli/storcli64`; v007.2705 installed
  2026-11-05). If it's missing the helper exits 3, and the check reports
  that as a problem, never as healthy.

### `tourbillon health` — the check

- Parses controller → virtual drives → physical drives. A VD is healthy
  only in `Optl`. A PD is healthy in `Onln`, `JBOD`, `UGood`, `GHS`,
  `DHS`. `Rbld` is a problem (the array isn't redundant yet) and carries
  rebuild progress. Anything else — `Failed`, `Offln`, `UBad`, `Msng`, a
  VD in `Dgrd` / `Pdgd` / `OfLn`, a controller command that didn't
  succeed, the helper failing — is a problem.
- Every run writes `$STATE/health.json`. Readers that can't sudo (the
  dashboard, under `NoNewPrivileges`, and `tourbillon status` as `ldavis`)
  read that file instead of running storcli, and flag it stale past 3h.
- `tourbillon health` alone prints a human report (exit 1 on problems);
  `--json` prints the structured result.

### Pool capacity — same check, same mail

- `capacity_check()` reads every imported ZFS pool (`zpool list -Hp` +
  `zfs get available`, no sudo). **≥ 95% full → problem** (mailed);
  **≥ 90% → warning** (status, dashboard, weekly summary WARN — never
  mailed). **`available` = 0 → a separate problem**, because that's the
  point writes actually fail, and it's a distinct fingerprint so crossing
  it mails even when the ≥ 95% alert already went out.
- Problem strings name the threshold, not the live percentage, so 96% →
  97% doesn't re-mail.
- Only ZFS pools: the LVM/ext4 filesystems on the RAID volume aren't
  checked (they sit at 35% with ~16.7 TB unallocated in the VG).
- `tourbillon health` therefore records `$STATE/health.json` (RAID +
  pools), and `status --json` exposes it as `health`.

### Alerting — hourly check, deduped mail

- tourbillon's crontab runs `tourbillon health --alert` hourly through
  `mail-on-output.sh -V "storage health"`. In `--alert` mode the command is
  **silent unless a mail is due**:
  - problems whose fingerprint (the sorted problem list) differs from the
    last alert → print + exit 1 (mail: `storage health FAILED`);
  - the same problems, last alerted ≥ 24h ago → reminder, exit 1;
  - healthy after an alert → one "recovered" message, exit 0 (mailed
    via `-V`);
  - otherwise silent, exit 0.
- RAID and pool problems share one fingerprint and one mail ("STORAGE
  PROBLEM"); "recovered" is sent only once *nothing* is wrong.
- So a failure mails within the hour, once a day while it persists, and
  once on recovery. A rebuild's changing progress percentage is excluded
  from the fingerprint so it doesn't re-mail hourly.

### Visibility

- The weekly summary flags any problem or a stale check as FAIL (a ≥ 90% pool as WARN) and
  gains a "RAID controller" section; `tourbillon status` and the
  dashboard's status panel show array state and any non-healthy drives.

## Consequences

**Good**
- Both failure modes that went unseen — a degraded array for 3½ months, a
  full backup pool for weeks — now mail within an hour.
- The privilege boundary keeps ADR-010's shape: one more validating helper
  under the same drop-in, read-only by construction.

**Costs**
- A hand-installed vendor binary the package can't pin or upgrade; a
  missing/broken storcli is at least reported loudly rather than silently.
- Only MegaRAID controllers are understood. A future HBA/mdraid/ZFS-only
  layout would need its own source.
- No other alarm is silenced: the controller beeper/console alerts are
  unchanged.

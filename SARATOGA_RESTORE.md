# SARATOGA_RESTORE

How to get data back when saratoga loses it. Companion to [PLAYBOOK.md](PLAYBOOK.md).

**Scope:** restore from the kodiak-side ZFS pool `backups-00` (mounted at `/kodiak00/backups-00`), populated by TrueNAS Replication Tasks pushing from saratoga. The replicated snapshots follow saratoga's TrueNAS naming schema (`auto-YYYY-MM-DD_HH-MM`).

**Not in scope:** restoring the TrueNAS system config itself (apps, SMB share definitions, network config). Those are state, not data — recreate with `saratoga-build.sh` / `saratoga-shares.sh` from `~/development/data-organizer/`.

---

## Mental model — three safety nets, in order

1. **Saratoga's own snapshots** — TrueNAS Periodic Snapshot Tasks keep recent history on saratoga itself. Restore from there first, no kodiak round-trip needed.
2. **Kodiak's replicated snapshots** — `backups-00/saratoga/{tank,media}/...@auto-YYYY-MM-DD_HH-MM`, accessible via `.zfs/snapshot/`. Same naming as saratoga's, just lives on kodiak.
3. **Saratoga is gone** — reverse-replicate from kodiak back to fresh saratoga hardware via `zfs send | ssh new-saratoga zfs recv`.

Each layer is independent — a botched restore at layer 2 doesn't corrupt layer 3.

---

## Important: destinations are unmounted on kodiak

`backups-00/saratoga/tank` and `backups-00/saratoga/media` have `canmount=noauto` (see [PLAYBOOK.md](PLAYBOOK.md#3-pre-create-destination-datasets-unmounted) for why). To browse a backed-up tree on kodiak:

```bash
# mount the specific child dataset you need
sudo zfs mount backups-00/saratoga/tank/archive/photography
ls /kodiak00/backups-00/saratoga/tank/archive/photography
# ... do your thing ...
sudo zfs unmount backups-00/saratoga/tank/archive/photography
```

The `.zfs/snapshot/` magic dir *should* be accessible without explicitly mounting (depending on ZFS version), but mounting is the safe play.

---

## Scenario 1 — single file recovery

Cost: minutes. Risk: none.

### From saratoga's own snapshots (preferred)

```bash
# On saratoga — every snapshot is read-only mounted under .zfs/snapshot/
ls /mnt/tank/archive/photography/.zfs/snapshot/
cp /mnt/tank/archive/photography/.zfs/snapshot/auto-2026-05-23_02-00/IMG_0042.jpg \
   /mnt/tank/archive/photography/IMG_0042.jpg
```

### From kodiak's replicated snapshots

```bash
# On kodiak — mount the destination dataset first
sudo zfs mount backups-00/saratoga/tank/archive/photography

ls /kodiak00/backups-00/saratoga/tank/archive/photography/.zfs/snapshot/
scp /kodiak00/backups-00/saratoga/tank/archive/photography/.zfs/snapshot/auto-2026-05-23_02-00/IMG_0042.jpg \
    saratoga:/mnt/tank/archive/photography/

sudo zfs unmount backups-00/saratoga/tank/archive/photography
```

---

## Scenario 2 — directory or dataset wiped on saratoga

Cost: minutes to hours.

### Path A — preferred: clone the snapshot, cherry-pick

Non-destructive. Lets you compare and choose what to bring back.

```bash
# On saratoga
zfs clone tank/archive@auto-2026-05-23_02-00 tank/restore-tmp
# /mnt/tank/restore-tmp/ is now a writable copy of the snapshot.
rsync -aHAX /mnt/tank/restore-tmp/<lost-path>/ /mnt/tank/archive/<lost-path>/
zfs destroy tank/restore-tmp
```

### Path B — last-resort: full dataset rollback (DESTRUCTIVE)

Wipes everything in the dataset newer than the snapshot. Only use if certain nothing post-snapshot matters.

```bash
zfs rollback tank/archive@auto-2026-05-23_02-00
```

### Path C — if saratoga snapshot is gone, restore from kodiak

```bash
# On kodiak — pipe a snapshot back to saratoga as a new dataset
sudo zfs send backups-00/saratoga/tank/archive@auto-2026-05-23_02-00 \
  | ssh root@saratoga "zfs recv tank/restore-tmp"

# On saratoga — cherry-pick + clean up (see Path A)
```

(`root@saratoga` requires either re-enabling root SSH on TrueNAS temporarily, or using the TrueNAS UI's Shell to pipe via netcat. The TrueNAS Replication UI also supports reverse replication tasks.)

---

## Scenario 3 — saratoga is gone (disaster recovery)

Cost: hours, dominated by hardware setup and the ~2.4 TB transfer.

### Steps

1. **Stand up new hardware**; install TrueNAS to a fresh boot pool.
2. **Re-create pool layout** per `saratoga-build.sh` (raidz1 `tank`, mirror `media`, NVMe `apps`).
3. **Restore TrueNAS config**: SSH keypairs, replication credentials, network. Either from a TrueNAS config backup if you have one, or re-create via UI + the JSON snapshots in `configs/` for replication structure.
4. **Open SSH to new-saratoga** so kodiak can push the data back. Root over SSH works for DR (you control both ends; temporary).
5. **From kodiak, reverse-replicate** each top-level dataset RECURSIVELY:

```bash
# Tank
sudo zfs send -R backups-00/saratoga/tank@<latest-snap> \
  | ssh root@new-saratoga "zfs recv -F tank"

# Media
sudo zfs send -R backups-00/saratoga/media@<latest-snap> \
  | ssh root@new-saratoga "zfs recv -F media"
```

Find `<latest-snap>` via:
```bash
sudo zfs list -t snapshot -o name,creation -r backups-00/saratoga/tank \
  | sort -k2,3 | tail -5
```

Transfer time: ~3-6 hours total over 10 GbE for 2.4 TB (varies based on incompressible content; the photography subset will dominate).

6. **Re-create TrueNAS-side state that doesn't transfer**:
   - SMB share definitions (`saratoga-shares.sh` as starting point)
   - App / container instances (re-deploy via TrueNAS UI; user data IS in the replicated `tank/archive/...`)
   - Scheduled tasks (snapshot tasks, scrubs)
   - User accounts / passwords
   - The Replication + Snapshot Tasks themselves — POST the JSON in `configs/` via API

7. **Re-enable client-side mounts** (SMB shares on laptop, kodiak, etc.).

### What does NOT transfer

Things that live in TrueNAS application/system state, not in user data, and aren't replicated:

- TrueNAS system config (use `saratoga-build.sh` to re-create pool layout).
- SMB share definitions (`saratoga-shares.sh`).
- App / container instances (re-define via TrueNAS UI; user data they hold IS in the backup if the data lived on a replicated dataset).
- Cron / scheduled tasks (re-create from `configs/snapshot-tasks.json` and `configs/replication-tasks.json` via API).
- User passwords / SSH keys.
- TrueNAS apps internals (`apps/.ix-virt`, `apps/.system`) — intentionally excluded; re-create on fresh install.

---

## Scenario 4 — file recovery from a non-ZFS terminal

Kodiak is the bridge:

```bash
# From a laptop, Mac, Windows, whatever
ssh ldavis@kodiak 'sudo zfs mount backups-00/saratoga/tank/archive/photography'
scp ldavis@kodiak:/kodiak00/backups-00/saratoga/tank/archive/photography/<path> .
ssh ldavis@kodiak 'sudo zfs unmount backups-00/saratoga/tank/archive/photography'
```

Or SMB-share `/kodiak00/backups-00/saratoga/` over the LAN if GUI browsing is needed.

---

## Restore confidence-builder — run once, then annually

A backup you've never restored from is theoretical.

### Test 1 — single-file restore (5 min)

1. Pick a random file in a replicated dataset on kodiak.
2. Hash it: `sha256sum <path>`.
3. Hash the saratoga original: `ssh ldavis@saratoga sha256sum <path>`.
4. Confirm match.

### Test 2 — snapshot-mount (1 min)

```bash
sudo zfs mount backups-00/saratoga/tank/archive
ls /kodiak00/backups-00/saratoga/tank/archive/.zfs/snapshot/
cd /kodiak00/backups-00/saratoga/tank/archive/.zfs/snapshot/<some-snap>/ && ls
sudo zfs unmount backups-00/saratoga/tank/archive
```

### Test 3 — reverse-send to scratch (15 min)

Round-trips a small dataset to prove DR mechanics work end-to-end.

```bash
sudo zfs create backups-00/restore-test
sudo zfs send backups-00/saratoga/tank/scratch@<recent-snap> \
  | sudo zfs recv backups-00/restore-test/scratch
sudo zfs list -r backups-00/restore-test
sudo zfs destroy -r backups-00/restore-test
```

---

## Permissions reference

For all the operations above as root (or `ldavis` with `sudo`):
- `zfs mount` / `zfs unmount` of `backups-00/*` on kodiak.
- `zfs send` from `backups-00/*` on kodiak.
- `zfs recv` / `zfs rollback` on `tank/*` or `media/*` on saratoga — requires root via TrueNAS Shell, or temporarily-enabled root SSH for DR.

The dedicated `tnreplicate` user has just enough to *receive* on `backups-00/saratoga`, not enough to do general restore — that's intentional; use root/sudo for restore operations.

---

## Quick reference

| Need | Path |
|---|---|
| Recover a file, saratoga is alive | `.zfs/snapshot/` on saratoga |
| Recover a file, saratoga lost the snapshot | Mount + `.zfs/snapshot/` on kodiak |
| Recover a directory tree | `zfs clone` on saratoga, cherry-pick, destroy clone |
| Roll back a whole dataset | `zfs rollback` — DESTRUCTIVE, last resort |
| saratoga is dead | `zfs send -R … | ssh new-saratoga zfs recv -F …` |
| Browse from non-ZFS terminal | `scp` or SMB share from kodiak |

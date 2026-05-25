# Saratoga → Kodiak Backup Playbook

**Date written:** 2026-05-24, after first successful seed.

A condensed operational record of the saratoga (TrueNAS) → kodiak (Debian/ZFS) backup system. Captures what works, the order things had to be done in, and the dead ends so future-you doesn't re-walk them.

---

## Architecture, in one paragraph

TrueNAS Replication Tasks **push** ZFS snapshots from saratoga to kodiak's `backups-00` ZFS pool. Two tasks: `tank → backups-00/saratoga/tank` and `media → backups-00/saratoga/media`, both recursive, both excluding TrueNAS-internal datasets (`tank/system`, `tank/timemachine`). Snapshots originate from TrueNAS Periodic Snapshot Tasks on saratoga (daily @ 02:00, 2-week source retention). On kodiak the destination pool stays unmounted (`canmount=noauto`) so the Linux mount/umount permission gate doesn't block the receive. Configuration is authoritative in this repo as JSON; the TrueNAS UI is the operational view. The repo refreshes its config dump on demand via the TrueNAS REST API.

---

## Why push (not pull)

Pull-via-syncoid from kodiak is the "obviously correct" architecture (backup host owns "did it happen"). We tried it. **TrueNAS 25's hardening is structurally hostile to unprivileged external clients invoking ZFS over SSH.** Specifically:

1. Root SSH login is locked by default.
2. `/` is read-only — no symlinking `zfs` into a PATH-discoverable location.
3. `AcceptEnv PATH` in Auxiliary Parameters (the only way to add sshd directives) gets wrapped in a `Match Group "truenas_admin"` block, so it only applies to truenas_admin users, not our dedicated backup user.
4. `PermitUserEnvironment` is not allowed inside Match blocks; adding it via Aux Params breaks sshd's config validator → sshd fails to start.
5. ZFS delegation alone doesn't get you around Linux's kernel-level mount/umount permission gate on the receive side either.

After four diagnosed dead-ends with concrete blast-radius (one broke sshd), we pivoted to push. TrueNAS owns its own side as root internally; we only have to make the *receive* side work on kodiak — a system we fully control.

What this design gives up:
- **Config not in repo (natively)** — recovered by `bin/dump-saratoga-config.sh` pulling the live state into JSON.
- **Saratoga owns "did it happen?"** — recovered by `bin/check-saratoga-replication.sh` on kodiak: passive "did a fresh snapshot land in the last 26h?" check.

---

## Final shape (the steady state)

### Kodiak side

- **ZFS pool `backups-00`** on `/dev/sdb` (WDC WD40EFRX 4TB, by-id `ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E1DKPPNP`).
  - `ashift=12`, `compression=lz4`, `atime=off`, `xattr=sa`, `acltype=posixacl`.
  - Mountpoint `/kodiak00/backups-00` (drop-in for the old LVM that lived there).
- **Datasets** (pre-created with `canmount=noauto`):
  - `backups-00/saratoga` — parent container
  - `backups-00/saratoga/tank` — receives saratoga's `tank` tree
  - `backups-00/saratoga/media` — receives saratoga's `media` tree
- **User `tnreplicate`** (uid 997, home `/var/lib/tnreplicate`, shell bash).
  - `~/.ssh/authorized_keys` contains TrueNAS's replication pubkey.
  - `/etc/sudoers.d/tnreplicate` grants passwordless sudo for `/usr/sbin/zfs` and `/usr/sbin/zpool` (and `/sbin/` versions).
  - ZFS delegation on `backups-00/saratoga`: `create,mount,receive,destroy,rollback,bookmark,hold,release,mountpoint,canmount,readonly,compression,recordsize,atime,xattr,acltype,quota,reservation,userprop` (Local+Descendent). NB: the delegation is partly belt-and-suspenders given sudo is also in place.

### Saratoga side (TrueNAS 25)

- **SSH Keypair** named `kodiak-tnreplicate` (Credentials → Backup Credentials → SSH Keypairs).
- **SSH Connection** named `kodiak` pointing at `192.168.0.61:22` as user `tnreplicate` (Credentials → Backup Credentials → SSH Connections).
- **API Key** (one) for config dumps from kodiak.
- **Periodic Snapshot Tasks** — `tank` (recursive, 2-week lifetime, daily @ 02:00), `media` (same), plus pre-existing finer-grained tasks (`tank/active` 1-day, `tank/archive` 30-day, `media/music` 1-year, etc. — all using the `auto-%Y-%m-%d_%H-%M` naming schema).
- **Replication Tasks**:
  - `tank - backups-00/saratoga` → push, recursive, exclude `tank/system, tank/timemachine`, properties_exclude `[mountpoint, canmount]`, large_block=true, compressed=true, sudo=false (the source side; we *do* need sudo on target but TrueNAS handles that via the connection user's privileges, not this flag).
  - `media - backups-00/saratoga` → push, recursive, no excludes, same properties_exclude, same flags.
- **Run trigger**: Run Automatically — fires after the matching snapshot task creates a new snapshot. No explicit cron.

---

## Setup, in order, from a freshly-imaged kodiak

This is the playbook for "I rebuilt kodiak; restore backups-00 from scratch." The saratoga side is already in place (TrueNAS UI state).

### 1. ZFS module on kodiak

Debian 13 contrib already enabled. Then:
```bash
sudo DEBIAN_FRONTEND=noninteractive apt install -y zfsutils-linux linux-headers-amd64
sudo modprobe zfs && zfs version       # confirm
```
**Gotcha:** `zfs-dkms` shows an interactive whiptail CDDL/GPL msgbox that `apt -y` doesn't dismiss — `DEBIAN_FRONTEND=noninteractive` is required, not optional. If you skip it, the install appears to hang.

**Gotcha:** kernel headers must match the running kernel exactly, *and* the meta-package `linux-headers-amd64` (so future kernel upgrades pull matching headers automatically).

### 2. Pool creation

```bash
sudo zpool create \
  -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  -O mountpoint=/kodiak00/backups-00 \
  backups-00 \
  /dev/disk/by-id/ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E1DKPPNP
```
**Gotcha:** never `/dev/sdb` — the by-id path is stable across reboots/hardware changes.

**Gotcha:** also confirm `/etc/fstab` doesn't have a stale `/kodiak00/backups-00` entry from any prior LVM setup; if so comment it out. ZFS auto-imports via `zfs-import.target`, doesn't need fstab.

### 3. Pre-create destination datasets, *unmounted*

```bash
sudo zfs create -o canmount=noauto backups-00/saratoga
sudo zfs create -o canmount=noauto backups-00/saratoga/tank
sudo zfs create -o canmount=noauto backups-00/saratoga/media
```
**Why `canmount=noauto`:** OpenZFS on Linux gates the mount/umount syscall at the kernel level regardless of ZFS-layer delegation. If destination datasets are mounted, `zfs recv -F` tries to unmount them and fails with `permission denied`. `canmount=noauto` keeps them unmounted; recv has nothing to unmount.

### 4. `tnreplicate` user + sudoers + ZFS delegation

```bash
sudo useradd -r -m -d /var/lib/tnreplicate -s /bin/bash \
  -c 'saratoga -> kodiak ZFS replication receiver' tnreplicate
sudo install -d -m 700 -o tnreplicate -g tnreplicate /var/lib/tnreplicate/.ssh
sudo install -m 600 -o tnreplicate -g tnreplicate /dev/null /var/lib/tnreplicate/.ssh/authorized_keys

sudo tee /etc/sudoers.d/tnreplicate >/dev/null <<'EOF'
tnreplicate ALL=(root) NOPASSWD: /usr/sbin/zfs, /sbin/zfs, /usr/sbin/zpool, /sbin/zpool
EOF
sudo chmod 0440 /etc/sudoers.d/tnreplicate
sudo visudo -cf /etc/sudoers.d/tnreplicate

sudo zfs allow -u tnreplicate \
  create,mount,receive,destroy,rollback,bookmark,hold,release,mountpoint,canmount,\
readonly,compression,recordsize,atime,xattr,acltype,quota,reservation,userprop \
  backups-00/saratoga
```
**Gotcha:** the Debian-default `backup` user (uid 34) is for OS-level archive snapshots (`/var/backups/alternatives.tar.*`). Don't repurpose it; create `tnreplicate` separately.

**Gotcha:** the "Use Sudo For ZFS Commands" checkbox in TrueNAS Replication Tasks **only applies to the local (source) side**, not the target side. To allow elevation on the kodiak receive, the SSH user must have sudo on the host directly (via sudoers).

### 5. TrueNAS side — SSH credential + key on kodiak

In TrueNAS UI:
- *Credentials → Backup Credentials → SSH Keypairs → Add* → Generate → save as `kodiak-tnreplicate`. **Copy the public key.**
- *Credentials → Backup Credentials → SSH Connections → Add* → Manual: name `kodiak`, host `192.168.0.61`, port `22`, username `tnreplicate`, private key = the keypair you just made.

On kodiak, paste the public key into `/var/lib/tnreplicate/.ssh/authorized_keys` (owned by tnreplicate, mode 0600).

### 6. API key + initial config dump

In TrueNAS UI: *Credentials → Local Users → root → API Keys → Add*. Copy the token. Store it where you'll find it; **TrueNAS shows it exactly once**.

```bash
export TRUENAS_API_TOKEN='1-...'
bin/dump-saratoga-config.sh   # snapshot the current live state into configs/
```

### 7. Snapshot + Replication Tasks via API

If recreating from scratch with no UI-managed tasks yet, run `bin/apply-tank-tasks.sh` and `bin/apply-media-tasks.sh` (or write equivalents per dataset). They POST templated JSON to `/api/v2.0/pool/snapshottask` and `/api/v2.0/replication`.

### 8. First seed — the snapshot precondition gotcha

A replication task references a snapshot task. Until that snapshot task has *fired at least once*, no matching snapshots exist at the parent dataset, and a manual Run Now fails:
> `[EFAULT] Dataset 'media' does not have any matching snapshots to replicate.`

Fix: create the first parent snapshot manually via API:
```bash
SNAP="auto-$(date '+%Y-%m-%d_%H-%M')"
curl -sk -X POST \
  -H "Authorization: Bearer $TRUENAS_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"dataset\":\"media\",\"name\":\"$SNAP\",\"recursive\":true}" \
  https://192.168.0.60/api/v2.0/pool/snapshot
```
Then fire the replication task:
```bash
curl -sk -X POST \
  -H "Authorization: Bearer $TRUENAS_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '2' \
  https://192.168.0.60/api/v2.0/replication/run
```
**Gotcha (API URL trap):** the endpoint is `/replication/run` with the task id as the JSON body — **not** `/replication/id/<id>/run`. The latter returns `404 Not Found`. The same shape is `/pool/snapshot` for snapshot create, not `/zfs/snapshot`. Stick to the actual middleware paths; many of the obvious-guess URLs 404.

### 9. Watch the seed

- API: `GET /replication/id/<id>` → `.job.progress.description` and `.state.state`
- Kodiak: `zfs list -r backups-00/saratoga`
- Pool throughput: `zpool iostat backups-00 2`

Tank's first seed (1.99 TiB) took ~2.5 hours over 10 GbE. Media (~430 GB) took ~30-45 min sequential. **Initial transfer rate was misleadingly fast** (~1.25 GB/s on highly compressible small files) — actual sustained on photography was ~95 MB/s, which dominates wall clock. Don't estimate ETA from the first minute.

---

## Adding a new replication target

1. Pre-create destination dataset on kodiak: `sudo zfs create -o canmount=noauto backups-00/saratoga/<new>`.
2. In TrueNAS UI, add a Periodic Snapshot Task at the source (recursive, naming schema `auto-%Y-%m-%d_%H-%M`, sensible lifetime). Or do it via API.
3. Add the Replication Task — easiest via `bin/apply-<target>-tasks.sh` mirroring `apply-media-tasks.sh`. Same templated settings.
4. Create the first parent-level snapshot via API (the precondition gotcha above).
5. Fire the replication via API or UI Run Now.
6. After it succeeds, run `bin/dump-saratoga-config.sh` to refresh the JSON in this repo.

---

## Operational

### Daily

The snapshot tasks fire at 02:00. Each replication task with `auto: true` runs immediately after its snapshot task completes. No active operator role.

### Weekly-ish

```bash
bin/check-saratoga-replication.sh    # "did backup happen?"
```
Logs to stderr if no fresh snapshot landed in the last 26h. Wire as cron mail if you want a heartbeat.

### When something changes in TrueNAS

```bash
export TRUENAS_API_TOKEN='1-...'
bin/dump-saratoga-config.sh
git -C /home/ldavis/development/server-backups diff configs/
git -C /home/ldavis/development/server-backups commit -am "config: refresh after <change>"
```

### Restore

See **[SARATOGA_RESTORE.md](SARATOGA_RESTORE.md)**.

---

## Dead ends — what NOT to do

Things tried during setup that don't work, with the specific failure mode so you can recognize the symptom in the future:

| Attempted | How it fails | Why |
|---|---|---|
| **Pull via syncoid from kodiak as root@saratoga** | `Permission denied (publickey)` | TrueNAS 25 locks root SSH login. Adding the pubkey to `/root/.ssh/authorized_keys` either doesn't survive middleware regeneration or is filtered. |
| **Pull as ldavis with `AcceptEnv PATH`** | `SetEnv=PATH` silently dropped | TrueNAS wraps Aux Params in `Match Group "truenas_admin"` — only that group's sessions see them. |
| **`PermitUserEnvironment yes` in Aux Params** | sshd refuses to start, ssh service goes down | Directive not legal in Match block; TrueNAS doesn't catch it; sshd config validator fails. **Don't do this — it breaks SSH access entirely until removed.** |
| **Symlinks into `/usr/local/bin` for PATH fix** | `Read-only file system` | `/` on TrueNAS Scale is immutable; `/etc` is the only writable system dir, and it's still managed. |
| **Pull working but ZFS delegation alone for recv** | `cannot unmount '...': permission denied` | OpenZFS on Linux gates mount/umount at kernel level; ZFS-layer delegation doesn't bypass it. Need either sudo OR `canmount=noauto` to avoid the mount step entirely. |
| **"Use Sudo For ZFS Commands" toggle** | No change in behavior; same `permission denied` | Toggle only applies to *local* zfs commands on the TrueNAS side, not the receiver side over SSH. |
| **URL `POST /replication/id/<id>/run`** | `404 Not Found` | Correct shape is `POST /replication/run` with raw integer task id as JSON body. |
| **URL `POST /zfs/snapshot`** | `404 Not Found` | Correct path is `POST /pool/snapshot`. |
| **Recursive snapshot via `zfs snapshot -r media@...` as ldavis** | `cannot create snapshots : permission denied` | ldavis has no ZFS delegation (those grants were going to be done during the pull design, never executed before the push pivot). Use the API instead, or grant explicit `snapshot` delegation. |

---

## What's intentionally NOT in this design

- **No syncoid / sanoid on kodiak.** Briefly installed, no longer used; can be left installed (it's small) or `apt remove sanoid` if you prefer. None of the daily flow touches it.
- **No mount of `backups-00/saratoga/*` as a working filesystem.** `canmount=noauto`. To browse files: `sudo zfs mount backups-00/saratoga/<dataset>` ad-hoc; unmount when done. The `.zfs/snapshot/` magic dir works without the dataset being mounted on most ZFS versions.
- **No kodiak-side sanoid.conf retention policy** (yet). Snapshots arrive with saratoga's lifetime metadata; TrueNAS prunes the source side; the destination accumulates per `retention_policy: SOURCE`. If we want kodiak to keep longer history than saratoga (the natural "deep history backup" use case), add a sanoid policy or change `retention_policy` to `CUSTOM` on the replication tasks.
- **No off-site / cloud tier.** If both saratoga AND kodiak die simultaneously, the data is gone. This is the next architectural layer when motivated.
- **No client-host backups.** A2 (LynchMBP + linux desktops + Windows box) is a separate problem with a separate playbook.

---

## Files in this repo

```
README.md                    overview
PLAYBOOK.md                  this file
SARATOGA_RESTORE.md          restore scenarios + commands
configs/
  replication-tasks.json     live state, refreshed by dump script
  snapshot-tasks.json        live state
  ssh-connections.json       live state
  ssh-keypairs.sanitized.json   live state (private keys redacted)
  templates/
    snapshot-task-media.json   template for new media-style snapshot tasks
    replication-task-media.json   template for new media-style replication tasks
bin/
  dump-saratoga-config.sh        refresh configs/ from TrueNAS API
  apply-media-tasks.sh           create snapshot + replication task for media via API
  check-saratoga-replication.sh  passive monitor: did a snapshot land in last 26h
```

## Saratoga API quick reference

| Need | Endpoint |
|---|---|
| List replication tasks | `GET /api/v2.0/replication` |
| List snapshot tasks | `GET /api/v2.0/pool/snapshottask` |
| List SSH connections | `GET /api/v2.0/keychaincredential?type=SSH_CREDENTIALS` |
| List SSH keypairs | `GET /api/v2.0/keychaincredential?type=SSH_KEY_PAIR` |
| Create a snapshot task | `POST /api/v2.0/pool/snapshottask` body=full task object |
| Create a replication task | `POST /api/v2.0/replication` body=full task object |
| Create a manual snapshot | `POST /api/v2.0/pool/snapshot` body=`{"dataset":..., "name":..., "recursive":...}` |
| Fire a replication task | `POST /api/v2.0/replication/run` body=`<task_id>` (raw integer) |

Auth: `Authorization: Bearer <token>`. Self-signed cert; use `-k` with curl or trust the cert.

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
- **Saratoga owns "did it happen?"** — recovered by `tests/check-saratoga-replication.sh` on kodiak: passive "did a fresh snapshot land in the last 26h?" check.

---

## Final shape (the steady state)

### Kodiak side

- **ZFS pool `backups-00`** on `/dev/sdb` (WDC WD40EFRX 4TB, by-id `ata-WDC_WD40EFRX-68WT0N0_WD-WCC4E1DKPPNP`).
  - `ashift=12`, `compression=lz4`, `atime=off`, `xattr=sa`, `acltype=posixacl`.
  - Mountpoint `/kodiak00/backups-00` (drop-in for the old LVM that lived there).
- **Datasets**:
  - `backups-00/saratoga` — parent container for saratoga DR (`canmount=noauto`)
  - `backups-00/saratoga/tank` — receives saratoga's `tank` tree (`canmount=noauto`)
  - `backups-00/saratoga/media` — receives saratoga's `media` tree (`canmount=noauto`)
  - `backups-00/repos` — bare-repo mirrors from GitHub + Bitbucket (`canmount=on`, `recordsize=128K`, owned by `tourbillon` per [ADR-004](doc/ADR-004-kodiak-side-service-user.md)). Managed by `bin/tourbillon repos sync` running as the kodiak `tourbillon` user.
  - `backups-00/hosts` — rsync mirrors of each backed-up host (one child dataset per host; owned by `tourbillon`). Managed by `bin/tourbillon hosts sync`.
- **User `tnreplicate`** (uid 997, home `/var/lib/tnreplicate`, shell bash).
  - `~/.ssh/authorized_keys` contains TrueNAS's replication pubkey.
  - `/etc/sudoers.d/tnreplicate` grants passwordless sudo for `/usr/sbin/zfs` and `/usr/sbin/zpool` (and `/sbin/` versions).
  - ZFS delegation on `backups-00/saratoga`: `create,mount,receive,destroy,rollback,bookmark,hold,release,mountpoint,canmount,readonly,compression,recordsize,atime,xattr,acltype,quota,reservation,userprop` (Local+Descendent). NB: the delegation is partly belt-and-suspenders given sudo is also in place.

### Saratoga side (TrueNAS 25)

- **SSH Keypair** named `kodiak-tnreplicate` (Credentials → Backup Credentials → SSH Keypairs).
- **SSH Connection** named `kodiak` pointing at `192.168.0.61:22` as user `tnreplicate` (Credentials → Backup Credentials → SSH Connections).
- **API Key** (one) for config dumps from kodiak.
- **Periodic Snapshot Tasks** — `tank` (recursive, 2-week lifetime, daily @ **02:05**), `media` (recursive, 2-week, daily @ 02:00), plus pre-existing finer-grained tasks (`tank/active` 1-day hourly, `tank/archive` 30-day @ 03:00, `media/music` 1-year, etc. — all using the `auto-%Y-%m-%d_%H-%M` naming schema). The 02:05 minute offset on the `tank` task is intentional — see "Snapshot-task scope/schedule collisions" below.
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

### 3. Pre-create destination datasets

Three distinct datasets — one for saratoga (must stay unmounted), one
for repo mirrors (mounted, owned by the kodiak `tourbillon` service user
per [ADR-004](doc/ADR-004-kodiak-side-service-user.md)), one parent
dataset for host backups (also tourbillon-owned; per-host children get
created at first-seed time).

Prereq: the `tourbillon` system user must exist on kodiak, plus its sudoers entry. One-shot setup script (idempotent) handles both:

```bash
bash bin/bootstrap-kodiak-tourbillon.sh
```

That creates the user (locked password, `/var/lib/tourbillon` home), installs `/etc/sudoers.d/tourbillon` with the narrow NOPASSWD entries for `zfs create backups-00/hosts/*`, `chown tourbillon:tourbillon /kodiak00/backups-00/hosts/*`, and `rsync`, and flips ownership of any existing A2 dataset paths.

Then create the datasets:

```bash
# saratoga DR — canmount=noauto to sidestep Linux's mount-permission gate
sudo zfs create -o canmount=noauto backups-00/saratoga
sudo zfs create -o canmount=noauto backups-00/saratoga/tank
sudo zfs create -o canmount=noauto backups-00/saratoga/media

# repo mirrors — small files, mounted, owned by the tourbillon service user
sudo zfs create -o canmount=on -o compression=lz4 -o atime=off \
                -o recordsize=128K -o xattr=sa -o acltype=posixacl \
                backups-00/repos
sudo chown tourbillon:tourbillon /kodiak00/backups-00/repos

# host backups — parent dataset only; per-host children at first-seed time
sudo zfs create -o canmount=on -o compression=lz4 -o atime=off \
                -o xattr=sa -o acltype=posixacl \
                backups-00/hosts
sudo chown tourbillon:tourbillon /kodiak00/backups-00/hosts
```

**Why `canmount=noauto` on the saratoga side:** OpenZFS on Linux gates the
mount/umount syscall at the kernel level regardless of ZFS-layer delegation.
If destination datasets are mounted, `zfs recv -F` tries to unmount them and
fails with `permission denied`. `canmount=noauto` keeps them unmounted; recv
has nothing to unmount.

**Why `canmount=on` + chown on the A2 side:** bare-repo mirrors and rsync
host backups are plain filesystem writes (`git clone --mirror`, `rsync`),
which need a mounted filesystem and the script user (`tourbillon`) to be
able to write. No ZFS recv tricks involved.

### 3a. Snapshot retention on tourbillon datasets (sanoid)

`backups-00/saratoga/*` snapshot retention is managed by TrueNAS's
replication tasks (`retention_policy=SOURCE`). The tourbillon-side
datasets (`backups-00/repos`, `backups-00/hosts/*`) aren't covered by
that and need their own retention. Sanoid handles them:

```bash
# Deploy the canonical config from the repo:
sudo install -d -m 755 /etc/sanoid
sudo install -m 644 configs/sanoid/sanoid.conf /etc/sanoid/sanoid.conf

# The sanoid.timer is enabled by default by the package; verify:
systemctl is-enabled sanoid.timer
systemctl is-active  sanoid.timer

# Take the first snapshot immediately (the timer would also fire within
# 15 min; this just removes the wait):
sudo sanoid --configdir=/etc/sanoid --cron
```

Policy (`configs/sanoid/sanoid.conf`):
- `backups-00/repos` — 30 daily snapshots, non-recursive (one dataset).
- `backups-00/hosts` — 30 daily snapshots, **recursive** (each per-host
  child dataset gets its own snapshot timeline). New children added at
  first-seed time are picked up automatically on the next sanoid tick.

No hourly/monthly/yearly. Repo and host data churn slowly; 30 daily
deltas is generous without being expensive.

**Gotcha:** sanoid's `--readonly` flag affects *pruning*, not snapshot
*creation* — running `--readonly --cron` will still take a snapshot if
one is due. If you want a true dry-run, just read the config and trust
that the policy does what it says.

### 3b. Monthly `zpool scrub` on `backups-00`

Scrub reads every block in the pool and verifies checksums against ZFS's
recorded metadata. On a single-disk pool there's no parity for self-repair,
but scrub *detects* silent corruption before you hit it during a real read.
Standard cadence: monthly.

`zfsutils-linux` ships a parameterized systemd timer for exactly this. We
don't need a custom cron entry — just enable the shipped timer:

```bash
sudo systemctl enable --now zfs-scrub-monthly@backups-00.timer
```

Verify:
```bash
systemctl status zfs-scrub-monthly@backups-00.timer
systemctl list-timers 'zfs-scrub*'
```

What the timer does:
- Fires on `OnCalendar=monthly` (first of each month, jittered by up to 1h).
- `Persistent=true` — catches up if the host was off when the timer would have fired.
- `ConditionACPower=true` — skips on battery (irrelevant for a NAS but defensible).
- Service uses `zpool scrub -w <pool>` which **blocks** until scrub completes,
  so the systemd unit's state accurately reflects scrub progress / completion.
- Scrub on this 4 TB drive at ~150 MB/s read = ~7-8 hours wall clock.

To watch progress mid-scrub:
```bash
zpool status backups-00          # shows "scrub in progress" with % and ETA
```

To check post-scrub:
```bash
zpool status -x backups-00        # "all pools are healthy" or details
```

`zpool status -x` is the right thing to wrap if you want a periodic email
heartbeat: it's silent on healthy pools and outputs problems otherwise.

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

In TrueNAS UI: *Credentials → Local Users → root → API Keys → Add*. Copy the token. **TrueNAS shows it exactly once.**

Persist it at `~/.config/saratoga/env` so future shells (and cron) can source it. The file is `chmod 600`, not in git:

```bash
install -d -m 700 ~/.config/saratoga
cat > ~/.config/saratoga/env <<'EOF'
# TrueNAS API access. If lost: regenerate in UI -> Credentials -> Local Users
# -> root -> API Keys. Token shows once.
export TRUENAS_API_TOKEN='1-...'                       # paste the new token here
export SARATOGA_API_URL='https://192.168.0.60/api/v2.0'
EOF
chmod 600 ~/.config/saratoga/env
```

Usage thereafter:
```bash
. ~/.config/saratoga/env
bin/dump-saratoga-config.sh   # snapshot live state into configs/
```

For cron entries that need API access (the scripts fail-fast on missing `TRUENAS_API_TOKEN`):
```
0 4 * * 0  . $HOME/.config/saratoga/env && $HOME/development/server-backups/bin/dump-saratoga-config.sh
```

**Gotcha worth flagging early:** the token only lives in shell environment variables during a session. If you didn't persist it the first time you generated it, the only fix is regenerating a new one in the UI — TrueNAS never re-displays an issued token.

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

### 9b. Cron entries (operator monitoring + tourbillon A2 runtime)

Two crontabs, one per user. Canonical content is checked in under
`configs/cron/` so a kodiak rebuild can install from-file rather than
typing them back from memory.

**Operator (`ldavis`) — saratoga DR freshness monitoring** (one entry, daily):

```bash
crontab configs/cron/ldavis-crontab
crontab -l    # confirm
```

**Service user (`tourbillon`) — A2 sync (repos every 30 min, hosts at 5/35)**:

```bash
sudo crontab -u tourbillon configs/cron/tourbillon-crontab
sudo crontab -u tourbillon -l    # confirm
```

The tourbillon crontab assumes `~tourbillon/.config/tourbillon/env` exists (github + bitbucket tokens — see `doc/CREDENTIALS.md`). The repos sync entry sources it before running; failures land in cron mail via `MAILTO=ldavis`. The hosts sync entry doesn't need the env file (rsync over SSH, no API tokens).

---

## Adding a new replication target

1. Pre-create destination dataset on kodiak: `sudo zfs create -o canmount=noauto backups-00/saratoga/<new>`.
2. In TrueNAS UI, add a Periodic Snapshot Task at the source (recursive, naming schema `auto-%Y-%m-%d_%H-%M`, sensible lifetime). Or do it via API. **Pick a minute that doesn't collide with any ancestor- or descendant-scoped task** (see "Snapshot-task scope/schedule collisions" below).
3. Add the Replication Task — easiest via `bin/apply-<target>-tasks.sh` mirroring `apply-media-tasks.sh`. Same templated settings.
4. Create the first parent-level snapshot via API (the precondition gotcha above).
5. Fire the replication via API or UI Run Now.
6. After it succeeds, run `bin/dump-saratoga-config.sh` to refresh the JSON in this repo.

---

## Snapshot-task scope/schedule collisions

If two Periodic Snapshot Tasks cover overlapping datasets, use the same naming schema (`auto-%Y-%m-%d_%H-%M`), and fire in the same minute, the later one aborts entirely. TrueNAS does not detect this at create time; it shows up in the snapshot task `state` as `ERROR`:

> `cannot create snapshot 'tank/active@auto-<ts>': dataset already exists ... no snapshots were created.`

"No snapshots were created" is literal — the recursive operation rolls back on first conflict, so even non-overlapping datasets in the same task get no snapshot for that slot. If that task is the trigger for a replication task (the common case), the replication also skips that slot.

The collision exists between any pair where one task's recursive scope contains the other's dataset AND their schedules land on the same `HH:MM`. With the `tank` recursive task @ 02:00 and the `tank/active` recursive task at minute 0 of every hour, both fired at 02:00 → `tank/active` won, `tank` aborted.

**Fix:** offset one task's minute (currently: `tank` is at 02:05, the hourly `tank/active` keeps 02:00). Schedules with different `HH` automatically don't collide because the timestamp embeds `HH-MM`.

**When adding any new snapshot task**, before saving:
- List datasets it will recursively touch.
- For each, check whether an existing snapshot task covers it with the same naming schema.
- If yes, pick a minute that doesn't match any of them — even one minute of offset is enough.

---

## Onboarding a new host (A2)

Adds a host to tourbillon's `hosts sync` fleet. Different shape than A1 — rsync-over-SSH pull, not ZFS push.

### Linux — multi-user (per ADR-002, the common case)

Target gets a dedicated `tourbillon` service user; kodiak holds a per-host SSH key.

**Prereqs on the target:**
- OpenSSH server reachable from kodiak.
- Sudo on the target for the bootstrap step.
- Stable LAN address. If DHCP, pin a router reservation — host configs assume the IP doesn't drift.
- Stays awake during the backup window. Desktops: `sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`. Laptops with lids: also `HandleLidSwitch=ignore` in `/etc/systemd/logind.conf`.

**Steps:**

1. **On the target, as root** — copy `bin/bootstrap-tourbillon-user.sh` over and run:
   ```bash
   sudo bash bootstrap-tourbillon-user.sh
   ```
   Creates the `tourbillon` service user, installs the sudoers drop-in for narrow rsync access, prints a one-time password. **Save it — step 2 needs it.**

2. **On kodiak, as ldavis** — push the key, verify auth, lock the password:
   ```bash
   bin/bootstrap-from-kodiak.sh <hostname> [<ip>]
   ```
   Generates the per-host ed25519 key under `~tourbillon/.ssh/`, ssh-copy-ids it (paste step 1's password when prompted), verifies key-only auth, then locks the target's tourbillon password. Pass `<ip>` if `<hostname>` doesn't resolve via DNS — the script appends a line to kodiak's `/etc/hosts`.

3. **Create `configs/hosts/<hostname>.toml`** — most fields inherit from `defaults.toml`:
   ```toml
   host = "<ip-or-hostname>"
   # Override paths / excludes_file / schedule_when_up only when defaults don't fit.
   ```

4. **First sync, forced** to skip the schedule-window check:
   ```bash
   sudo -u tourbillon bin/tourbillon hosts sync --force --name <hostname>
   ```
   Auto-creates `backups-00/hosts/<hostname>` dataset, runs the first rsync, persists state. The every-30-min cron picks it up from then on per `schedule_when_up` (default 24h).

5. **Verify** — `bin/tourbillon hosts status` shows last-success time. `sudo -u tourbillon bin/tourbillon hosts ping <hostname>` retests connectivity.

Both scripts are idempotent — safe to re-run if something failed mid-flow.

### macOS / Windows — single-user (per ADR-003)

No `tourbillon` service user on the target; rsync runs as the operator's existing account. Single command from kodiak:

```bash
bin/bootstrap-from-kodiak-single-user.sh <hostname> <existing-user> [<ip>]
```

Then per-host config sets `ssh_user = "<user>"`, `sudo_required = false`, plus platform-specific overrides:

- **macOS** — `rsync_path = "/opt/homebrew/bin/rsync"` (brew GNU rsync; `/usr/bin/rsync` on macOS is `openrsync`, incompatible with the `--server` protocol). `rsync_archive_flags = "-avHX"` (drop `-A` — macOS NFSv4 ACLs can't round-trip through GNU rsync). `excludes_file = "configs/hosts/excludes/mac-user.txt"`. See `configs/hosts/lynchmbp.toml` for a working reference.
- **Windows** — `rsync_path = "/cygdrive/c/Program Files/cwRsync/bin/rsync"` (cwRsync) or WSL rsync path. Excludes file TBD when the first windows host onboards.

---

## Operational

### Daily

The snapshot tasks fire at 02:00. Each replication task with `auto: true` runs immediately after its snapshot task completes. No active operator role.

### Weekly-ish

```bash
tests/check-saratoga-replication.sh    # "did backup happen?"
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
| **Two snapshot tasks on overlapping scopes at the same minute, same naming schema** | Later task: `cannot create snapshot '<dataset>@auto-<ts>': dataset already exists ... no snapshots were created` — the whole recursive op rolls back, downstream replication misses the slot | See "Snapshot-task scope/schedule collisions" above. Offset minute by 1+ on one of the tasks. |

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

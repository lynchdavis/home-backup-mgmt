# ADR-002: Linux host backups (A2 starting slice)

**Status:** Proposed, 2026-05-26.
**First target:** `arrow-iii` (192.168.1.65) — a minimal-use linux host, light enough to be a real but low-stakes proving ground.
**Builds on:** ADR-001 (repo mirror) — same single-file `bin/tourbillon` extension, same `~/.config/{saratoga,tourbillon}/env` pattern, same `backups-00/` ZFS pool.

---

## Context

Backup the operator's linux hosts (today: `arrow-iii`; soon: an unnamed currently-off-desk machine + `192.168.1.59`; eventually macs + a Windows box treated as Unix-shaped). The repos subsystem from ADR-001 protects code state. This subsystem protects everything else that lives on a workstation that isn't recoverable from a package manager.

A constraint surfaced by the operator that fundamentally shapes the design:

> **Linux is more user-based than host-based.** Rebuilding a linux box from a fresh install + package reinstall is straightforward; the irreplaceable bytes are in user homes (and a small handful of system files like `/etc` for the configuration drift that's actually been done by hand). Most installed software is open-source or distro-packaged and need not be in the backup.

This reframes scope: we are NOT making a full-disk image backup. We are capturing **the data that wouldn't come back from a `pacman -S` / `apt install`**. Smaller, faster, simpler.

---

## Decision

### What gets backed up

A per-host **`paths` array** lists exactly the directories rsync will mirror. Anything not in `paths` is not in the backup. No implicit defaults beyond what `defaults.toml` provides.

**`configs/hosts/defaults.toml`** sets the system-wide default:

```toml
paths = ["/home"]   # all user homes on the host
```

A per-host file can extend, narrow, or replace it:

```toml
# configs/hosts/arrow-iii.toml — minimal-use host with /etc drift worth keeping
paths = ["/home", "/etc"]

# configs/hosts/multi-user-box.toml — only specific users
paths = ["/home/lynch", "/home/aikiav8r"]
```

This is "feature creep" in the [[personal-systems-scope]] sense only if we never actually use it. The operator confirmed they want at least one host (`arrow-iii`) with `/etc` included, and the array is the simplest schema that accommodates "all users", "some users", and "extra dirs" without inventing flags.

**What's explicitly NOT backed up unless added to a host's `paths`**:

- `/var`, `/usr`, `/opt`, `/srv`, `/tmp`, `/proc`, `/sys`, `/dev` — system-managed, regenerable, or transient.
- `/root` — opt-in via `paths` if a host has hand-curated state there.

This isn't a paranoid full-system backup. It's "what would you cry over if the machine dropped off a desk."

### Excludes within `/home/*`

Heavy excludes via a shared `configs/hosts/excludes/linux-user.txt`, applied via rsync `--exclude-from=`. Inherits the structure of `data-organizer/excludes/lynchmbp.txt` (the mac one used during the migration), with linux-specifics added:

- **Language-toolchain caches**: `node_modules/`, `.cargo/registry/`, `.rustup/`, `target/` (Rust build), `__pycache__/`, `.venv/`, `venv/`, `.npm/_cacache/`, `.gradle/`, `.m2/repository/`, `pkg/mod/cache/` (Go), `.cache/uv/`, `.cache/pip/`.
- **Browser data**: `.cache/google-chrome/`, `.cache/mozilla/`, `.cache/chromium/`, `.config/google-chrome/Cache*/`, `.mozilla/firefox/*/Cache*/`.
- **Editor / IDE caches**: `.vscode/extensions/`, `.idea/`, `.cache/JetBrains/`, `*.swp`, `*.swo`.
- **VM / container disks**: `*.vdi`, `*.vmdk`, `*.qcow2`, `.docker/`, `containers/storage/`, `.local/share/containers/`.
- **Misc cache**: `.cache/`, `.local/share/Trash/files/` (the Trash itself — see [[safety-nets-for-scratch]] — INCLUDED with shorter snapshot retention rather than excluded), `.thumbnails/`.
- **OS metadata that occasionally rides linux dirs**: `.DS_Store`, `Thumbs.db`.

A per-host extras file (`configs/hosts/excludes/<hostname>-extras.txt`) can add or override.

**Trash** decision: include, per the existing [[safety-nets-for-scratch]] working note. Trash on linux is at `~/.local/share/Trash/`. Counterintuitive but consistent: short retention covers the "wait, I shouldn't have deleted that" case for ~14 days, then prunes naturally.

### Storage layout on kodiak

```
backups-00/hosts/                                ZFS dataset, recordsize=128K
                                                 (many small files, like repos)
backups-00/hosts/<hostname>/                    one child dataset per host
                                                 (so per-host snapshot retention)
backups-00/hosts/<hostname>/home/<user>/...     mirrored content
backups-00/hosts/<hostname>/etc/...             optional, when /etc backup is on
backups-00/hosts/<hostname>/root/...            optional, when /root backup is on
```

One ZFS *dataset* per host (not just a directory) so each host gets its own snapshot timeline, independent retention, independent scrub view.

### Auth

**Dedicated `backup` user on each linux host.** Not the operator's regular user.

- On each target host: `useradd -m -d /var/lib/backup -s /bin/bash backup`.
- SSH key pair on kodiak: `~/.ssh/id_ed25519_backup` (no passphrase, ed25519). Generated once on kodiak; the public half goes into each host's `~backup/.ssh/authorized_keys` with `command="rsync --server …" restrict`.
- Sudo on target hosts: narrow drop-in at `/etc/sudoers.d/backup`:
  ```
  backup ALL=(root) NOPASSWD: /usr/bin/rsync --server *, /usr/bin/rsync --server *
  ```
  Wildcards on the arguments are necessary because rsync server invocation embeds the source path. Restrict to `--server` mode only so the key can't be repurposed.
- Why dedicated user (not ldavis-with-his-own-key): compartmentalization. The backup pathway should not have the same blast radius as the operator's interactive shell access.

### Transport

`rsync -avHAX --delete --numeric-ids --partial --exclude-from=<excludes>` over SSH, kodiak pulling from the target.

Flags rationale:
- `-a` — preserve everything reasonable.
- `-H` — preserve hardlinks (matters for some browser stores and a few backup-of-backup scenarios).
- `-A -X` — POSIX ACLs and xattrs (mostly a no-op on most linux dirs but worth it where it matters; cheap).
- `--delete` — keep the mirror clean; files removed on source are removed in the mirror's *current* state. Snapshots preserve the deleted-files state for history.
- `--numeric-ids` — store uid/gid as numbers, don't try to map names. Cleaner across hosts.
- `--partial` — resume-friendly for big transfers or flaky links.

### Intermittent reachability

Most linux hosts are not always on (laptops, often-off desktops). The orchestrator handles this without erroring out:

1. **SSH probe before each sync**: `ssh -o BatchMode=yes -o ConnectTimeout=5 backup@<host> true`.
2. **If probe fails**: log `unreachable` in the host's state file, skip cleanly, no error.
3. **If probe succeeds**: do the rsync. Record success/failure normally.

State file per host tracks `last_attempt_at`, `last_reachable_at`, `last_success_at`, `last_unreachable_at`, `last_error`. The `last_reachable_at`/`last_unreachable_at` split is what lets `tourbillon hosts status` show "host is currently offline" vs "host is online but backup failed."

### Cadence

Per-host TOML field `schedule_when_up`. **Default `24h`** — opportunistic daily; "try once per day, never fail if the host isn't up." Per-host override for hosts where more frequent makes sense (heavy-development laptops, etc.):

```toml
# configs/hosts/<some-active-machine>.toml
schedule_when_up = "1h"
```

Cron fires every 30 min as the *outer* scheduler (matching the repo-sync cadence); each invocation walks all hosts and acts only on the ones whose interval has elapsed since their last success.

### Snapshots on kodiak side

Sanoid policy on `backups-00/hosts/*` (recursive): daily snapshots, 30-day retention. Same template as `backups-00/repos`. One configuration addition in `configs/sanoid/sanoid.conf`.

### Tourbillon CLI surface

```
tourbillon hosts                                 # show table (alias for status)
tourbillon hosts status [--name HOST]            # per-host last-run state, reachability, ages
tourbillon hosts issues                          # filtered: unreachable >7d, failed, stale
tourbillon hosts sync [--name HOST] [--force]    # try to sync any due, reachable hosts
                                                 # (cron-friendly; silent on nothing-due-or-down)
tourbillon hosts ping <host>                     # one-off reachability test, exit 0/1
tourbillon hosts show <host>                     # detail for one host (sizes, paths, last activity)
```

`tourbillon status` (the top-level rollup from D) gains a Hosts section: total hosts, currently reachable, last successful sync ages.

### Cron

```
*/30 * * * *  . $HOME/.config/tourbillon/env && \
              $HOME/development/server-backups/bin/tourbillon hosts sync --quiet
```

Same half-hour cadence as the repo sync, same ldavis crontab, same `--quiet` cron-friendly silence-on-no-work behavior.

---

## Consequences

### Good

- **Scope is small and intentional.** /home is what matters. Excluded everything that comes back from a package manager.
- **Per-host ZFS dataset** = per-host snapshot retention, per-host capacity reporting, per-host scrub visibility. Each host stands alone.
- **Intermittent reachability is a first-class case**, not a failure. A laptop that's online 2 hours a day gets backed up during those 2 hours and the rest of the time the system is correctly silent about it.
- **rsync over SSH is the boring obvious choice.** No new transport to learn; works the same shape that we'll later use for Mac and Windows-via-OpenSSH-Server.
- **Dedicated `backup` user with narrow sudo** = backup pathway compromise has bounded blast radius.

### Cost

- **Per-host setup is hand work**: create `backup` user, drop pubkey, add sudoers entry. Worth automating eventually as `bin/bootstrap-backup-user.sh <host>`, but doing the first host (arrow-iii) by hand is reasonable.
- **rsync metadata-walk cost**: each run walks the source tree. For a quiet laptop with mostly-unchanged /home, this is minutes of stat() over potentially 100k+ files. Acceptable. ZFS-send-style block-level efficiency isn't available because the source isn't ZFS.
- **rsync over SSH on the LAN, not 10 GbE**: kodiak<->saratoga is on the private 10 GbE link; client hosts are on 192.168.1.x regular LAN. Throughput ceiling is ~110 MB/s gigabit. Fine for /home-only backups (usually small).
- **No deduplication across hosts.** If `ldavis@arrow-iii` and `ldavis@laptop` have the same files, they're stored twice. Acceptable; lz4 helps; cheap disks help more.

### Neutral but worth naming

- **No system-image backup.** Per the operator's framing — rebuilding linux from fresh install is the recovery path, not bare-metal restore.
- **No restore tooling beyond rsync-reverse.** Recovery procedure: `rsync -avHAX backup@kodiak:/path/to/mirror/ /target/`. Documented in a future `LINUX_RESTORE.md` companion to `SARATOGA_RESTORE.md`.

---

## Alternatives considered

1. **Push from each host to kodiak** (host runs cron, pushes to kodiak). Rejected: requires kodiak to accept inbound rsync from every host (more open surface); host running the backup is the host most likely to be in trouble; ownership of "did it happen" is again on the wrong side.
2. **Full system image** (rsync `/` with broad excludes; or `dd`/`partclone`). Rejected per the operator's framing: most of `/` is recoverable from packages and would just be noise in the backup.
3. **borg/restic-style deduped backups**. Rejected: another transport to learn, another credential model. ZFS snapshots give us the time-travel layer; rsync is the boring well-understood transfer. If dedup becomes important later, swap rsync for restic at that one layer.
4. **Same backup user as repos (`tnreplicate` from ADR-001)**. Rejected: those are *receiving* on kodiak; this `backup` user is *sending* on each remote host. Different roles, different blast radii, kept distinct.
5. **One ZFS dataset for all hosts** (under `backups-00/hosts`, no per-host child). Rejected: loses per-host snapshot retention granularity. Per-host dataset is one `zfs create` per onboarding — cheap.

---

## Decisions resolved during initial review (2026-05-26)

1. **Per-host SSH user**: dedicated **`backup`** user on every target. Consistent across hosts (same key everywhere), easier to rotate when needed. Matches the cleanliness of the kodiak-side `tnreplicate` pattern.
2. **`/etc` backup**: **opt-in** per host (off by default). Conservative: avoids accidental "/etc on a host where I haven't audited what's in it" surprises during initial setup.
3. **Trash inclusion**: **include** `~/.local/share/Trash/` with 14-day snapshot retention on the kodiak side. Same reasoning as [[safety-nets-for-scratch]] — labels say "disposable" but content sometimes isn't.
4. **`arrow-iii` first-host coverage**: `paths = ["/home", "/etc"]`. Used as the concrete test case for the `paths`-array schema and verifies the `/etc` opt-in path works.
5. **Default cadence**: **`schedule_when_up = "24h"`** (daily). Per-host override available — set `1h` or `4h` on hosts that warrant tighter cadence. `arrow-iii` keeps the daily default.

## Future questions

(None pinned today.)

---

## Implementation plan (once this ADR is accepted)

Per the same incremental approach we used for repos:

1. **`configs/hosts/defaults.toml`** + **`configs/hosts/excludes/linux-user.txt`** committed.
2. **`bin/bootstrap-backup-user.sh`** — one-shot script to run on a new target host (creates user, installs pubkey, drops sudoers entry). Not a tourbillon subcommand because it runs on the *target*, not on kodiak.
3. **`bin/tourbillon hosts {ping,status,issues,sync}`** stubs → working in stages, mirroring the repos rollout.
4. **First host: `arrow-iii`**. Hand-bootstrap the backup user; create `configs/hosts/arrow-iii.toml`; pre-create `backups-00/hosts/arrow-iii` ZFS dataset; run `tourbillon hosts sync --name arrow-iii --force` to seed; eyeball.
5. **Add sanoid stanza** for `backups-00/hosts/*` after first-seed lands.
6. **Wire cron** for hourly sync once first host is steady-state.
7. **Document restore path** in `LINUX_RESTORE.md`.

Each step is a commit, in order. Same shape as the repos rollout.

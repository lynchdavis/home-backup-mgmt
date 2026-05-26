# Changelog

Pragmatic record of functional changes to this backup system. Conceptual
material (name origins, design rationale) lives in `doc/`. Operational
how-to lives in `PLAYBOOK.md`.

Most-recent first.

## 2026-05-26

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

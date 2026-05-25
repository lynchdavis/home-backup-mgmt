# Changelog

Pragmatic record of functional changes to this backup system. Conceptual
material (name origins, design rationale) lives in `doc/`. Operational
how-to lives in `PLAYBOOK.md`.

Most-recent first.

## 2026-05-25

### Added
- `bin/restructure-snapshot-naming.sh` — idempotent API-driven fix for the snapshot-task naming collision. Renames parent-scope task schemas to distinct values (`auto-tank-*`, `auto-media-*`).
- `~/.config/saratoga/env` — persisted location for `TRUENAS_API_TOKEN` (mode 600, kodiak-local, not git-tracked) so future shells and cron find the API token.
- `doc/` directory — name origins and explanations. `doc/NAMING.md` covers tourbillon, backups-00, tnreplicate.
- Tourbillon chosen as the name for the future operator CLI (rationale in `doc/NAMING.md`).

### Changed
- Snapshot task 6 (`tank` recursive): `naming_schema` from `auto-%Y-%m-%d_%H-%M` to `auto-tank-%Y-%m-%d_%H-%M`; `schedule.minute` returned to `0` (the 02:05 offset workaround dropped).
- Snapshot task 7 (`media` recursive): `naming_schema` to `auto-media-%Y-%m-%d_%H-%M`.
- Replication tasks 1 and 2: `also_include_naming_schema` adds the legacy `auto-%Y-%m-%d_%H-%M` for the 2-week transition.

### Documented
- Step 6 of PLAYBOOK setup section now specifies `~/.config/saratoga/env` as the canonical token storage location.
- (Parallel-session commit `f98328c`) Snapshot-task scope/schedule collision gotcha — wired into Final-Shape, Adding-a-new-target step 2, and the dead-ends table.

### Operational reminders
- **2026-06-08**: drop `also_include_naming_schema` entries from replication tasks 1 and 2 once the old `auto-%Y-%m-%d_%H-%M` snapshots have aged out via 2-week retention. The calendar entry exists for a reason; future-us is encouraged to use it.

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

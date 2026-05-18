# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Greenfield directory. No code yet. Goal is a `backup-server <server-name>` script that pulls a remote NAS's NFS-exported shares onto this host (kodiak) for safekeeping ahead of a FreeNAS→TrueNAS migration of the primary NAS.

## Locked design decisions

- **Language:** Python 3, stdlib only (`tomllib`, `subprocess`, `json`, `argparse`, `pathlib`, `socket`). No pip dependencies.
- **Venv layout:** dev venv at `./.venv/` for tooling; deploy venv at `/kodiak00/opt/backup-server/venv/` with a pinned interpreter so a host Python upgrade can't silently break scheduled runs. `/kodiak00/bin/backup-server` is a thin wrapper that execs the deployed venv's python against the installed script.
- **Task runner:** [go-task](https://taskfile.dev) via `Taskfile.yml`. Do **not** add a `Makefile` or ad-hoc shell scripts for build/install/test/deploy — those go as `task` targets (e.g. `task install`, `task deploy`, `task test`).
- **Per-server config:** `/kodiak00/etc/servers/<host>.toml` — optional. Tool also works from autofs-only or live-probe discovery.
- **Master index:** per-host JSON files at `/kodiak00/data-00/backups/index/<host>.json`. One file per host = atomic updates without locking.
- **Backup data target:** `/kodiak00/data-00/backups/host-backups/<host>/<share>/`.
- **Default mode:** preflight only. `--execute` actually runs rsync.
- **SMB:** v1 detects SMB shares in the preflight report but does not back them up. SMB backup is phase 2 (see `TODO.md`).

## Discovery layering

The tool tries these in order when figuring out what to back up for `<host>`:

1. **Config file** at `/kodiak00/etc/servers/<host>.toml` — authoritative if present.
2. **Autofs maps** — grep `/etc/auto.master.d/*.{nfs,autofs}` for entries pointing at the host (by name or IP). Build mount list from what's already configured locally.
3. **Live probe** — `showmount -e <host>` for NFS exports, `smbclient -L //<host> -N -g` for SMB shares (detection only in v1).

After successful discovery from tier 2 or 3, offer to write a tier-1 config file so next time is deterministic.

## Preflight stages

All run, all report PASS / FAIL / WARN:

1. Resolve & reach (private 10 GbE first, LAN fallback with WARN).
2. Discover mounts via the layering above.
3. Trigger and verify each auto-mount with `stat` + `mountpoint -q`.
4. Consult master index, report last backup state for the host.
5. Space estimate via `rsync -an --stats` per mount, summed and compared to `df` on the target.

## Execute stage

For each mount that cleared preflight:
```
rsync -rlptDv --stats --log-file=<date>.log \
  /saratoga-01/<share>/ \
  /kodiak00/data-00/backups/host-backups/<hostname>/<share>/
```
Same flag profile as the legacy `/kodiak00/bin/rsync-saratoga.sh`. On completion, append a record to the host's index with date, duration, bytes, per-share status, and log path.

## Host topology

This host is **kodiak** (LAN `192.168.1.61`, private 10 GbE `192.168.0.61`). It has two large ext4 data volumes used as scratch/staging:

- `/kodiak00/data-00` — general data; backups land under `/kodiak00/data-00/backups`
- `/kodiak00/media-00` — media (e.g. `music_flac`)

The remote NAS is **saratoga** (LAN `192.168.1.60`, private 10 GbE `192.168.0.60`, FreeNAS / ZFS). Backups should traverse the `192.168.0.x` private link, not `192.168.1.x`.

## Saratoga shares (autofs)

Saratoga's NFS exports are auto-mounted on kodiak at `/saratoga-01/<share>` per `/etc/auto.master.d/saratoga-01.nfs`. Accessing a path under `/saratoga-01/` triggers the mount (180 s idle timeout). Available shares include `applications`, `archives`, `backups`, `music`, `music_flac`, `open_audible`, `photography`, `videos`, `source_repos`, plus `MusicShare` and the `PhotoArchive_*` series on `saratoga-02`. All exports point at `192.168.0.60:/mnt/saratoga-0{1,2}/...`.

Treat `/saratoga-01/<share>` as the canonical read path for backing **up** saratoga onto kodiak.

## Existing rsync pattern (reference, opposite direction)

`/kodiak00/bin/rsync-saratoga.sh` already pushes kodiak→saratoga (photos, music_flac, etc.) using `rsync -rlptDv --stats --log-file=YYYY-MM-DD.log`. Logs accumulate alongside the script in `/kodiak00/bin/`. The new pull-direction tool here is the inverse — same rsync flag profile is a reasonable starting point.

## Backup index location

`/kodiak00/data-00/backups/` is the intended root for the new tool's master index (host → mounts → last-backup-date). Existing layout there: dated `.log` files from the legacy script, plus a `host-backups/` subtree of per-host snapshots (e.g. `dev-01-cyfir`, `2024-02-07-LynchMBP`).

## Design notes for `backup-server`

Per the user's spec, the dry-run / plan phase must validate independently of executing the backup:
1. Remote host resolves and is reachable (prefer the `192.168.0.x` private interface).
2. Expected NFS shares are reachable / auto-mountable.
3. Local autofs map entries exist for those shares.
4. Whether this host has been backed up before (consult the master index).
5. Sufficient free space on `/kodiak00/data-00` (or the chosen target volume).

Mount selection is deferred — see `TODO.md`.

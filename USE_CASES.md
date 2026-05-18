# Use cases

A scannable map of what `backup-server` is for. Use cases marked **v1** are what the current build targets; everything else is parked in `TODO.md` for a later phase.

## v1 — saratoga preflight & pull

**1. Pre-migration safety net for the FreeNAS→TrueNAS move on saratoga.** [v1]
Pull every NFS-exported share from saratoga onto kodiak so the migration has a known-good off-box copy. Backups land under `/kodiak00/data-00/backups/host-backups/saratoga/<share>/`.

**2. Preflight without execute, as the default.** [v1]
`backup-server saratoga` runs all five preflight stages (resolve & reach, discover, trigger mounts, index lookup, space estimate) and reports PASS/WARN/FAIL per stage — without writing anything. `--execute` is required to actually run rsync. Lets you sanity-check before committing the disk and the wall-clock.

**3. Per-host history.** [v1]
Each run appends a record to `/kodiak00/data-00/backups/index/<host>.json` — date, duration, bytes, per-share status, log path. Future runs consult it during preflight (stage 4) to report when the host was last backed up.

**4. Three-tier discovery: config → autofs → live probe.** [v1, with caveat]
Optional `/kodiak00/etc/servers/<host>.toml` is authoritative if present; otherwise scan autofs maps; otherwise `showmount -e` against the host. **Caveat:** autofs tier is implemented but currently bypassed — saratoga's FreeNAS NFS exports ESTALE on the access pattern autofs triggers, so v1 mounts directly. Restoring the autofs tier is parked as a phase-2 item.

**5. SMB share *detection* (not backup).** [v1]
`smbclient -L` runs as part of probe discovery and reports SMB shares in the preflight output. v1 does not back them up — they exist in the report so you know what's there. SMB backup is phase 2.

## Phase 2 — likely soon

**6. SMB share backup.** [TODO — phase 2]
Mount via `cifs-utils`, credentials file, ACL-aware rsync flags.

**7. rsync-over-SSH for hosts without NFS/SMB.** [TODO — phase 2]
Back up arbitrary remote paths — a user's home directory, `/etc`, `/var/log` — on a host that doesn't export shares. `backup-server <host> --ssh user@host:/path`. Per-server TOML grows an `[ssh]` section. **Gated on default excludes** (see below) — home dirs must not be pulled raw.

**8. Default exclude patterns shipped with the tool.** [TODO — phase 2]
A `defaults/excludes.txt` applied via rsync `--exclude-from=`, so caches, language toolchains, browser data, IDE state, and OS metadata never enter the backup. Inventory ported from the existing `clean-home.sh` at `/kodiak00/data-00/backups/host-backups/dev-01-cyfir/clean-home.sh`. Most relevant for the SSH-mode case above.

**9. Per-server exclusion patterns.** [TODO — phase 2]
Top-level `exclude = [...]` in `<host>.toml` to extend or override the defaults for a specific host.

**10. Selective mount backup.** [TODO — phase 2]
`backup-server saratoga --mounts=photography,videos` to limit a run; also `--exclude=open_audible`.

**11. Restoring autofs-map discovery (tier 2).** [TODO — phase 2/3]
Wire `discovery.from_autofs` back into `discover()` once the FreeNAS ESTALE quirk is understood (or once saratoga is on TrueNAS and the issue goes away).

## Operational — when v1 stabilizes

**12. Scheduled runs.** [TODO — operational]
systemd timer or cron wrapper. `backup-server <host> --execute --quiet` invoked weekly.

**13. Completion / failure notifications.** [TODO — operational]
Email or Slack hook after the rsync stage.

**14. Resume interrupted runs.** [TODO — operational]
Detect a half-finished backup in the index and re-run only the failed shares.

**15. Bandwidth limiting.** [TODO — operational]
`--bwlimit` passthrough so a scheduled run can't saturate the 10 GbE during work hours.

**16. Multi-server invocation.** [TODO — operational]
`backup-server all` or `backup-server group:nas` to sweep every known host in sequence.

## Data lifecycle — when there's enough history to matter

**17. Rotation / pruning.** [TODO — data]
Age out old per-host backups. Probably "keep last N successful runs."

**18. Hard-link snapshots (Time Machine style).** [TODO — data]
`rsync --link-dest=<prev>` for space-efficient incremental snapshots.

**19. Post-backup verification.** [TODO — data]
Checksum sample against the source. Optional, slow.

**20. Encryption at rest.** [TODO — data]
For any share with sensitive content. Out of scope unless something specific motivates it.

## Restore / inverse

**21. Restore helper.** [TODO — restore]
`backup-server restore <host> <share> [--to <path>]` — inverse rsync with safety prompts.

**22. Dry-run diff.** [TODO — restore]
Show what a backup would change (file count, byte delta) without writing the index.

## Reporting

**23. `backup-server status`.** [TODO — reporting]
Print last-backup dates, sizes, overdue hosts from the index.

**24. `backup-server history <host>`.** [TODO — reporting]
Render per-host JSON as a readable timeline.

## Integration

**25. iDrive cloud handoff.** [TODO — integration]
Today saratoga is mounted for iDrive backup. Once saratoga→kodiak is reliable, decide whether iDrive should source from kodiak's copy instead.

## Peripheral (not a `backup-server` feature)

**26. Disk reclaim on existing backups.** [TODO — peripheral]
`clean-home.sh` already exists at `/kodiak00/data-00/backups/host-backups/dev-01-cyfir/clean-home.sh` and reclaims ~tens of GB per legacy snapshot (LynchMBP: ~57 GB). Run with `--target=<host-backups-subdir>` periodically. General disk hygiene, not a `backup-server` feature.

**27. Orphan `host-backups/` audit.** [TODO — peripheral]
`host-backups/` contains entries from one-off pushes the new tool won't refresh (`2024-02-07-LynchMBP` already removed; `dev-01-cyfir` remains). Decide per-dir: keep, remove, or promote to a proper `<host>/` layout the new tool can manage.

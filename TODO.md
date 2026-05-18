# TODO

Future features for `backup-server`. Not commitments — a parking lot.

## Phase 2 (likely)

- [ ] **SMB backup support.** v1 detects SMB shares and reports them; v2 actually mounts and backs them up. Needs `cifs-utils`, credentials file, mount lifecycle, ACL-aware rsync flags.
- [ ] **Autofs-map discovery (tier 2).** Originally planned for v1 but deferred — the user's existing autofs setup against FreeNAS causes spurious ESTALE errors when rsync walks the source. Could be revived once we understand the FreeNAS NFS export quirk, or once we're on TrueNAS. For now `backup-server` mounts directly via NFS instead of relying on `/saratoga-01/<share>`. Implementation is already in `discovery.from_autofs` but not wired into `discover()`.
- [ ] **rsync-over-SSH transport.** Back up arbitrary remote paths (a user's home directory, `/etc`, `/var/log`, etc.) on a host that doesn't export NFS/SMB. New tier in discovery or a dedicated mode: `backup-server <host> --ssh user@host:/path [user@host:/path ...]`. Per-server TOML grows an `[ssh]` section with `user`, `paths = [...]`, optional `identity_file`. Skips the mount-trigger preflight stage; still runs reach + index + space estimate. Auth via SSH key only. **Must ship with default excludes from day one** — when the source path is a user home (the typical SSH-mode case), the path inventory in `/kodiak00/data-00/backups/host-backups/dev-01-cyfir/clean-home.sh` is exactly the set of paths that should never end up in a backup in the first place. Wire `--exclude-from=` to those defaults before turning this mode on; do not ship a v0 that pulls home dirs without filtering.
- [ ] **Selective mount backup.** `backup-server saratoga --mounts=photography,videos` to limit a run. Also `--exclude=open_audible`.
- [ ] **Per-server exclusion patterns.** Top-level `exclude = ["*.tmp", ".DS_Store"]` in the server's TOML config, passed through to rsync as `--exclude`.
- [ ] **Default exclude patterns (ship with tool).** Backups should skip regenerable cruft by default. Ship a `defaults/excludes.txt` in the package, applied via `--exclude-from=`. Per-server TOML can extend or override. Most relevant for the SSH-over-rsync mode (above) since NFS share backups tend not to contain home-dir cruft, but the same list applies anywhere we pull a path that might. **Starting point:** port the path inventory from `/kodiak00/data-00/backups/host-backups/dev-01-cyfir/clean-home.sh` — same categories, just transposed from "delete after" to "exclude during rsync" (e.g. its `scrub "~/.cache (all)"` becomes `--exclude=.cache/`, `find ... -name node_modules` becomes `--exclude=node_modules/`). Categories:
  - **Language toolchains:** `__pycache__/`, `*.pyc`, `*.pyo`, `.venv/`, `venv/`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, `*.egg-info/`, `node_modules/`, `.npm/_cacache/`, `.yarn/cache/`, `.cargo/registry/cache/`, `.cargo/registry/src/`, `target/` (Rust), `pkg/mod/cache/` (Go), `.gradle/`, `.m2/repository/`.
  - **Editor / IDE caches:** `.vscode/extensions/`, `.idea/caches/`, `.idea/shelf/`, `*.swp`, `*.swo`.
  - **Browser caches:** `Library/Caches/`, `*/Cache/`, `*/CachedData/`, `*/Code Cache/`, `*/GPUCache/`, `Library/Application Support/*/Cache*/`, `AppData/Local/*/Cache/`.
  - **OS metadata:** `.DS_Store`, `._.*` (macOS resource forks), `.Spotlight-V100/`, `.fseventsd/`, `.TemporaryItems/`, `.Trash/`, `.Trashes/`, `Thumbs.db`, `desktop.ini`.
  - **Build artifacts:** `dist/`, `build/`, `out/`, `.next/`, `.nuxt/`, `.turbo/`, `*.dSYM/`.
  Concretely worth doing soon: the running push is transferring 3 months of `.vscode/extensions/ms-python.../typeshed/*.pyi` and `.npm/_cacache/` — pure noise we shouldn't be hauling across NFS.

## Operational

- [ ] **Scheduling.** systemd timer or cron wrapper. Probably `backup-server <host> --execute --quiet` invoked weekly.
- [ ] **Notifications.** Email or Slack on completion/failure. Hook point after the rsync stage.
- [ ] **Resume interrupted runs.** Detect a half-finished backup in the index and re-run only the failed shares.
- [ ] **Bandwidth limiting.** `--bwlimit` passthrough for runs that shouldn't saturate the 10 GbE.
- [ ] **Multi-server invocation.** `backup-server all` or `backup-server group:nas` to run every known host in sequence.

## Data management

- [ ] **Rotation / pruning.** Policy for aging out old per-host backups. Probably keep last N successful runs.
- [ ] **Hard-link snapshots.** `rsync --link-dest=<prev>` for space-efficient incremental snapshots (Time Machine style).
- [ ] **Verification pass.** Post-backup checksum sample against the source. Optional, slow.
- [ ] **Encryption at rest.** For shares with anything sensitive. Probably out of scope unless something specific motivates it.

## Restore / inverse

- [ ] **Restore helper.** `backup-server restore <host> <share> [--to <path>]` — the inverse rsync, with safety prompts.
- [ ] **Dry-run diff.** Show what a backup would change (file count, byte delta) without writing the index.

## Reporting

- [ ] **`backup-server status`.** Read the index, print last-backup dates, sizes, and overdue hosts.
- [ ] **`backup-server history <host>`.** Render the per-host JSON as a readable timeline.

## Integration

- [ ] **iDrive cloud handoff.** Today saratoga is mounted for iDrive backup. Once saratoga→kodiak backups exist, decide whether iDrive should source from kodiak's copy instead.

## Peripheral cleanup (not script work)

- [ ] **Audit orphan `host-backups/` subdirs.** `/kodiak00/data-00/backups/host-backups/` accumulated entries from one-off pushes (e.g. `2024-02-07-LynchMBP`, `dev-01-cyfir`) that the new tool will not refresh. Decide per-dir: still wanted (keep), stale (remove), or promote to a proper `<host>/` layout the new tool can manage. Same audit applies to the saratoga side of any kodiak→saratoga snapshots.
- [ ] **Disk reclaim across existing backups.** `clean-home.sh` at `/kodiak00/data-00/backups/host-backups/dev-01-cyfir/clean-home.sh` is reusable as a disk-management tool against any backup we already have on this host. The LynchMBP cleanup demonstrated the impact: ~57 GB recovered from a single legacy snapshot. Run it (with `--target=` pointed at each `host-backups/<host>/` subtree) periodically, or as a one-shot before adopting any forward-going exclude policy. Independent of the `backup-server` tool — this is general disk hygiene, not a feature.

# server-backups

Backup-system playbook and configuration for the saratoga (TrueNAS NAS) → kodiak (Debian + ZFS) backup setup.

**This is not a generic tool.** It is a targeted playbook for one specific home infrastructure: a single TrueNAS source, a single Debian backup host, a small known fleet of client machines. Configuration-as-code via TrueNAS API; UI is the operational view.

## Files

- **[PLAYBOOK.md](PLAYBOOK.md)** — the operational playbook: what runs where, how to recreate from scratch, what to do when things change, gotchas captured the hard way.
- **[SARATOGA_RESTORE.md](SARATOGA_RESTORE.md)** — restore scenarios (single-file → full DR), in priority order.
- **[HOSTS_RESTORE.md](HOSTS_RESTORE.md)** — restore scenarios for the host-backup mirrors (multi-user linux + single-user Mac/Windows).
- **[CHANGELOG.md](CHANGELOG.md)** — pragmatic record of functional changes (what shipped, when, what to remove later).
- `configs/` — JSON dumps of the live TrueNAS replication / snapshot / SSH configuration. Refresh with `bin/dump-saratoga-config.sh`.
- `configs/templates/` — JSON templates used to create new tasks via API.
- `bin/` — small scripts for setup, monitoring, and config dumping. No framework; each script does one thing.
- `doc/` — ADRs and explanations (e.g., `doc/NAMING.md` — name origins; `doc/CREDENTIALS.md` — credentials inventory + rotation paths; `doc/ADR-001-repo-mirror.md` — repo-mirror design).

## Status

- **A1 — saratoga → kodiak DR backup**: operational. Daily replication via TrueNAS Replication Tasks (push), receiving on `backups-00/saratoga` ZFS pool on kodiak.
- **A2 — client-host backups**: not yet built. Different problem (rsync-over-SSH from heterogeneous OSes); separate playbook when it lands.

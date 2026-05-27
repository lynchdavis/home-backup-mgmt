# tests/

Verification scripts that check the **backup system is healthy**, separate from `bin/` (the operator-facing CLI / setup / teardown / apply scripts).

## What lives here

| Script | Cadence | What it verifies | Exit-code contract |
|---|---|---|---|
| [`check-saratoga-replication.sh`](check-saratoga-replication.sh) | Daily 08:00 via cron | A saratoga snapshot has landed on kodiak in the last 26h | 0 = fresh; 1 = stale; 2 = pool/zfs error |
| [`restore-drill.sh`](restore-drill.sh) | Monthly per host via cron | Host mirror == live source == reverse-rsync'd file, by sha256 | 0 = three-way match; 1 = mismatch or transport failure |
| [`test-restore-drill.sh`](test-restore-drill.sh) | Manual, on-demand | Self-test of `restore-drill.sh` — runs the drill in four shapes (happy verbose, happy silent, bad host, symlink refused) and confirms each behaves correctly | 0 = all cases pass; 1 = any case failed |

## How they fit in

- **`bin/`** is for things the operator (or a setup process) runs to *do* something: invoke the CLI, bootstrap a host, apply a TrueNAS config.
- **`tests/`** is for things that run on a schedule (or by hand before relying on the system) to *verify* something. Silent on success, alarms on failure. Cron-friendly.

Add more here as the system grows. From `doc/GAPS.md`, candidates: capacity-trending alarm, stale-mirror detection (repos that disappeared from github), cron-mail-delivery verification.

## Conventions

- **Silent on success** (cron-friendly — output = something for the operator to read = a failure or anomaly).
- **`--verbose` flag** for ad-hoc forensics.
- **Exit 0 on healthy, non-zero on any anomaly.**
- **`set -uo pipefail`** (not `-e`) so we collect failure context for the user before exiting.
- **No side effects on the system** — these checks are passive (where possible). `restore-drill.sh` does write a temp file on the target then deletes it; that's the closest to a side effect, and it's by design.

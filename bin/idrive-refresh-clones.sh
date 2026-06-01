#!/usr/bin/env bash
# idrive-refresh-clones.sh — refresh the ZFS clones iDrive scans.
#
# Why this exists (per ADR-005 + 2026-05-31 A1 incident):
#
# Saratoga DR datasets on kodiak (backups-00/saratoga/...) MUST stay
# unmounted, because TrueNAS push replication invokes `zfs recv -F` as
# the non-root `tnreplicate` user, and recv-F can't unmount mounted
# destinations on Linux. iDrive's client scans files via the
# filesystem, not via zfs send.
#
# Solution: clone the most-recent autosnap of each saratoga child
# dataset we want backed up off-site; mount the clone at a side
# mountpoint under backups-00/idrive-staging/; point iDrive at the
# clone. Daily: destroy yesterday's clone, create a fresh one from
# today's just-replicated snapshot. The live saratoga datasets stay
# unmounted; A1 keeps working.
#
# Operational shape: silent on full success (cron-safe). Reports
# count line if there were skips or failures. `--verbose` prints
# the per-dataset progress.
#
# Run as root (needs zfs create/destroy/mount). Wire to root's
# crontab or a systemd timer at ~02:30 daily (after A1 lands fresh
# snapshots, before idrivecron.service fires).

set -uo pipefail

# ── config ───────────────────────────────────────────────────────────────
STAGING_PARENT="backups-00/idrive-staging"
STAGING_MOUNT="/kodiak00/backups-00/idrive-staging"

# The saratoga child datasets to clone. Each gets cloned to
# STAGING_PARENT/<flat-name>, mounted at STAGING_MOUNT/<flat-name>.
# Update this list as the saratoga schema evolves.
SOURCES=(
    # photos
    "backups-00/saratoga/tank/archive/photography"
    # documents (non-photo archive)
    "backups-00/saratoga/tank/archive/books"
    "backups-00/saratoga/tank/archive/employers"
    "backups-00/saratoga/tank/archive/finance"
    "backups-00/saratoga/tank/archive/legal"
    "backups-00/saratoga/tank/archive/medical"
    "backups-00/saratoga/tank/archive/personal"
    "backups-00/saratoga/tank/archive/writing"
    "backups-00/saratoga/tank/archive/software"
    # active (currently-being-edited)
    "backups-00/saratoga/tank/active/aviation"
    "backups-00/saratoga/tank/active/finance-current"
    "backups-00/saratoga/tank/active/flightclub-personal"
    "backups-00/saratoga/tank/active/personal"
)

# ── flags ────────────────────────────────────────────────────────────────
VERBOSE=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --verbose|-v)  VERBOSE=1 ;;
        --dry-run|-n)  DRY_RUN=1; VERBOSE=1 ;;  # dry-run implies verbose
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2 ;;
    esac
done

# Sudo prefix: empty when root, "sudo" otherwise
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# In dry-run mode, all $SUDO_OR_NOP zfs commands become echoes
if [ "$DRY_RUN" -eq 1 ]; then
    DO() { echo "    DRY-RUN: $*"; }
else
    DO() { $SUDO "$@"; }
fi

log() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "$@"
    fi
}

# ── ensure the staging parent dataset exists (one-time) ──────────────────
if ! zfs list "$STAGING_PARENT" >/dev/null 2>&1; then
    log "→ creating staging parent: $STAGING_PARENT (mountpoint=$STAGING_MOUNT)"
    DO zfs create \
        -o canmount=noauto \
        -o mountpoint="$STAGING_MOUNT" \
        "$STAGING_PARENT" \
        || { echo "ERROR: failed to create $STAGING_PARENT" >&2; exit 1; }
fi

# Ensure the staging mountpoint directory exists for child mounts
[ -d "$STAGING_MOUNT" ] || DO mkdir -p "$STAGING_MOUNT"

# ── per-source: destroy old clone, create fresh from latest snapshot ─────
OK_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

for SRC in "${SOURCES[@]}"; do
    # Skip if source doesn't exist (saratoga dataset renamed / removed)
    if ! zfs list "$SRC" >/dev/null 2>&1; then
        log "  SKIP $SRC: source dataset not found"
        SKIP_COUNT=$((SKIP_COUNT+1))
        continue
    fi

    # Flat name: tank/archive/photography → tank-archive-photography
    REL="${SRC#backups-00/saratoga/}"
    FLAT="${REL//\//-}"
    CLONE_TARGET="$STAGING_PARENT/$FLAT"
    CLONE_MOUNT="$STAGING_MOUNT/$FLAT"

    # Find the latest snapshot of SRC (TrueNAS naming: @auto-<dataset>-YYYY-MM-DD_HH-MM)
    LATEST=$(zfs list -H -o name -t snapshot "$SRC" 2>/dev/null | tail -1)
    if [ -z "$LATEST" ]; then
        log "  SKIP $SRC: no snapshots available"
        SKIP_COUNT=$((SKIP_COUNT+1))
        continue
    fi

    log "→ $SRC"
    log "    latest: $LATEST"

    # Destroy old clone if present
    if zfs list "$CLONE_TARGET" >/dev/null 2>&1; then
        log "    destroying old clone: $CLONE_TARGET"
        # Unmount first (best-effort; -f on destroy as fallback)
        DO zfs unmount "$CLONE_TARGET" 2>/dev/null || true
        if ! DO zfs destroy "$CLONE_TARGET"; then
            echo "ERROR: zfs destroy failed for $CLONE_TARGET" >&2
            FAIL_COUNT=$((FAIL_COUNT+1))
            continue
        fi
    fi

    # Create fresh clone with explicit mountpoint (override the source's
    # mountpoint, which points at the live unmounted dataset).
    # canmount=on means ZFS will auto-mount the clone immediately on
    # creation — we don't need to call `zfs mount` afterwards (it would
    # fail with "filesystem already mounted").
    log "    cloning into $CLONE_TARGET (mountpoint=$CLONE_MOUNT)"
    if ! DO zfs clone \
        -o mountpoint="$CLONE_MOUNT" \
        -o canmount=on \
        "$LATEST" "$CLONE_TARGET"; then
        echo "ERROR: zfs clone failed: $LATEST -> $CLONE_TARGET" >&2
        FAIL_COUNT=$((FAIL_COUNT+1))
        continue
    fi

    # Verify the clone is mounted (zfs clone with canmount=on should have
    # auto-mounted; only call `zfs mount` if for some reason it didn't).
    if [ "$DRY_RUN" -eq 0 ]; then
        if [ "$(zfs get -H -o value mounted "$CLONE_TARGET")" != "yes" ]; then
            log "    (clone didn't auto-mount; calling zfs mount explicitly)"
            if ! DO zfs mount "$CLONE_TARGET"; then
                echo "ERROR: zfs mount failed for $CLONE_TARGET" >&2
                FAIL_COUNT=$((FAIL_COUNT+1))
                continue
            fi
        else
            log "    auto-mounted (canmount=on)"
        fi
    fi

    OK_COUNT=$((OK_COUNT+1))
done

# ── summary ──────────────────────────────────────────────────────────────
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "idrive-refresh-clones: $OK_COUNT ok, $SKIP_COUNT skipped, $FAIL_COUNT FAILED" >&2
    exit 1
elif [ "$VERBOSE" -eq 1 ] || [ "$SKIP_COUNT" -gt 0 ]; then
    echo "idrive-refresh-clones: $OK_COUNT ok, $SKIP_COUNT skipped, $FAIL_COUNT failed"
fi

exit 0

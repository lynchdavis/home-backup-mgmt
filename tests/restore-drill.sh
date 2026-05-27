#!/usr/bin/env bash
# restore-drill.sh — verify host-backup integrity end-to-end for ONE host.
#
# Three independent checks, sha256-anchored:
#
#   1. The mirror copy of <file> on kodiak hashes to X.
#   2. The LIVE copy on the target hashes to X — i.e., the mirror is
#      byte-identical to source as of the last sync.
#   3. Reverse-rsyncing the mirror back to /tmp on the target produces
#      a file that also hashes to X — i.e., the restore direction of
#      the pipeline (the one we actually need in an emergency) works.
#
# All three must match for the drill to pass.
#
# Exits 0 on success, non-zero on mismatch / failure (cron-safe — output
# only on failure, by default).
#
# Usage:
#   tests/restore-drill.sh <hostname> [<file-path>]
#
# Defaults:
#   <file-path> = /etc/hostname
#       Small, stable, regular file present on linux targets. On macOS
#       it may not exist; pass an alternate like /etc/hosts. The script
#       refuses to use a symlink (those resolve cross-path and our
#       backups are scoped — see SARATOGA_RESTORE / HOSTS_RESTORE).
#
# Flags:
#   --verbose   print all three hashes even on success
#
# Runs as the operator (ldavis); shells out via `sudo -u tourbillon -H`
# to use the per-host SSH key kept under ~tourbillon/.ssh/.

set -euo pipefail

VERBOSE=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

HOSTNAME="${1:-}"
FILE="${2:-/etc/hostname}"

if [ -z "$HOSTNAME" ]; then
    cat >&2 <<USAGE
usage: $0 <hostname> [<file-path>] [--verbose]

  <hostname>   matches configs/hosts/<hostname>.toml
  <file-path>  defaults to /etc/hostname. Must be a regular file on
               the target (not a symlink) AND must be present in the
               mirror under /kodiak00/backups-00/hosts/<hostname>/...

  --verbose    show all three hashes even on success

Example:
  $0 pilatus
  $0 pilatus /etc/hosts --verbose
USAGE
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TB_HOME="/var/lib/tourbillon"
KEY="$TB_HOME/.ssh/id_ed25519_tourbillon_$HOSTNAME"
MIRROR_PATH="/kodiak00/backups-00/hosts/$HOSTNAME$FILE"
STAMP=$(date +%Y%m%d-%H%M%S)
RESTORE_DEST="/tmp/restore-drill-${STAMP}-$(basename "$FILE")"

# ---- preflight --------------------------------------------------------------
if [ ! -f "$REPO_ROOT/configs/hosts/$HOSTNAME.toml" ]; then
    echo "ERROR: configs/hosts/$HOSTNAME.toml not present" >&2
    exit 1
fi
if ! sudo test -f "$KEY"; then
    echo "ERROR: per-host key $KEY missing — has $HOSTNAME been bootstrapped?" >&2
    exit 1
fi
if [ -L "$MIRROR_PATH" ]; then
    echo "ERROR: mirror $MIRROR_PATH is a symlink; pick a regular file." >&2
    echo "  (symlink targets may be outside the backed-up subtree — see HOSTS_RESTORE.md)" >&2
    exit 1
fi
if [ ! -f "$MIRROR_PATH" ]; then
    echo "ERROR: mirror $MIRROR_PATH not found" >&2
    echo "  ($FILE may be excluded by the per-host excludes_file, or the host hasn't been seeded yet.)" >&2
    exit 1
fi

# ---- helpers ----------------------------------------------------------------
ssh_target() {
    sudo -u tourbillon -H ssh -i "$KEY" -o BatchMode=yes "tourbillon@$HOSTNAME" "$@"
}

# ---- run --------------------------------------------------------------------
MIRROR_HASH=$(sha256sum "$MIRROR_PATH" | cut -d' ' -f1)
SOURCE_HASH=$(ssh_target "sha256sum $FILE" | cut -d' ' -f1)

sudo -u tourbillon -H rsync -a \
    -e "ssh -i $KEY -o BatchMode=yes" \
    "$MIRROR_PATH" "tourbillon@$HOSTNAME:$RESTORE_DEST" >/dev/null

RESTORED_HASH=$(ssh_target "sha256sum $RESTORE_DEST" | cut -d' ' -f1)

# Cleanup before reporting (so the verdict is the last line)
ssh_target "rm -f $RESTORE_DEST" >/dev/null

# ---- verdict ----------------------------------------------------------------
if [ "$MIRROR_HASH" = "$SOURCE_HASH" ] && [ "$SOURCE_HASH" = "$RESTORED_HASH" ]; then
    if [ "$VERBOSE" = "1" ]; then
        echo "✓ restore drill PASSED for $HOSTNAME:$FILE"
        echo "  mirror   : $MIRROR_HASH"
        echo "  source   : $SOURCE_HASH"
        echo "  restored : $RESTORED_HASH"
    fi
    # silent-on-success by default (cron-friendly)
    exit 0
else
    echo "✗ restore drill FAILED for $HOSTNAME:$FILE" >&2
    echo "  mirror   : $MIRROR_HASH" >&2
    echo "  source   : $SOURCE_HASH" >&2
    echo "  restored : $RESTORED_HASH" >&2
    if [ "$MIRROR_HASH" != "$SOURCE_HASH" ]; then
        echo "  -> mirror has drifted from source (force a sync?)" >&2
    fi
    if [ "$SOURCE_HASH" != "$RESTORED_HASH" ]; then
        echo "  -> reverse-rsync produced different bytes (transport corruption?)" >&2
    fi
    exit 1
fi

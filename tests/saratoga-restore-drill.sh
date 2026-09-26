#!/usr/bin/env bash
# saratoga-restore-drill.sh — verify a saratoga dataset can actually be
# restored from its latest snapshot via zfs send/recv, ZFS-native (not
# rsync — see restore-drill.sh for the host-backup equivalent).
#
# Steps (same four as the manual pass in GAPS.md sec 1.3 / CHANGELOG
# 2026-09-23):
#   1. zfs create backups-00/restore-test
#   2. zfs send <dataset>@<latest-snapshot> | zfs recv into it
#   3. Spot-check: a regular file from the restored copy is valid
#      (via `file`) and readable end-to-end (sha256 doesn't error)
#   4. zfs destroy -r backups-00/restore-test (always, via trap)
#
# Deliberately does NOT mount or read the live source dataset for
# comparison — saratoga datasets are canmount=noauto by design (the
# 2026-05-31 incident's hard-learned lesson: mounting them broke A1
# replication). The real integrity proof is zfs recv's own exit status:
# a corrupted send stream fails the receive, it doesn't silently succeed
# (ZFS embeds and verifies checksums in the stream). The file spot-check
# is a second, independent layer confirming the received bytes are
# actually usable, not just "zfs said ok."
#
# Exits 0 on success, non-zero on failure (cron-safe — silent by default).
#
# Usage:
#   tests/saratoga-restore-drill.sh [<dataset>] [--verbose]
#
# Defaults:
#   <dataset> = auto-picks the smallest non-empty leaf dataset under
#               backups-00/saratoga that actually contains a regular file
#               (tries candidates smallest-first; a dataset that's
#               technically non-empty but holds no real files — just
#               per-dataset overhead — is skipped, not treated as a
#               failure, since we didn't choose it deliberately). Pass a
#               dataset explicitly to pin it (e.g. for the monthly cron,
#               so it's the same one each time and drift is comparable) —
#               an explicit pick with no files IS a failure, since that's
#               a deliberate choice.
#
# Flags:
#   --verbose   print progress + the spot-checked file's details even on success
#
# Runs as the operator (ldavis) — needs sudo for zfs create/recv/destroy,
# same as the manual pass.

set -uo pipefail

VERBOSE=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=1 ;;
        --help|-h)
            cat <<USAGE
usage: $0 [<dataset>] [--verbose]

  <dataset>   relative to backups-00/saratoga, e.g. tank/archive/writing.
              Defaults to auto-picking the smallest leaf dataset that
              actually has a file to spot-check.
  --verbose   print progress + spot-checked file details even on success

Example:
  $0
  $0 tank/archive/writing --verbose
USAGE
            exit 0
            ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

POOL="backups-00"
PARENT="$POOL/saratoga"
TEST_DS="$POOL/restore-test"
log() { [ "$VERBOSE" = "1" ] && echo "$@" >&2; }

# ---- preflight ----------------------------------------------------------
if ! zpool list "$POOL" >/dev/null 2>&1; then
    echo "ERROR: pool $POOL not imported" >&2
    exit 2
fi
if ! zfs list "$PARENT" >/dev/null 2>&1; then
    echo "ERROR: $PARENT does not exist" >&2
    exit 2
fi

# ---- build the candidate list -----------------------------------------------
CANDIDATES=()
if [ -n "${1:-}" ]; then
    DS="$PARENT/$1"
    if ! zfs list "$DS" >/dev/null 2>&1; then
        echo "ERROR: $DS does not exist" >&2
        exit 2
    fi
    CANDIDATES=("$DS")
    EXPLICIT=1
else
    EXPLICIT=0
    # Leaf datasets under $PARENT (no children), non-empty, smallest first.
    mapfile -t ALL_NAMES < <(zfs list -H -r -o name "$PARENT")
    mapfile -t RANKED < <(
        zfs list -H -r -p -o name,used "$PARENT" | while IFS=$'\t' read -r name used; do
            [ "$name" = "$PARENT" ] && continue
            [ "$used" = "0" ] && continue
            is_leaf=1
            for other in "${ALL_NAMES[@]}"; do
                case "$other" in
                    "$name"/*) is_leaf=0; break ;;
                esac
            done
            [ "$is_leaf" = "0" ] && continue
            printf '%s\t%s\n' "$used" "$name"
        done | sort -n | cut -f2
    )
    CANDIDATES=("${RANKED[@]}")
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    echo "ERROR: no non-empty leaf dataset found under $PARENT" >&2
    exit 2
fi

# ---- cleanup (always, even on failure) ------------------------------------
cleanup() {
    sudo zfs destroy -r "$TEST_DS" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Clear out any leftover from a previous crashed run before starting.
sudo zfs destroy -r "$TEST_DS" >/dev/null 2>&1 || true

# try_dataset <dataset> — attempt the full drill against one dataset.
# Echoes "PASS <file> <type> <hash> <snapshot>" or "FAIL <reason>" on stdout.
try_dataset() {
    local dataset="$1" snapshot mountpoint sample_file file_type sample_hash
    local send_err recv_err
    local -a pipe_rc

    snapshot=$(zfs list -H -t snapshot -o name -S creation "$dataset" 2>/dev/null | head -1)
    if [ -z "$snapshot" ]; then
        echo "FAIL $dataset has no snapshots"
        return 1
    fi
    log "trying $dataset @ $snapshot"

    sudo zfs destroy -r "$TEST_DS" >/dev/null 2>&1 || true
    if ! sudo zfs create "$TEST_DS" 2>/tmp/saratoga-drill-err.$$; then
        echo "FAIL zfs create $TEST_DS failed: $(cat /tmp/saratoga-drill-err.$$)"
        rm -f /tmp/saratoga-drill-err.$$
        return 1
    fi
    rm -f /tmp/saratoga-drill-err.$$

    local dest_leaf="$TEST_DS/$(basename "$dataset")"
    send_err="/tmp/saratoga-drill-send-err.$$"
    recv_err="/tmp/saratoga-drill-recv-err.$$"
    sudo zfs send "$snapshot" 2>"$send_err" | sudo zfs recv "$dest_leaf" 2>"$recv_err"
    # Capture the whole array in one statement — a separate `x=${PIPESTATUS[0]}`
    # assignment is itself a simple command, which resets PIPESTATUS to its
    # own 1-element result before a second assignment could read index 1.
    pipe_rc=("${PIPESTATUS[@]}")

    if [ "${pipe_rc[0]}" != "0" ] || [ "${pipe_rc[1]}" != "0" ]; then
        echo "FAIL zfs send exit ${pipe_rc[0]} ($(cat "$send_err" 2>/dev/null)); zfs recv exit ${pipe_rc[1]} ($(cat "$recv_err" 2>/dev/null))"
        rm -f "$send_err" "$recv_err"
        return 1
    fi
    rm -f "$send_err" "$recv_err"

    mountpoint=$(zfs list -H -o mountpoint "$dest_leaf")
    sample_file=$(find "$mountpoint" -type f 2>/dev/null | head -1)
    if [ -z "$sample_file" ]; then
        echo "FAIL no regular files under $dataset's latest snapshot"
        return 1
    fi

    file_type=$(file -b "$sample_file")
    if ! sample_hash=$(sha256sum "$sample_file" 2>&1 | cut -d' ' -f1); then
        echo "FAIL spot-check file unreadable: $sample_file"
        return 1
    fi

    echo "PASS $sample_file|$file_type|$sample_hash|$snapshot"
    return 0
}

# ---- run --------------------------------------------------------------------
RESULT=""
CHOSEN=""
for ds in "${CANDIDATES[@]}"; do
    RESULT=$(try_dataset "$ds")
    if [[ "$RESULT" == PASS* ]]; then
        CHOSEN="$ds"
        break
    fi
    log "skipping $ds: ${RESULT#FAIL }"
    if [ "$EXPLICIT" = "1" ]; then
        # An explicit pick failing IS the verdict — don't fall through.
        break
    fi
done

if [[ "$RESULT" != PASS* ]]; then
    echo "✗ saratoga restore drill FAILED" >&2
    if [ "$EXPLICIT" = "1" ]; then
        echo "  ${1}: ${RESULT#FAIL }" >&2
    else
        echo "  no candidate dataset under $PARENT produced a usable restore" >&2
        echo "  last tried: ${RESULT#FAIL }" >&2
    fi
    exit 1
fi

# ---- verdict ----------------------------------------------------------------
IFS='|' read -r sample_file file_type sample_hash snapshot <<<"${RESULT#PASS }"
if [ "$VERBOSE" = "1" ]; then
    echo "✓ saratoga restore drill PASSED for $CHOSEN"
    echo "  snapshot     : $snapshot"
    echo "  spot-checked : $sample_file"
    echo "  file type    : $file_type"
    echo "  sha256       : $sample_hash"
fi
# silent-on-success by default (cron-friendly)
exit 0

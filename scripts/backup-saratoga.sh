#!/usr/bin/env bash
# backup-saratoga.sh — one-shot pre-migration backup of saratoga's NFS exports onto kodiak.
#
# For each known saratoga share:
#   1. Mount over the private 10 GbE (192.168.0.60) as NFSv3 read-only
#   2. rsync to the share's destination on kodiak
#   3. Unmount
#
# Continues past per-share failures. Per-share rsync logs accumulate in
# LOG_DIR; a summary log captures the run-level PASS/FAIL table.
#
# All long-standing saratoga NFS exports land on the dedicated
# /kodiak00/backups-00 volume. The one outlier — saratoga-01/photography,
# which was re-exported just for this pre-migration backup — lands on
# /kodiak00/data-00/backups/host-backups/saratoga to keep it visibly
# distinct from the canonical export set.

set -uo pipefail
umask 0022

readonly NFS_HOST=192.168.0.60
readonly MOUNT_POINT=/mnt/saratoga-pull
readonly LOG_DIR=/kodiak00/data-00/backups/logs
readonly MOUNT_OPTS="ro,hard,nolock,nfsvers=3"
readonly RSYNC_FLAGS="-rlptDv --stats"

# Default destination for all long-standing saratoga NFS exports.
readonly EXPORTS_DEST=/kodiak00/backups-00/saratoga
# Destination for the saratoga-01/photography share, which is an outlier
# that was re-exported on saratoga specifically for this pre-migration
# backup. Lands on data-00 to keep failure isolation distinct from the
# canonical export set.
readonly OUTLIER_DEST=/kodiak00/data-00/backups/host-backups/saratoga

# Pipe-delimited: name | saratoga-source-path | local-destination
#
# saratoga's `music` and `MusicShare` shares (MP3) are intentionally omitted:
# they are lossy transcodes of music_flac (lossless, backed up below), and an
# AAC set exists separately for the Apple player. Regenerable from the FLAC
# originals, so not worth the backup space.
SHARES=(
  "applications|/mnt/saratoga-01/NetworkShares01/applications|${EXPORTS_DEST}/applications"
  "OpenAudible|/mnt/saratoga-01/NetworkShares01/OpenAudible|${EXPORTS_DEST}/OpenAudible"
  "archives|/mnt/saratoga-01/NetworkShares01/archives|${EXPORTS_DEST}/archives"
  "backups|/mnt/saratoga-01/NetworkShares01/backups|${EXPORTS_DEST}/backups"
  "music_flac|/mnt/saratoga-01/NetworkShares01/music_flac|${EXPORTS_DEST}/music_flac"
  "RepositoryBackups|/mnt/saratoga-01/RepositoryBackups|${EXPORTS_DEST}/RepositoryBackups"
  "videos|/mnt/saratoga-01/videos|${EXPORTS_DEST}/videos"
  "PhotoArchive_0000_2009|/mnt/saratoga-02/PhotoArchive/PhotoArchive_0000_2009|${EXPORTS_DEST}/PhotoArchive_0000_2009"
  "PhotoArchive_2010_2019|/mnt/saratoga-02/PhotoArchive/PhotoArchive_2010_2019|${EXPORTS_DEST}/PhotoArchive_2010_2019"
  "PhotoArchive_2020_2029|/mnt/saratoga-02/PhotoArchive/PhotoArchive_2020_2029|${EXPORTS_DEST}/PhotoArchive_2020_2029"
  # photography is handled in parallel by a separate rsync writing to a
  # different physical disk (data-00 / sdc) to make use of otherwise-idle
  # destination spindle while this script saturates sdb. See the README
  # for the parallel invocation pattern.
)

RUN_TS="$(date +%Y%m%d-%H%M%S)"
SUMMARY_LOG="${LOG_DIR}/saratoga-backup-${RUN_TS}.summary.log"

mkdir -p "${LOG_DIR}" "${EXPORTS_DEST}" "${OUTLIER_DEST}"
sudo mkdir -p "${MOUNT_POINT}"

# Keep the sudo credential cache warm across a multi-hour run so the
# per-share mount/umount calls don't block on a password prompt.
( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill ${SUDO_KEEPALIVE_PID} 2>/dev/null || true' EXIT

declare -a RESULTS

note() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${SUMMARY_LOG}"
}

ensure_unmounted() {
  if mountpoint -q "${MOUNT_POINT}"; then
    sudo umount "${MOUNT_POINT}" 2>/dev/null || sudo umount -f "${MOUNT_POINT}" 2>/dev/null || true
  fi
}

backup_share() {
  local name="$1" src="$2" dst="$3"
  local log="${LOG_DIR}/saratoga-${name}-${RUN_TS}.log"
  local start_ts end_ts elapsed bytes_raw bytes

  note "===== ${name} ====="
  note "    src: ${NFS_HOST}:${src}"
  note "    dst: ${dst}"
  note "    log: ${log}"

  ensure_unmounted

  if ! sudo mount -t nfs -o "${MOUNT_OPTS}" "${NFS_HOST}:${src}" "${MOUNT_POINT}" 2>>"${log}"; then
    note "    FAIL: mount"
    RESULTS+=("${name}|FAIL-MOUNT|0|0")
    return 1
  fi

  if ! ls "${MOUNT_POINT}" >/dev/null 2>"${log}"; then
    note "    FAIL: cannot read mount (stale handle?)"
    ensure_unmounted
    RESULTS+=("${name}|FAIL-READ|0|0")
    return 1
  fi

  mkdir -p "${dst}"

  start_ts=$(date +%s)
  # shellcheck disable=SC2086
  if rsync ${RSYNC_FLAGS} --log-file="${log}" "${MOUNT_POINT}/" "${dst}/" >>"${log}" 2>&1; then
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    # Pull just the number after "file size:" — rsync log lines are prefixed
    # with timestamps, so a naive grep would pick up the timestamp digits too.
    bytes_raw=$(awk -F'file size:' '/Total transferred file size:/ {
      n=$2; gsub(/[^0-9]/,"",n); print n; exit
    }' "${log}")
    bytes="${bytes_raw:-0}"
    note "    PASS: ${elapsed}s, ${bytes} bytes"
    RESULTS+=("${name}|PASS|${elapsed}|${bytes}")
  else
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    note "    FAIL: rsync (after ${elapsed}s) — see ${log}"
    RESULTS+=("${name}|FAIL-RSYNC|${elapsed}|0")
  fi

  ensure_unmounted
}

note "###########################################"
note "saratoga backup run starting"
note "summary log: ${SUMMARY_LOG}"
note "###########################################"

OVERALL_START=$(date +%s)
for entry in "${SHARES[@]}"; do
  IFS='|' read -r name src dst <<<"${entry}"
  backup_share "${name}" "${src}" "${dst}"
done
OVERALL_END=$(date +%s)
OVERALL_ELAPSED=$((OVERALL_END - OVERALL_START))

ensure_unmounted
sudo rmdir "${MOUNT_POINT}" 2>/dev/null || true

note ""
note "###########################################"
note "SUMMARY  total elapsed: $((OVERALL_ELAPSED / 60))m $((OVERALL_ELAPSED % 60))s"
note "###########################################"
printf '%-25s %-12s %-8s %s\n' "SHARE" "STATUS" "TIME" "BYTES" | tee -a "${SUMMARY_LOG}"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r n s t b <<<"${r}"
  printf '%-25s %-12s %-7ss %s\n' "${n}" "${s}" "${t}" "${b}" | tee -a "${SUMMARY_LOG}"
done

if printf '%s\n' "${RESULTS[@]}" | grep -q "|FAIL"; then
  note "Some shares failed — review per-share logs in ${LOG_DIR}/"
  exit 1
fi
note "All shares completed successfully."
exit 0

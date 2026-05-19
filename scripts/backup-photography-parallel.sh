#!/usr/bin/env bash
# backup-photography-parallel.sh — pulls the saratoga-01/NetworkShares01/photography
# share onto kodiak's /kodiak00/data-00 in parallel with backup-saratoga.sh.
#
# Rationale: backup-saratoga.sh writes to /kodiak00/backups-00 (sdb, SATA, the
# single-stream bottleneck). This run writes to /kodiak00/data-00 (sdc, SAS,
# otherwise idle) so the two destination spindles work in parallel.
#
# Both runs read from saratoga over the 192.168.0 10 GbE; saratoga's source
# pool (saratoga-01) is a multi-disk ZFS pool and serves both streams.

set -uo pipefail
umask 0022

readonly NFS_HOST=192.168.0.60
readonly SRC=/mnt/saratoga-01/NetworkShares01/photography
readonly DST=/kodiak00/data-00/backups/host-backups/saratoga/photography
readonly MOUNT_POINT=/mnt/saratoga-pull-photography
readonly LOG_DIR=/kodiak00/data-00/backups/logs
readonly RUN_TS="$(date +%Y%m%d-%H%M%S)"
readonly LOG="${LOG_DIR}/saratoga-photography-parallel-${RUN_TS}.log"

mkdir -p "${LOG_DIR}" "${DST}"
sudo mkdir -p "${MOUNT_POINT}"

# Keep sudo timestamp warm so the umount at the end doesn't block.
( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &
KEEP_PID=$!

cleanup() {
  kill "${KEEP_PID}" 2>/dev/null || true
  if mountpoint -q "${MOUNT_POINT}"; then
    sudo umount "${MOUNT_POINT}" 2>/dev/null || sudo umount -l "${MOUNT_POINT}" 2>/dev/null || true
  fi
  sudo rmdir "${MOUNT_POINT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[$(date)] parallel photography pull starting"
echo "          src: ${NFS_HOST}:${SRC}"
echo "          dst: ${DST}"
echo "          log: ${LOG}"

if ! sudo mount -t nfs -o ro,hard,nolock,nfsvers=3 "${NFS_HOST}:${SRC}" "${MOUNT_POINT}"; then
  echo "[$(date)] FAIL: mount"
  exit 1
fi

START=$(date +%s)
if rsync -rlptDv --stats --log-file="${LOG}" "${MOUNT_POINT}/" "${DST}/"; then
  ELAPSED=$(($(date +%s) - START))
  echo "[$(date)] PASS in ${ELAPSED}s (${ELAPSED} sec / $((ELAPSED/60)) min)"
else
  rc=$?
  ELAPSED=$(($(date +%s) - START))
  echo "[$(date)] FAIL: rsync exit ${rc} after ${ELAPSED}s — see ${LOG}"
  exit "${rc}"
fi

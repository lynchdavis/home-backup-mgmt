#!/usr/bin/env bash
# idrive-status.sh — observability snapshot for the iDrive backup.
#
# Not a pass/fail check — a status report. Run on-demand for "is it
# still going?", or wrap in `watch -n 60` for a live dashboard.
#
# Reports:
#   1. iDrive worker process state (idevsutil_dedup running or not)
#   2. idrivecron.service systemd state + recent journal lines
#   3. Network throughput (last 2 seconds) on the primary interface
#   4. Snapshot-clone state (backup sources — mounted? origin snapshot?)
#   5. Most recent iDrive log entries (search common paths)
#   6. Pointer to the iDrive web UI (the authoritative view)

set -uo pipefail

# Sudo prefix (needs root for some peeks at iDrive's files)
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

echo "================ idrive-status.sh — $(date) ================"

# ── 1) Process state ─────────────────────────────────────────────────────
echo
echo "── 1) iDrive worker process ──"
PROCS=$($SUDO pgrep -af 'idevsutil' 2>/dev/null | grep -v 'pgrep' || true)
if [ -n "$PROCS" ]; then
    echo "$PROCS" | head -3 | sed 's/^/  /'
    echo "  ✓ idevsutil running"
else
    echo "  ✗ no idevsutil process — backup is NOT currently running"
    echo "    (might be scheduled-only — see (2) for daemon state)"
fi

# ── 2) Scheduler daemon ──────────────────────────────────────────────────
echo
echo "── 2) idrivecron.service ──"
STATE=$(systemctl is-active idrivecron.service 2>&1)
ENABLED=$(systemctl is-enabled idrivecron.service 2>&1)
echo "  active: $STATE   enabled: $ENABLED"
echo "  recent journal (1h):"
$SUDO journalctl -u idrivecron.service --since '1 hour ago' --no-pager 2>&1 \
    | tail -5 | sed 's/^/    /'

# ── 3) Network throughput ────────────────────────────────────────────────
echo
echo "── 3) Network throughput (primary interface, 2s sample) ──"
IFACE=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
if [ -n "$IFACE" ]; then
    # /proc/net/dev format: "  eno1: <rx bytes> <rx pkts> ... <tx bytes> <tx pkts> ..."
    # awk default FS splits the iface-and-colon as $1=iface_with_colon, then
    # $2..$9 = rx fields, $10 = tx bytes.
    START_TX=$(awk -v iface="${IFACE}:" '$1 == iface {print $10}' /proc/net/dev)
    sleep 2
    END_TX=$(awk -v iface="${IFACE}:" '$1 == iface {print $10}' /proc/net/dev)
    if [ -n "$START_TX" ] && [ -n "$END_TX" ]; then
        DELTA=$(( END_TX - START_TX ))
        MB_PER_SEC=$(awk -v d=$DELTA 'BEGIN { printf "%.2f", d / 2 / 1024 / 1024 }')
        MBPS=$(awk -v d=$DELTA 'BEGIN { printf "%.1f", d * 8 / 2 / 1000000 }')
        echo "  $IFACE TX: ${MB_PER_SEC} MB/s ≈ ${MBPS} Mbps over the 2-second window"
    else
        echo "  $IFACE — could not parse /proc/net/dev"
    fi
else
    echo "  (no default-route interface found)"
fi

# ── 4) Snapshot-clone state ──────────────────────────────────────────────
echo
echo "── 4) Backup-source clones (backups-00/idrive-staging/*) ──"
if zfs list backups-00/idrive-staging >/dev/null 2>&1; then
    zfs list -H -o name,mounted -r backups-00/idrive-staging 2>/dev/null \
        | awk '
            NR == 1 { next }  # skip parent itself
            $2 == "yes" { mounted++ }
            $2 == "no" { unmounted++ }
            END {
                printf "  %d clones mounted, %d unmounted\n", mounted+0, unmounted+0
            }'
    # Origin snapshot of the photos clone tells us how fresh the data is
    ORIG=$(zfs get -H -o value origin backups-00/idrive-staging/tank-archive-photography 2>/dev/null)
    if [ -n "$ORIG" ] && [ "$ORIG" != "-" ]; then
        echo "  photography clone origin: $ORIG"
    fi
else
    echo "  ✗ backups-00/idrive-staging dataset doesn't exist."
    echo "    Run bin/idrive-refresh-clones.sh first."
fi

# ── 5) Recent iDrive log entries ─────────────────────────────────────────
echo
echo "── 5) Recent iDrive log ──"
# iDrive 1.7.0 log locations vary; check common ones
LOG=""
for cand in \
    /opt/IDriveForLinux/idriveIt/user_profile/idriveforlinux.log \
    /opt/IDriveForLinux/idriveIt/idriveforlinux.log \
    /var/log/idriveforlinux.log \
    /root/.IDrive/logs/idriveforlinux.log \
; do
    if $SUDO test -f "$cand"; then
        LOG="$cand"
        break
    fi
done
# Fallback: find the most recently modified .log under /opt/IDriveForLinux
if [ -z "$LOG" ]; then
    LOG=$($SUDO find /opt/IDriveForLinux -type f -name '*.log' 2>/dev/null \
          | xargs -I{} $SUDO stat -c '%Y {}' {} 2>/dev/null \
          | sort -rn | head -1 | awk '{print $2}')
fi
if [ -n "$LOG" ] && $SUDO test -f "$LOG"; then
    echo "  source: $LOG"
    $SUDO tail -8 "$LOG" 2>&1 | sed 's/^/    /'
else
    echo "  (no iDrive log file found at known paths; try \`sudo find /opt/IDriveForLinux -name \"*.log\"\` to locate)"
fi

# ── 6) Pointer to authoritative source ──────────────────────────────────
echo
echo "── 6) Authoritative state ──"
echo "  iDrive web UI:  https://www.idrive.com  →  Dashboard  →  Manage Devices"
echo "                  Look for 'kodiak' — should show growing data size over time."
echo

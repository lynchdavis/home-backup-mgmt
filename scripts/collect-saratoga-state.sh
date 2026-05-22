#!/usr/bin/env bash
# collect-saratoga-state.sh
#
# Run ON saratoga (FreeBSD / FreeNAS) — NOT on kodiak. Captures the Tier 2/3
# OS-side reference state described in the pre-migration plan into a single
# tarball at /tmp/saratoga-state-<ts>.tar.gz, then prints the scp command
# to pull it back to kodiak.
#
# Tier 1 (FreeNAS GUI "Save Config") is NOT collected here — that download
# has to come from the web UI. /data/freenas-v1.db IS captured as a
# belt-and-suspenders reference copy, but is NOT a substitute for the
# GUI Save Config bundle (which adds the password seed + version metadata).
#
# Several captures need root. Run as root, or via sudo:
#
#   # one-shot from kodiak:
#   scp scripts/collect-saratoga-state.sh ldavis@192.168.0.60:/tmp/
#   ssh -t ldavis@192.168.0.60 'sudo /usr/local/bin/bash /tmp/collect-saratoga-state.sh'
#   scp ldavis@192.168.0.60:/tmp/saratoga-state-*.tar.gz \
#       /kodiak00/data-00/backups/saratoga-pre-migration-state/
#
# Continues past per-command failures — each capture records its own exit
# status in the captured file. The manifest at the end checksums every
# file in the bundle.

set -u
umask 0077  # bundle may contain authorized_keys / sshd_config

TS="$(date +%Y%m%d-%H%M%S)"
OUT="/tmp/saratoga-state-${TS}"
TARBALL="/tmp/saratoga-state-${TS}.tar.gz"

mkdir -p \
  "${OUT}/system" \
  "${OUT}/network" \
  "${OUT}/boot" \
  "${OUT}/storage" \
  "${OUT}/storage/smartctl" \
  "${OUT}/shares" \
  "${OUT}/users" \
  "${OUT}/cron" \
  "${OUT}/cron/user-tabs" \
  "${OUT}/ssh" \
  "${OUT}/ssh/host-keys" \
  "${OUT}/ssh/authorized-keys" \
  "${OUT}/data"

note() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Run a command, write its output (with a small header + exit code) to a file.
capture() {
  local out_path="$1"; shift
  {
    printf '# host:    %s\n' "$(hostname)"
    printf '# command: %s\n' "$*"
    printf '# ts:      %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "$@" 2>&1
    printf '\n# exit: %d\n' "$?"
  } >"${out_path}"
}

copy_if_present() {
  local src="$1" dst="$2"
  if [ -r "${src}" ]; then
    cp "${src}" "${dst}"
  else
    printf '# %s not readable (missing, or this script was not run as root)\n' \
      "${src}" >"${dst}.absent"
  fi
}

note "collecting into ${OUT}"
note "running as: $(id -un) (uid $(id -u))"

# ---------- system / version ----------
capture          "${OUT}/system/uname.txt"           uname -a
copy_if_present  /etc/version                        "${OUT}/system/freenas-version.txt"
capture          "${OUT}/system/hostname.txt"        hostname
capture          "${OUT}/system/uptime.txt"          uptime
capture          "${OUT}/system/date.txt"            date
capture          "${OUT}/system/id.txt"              id
copy_if_present  /var/run/dmesg.boot                 "${OUT}/system/dmesg-boot.txt"
capture          "${OUT}/system/pkg-info.txt"        pkg info -aq
# Filename-only inventory of admin homes — captures *what* is there without
# pulling potentially-large or sensitive contents. -xdev keeps us on the
# boot device (no descent into /mnt/saratoga-*).
capture          "${OUT}/system/root-home-inventory.txt" \
                 find /root /home -xdev -type f -ls

# ---------- network ----------
capture          "${OUT}/network/ifconfig.txt"       ifconfig -v
capture          "${OUT}/network/routing-table.txt"  netstat -rn
capture          "${OUT}/network/netstat-an.txt"     netstat -an
copy_if_present  /etc/resolv.conf                    "${OUT}/network/resolv-conf.txt"
copy_if_present  /etc/hosts                          "${OUT}/network/hosts.txt"

# ---------- boot / runtime tunables ----------
copy_if_present  /etc/rc.conf                        "${OUT}/boot/rc-conf.txt"
copy_if_present  /etc/sysctl.conf                    "${OUT}/boot/sysctl-conf.txt"
copy_if_present  /boot/loader.conf                   "${OUT}/boot/loader-conf.txt"
copy_if_present  /etc/ntp.conf                       "${OUT}/boot/ntp-conf.txt"
capture          "${OUT}/boot/sysctl-all.txt"        sysctl -a

# ---------- storage / ZFS ----------
capture          "${OUT}/storage/zpool-list.txt"     zpool list -v
capture          "${OUT}/storage/zpool-status.txt"   zpool status -v
for pool in $(zpool list -H -o name 2>/dev/null); do
  capture        "${OUT}/storage/zpool-history-${pool}.txt"  zpool history -l "${pool}"
done
capture          "${OUT}/storage/zfs-list-fs.txt" \
                 zfs list -t filesystem,volume \
                 -o name,used,avail,refer,mountpoint,compression,quota,reservation,sharenfs,sharesmb,readonly,recordsize,dedup
capture          "${OUT}/storage/zfs-list-snapshots.txt" \
                 zfs list -t snapshot -o name,used,refer,creation -s creation
capture          "${OUT}/storage/zfs-get-all.txt"    zfs get -t filesystem,volume all
capture          "${OUT}/storage/camcontrol-devlist.txt" camcontrol devlist
capture          "${OUT}/storage/geom-disk-list.txt" geom disk list
capture          "${OUT}/storage/glabel-status.txt"  glabel status
capture          "${OUT}/storage/gpart-show.txt"     gpart show

# smartctl per disk — sysctl(8) gives a clean space-separated list.
# Resolve the binary explicitly because sudo's secure_path may strip /usr/local/sbin.
SMARTCTL=""
for cand in /usr/local/sbin/smartctl /usr/sbin/smartctl smartctl; do
  if command -v "${cand}" >/dev/null 2>&1; then
    SMARTCTL="${cand}"
    break
  fi
done
if [ -n "${SMARTCTL}" ]; then
  for disk in $(sysctl -n kern.disks 2>/dev/null); do
    capture      "${OUT}/storage/smartctl/${disk}.txt" "${SMARTCTL}" -a "/dev/${disk}"
  done
else
  printf '# smartctl not found on this host\n' \
    >"${OUT}/storage/smartctl/_unavailable.txt"
fi

# ---------- shares ----------
copy_if_present  /etc/exports                        "${OUT}/shares/etc-exports.txt"
capture          "${OUT}/shares/showmount-localhost.txt"  showmount -e localhost
copy_if_present  /usr/local/etc/smb4.conf            "${OUT}/shares/smb4-conf.txt"

# ---------- users / groups ----------
copy_if_present  /etc/passwd                         "${OUT}/users/etc-passwd.txt"
copy_if_present  /etc/group                          "${OUT}/users/etc-group.txt"
capture          "${OUT}/users/pw-usershow.txt"      pw usershow -a
capture          "${OUT}/users/pw-groupshow.txt"     pw groupshow -a

# ---------- cron / periodic ----------
copy_if_present  /etc/crontab                        "${OUT}/cron/etc-crontab.txt"
copy_if_present  /etc/periodic.conf                  "${OUT}/cron/periodic-conf.txt"
if [ -d /var/cron/tabs ]; then
  for tab in /var/cron/tabs/*; do
    [ -r "${tab}" ] || continue
    cp "${tab}" "${OUT}/cron/user-tabs/$(basename "${tab}")"
  done
fi

# ---------- ssh ----------
copy_if_present  /etc/ssh/sshd_config                "${OUT}/ssh/sshd-config.txt"
# Public host keys only by default. To also preserve host identity verbatim
# (so clients don't get known-hosts warnings on the new box), uncomment the
# private-key copy below — the bundle is already mode 0700/0600 via umask.
for k in /etc/ssh/ssh_host_*_key.pub; do
  [ -r "${k}" ] || continue
  cp "${k}" "${OUT}/ssh/host-keys/$(basename "${k}")"
done
# for k in /etc/ssh/ssh_host_*_key; do
#   [ -r "${k}" ] || continue
#   cp "${k}" "${OUT}/ssh/host-keys/$(basename "${k}")"
# done
for home in /root /home/*; do
  [ -d "${home}" ] || continue
  ak="${home}/.ssh/authorized_keys"
  if [ -r "${ak}" ]; then
    cp "${ak}" "${OUT}/ssh/authorized-keys/$(basename "${home}").txt"
  fi
done

# ---------- FreeNAS config DB (reference only — see header comment) ----------
if [ -r /data/freenas-v1.db ]; then
  cp /data/freenas-v1.db "${OUT}/data/freenas-v1.db"
else
  printf '# /data/freenas-v1.db not readable; re-run as root\n' \
    >"${OUT}/data/freenas-v1.db.absent"
fi

# ---------- manifest ----------
# FreeBSD has /sbin/sha256 (-q gives bare hash); Linux/macOS have sha256sum.
hash_of() {
  if command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$1"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'NO-SHA256-AVAILABLE'
  fi
}
(
  cd "${OUT}"
  find . -type f ! -name manifest.sha256 | sort | while read -r f; do
    printf '%s  %s\n' "$(hash_of "${f}")" "${f}"
  done
) >"${OUT}/manifest.sha256"

# ---------- bundle ----------
tar -C /tmp -czf "${TARBALL}" "saratoga-state-${TS}"
SIZE="$(du -h "${TARBALL}" | awk '{print $1}')"

note ""
note "DONE — bundle: ${TARBALL} (${SIZE})"
note ""
note "Pull from kodiak:"
note "  scp ldavis@192.168.0.60:${TARBALL} \\"
note "      /kodiak00/data-00/backups/saratoga-pre-migration-state/"
note ""
note "After it's safely on kodiak, remove the temp copies from saratoga:"
note "  rm -rf ${OUT} ${TARBALL}"

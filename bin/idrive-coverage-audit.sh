#!/usr/bin/env bash
# idrive-coverage-audit.sh — collect everything needed to audit what kodiak
# pushes to iDrive versus what exists on backups-00 / data-00.
#
# Usage:  sudo bin/idrive-coverage-audit.sh [--no-clone] [--no-photo-scan] [--force]
#
# Read-only, with ONE exception: to see inside saratoga datasets that are
# deliberately unmounted (canmount=noauto, ADR-005), it makes a temporary
# read-only ZFS clone of each one's latest snapshot under
# backups-00/idrive-staging/_audit-*, inspects it, and destroys it on exit
# (trap). It never mounts the live replicated datasets. --no-clone skips this.
#
# Refuses to run 01:45–06:30 local time (clone refresh at 02:30, TrueNAS push
# at 05:00 EST) unless --force, so a temp clone can't pin a snapshot that
# replication wants to prune.
#
# Credentials are NOT copied: from iDrive's profile tree it copies only
# allow-listed config/backup-set/exclude/log files, and lists everything
# else by name and size only.
#
# Output: ~$SUDO_USER/idrive-audit-<timestamp>/ (mode 700, owned by you) plus a
# .tgz of the same directory.

set -uo pipefail

DO_CLONE=1; DO_PHOTOS=1; FORCE=0
for a in "$@"; do
    case "$a" in
        --no-clone) DO_CLONE=0 ;;
        --no-photo-scan) DO_PHOTOS=0 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown flag: $a" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

HHMM=$((10#$(date +%H%M)))
if [ "$FORCE" -eq 0 ] && [ "$DO_CLONE" -eq 1 ] && [ "$HHMM" -ge 145 ] && [ "$HHMM" -le 630 ]; then
    echo "refusing to clone during the 01:45–06:30 replication window; use --no-clone or --force" >&2
    exit 1
fi
if pgrep -x 'zfs' >/dev/null && pgrep -af 'zfs (recv|receive)' >/dev/null; then
    echo "a zfs receive is running right now; try again later" >&2
    exit 1
fi

OWNER="${SUDO_USER:-root}"
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
TS=$(date +%Y%m%d-%H%M%S)
OUT="$OWNER_HOME/idrive-audit-$TS"
install -d -m 700 "$OUT"
LOG="$OUT/00-run.log"

STAGING_PARENT="backups-00/idrive-staging"
AUDIT_MNT_BASE="/run/idrive-audit"
AUDIT_CLONES=()

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG" >&2; }
sec() { echo; echo "===== $* ====="; }

cleanup() {
    # find leftovers by name, so an interrupt mid-loop (subshell) still cleans up
    mapfile -t AUDIT_CLONES < <(zfs list -H -o name -r "$STAGING_PARENT" 2>/dev/null | grep '/_audit-')
    for c in "${AUDIT_CLONES[@]}"; do
        zfs unmount "$c" 2>/dev/null
        if zfs destroy "$c" 2>>"$LOG"; then
            log "destroyed temp clone $c"
        else
            log "WARNING: could not destroy $c — run: sudo zfs destroy $c"
        fi
    done
    rmdir "$AUDIT_MNT_BASE"/* "$AUDIT_MNT_BASE" 2>/dev/null
    chown -R "$OWNER": "$OUT" "$OUT.tgz" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── 1. ZFS inventory ─────────────────────────────────────────────────────
log "1/8 zfs inventory"
{
    sec "zfs list (filesystems)"
    zfs list -r -t filesystem -o name,used,usedbydataset,usedbysnapshots,logicalused,mounted,canmount,readonly,origin,mountpoint \
        backups-00 scratch-00
    sec "latest snapshot per dataset (backups-00)"
    for ds in $(zfs list -H -r -t filesystem -o name backups-00); do
        printf '%-60s %s\n' "$ds" "$(zfs list -H -t snapshot -o name -s creation "$ds" 2>/dev/null | tail -1)"
    done
    sec "idrive-staging clone origins + creation time"
    zfs list -H -r -o name,origin,creation,used,mounted "$STAGING_PARENT"
    sec "zpool status"
    zpool status -x
} >"$OUT/10-zfs.txt" 2>&1

# ── 2. iDrive install / scheduler ────────────────────────────────────────
log "2/8 idrive scheduler + service"
{
    sec "package"; dpkg -l idriveforlinux 2>&1 | tail -1
    cat /opt/IDriveForLinux/AppVersion 2>/dev/null
    sec "idrivecron.service"; systemctl status idrivecron.service --no-pager 2>&1 | head -15
    sec "/etc/idrivecrontab.json"; cat /etc/idrivecrontab.json 2>&1
    sec "journal idrivecron (7 days, last 300 lines)"
    journalctl -u idrivecron.service --since '7 days ago' --no-pager 2>&1 | tail -300
    sec "root crontab"; crontab -l -u root 2>&1
} >"$OUT/20-idrive-service.txt" 2>&1

# ── 3. iDrive profile tree (allow-listed copy) ───────────────────────────
log "3/8 idrive profile files"
PROF=/opt/IDriveForLinux/idriveIt/user_profile
{
    sec "full tree listing (names + sizes only)"
    find "$PROF" -printf '%y %10s %TY-%Tm-%Td %TH:%TM  %p\n' 2>&1 | grep -v '/LOGS/' | sort -k5
    sec "LOGS directories (count + newest 15 per dir)"
    find "$PROF" -type d -name LOGS 2>/dev/null | while read -r d; do
        echo "--- $d ($(ls -1 "$d" | wc -l) files)"
        ls -lt "$d" | head -16
    done
} >"$OUT/30-idrive-profile-tree.txt" 2>&1

mkdir -p "$OUT/31-idrive-config"
# allow-list: backup sets, exclude lists, non-secret config. Deny anything that looks like a credential.
find "$PROF" -type f \( -iname 'Backupset*' -o -iname '*Exclude*' -o -iname 'CONFIGURATION*' \
        -o -iname '*.json' -o -iname 'LocalBackupset*' -o -iname '*schedule*' \) \
    ! -path '*/LOGS/*' ! -iname '*PWD*' ! -iname '*PVT*' ! -iname '*key*' ! -iname '*token*' \
    ! -iname '*pass*' ! -iname '.userInfo*' -print0 2>/dev/null |
while IFS= read -r -d '' f; do
    dest="$OUT/31-idrive-config/$(echo "${f#$PROF/}" | tr '/' '__')"
    cp -p "$f" "$dest"
done
# belt and braces: blank any obvious secret-looking values in copied config
sed -i -E 's/("?(PASSWORD|PWD|PVTKEY|ENCKEY|TOKEN|ACCESS_?KEY)"?[[:space:]]*[:=][[:space:]]*)"?[^",}]*"?/\1"<redacted>"/Ig' \
    "$OUT"/31-idrive-config/* 2>/dev/null

# ── 4. iDrive backup logs ────────────────────────────────────────────────
log "4/8 idrive logs"
mkdir -p "$OUT/40-idrive-logs"
find "$PROF" -type d -name LOGS 2>/dev/null | while read -r d; do
    tag=$(echo "${d#$PROF/}" | tr '/' '_')
    # newest 8 logs: summary lines in full, file-level lines capped
    ls -1t "$d" | head -8 | while read -r f; do
        p="$d/$f"
        {
            echo "##### $p ($(stat -c %s "$p") bytes, $(stat -c %y "$p"))"
            grep -a -i -E 'summary|consider|backed ?up|in sync|fail|error|denied|skip|exclud|total|start|end|status|transfer|quota' "$p" | head -400
            echo "----- head -40"; head -40 "$p"
            echo "----- tail -60"; tail -60 "$p"
        } >"$OUT/40-idrive-logs/${tag}__$f.txt" 2>&1
    done
    # every log's name gives success/failure history
    ls -lt "$d" >"$OUT/40-idrive-logs/${tag}__INDEX.txt"
done
# iDrive also keeps error/failed-file lists outside LOGS on some versions
find "$PROF" -type f \( -iname '*error*' -o -iname '*fail*' \) ! -path '*/LOGS/*' -print0 2>/dev/null |
while IFS= read -r -d '' f; do
    { echo "##### $f"; tail -300 "$f"; } >>"$OUT/40-idrive-logs/zz-error-files.txt"
done

# ── 5. Inspect unmounted saratoga datasets via temp clones ───────────────
inspect_tree() {  # $1 = path, $2 = label
    local p="$1"
    sec "$2 — top-level (apparent size)"
    du -x --apparent-size -h -d 1 "$p" 2>/dev/null | sort -k2
    sec "$2 — second level (apparent size)"
    du -x --apparent-size -h -d 2 "$p" 2>/dev/null | sort -k2
    sec "$2 — file count"; find "$p" -xdev -type f | wc -l
    sec "$2 — git repos / repo archives"
    find "$p" -xdev \( -type d -name '.git' -o -type d -name '*.git' -o -iname '*.git.zip' -o -iname '*.bundle' \) -prune -print 2>/dev/null | head -500
    sec "$2 — hidden files/dirs (count; may be hit by iDrive excludes)"
    find "$p" -xdev -name '.*' | wc -l
}

if [ "$DO_CLONE" -eq 1 ]; then
    log "5/8 temp clones of unmounted datasets"
    install -d -m 700 "$AUDIT_MNT_BASE"
    # every saratoga dataset with real data of its own that is NOT mounted
    zfs list -H -p -r -t filesystem -o name,usedbydataset,mounted backups-00/saratoga |
    awk '$3=="no" && $2 > 1048576 {print $1}' |
    grep -v -E '/media/music/(aac|flac)$|/media/audiobooks$' |   # bulk media: size known, contents not needed
    while read -r ds; do
        snap=$(zfs list -H -t snapshot -o name -s creation "$ds" | tail -1)
        [ -n "$snap" ] || { log "  no snapshot for $ds"; continue; }
        flat=$(echo "${ds#backups-00/saratoga/}" | tr '/' '-')
        clone="$STAGING_PARENT/_audit-$flat"
        mnt="$AUDIT_MNT_BASE/$flat"
        zfs list "$clone" >/dev/null 2>&1 && zfs destroy "$clone"
        if zfs clone -o readonly=on -o canmount=on -o mountpoint="$mnt" "$snap" "$clone" 2>>"$LOG"; then
            echo "$clone" >>"$OUT/.clones"
            log "  cloned $snap -> $mnt"
            inspect_tree "$mnt" "$ds @ ${snap#*@}" >"$OUT/50-unmounted-$flat.txt" 2>&1
            zfs unmount "$clone" 2>/dev/null; zfs destroy "$clone" 2>>"$LOG" && log "  destroyed $clone" \
                || echo "$clone" >>"$OUT/.clones-leftover"
        else
            log "  clone FAILED for $snap"
        fi
    done
    # anything the loop couldn't destroy gets another try in the trap
else
    log "5/8 skipped (--no-clone)"
fi

# ── 6. Mounted areas: what iDrive can see, and what's outside it ─────────
log "6/8 mounted areas"
{
    for p in /kodiak00/backups-00/idrive-staging/* /kodiak00/backups-00/repos \
             /kodiak00/backups-00/saratoga/tank/staging; do
        inspect_tree "$p" "$p"
    done
    sec "repos: per-repo size + HEAD date"
    for r in /kodiak00/backups-00/repos/*/*/*; do
        [ -d "$r" ] || continue
        d=$(git --git-dir="$r" log -1 --format=%ci --all 2>/dev/null || git -C "$r" log -1 --format=%ci --all 2>/dev/null)
        printf '%8s  %s  %s\n' "$(du -sh "$r" | cut -f1)" "${d:-?}" "$r"
    done
} >"$OUT/60-mounted-areas.txt" 2>&1
{
    sec "hosts: top two levels per host"
    for h in /kodiak00/backups-00/hosts/*; do
        du -x --apparent-size -h -d 2 "$h" 2>/dev/null | sort -h | tail -40
    done
} >"$OUT/61-hosts.txt" 2>&1
{
    sec "data-00 top levels"
    du -x --apparent-size -h -d 2 /kodiak00/data-00 2>/dev/null | sort -k2
    sec "/home top levels"
    du -x --apparent-size -h -d 2 /home 2>/dev/null | sort -k2
    sec "scratch-00 top levels (not backed up anywhere by design)"
    du --apparent-size -h -d 2 /kodiak00/scratch-00 2>/dev/null | sort -k2
} >"$OUT/62-data00-home-scratch.txt" 2>&1

# ── 7. Photo scan: image/raw/video files OUTSIDE tank/archive/photography ─
if [ "$DO_PHOTOS" -eq 1 ]; then
    log "7/8 photo scan (can take a while on hosts/lynchmbp)"
    EXT='jpg|jpeg|heic|heif|png|tif|tiff|dng|nef|cr2|cr3|arw|raf|orf|rw2|psd|mov|mp4|m4v|avi'
    {
        sec "image/video files by directory (2 levels below root), count + bytes"
        for root in /kodiak00/backups-00/hosts /kodiak00/backups-00/saratoga/tank/staging \
                    /kodiak00/data-00 /home /kodiak00/backups-00/idrive-staging; do
            # no -xdev: hosts/* and idrive-staging/* are child datasets (separate mounts)
            find "$root" -type f -regextype posix-extended -iregex ".*\.($EXT)$" \
                 -not -path '*/idrive-staging/tank-archive-photography/*' -printf '%s %h\n' 2>/dev/null |
            awk -v r="$root" '{
                n=split(substr($2, length(r)+2), a, "/");
                k=r "/" a[1] (n>1 ? "/" a[2] : "") (n>2 ? "/" a[3] : "");
                c[k]++; s[k]+=$1
            } END { for (k in c) printf "%8d  %10.1f MB  %s\n", c[k], s[k]/1048576, k }' | sort -k4
        done
        sec "Photos/Lightroom/Aperture/Capture One libraries anywhere"
        find /kodiak00/backups-00/hosts /kodiak00/data-00 /home /kodiak00/backups-00/idrive-staging -maxdepth 8 \
            \( -iname '*.photoslibrary' -o -iname '*.lrcat' -o -iname '*.aplibrary' -o -iname '*.cocatalog' -o -iname '*.lrlibrary' \) \
            -prune -print 2>/dev/null
    } >"$OUT/70-photos-outside-archive.txt" 2>&1
else
    log "7/8 skipped (--no-photo-scan)"
fi

# ── 8. package ───────────────────────────────────────────────────────────
log "8/8 packaging"
rm -f "$OUT/.clones" "$OUT/.clones-leftover"
tar -C "$(dirname "$OUT")" -czf "$OUT.tgz" "$(basename "$OUT")"
chmod 600 "$OUT.tgz"
log "done: $OUT  (and $OUT.tgz)"

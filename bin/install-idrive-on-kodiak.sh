#!/usr/bin/env bash
# install-idrive-on-kodiak.sh — verify the iDrive Linux toolkit is in
# place + hand off to the headless setup CLI. Per ADR-005 (updated
# 2026-05-31 after the research dive).
#
# The IDriveForLinux .deb package (1.7.0 today) installs both:
#   - An Electron GUI app at /usr/local/bin/idriveforlinux (requires
#     X11/Wayland — refuses to run headless; not what we want)
#   - The legacy Perl-script CLI toolkit at /opt/IDriveForLinux/
#     {bin/idrive, idriveIt/*.pl} (headless-capable; this is what
#     we use for kodiak)
#   - The Perl scheduler daemon idrivecron.service (runs the
#     configured backup schedule once we set one up)
#
# This script's job:
#   1. Confirm the .deb was installed (dpkg -l idriveforlinux).
#   2. Confirm the scripts toolkit exists at /opt/IDriveForLinux/.
#   3. Print the runbook for the interactive setup that comes next
#      (login → encryption key → backup sets → schedule → enable scheduler).
#
# Run as the operator (ldavis). No sudo needed for the verify steps;
# the runbook tells you when sudo is required.
#
# Pre-req: download IDriveForLinux.deb from
#   https://www.idrive.com/online-backup-linux
# and install it: sudo apt install ./IDriveForLinux.deb

set -uo pipefail

echo "================ install-idrive-on-kodiak.sh — $(date) ================"
echo
echo "Per ADR-005 (2026-05-31 update). This helper VERIFIES the iDrive"
echo "Linux toolkit is installed and prints the runbook for the headless"
echo "setup CLI. It does NOT install the .deb itself — that's an apt"
echo "step the operator runs once."
echo

# ---- 1. Package installed? --------------------------------------------------
echo "→ checking idriveforlinux package..."
if dpkg -l idriveforlinux >/dev/null 2>&1; then
    VERSION=$(dpkg -l idriveforlinux 2>/dev/null | awk '/^ii/ {print $3}')
    echo "  ✓ idriveforlinux $VERSION installed"
else
    cat >&2 <<EOF
  ✗ idriveforlinux package not installed.

  Install it first:
    1. Download from https://www.idrive.com/online-backup-linux
       (Linux Backup → Debian/Ubuntu → IDriveForLinux.deb)
    2. sudo apt install ./IDriveForLinux.deb
       (Brings in 25 dependencies including redis-server, python3-dev, etc.)
    3. Re-run this script.
EOF
    exit 1
fi

# ---- 2. Scripts toolkit present? --------------------------------------------
echo "→ checking the CLI toolkit (the headless entry point)..."
MISSING=()
for path in \
    /opt/IDriveForLinux/bin/idrive \
    /opt/IDriveForLinux/idriveIt/idevsutil \
    /opt/IDriveForLinux/idriveIt/idevsutil_dedup \
; do
    if [ ! -x "$path" ]; then
        MISSING+=("$path")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    cat >&2 <<EOF
  ✗ CLI toolkit incomplete — these executables are missing:
$(printf '      %s\n' "${MISSING[@]}")

  This usually means the .deb didn't fully unpack. Try:
    sudo dpkg-reconfigure idriveforlinux
  Or reinstall the .deb.
EOF
    exit 1
fi
echo "  ✓ /opt/IDriveForLinux/bin/idrive (the menu CLI — 18 MB binary)"
echo "  ✓ /opt/IDriveForLinux/idriveIt/idevsutil_dedup (the worker — script target)"

# Permissions audit (the .deb is loose by default)
echo "→ checking permissions on iDrive's config tree (the .deb is loose by default)..."
LOOSE=()
for p in /opt/IDriveForLinux/idriveIt /opt/IDriveForLinux/idriveIt/user_profile; do
    if [ -d "$p" ]; then
        MODE=$(stat -c '%a' "$p")
        if [ "$MODE" != "700" ] && [ "$MODE" != "755" ]; then
            LOOSE+=("$p  mode=$MODE")
        fi
    fi
done
if [ ${#LOOSE[@]} -gt 0 ]; then
    echo "  ⚠ loose permissions found (world-writable or worse):"
    printf '    %s\n' "${LOOSE[@]}"
    echo "    Tighten AFTER first interactive setup completes (account creds end up here):"
    echo "      sudo chmod -R go-rwx /opt/IDriveForLinux/idriveIt"
    echo "      sudo chown -R root:root /opt/IDriveForLinux/idriveIt"
else
    echo "  ✓ idriveIt/ perms look reasonable"
fi

# ---- 3. Scheduler service? --------------------------------------------------
echo "→ checking idrivecron.service (scheduler daemon)..."
if systemctl list-unit-files idrivecron.service >/dev/null 2>&1; then
    STATUS=$(systemctl is-enabled idrivecron.service 2>/dev/null || echo "disabled")
    ACTIVE=$(systemctl is-active idrivecron.service 2>/dev/null || echo "inactive")
    echo "  ✓ idrivecron.service: $STATUS, $ACTIVE"
    if [ "$STATUS" = "disabled" ]; then
        echo "    (will be enabled after interactive setup configures backup sets)"
    fi
else
    echo "  ⚠ idrivecron.service not visible to systemd — may need a daemon-reload"
    echo "    sudo systemctl daemon-reload"
fi

cat <<'EOF'

================ verification complete — toolkit is ready ================

NEXT — interactive setup via the menu CLI:

  sudo /opt/IDriveForLinux/bin/idrive

Walk through the menu prompts:
  1. Login → enter iDrive account email (lynchdavis0@gmail.com) and
     the IDRIVE account password (not the gmail app password).
  2. Encryption → CHOOSE "Private Encryption Key" (NOT Default).
     Copy the generated key into 1Password immediately as
     "kodiak iDrive private key". Unrecoverable if lost.
  3. Backup sets — define four per ADR-005:
       photos     → /kodiak00/backups-00/idrive-staging/photography
       documents  → /kodiak00/backups-00/idrive-staging/archive
                    (with each non-photography subdir included)
       active     → /kodiak00/backups-00/idrive-staging/active
       hosts      → /kodiak00/backups-00/hosts
                    (this one doesn't need the staging clone — hosts/*
                     datasets are normally mounted, no recv conflict)
     NB: the saratoga subset paths are inside backups-00/idrive-staging/,
     which is the snapshot-clone target (NOT the live A1 replica). The
     live datasets stay unmounted to keep TrueNAS push replication
     working. The clones get refreshed daily by bin/idrive-refresh-clones.sh
     (TBD, future commit).
  4. Schedule → daily, sometime after sanoid autosnaps land (post-02:30 is fine).

AFTER SETUP:

  # Tighten config perms (the package leaves some files chmod 666 — bad)
  sudo find /etc/idrive*.json -exec chmod 600 {} \;
  sudo chmod 700 /root/.IDrive 2>/dev/null
  sudo chown -R root:root /root/.IDrive 2>/dev/null

  # Enable + start the scheduler
  sudo systemctl enable --now idrivecron.service
  sudo systemctl status idrivecron.service

FIRST PUSH (manual, ~24-72h on residential upload):

  # The scheduler will fire it on its next cycle, but you can also kick
  # it manually right after setup. Two options — use whichever the
  # interactive menu shows you:
  #
  # via the menu CLI (recommended — same prompts you used for setup):
  sudo /opt/IDriveForLinux/bin/idrive
  #   (pick "Backup" → "Backup now" → choose the set)
  #
  # via direct worker invocation (scriptable; the schedule daemon uses this):
  sudo /opt/IDriveForLinux/idriveIt/idevsutil_dedup --backup --setname photos
  # ... repeat per set
  # Run --help on idevsutil_dedup to see the actual flag list for v1.7.0.

CRITICAL — back up the encryption key NOW:
  Whatever path iDrive saved it to (typically under /root/.IDrive/),
  copy the key content into 1Password. The Private Key option means
  iDrive cannot decrypt your data — including for restore. Lose this
  key = lose access to the backup. Belt-and-suspenders: save in
  1Password AND a printed copy somewhere physical.

================ done — see ADR-005 for the full architecture ================
EOF

#!/usr/bin/env bash
# install-idrive-on-kodiak.sh — set up the iDrive Personal Linux client
# on kodiak as the off-site relay (per ADR-005).
#
# This is a HELPER, not a fully automated install. iDrive's installer is
# interactive (asks for account email, password, encryption-key choice,
# backup set definitions). The script handles what can be safely
# scripted — download, extract, prereq checks, post-install template —
# and hands off to iDrive's installer for the rest.
#
# Run as the operator (ldavis). Uses sudo where it needs to (install
# location is /opt/idrive/, credentials end up under ~root/.).
#
# Usage:
#   bash bin/install-idrive-on-kodiak.sh

set -euo pipefail

IDRIVE_DOWNLOAD_URL="https://www.idrive.com/downloads/linux/download/idriveforlinux.bin.gz"
INSTALL_DIR="/opt/idrive"
DOWNLOAD_DIR="/tmp/idrive-install-$(date +%Y%m%d)"

echo "================ install-idrive-on-kodiak.sh — $(date) ================"
echo
echo "Per ADR-005. This script handles the wrapper steps; you'll be"
echo "prompted by iDrive's installer for the interactive parts (account"
echo "email, password, encryption-key choice)."
echo

# ---- 0. Pre-flight ----------------------------------------------------------
echo "→ pre-flight checks..."

# Required tools for the install/wrapper
for cmd in curl gzip perl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  ERROR: required tool '$cmd' not in PATH" >&2
        exit 1
    fi
done
echo "  ✓ curl, gzip, perl available"

# Storage check — installer wants a few hundred MB
AVAIL_OPT=$(df -BM /opt | awk 'NR==2 {gsub(/M/,"",$4); print $4}')
if [ "$AVAIL_OPT" -lt 500 ]; then
    echo "  ERROR: /opt only has ${AVAIL_OPT}M free; iDrive needs more" >&2
    exit 1
fi
echo "  ✓ /opt has ${AVAIL_OPT}M free"

# Mount check — must be able to read what we'll be backing up
echo "  ZFS mount status of saratoga subtree (iDrive needs these mounted):"
zfs get -H mounted backups-00/saratoga/tank/archive 2>/dev/null \
    | awk '{ printf "    %-50s %s\n", $1, $3 }'
echo
echo "    If 'mounted' is 'no' here, run (BEFORE the iDrive install):"
echo "      sudo zfs set canmount=on backups-00/saratoga/tank/archive"
echo "      sudo zfs mount -a"
echo "    Watch the next A1 replication cycle — if it fails citing"
echo "    'cannot unmount', fall back to the snapshot-clone approach"
echo "    documented in ADR-005."
echo

# Confirm with the operator before proceeding (this step takes a while)
read -r -p "Continue with download + extract? (yes/no): " GO
if [ "$GO" != "yes" ]; then
    echo "aborted by operator." >&2
    exit 1
fi

# ---- 1. Download ------------------------------------------------------------
mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"

echo
echo "→ downloading iDrive Linux client to $DOWNLOAD_DIR ..."
if [ -f idriveforlinux.bin.gz ]; then
    echo "  (download already present; reusing)"
else
    curl -fLO "$IDRIVE_DOWNLOAD_URL"
fi
ls -lah idriveforlinux.bin.gz

# ---- 2. Extract -------------------------------------------------------------
echo
echo "→ extracting installer ..."
gunzip -k -f idriveforlinux.bin.gz
chmod +x idriveforlinux.bin
ls -lah idriveforlinux.bin

# ---- 3. Run iDrive's installer (INTERACTIVE — hands off control) -----------
echo
echo "================ HANDING OFF TO IDRIVE'S INSTALLER ================"
echo
echo "iDrive's installer is interactive. It will ask for:"
echo "  • Account email (lynchdavis0@gmail.com)"
echo "  • Account password"
echo "  • Private encryption key — CHOOSE 'PRIVATE KEY' OPTION."
echo "    The default 'Default key' lets iDrive read your data on their"
echo "    servers; private key keeps the data encrypted to a key only"
echo "    you have. **THIS KEY IS NOT RECOVERABLE** — store a copy in"
echo "    1Password (or equivalent) before completing the install."
echo "  • Install location — accept default ($INSTALL_DIR) or override."
echo
echo "After install, this script will print the post-install template"
echo "(backup sets to define + the cron-entry shape)."
echo

read -r -p "Ready to launch iDrive installer? (yes/no): " GO
if [ "$GO" != "yes" ]; then
    echo "aborted at installer step. Re-run the script to resume." >&2
    exit 1
fi

sudo ./idriveforlinux.bin

# ---- 4. Post-install template ----------------------------------------------
cat <<EOF

================ post-install configuration template ================

iDrive's installer should have created the daemon under /opt/idrive
(or wherever you accepted). Verify with:

    /opt/idrive/IDrive --version
    /opt/idrive/idevsutil_dedup --help   # the CLI we'll script against

CONFIGURE BACKUP SETS (per ADR-005):

    Set 1: "photos"
      Source: /kodiak00/backups-00/saratoga/tank/archive/photography/
      Approx: 1.61 TB

    Set 2: "documents"
      Sources (one set or one each — your call):
        /kodiak00/backups-00/saratoga/tank/archive/books/
        /kodiak00/backups-00/saratoga/tank/archive/employers/
        /kodiak00/backups-00/saratoga/tank/archive/finance/
        /kodiak00/backups-00/saratoga/tank/archive/legal/
        /kodiak00/backups-00/saratoga/tank/archive/medical/
        /kodiak00/backups-00/saratoga/tank/archive/personal/
        /kodiak00/backups-00/saratoga/tank/archive/writing/
        /kodiak00/backups-00/saratoga/tank/archive/software/
      Approx: ~10 GB combined

    Set 3: "active"
      Source: /kodiak00/backups-00/saratoga/tank/active/
      Approx: ~520 MB

    Set 4: "hosts"
      Source: /kodiak00/backups-00/hosts/
      Approx: ~17 GB (growing as we onboard hosts)

    INTENTIONALLY OMITTED (re-buyable, not worth quota):
      /kodiak00/backups-00/saratoga/media/   (music + audiobooks)
      /kodiak00/backups-00/saratoga/tank/scratch/
      /kodiak00/backups-00/repos/   (already on github + bitbucket)

FIRST PUSH (manual, ~24-72h on residential upload):

    sudo /opt/idrive/idevsutil_dedup --backup --setname "photos"
    # ... repeat per set, or run them all if iDrive supports a batch flag

ADD CRON (after first push completes successfully):

    Add to ldavis's crontab (configs/cron/ldavis-crontab):
      # Daily 03:00 — iDrive off-site push (kodiak)
      0 3 * * * /home/ldavis/development/server-backups/bin/idrive-push.sh

    Then: crontab configs/cron/ldavis-crontab

NEXT IMPLEMENTATION SLICES (still to do):

    - bin/idrive-push.sh                # wraps idevsutil_dedup, handles
                                        # all configured sets, cron-safe
    - tests/idrive-freshness.sh         # restore-drill equivalent
    - doc/CREDENTIALS.md update         # iDrive account + encryption key
    - GAPS.md §1.2 marked closed        # after first restore drill passes
    - Decommission workstation device   # via iDrive web UI

CRITICAL — back up your encryption key NOW:
  The private key is NOT RECOVERABLE if lost. Whatever location iDrive
  saved it to, also copy it into 1Password or equivalent. Without the
  key, your backed-up data is unrecoverable.

================ done — see ADR-005 for the full plan ================
EOF

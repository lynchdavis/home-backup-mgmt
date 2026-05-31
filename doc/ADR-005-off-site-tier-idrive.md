# ADR-005: Off-site tier — iDrive Personal, kodiak-driven

**Status:** Proposed, 2026-05-27.
**Closes:** `doc/GAPS.md` §1.2 (zero off-site copy).
**Builds on:** ADR-004 (kodiak-side service-user model — `tourbillon` runs the on-site backup; this ADR adds an off-site relay layer on top).
**Pairs with:** existing iDrive Personal subscription (Yearly 5 TB, ~$100/year, renewed 2025-10-14).

---

## Context

GAPS.md §1.2 — zero off-site copy — is the largest remaining "single catastrophic failure mode" in the backup system. Today everything lives in one physical location: saratoga (source), kodiak (DR + host mirrors + repo mirrors), both at the operator's home. Fire/flood/theft/ransomware = total loss except whatever's still on github/bitbucket and external cloud services.

Historical off-site flow (pre-tourbillon):

```
saratoga ── SMB mount ──► workstation ── iDrive Personal client ──► iDrive
                              │
                              └── /kodiak00/data-00/photography (staging)
                              └── /kodiak00/data-00/backups/host-backups/saratoga/photography (older copy)
```

This worked but had drawbacks:
- Workstation had to be on for backups to run.
- `/kodiak00/data-00/` accumulated a parallel staging copy of much of saratoga (~625 GB + ~1.5 TB), now redundant with the A1 kodiak ZFS replica.
- The relay added a hop where nothing benefited from being relayed.

Post-tourbillon, kodiak holds a complete on-site copy of everything via A1 (saratoga DR) + A2 (repos + hosts). Pushing off-site directly from kodiak removes the workstation hop and makes the off-site flow run on the same operational footing as everything else (cron, observability, restore-drill discipline).

---

## Decision

**Install the iDrive Personal Linux client on kodiak**, configure backup sets pointing at a chosen subset of `/kodiak00/backups-00/`, and run it on a daily schedule. Retire the workstation-mount approach.

### Why iDrive Personal (vs e2 / Glacier / B2)

Already-paid 5 TB at ~$20/TB/year, with free retrieval and online (instant) restore. For ~1.7 TB of irreplaceable-subset coverage, no other option is meaningfully cheaper or more flexible:

| Option | Storage | Retrieval | Total for ~2 TB / yr | Lock-in |
|---|---|---|---|---|
| **iDrive Personal (current)** | ~$20/TB/yr | Free | $100/yr (paid) | Proprietary client; per-device folders |
| iDrive e2 (S3-compat) | ~$60/TB/yr reserved | Standard egress | ~$130/yr | Low (S3 API) |
| AWS Glacier Deep Archive | ~$48/TB/yr | ~$0.02/GB + per-request | $96/yr + restore surprises | Medium |
| Backblaze B2 | ~$60/TB/yr | First 3× free egress | ~$130/yr | Low (S3 API) |

Personal is the right call **for the current volume + use case**. If iDrive Personal removes the Linux client or otherwise becomes hostile, B2 + rclone is the natural off-ramp; the on-disk layout of what we'd push is already compatible (just files in directories — no iDrive-specific format).

### Why kodiak only (not also saratoga)

1. Kodiak already holds a complete A1 replica of saratoga. Pushing from kodiak covers the same content with one device, one subscription, one push pipeline.
2. TrueNAS SCALE's Cloud Sync Task supports S3 / B2 / Drive / etc. natively but **not iDrive Personal** (proprietary protocol). Running iDrive Personal on TrueNAS would need container hackery; not worth the friction.
3. Splits the work along the natural boundary: kodiak owns "back up to off-site" as a follow-on to "back up to ZFS pool."

### Backup-set scope (initial)

Pushed to iDrive:

- `/kodiak00/backups-00/saratoga/tank/archive/photography/` — **1.61 TB**. The single most-irreplaceable subset. Photos including iCloud library.
- `/kodiak00/backups-00/saratoga/tank/archive/{books,employers,finance,legal,medical,personal,writing,software}/` — **~10 GB**. The non-photo archive (financial/legal/medical/personal docs).
- `/kodiak00/backups-00/saratoga/tank/active/` — **~520 MB**. Currently-being-edited material.
- `/kodiak00/backups-00/hosts/` — **~17 GB now, growing**. Per-host /home + /etc mirrors (the bytes that don't exist anywhere else).

**Not pushed (initially):**

- `/kodiak00/backups-00/saratoga/media/` (428 GB music + audiobooks) — re-buyable from Apple Music / OpenAudible; not worth the quota.
- `/kodiak00/backups-00/saratoga/tank/scratch/` — explicitly scratch.
- `/kodiak00/backups-00/repos/` (284 MB) — already on github + bitbucket; tertiary redundancy not worth the operational complexity. May revisit.

**Total initial off-site footprint**: ~1.65 TB. Fits in 5 TB plan with ~3 TB headroom for growth.

### Schedule + observability

- **Daily push** via cron (analogous to A1's daily cadence). Specific time TBD; sometime in the small hours after A1 replication has landed fresh snapshots.
- **`tests/idrive-freshness.sh`** (future) — verifies a recent file from the iDrive backup is restorable (matching `tests/restore-drill.sh` for host backups). Same shape: sha256-anchored verification.
- **Failures**: iDrive client logs to a file under its install dir; cron-mail via the existing msmtp setup (ADR-action 4.3) so failures hit the operator's gmail.

---

## The mount question (canmount=noauto on saratoga datasets)

PLAYBOOK §3 set `backups-00/saratoga/*` to `canmount=noauto` because TrueNAS-side `zfs recv -F` tries to unmount the destination and fails on Linux when run as the non-root `tnreplicate` user. As a result, the saratoga datasets are *not auto-mounted* — the data is in the dataset (`zfs list` shows 1.61 TB), but the filesystem path is empty until something `zfs mount`s it.

This matters for iDrive: the client scans files via the filesystem, not via `zfs send`. The data needs to be mountable.

**Approach** (chosen for simplicity; will be revisited if recv breaks):

- Set `canmount=on` on the **specific saratoga subpaths the iDrive client needs to read** (the archive + active subtrees, not the parent). Children of the parent are independent at the ZFS layer; `zfs recv -F` on the parent ought not to touch a mounted child unless the snapshot itself changes the child's filesystem state.
- Mount them: `sudo zfs mount backups-00/saratoga/tank/archive` (recursive). Persistent across reboots due to `canmount=on`.
- **Watch for A1 replication failures** for the next few cycles. If TrueNAS reports a `zfs recv` failure citing the unmount issue, fall back to a snapshot-clone approach (clone a recent autosnap, mount the clone, iDrive reads from the clone; rotate clones daily).

### Update 2026-05-31 — the simple approach DID break A1, after a few days of working

The simple "just mount the datasets" approach above worked for several days, then A1 replication failed at the 2026-05-31 02:00 run with both tank and media in ERROR state. Recovery: `zfs unmount` every saratoga dataset (deepest-first; ZFS-on-Linux has no recursive `-R` flag), set `canmount=noauto` on all the children (not just the parent), and the next 02:00 replication succeeded normally.

**Confirmed lesson**: mounted saratoga datasets + `zfs recv -F` are incompatible when the recv runs as the non-root `tnreplicate` user. The PLAYBOOK §3 rationale (`canmount=noauto` everywhere under `backups-00/saratoga`) is correct and load-bearing; the iDrive integration must not break this invariant.

**Decision**: the snapshot-clone fallback below is the right approach. When iDrive setup resumes, do NOT mount the live saratoga datasets. Clone a recent sanoid autosnap, mount the clone, point iDrive at the clone; rotate the clone after each daily replication+sanoid cycle so iDrive always sees roughly day-old-or-fresher data without conflicting with live replication.

**Snapshot-clone fallback (kept in our back pocket, not used unless needed):**

```bash
# Take advantage of the existing sanoid daily autosnaps:
LATEST=$(zfs list -H -o name -t snapshot backups-00/saratoga/tank/archive/photography | tail -1)
sudo zfs clone "$LATEST" backups-00/idrive-staging/photography
# iDrive backs up from /kodiak00/backups-00/idrive-staging/photography
# Daily rotation: destroy old clone, create new from the latest snapshot
```

---

## Mechanics

### Initial install (one-time on kodiak)

`bin/install-idrive-on-kodiak.sh` (a helper, not a fully automated install — iDrive's setup is interactive). It will:

1. Download the iDrive Linux client from `https://www.idrive.com/online-backup-linux` (current versioned tarball).
2. Extract to `/opt/idrive/`.
3. Run the iDrive installer (interactive — prompts for account email + password + private encryption key).
4. Print the post-install configuration template — which backup sets to add, what cadence.

The script doesn't try to script through iDrive's installer prompts; those prompts will change, and getting them wrong costs more than typing them. The script's job is the wrapper (download, extract, post-install template).

### Daily backup invocation

Once configured, daily backup is one command:

```bash
/opt/idrive/idevsutil_dedup --backup --enc-key ~/idrive.key <backup-set-name>
```

Wrapped in a small `tests/`-style script that:
- Sources the env (account/key path)
- Invokes the client
- Reports a one-line success or stderr on failure (cron-mail-friendly)

### Credential storage

- iDrive account email + password: stored at `~root/.idrive/auth` (mode 600). Owned by root because iDrive's client wants root for the install. Documented in `doc/CREDENTIALS.md`.
- Private encryption key: stored at `~root/idrive.key` (mode 600). **CRITICAL**: lose this key = lose access to all encrypted data on iDrive. Documented in CREDENTIALS.md as the one file that absolutely needs to be in 1Password / external password manager too.

---

## Consequences

### Good

- **GAPS.md §1.2 closes**. Off-site coverage for the irreplaceable subset, automated.
- **Workstation no longer in the backup path**. Workstation can be off; iDrive push still happens.
- **One subscription, one push pipeline, one observability point.** Failures land via msmtp in the operator's gmail.
- **iDrive Personal cost-of-coverage is already paid for**. No additional spend.

### Costs

- **Mount strategy is a new operational concern** (the canmount discussion above). If it breaks A1 replication, we have to fix it.
- **Initial sync is long** (24-72 hours of upload for ~1.7 TB on residential upload). During this window, off-site coverage is partial.
- **Two iDrive devices during transition** — workstation's old device folder + kodiak's new one — consume quota together until cleanup. Should fit in the 5 TB plan but worth checking the dashboard.
- **iDrive proprietary protocol** — vendor lock-in. Migration off iDrive (to B2 + rclone, say) is a non-trivial reshape, but the data shape doesn't change so the migration is mostly "configure a different tool."
- **iDrive Personal Linux client is third-party closed-source** — the trust assumption is that iDrive's binaries aren't malicious. Acceptable for personal infra; would be different in an enterprise threat model.

---

## Transition plan (from workstation-pushed to kodiak-pushed)

The goal is **continuous off-site coverage during the cutover** — no window where new data has no off-site copy.

1. **Audit current iDrive quota**: log into iDrive web UI, note current Used / 5 TB total. Confirm there's headroom for both devices for ~1 week (~3 TB combined? probably fine).
2. **Disable workstation's iDrive client scheduler** — stop new pushes from workstation. Existing iDrive data REMAINS (don't delete yet).
3. **Install iDrive client on kodiak** via `bin/install-idrive-on-kodiak.sh`. Register as a new device "kodiak."
4. **Configure backup sets** per the scope above. Run the first push manually; let it complete (24-72h).
5. **Verify in iDrive web UI**: kodiak's device folder shows the expected file count + total size.
6. **Run a restore drill from iDrive**: pick a small file, restore via web UI or the client, sha256-match against kodiak's local copy.
7. **Add the daily cron entry** (after the first manual push confirms the path works).
8. **Decommission the workstation device on iDrive**: web UI → Manage Devices → workstation → Delete. Frees that quota. Workstation client can stay installed but inactive; or fully uninstall.
9. **Reclaim `/kodiak00/data-00/photography` and `/kodiak00/data-00/backups/host-backups/saratoga/photography`** — both already marked verified-redundant in `data-organizer/MIGRATION-CHECKLIST.md`. Frees ~2.1 TB on sdc.

If kodiak's initial sync fails partway, workstation's data on iDrive is still the off-site copy. Roll back = re-enable workstation's iDrive scheduler.

---

## Alternatives considered

1. **iDrive e2 + restic from kodiak.** Better technical fit (S3 API, client-side encryption, full restore-test discipline), but ~$30-50 more per year and adds operational complexity. Deferred to a future ADR if iDrive Personal becomes problematic.
2. **TrueNAS Cloud Sync to B2 or e2 from saratoga.** Splits the off-site work across both machines. Cleaner per-machine responsibility but doubles the install footprint and creates two off-site monitoring chains. Worth revisiting if saratoga starts holding data that kodiak doesn't.
3. **Glacier Deep Archive for the photo archive.** Cheapest per-TB *storage* but punitive retrieval costs and 12-48h restore latency make it a bad fit for backups you might actually want to restore.
4. **Status quo (workstation push).** Rejected. The workstation-as-relay is the source of the dependency we're trying to remove.
5. **Two-tier strategy**: iDrive Personal for hot retrievable subset + Glacier Deep Archive for cold archive. Operationally complex; cost savings small at this volume. Defer.

---

## Future / out of scope

- **`tests/idrive-freshness.sh`** — verification script (mirror-on-kodiak hash == restored-from-iDrive hash). Will be added after the first successful sync.
- **Capacity trending alarm** for iDrive quota — mail when usage crosses 80%. Pairs with the on-site capacity alarm queued in GAPS §3.1.
- **Multi-cloud diversification** — if iDrive ever has a multi-month outage, having a parallel B2 destination would matter. Not worth setting up before there's a reason.
- **Restore drill cadence** — like `tests/restore-drill.sh` for hosts, the iDrive drill should run periodically. Decide cadence once the system is live.

---

## Implementation slices

1. **ADR-005 (this doc)**.
2. **`bin/install-idrive-on-kodiak.sh`** — download + extract + post-install template.
3. **Mount the saratoga archive subtree** (`canmount=on` + `zfs mount`); verify A1 replication still works.
4. **Run the iDrive installer interactively**; configure backup sets per the scope above.
5. **First manual sync**; wait for it to complete; confirm in iDrive web UI.
6. **Restore drill from iDrive** (pick a small file, sha256-verify).
7. **Daily cron entry** to invoke iDrive backup.
8. **Decommission workstation device** on iDrive.
9. **Reclaim `/kodiak00/data-00/*` redundant subtrees** per the migration checklist.
10. **`doc/CREDENTIALS.md`** updates: iDrive account creds + private encryption key entry.
11. **`doc/GAPS.md` §1.2** marked closed.

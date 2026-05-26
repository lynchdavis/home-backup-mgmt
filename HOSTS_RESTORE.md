# HOSTS_RESTORE

How to get data back from the host-backup mirrors on kodiak. Companion to `SARATOGA_RESTORE.md`.

**Scope:** restoring from `/kodiak00/backups-00/hosts/<hostname>/...` — the rsync mirrors tourbillon pulls from each host (multi-user linux, single-user Mac/Windows). The two modes share the same restore mechanics; what differs is small (file ownership semantics — see "Mode notes" below).

**Not in scope:** restoring the host's *system state* (installed packages, system services, partition layout). Per ADR-002, the explicit design choice was "linux is rebuildable from packages; the irreplaceable bytes are in user homes." Recovery starts with a fresh OS install + package reinstall, then we restore from the mirror.

---

## Mental model — three safety nets

In order of preference, fastest to slowest:

1. **The host's own filesystem** — if the file is still there, just open it. (Yes, this happens.)
2. **A kodiak-side ZFS snapshot** — sanoid keeps 30 days of daily snapshots on `backups-00/hosts/*`. Each snapshot is read-only and browsable in place via the `.zfs/snapshot/` magic directory.
3. **The kodiak-side live mirror** — `/kodiak00/backups-00/hosts/<hostname>/...` reflects the host's state as of the last successful sync.

For most restore needs, layers 2 + 3 are equivalent (the mirror IS the most recent snapshot's content). The snapshot history is what gets you point-in-time recovery beyond "what's the latest."

---

## Scenario 1 — single file recovery (most common)

Cost: 10 seconds. Risk: none.

### Latest version (from the live mirror)

```bash
# On kodiak, find the file:
ls /kodiak00/backups-00/hosts/<hostname>/home/<user>/<path-to-file>

# Pull it back to the host:
scp /kodiak00/backups-00/hosts/<hostname>/home/<user>/<path-to-file> \
    <user>@<hostname>:<destination>
```

Or copy it to a temp location and let the operator move it manually — saves needing remote write permission.

### Older version (from a snapshot)

```bash
# List available snapshots for this host:
zfs list -t snapshot -r backups-00/hosts/<hostname>

# Browse a specific point-in-time:
ls /kodiak00/backups-00/hosts/<hostname>/.zfs/snapshot/autosnap_2026-05-25_00:00:00_daily/home/<user>/

# Pull the file from that snapshot:
scp /kodiak00/backups-00/hosts/<hostname>/.zfs/snapshot/<snapname>/home/<user>/<path> \
    <user>@<hostname>:<dest>
```

The `.zfs/snapshot/` directory is read-only and exists across the whole dataset hierarchy. You can browse any snapshot like a normal directory.

---

## Scenario 2 — directory tree recovery

Cost: minutes (depending on size). Risk: none if you stage to a side path first.

### From the live mirror

```bash
# On kodiak: rsync a directory tree back to the host (read-only on source side)
rsync -avHAX \
  -e "ssh -i ~/.ssh/id_ed25519_tourbillon_<hostname>" \
  /kodiak00/backups-00/hosts/<hostname>/home/<user>/<dir>/ \
  <ssh_user>@<hostname>:/tmp/restore-<dir>/

# Then on the host, the operator manually moves/merges /tmp/restore-<dir>/
# into the live location. Staging to /tmp/ first avoids accidentally
# overwriting newer files in place.
```

Where `<ssh_user>` is `tourbillon` (multi-user mode) or the operator's user (single-user mode). The same key tourbillon uses for the sync works for the restore direction.

### From a snapshot

Same command, just point the source at the snapshot subdir:

```bash
rsync -avHAX \
  -e "ssh -i ~/.ssh/id_ed25519_tourbillon_<hostname>" \
  /kodiak00/backups-00/hosts/<hostname>/.zfs/snapshot/<snapname>/home/<user>/<dir>/ \
  <ssh_user>@<hostname>:/tmp/restore-<dir>/
```

---

## Scenario 3 — host is dead, restore everything to a rebuild

Cost: hours (mostly hardware setup + transfer wall clock).

### Multi-user linux host

1. Stand up new hardware; install OS; install packages.
2. Re-run `bin/bootstrap-tourbillon-user.sh` on the new host (creates `tourbillon` + sudoers + temp password).
3. Re-run `bin/bootstrap-from-kodiak.sh <hostname>` on kodiak. The per-host key on kodiak (`~/.ssh/id_ed25519_tourbillon_<hostname>`) was preserved across the host loss — same key, ssh-copy-id sees an empty `authorized_keys` and pushes it.
4. On kodiak, rsync the mirror back to the new host. Reverse direction, same rsync flag profile:

   ```bash
   sudo rsync -avHAX --numeric-ids \
     -e "ssh -i ~/.ssh/id_ed25519_tourbillon_<hostname>" \
     --rsync-path='sudo /usr/bin/rsync' \
     /kodiak00/backups-00/hosts/<hostname>/home/ \
     tourbillon@<hostname>:/home/

   sudo rsync -avHAX --numeric-ids \
     -e "ssh -i ~/.ssh/id_ed25519_tourbillon_<hostname>" \
     --rsync-path='sudo /usr/bin/rsync' \
     /kodiak00/backups-00/hosts/<hostname>/etc/ \
     tourbillon@<hostname>:/etc/
   ```

   `--numeric-ids` matters here — without it, the restore might map uids back to whatever names exist on the rebuilt host, which can be wrong if the rebuild's `/etc/passwd` doesn't match the original. Numeric uids are the source of truth.

5. Restart services, log in, verify.

**Hand-restoration caveats**:
- The mirror has /home and /etc but NOT all of /etc (some files are excluded — see the excludes file). Specifically nothing under `/var`, `/usr`, `/opt`. Those are package-managed; restored by the package reinstall in step 1.
- If `/etc` wasn't in the per-host `paths` (it's opt-in), restoring `/etc` is a no-op — there's nothing to restore. That's fine; the rebuild from packages produces a stock `/etc`.

### Single-user Mac/Windows host

Same shape, simpler because there's no service account:

1. Fresh OS install. On macOS, also: install whatever apps make the machine yours (App Store + Brew + dmg installs). On Windows, install OpenSSH Server + cwRsync.
2. Re-run `bin/bootstrap-from-kodiak-single-user.sh <hostname> <user>` to re-deploy the per-host key.
3. rsync the mirror back. No sudo, no `--rsync-path` wrapper — the user reads their own home directly:

   ```bash
   rsync -avHAX \
     -e "ssh -i ~/.ssh/id_ed25519_tourbillon_<hostname>" \
     /kodiak00/backups-00/hosts/<hostname>/Users/<user>/ \
     <user>@<hostname>:/Users/<user>/
   ```

   (Path conventions: `/Users/` for macOS, `/cygdrive/c/Users/` for Windows-via-cwRsync, `/mnt/c/Users/` for Windows-via-WSL.)

4. Restart, log in.

The restore is simpler than multi-user because there's only one user to think about, no `/etc` to bring back, no uid mapping concerns (the user IS the owner of everything in their home).

---

## Mode notes

| | Multi-user (linux + `tourbillon` service account) | Single-user (Mac, Windows, single-user linux) |
|---|---|---|
| Mirror's file ownership | Original source uids/gids (via `--numeric-ids` on the original pull) | Operator's user (rsync ran as them) |
| Restore needs sudo on target | yes (`--rsync-path='sudo /usr/bin/rsync'`) | no |
| What's in the mirror | `/home/*` + optionally `/etc/` | `/Users/<user>/` (or equivalent) — one user's home |

For both modes: the restore *reverses* the rsync direction; everything else (the SSH key, the rsync flag profile, the ssh user) stays exactly as during the original sync.

---

## Confidence-builder — annual test restore

A backup you've never restored from is theoretical. Pick one host's mirror, restore a specific file to `/tmp/`, sha256 it, compare against the source. Five minutes, every year.

```bash
# Pick a stable file (something that doesn't change daily — e.g., a photo or doc).
HOST=arrow-iii
USER=lynch
FILE=Pictures/2026-favorites.jpg

# Get the mirror's copy:
sha256sum /kodiak00/backups-00/hosts/$HOST/home/$USER/$FILE

# Get the live source's copy (via SSH):
ssh tourbillon@$HOST "sha256sum /home/$USER/$FILE"

# Match? Restore mechanic works.
```

---

## What this doc does NOT cover

- Restoring TrueNAS / saratoga — see `SARATOGA_RESTORE.md`.
- Restoring repo mirrors (`backups-00/repos/`) — those are bare git repos; `git clone /kodiak00/backups-00/repos/...` to recover.
- System-state recovery (init scripts, services, packages) — explicitly out of scope per ADR-002. Use the host's package manager.

---

## Quick reference

| Need | Path |
|---|---|
| Latest copy of a file | `/kodiak00/backups-00/hosts/<host>/<path>` |
| Older copy | `/kodiak00/backups-00/hosts/<host>/.zfs/snapshot/<snapname>/<path>` |
| All snapshots for a host | `zfs list -t snapshot -r backups-00/hosts/<host>` |
| Restore a tree (any mode) | `rsync -avHAX ... <source> <user>@<host>:/tmp/restore-...` (stage, then move) |
| Full multi-user host restore | rsync the mirror back as `tourbillon` with `--rsync-path='sudo /usr/bin/rsync'` and `--numeric-ids` |
| Full single-user host restore | rsync the mirror back as the operator's user (no sudo, no `--rsync-path`) |

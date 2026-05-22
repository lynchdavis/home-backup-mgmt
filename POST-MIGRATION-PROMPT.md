# POST-MIGRATION PROMPT — read before working on backup-server

**Date: 2026-05-20.** This file flags a structural change that invalidates
parts of the existing design. Read it before touching `CLAUDE.md`,
`USE_CASES.md`, `TODO.md`, or the code.

## What changed

The original reason this tool existed — a one-shot, pre-migration pull of
saratoga's NFS exports onto kodiak — is **done**. saratoga has since been
wiped and rebuilt:

- **FreeNAS → TrueNAS 25.10.3.1**, clean install (May 2026).
- **saratoga is now SMB-only. It exports NO NFS.** The autofs maps that
  exposed `/saratoga-01/<share>` on kodiak are obsolete — do not restore them.
  `saratoga-pre-migration-state/REENABLE-AUTOFS.md` is a dead letter.
- saratoga is the rebuilt **primary** server (reorganized pools/datasets);
  kodiak is its backup host + staging server.
- saratoga's own disaster recovery is **TrueNAS-native ZFS replication**
  (tank → kodiak, nightly). That is NOT this tool's job.

As-built record of the new saratoga: `saratoga-build.sh` + `saratoga-shares.sh`.
Layout spec: `target-schema.md`. (All in `/home/ldavis/development/data-organizer/`.)

## What this means for backup-server

The tool was architected around NFS. Per `CLAUDE.md` / `USE_CASES.md`:

- **Discovery tier 2 (autofs maps) and tier 3 (`showmount -e`)** only made
  sense for an NFS NAS. The new saratoga has no NFS — this code is dead weight.
  (USE_CASES.md #4 already noted the autofs tier was bypassed for FreeNAS
  ESTALE bugs; that whole problem is now moot.)
- **v1's mission — "saratoga preflight & pull" over NFS** (USE_CASES.md #1-#5)
  — is complete and obsolete. saratoga is no longer an NFS backup subject.
- **SMB "detect only"** (USE_CASES.md #5) was scoped against the NFS-first
  world. Reconsider whether an SMB mode is needed at all.

## What the tool is FOR now

The other half of the original brief (`backup-use-cases.txt`): regular backups
of the **Linux and Mac client hosts**. Those machines have no ZFS and no NFS
exports — they need rsync-based backup. That is now the tool's primary mission.

The transport is **rsync-over-SSH** — formerly phase-2 (USE_CASES.md #7,
TODO.md). It is now the core. With it, **default exclude patterns**
(USE_CASES.md #8) are no longer optional — a home-dir pull without them drags
in caches, VM disk images, and browser data.

### Worked reference — this pattern already ran successfully

In May 2026 a full LynchMBP (Mac) backup was done by hand, exactly along the
lines the tool should automate:

- rsync-over-SSH, kodiak pulling from the Mac.
- `--exclude-from=` a hand-built exclude file.
- Landed at `/kodiak00/data-00/backups/host-backups/2026-05-19-LynchMBP/`.

The exclude file from that run —
`/home/ldavis/development/data-organizer/excludes/lynchmbp.txt` — is a
ready-made starting point for `defaults/excludes.txt`. It already covers
language-toolchain caches, macOS Library cruft, browser caches, VM disk
images, etc.

Lesson worth baking in: macOS ships an old rsync (no `-X` / xattr support).
The tool must drop xattr flags for old remotes or detect remote rsync
capability and adapt.

## Cleanup prompts

> Audit the codebase and docs for NFS / autofs / showmount assumptions. List
> every file and section that assumes saratoga exports NFS. Produce a
> removal/rework plan — do not delete yet.

> Remove the autofs-map discovery tier and the `showmount -e` NFS probe from
> `discovery`. Keep tier-1 config-file discovery. Update `CLAUDE.md`'s
> "Discovery layering" and "Saratoga shares (autofs)" sections to match.

> Rewrite `USE_CASES.md`: v1 use cases #1-#5 describe a completed, obsolete
> NFS mission. Move them to a "Completed / historical" section. Promote
> rsync-over-SSH (#7) and default-excludes (#8) to v1.

> Update `CLAUDE.md` host topology / saratoga sections: saratoga is TrueNAS
> 25.10, SMB-only; its DR is ZFS replication, not this tool.

## Moving-forward prompts

> Make rsync-over-SSH the primary transport. Re-scope discovery to: tier-1
> per-host TOML config + an SSH reachability probe. Drop the NFS tiers.

> Port `/home/ldavis/development/data-organizer/excludes/lynchmbp.txt` into
> the repo as `defaults/excludes.txt`, applied via rsync `--exclude-from=`.
> Support per-host exclude extensions in the host TOML.

> The preflight/execute split, the master index JSON, and the rsync flag
> profile are all still sound — keep them. Only the discovery layer and the
> saratoga-NFS framing need rework.

## Open questions for the rework

- **Where do client-host backups land?** They have been landing on kodiak
  (`/kodiak00/data-00/backups/host-backups/<host>/`). Kodiak likely stays the
  backup host — it also receives saratoga's ZFS replication. Confirm.
- **Is an SMB backup mode needed at all?** Only if some SMB source needs
  backing up that rsync-over-SSH can't reach. Possibly drop SMB entirely.
- **macOS rsync compatibility** — old bundled rsync lacks `-X`. Require a
  modern rsync on the client (`--rsync-path=`) or degrade flags gracefully.

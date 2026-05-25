# Names

## tourbillon

The CLI that watches the backup system: `tourbillon status`, `tourbillon run <target>`, `tourbillon logs <host>`, etc.

A **tourbillon** (French: *whirlwind*) is a watchmaking mechanism patented by Breguet in 1801. The escapement and balance wheel sit in a slowly rotating cage; the rotation averages out gravity's pull on the regulating organ, so positional errors cancel over time instead of accumulating. It exists to keep a watch *true*.

The metaphor: this tool's job is keeping backup state *true* over time — catching drift, surfacing what's aged out, rotating attention to whatever needs it. Not a daemon — invoked, observes, reports. A small mechanism keeping a bigger system honest.

(One footnote on the metaphor: on a modern wristwatch, the mechanical tourbillon is mostly horological theater — chronometer-grade accuracy is achievable without it. *This* tourbillon is expected to earn its name by actually working. The bar is low and we mean to clear it.)

Decided 2026-05-25 after a short detour through `backup-status` and `kodiak-backups` — both functional, neither memorable. Hour was at `backup-status` when the better name arrived; tourbillon won on the merits, though the watchmaking pun helped.

Bonus resonance for the operator's tastes: Steve Miller's *"time keeps on spinning, spinning, into the future"* and The Wheel of Time's cyclical-history conceit (Jordan, finished by Sanderson — see also: irony of history repeating). Same mechanism, different scale.

## backups-00 (the ZFS pool)

Pool that lives on the WD Red 4TB sdb drive, mounted at `/kodiak00/backups-00`. The name and path are a deliberate drop-in for the LVM that occupied that path before the migration. Existing scripts, runbooks, and muscle memory keep working.

The `-00` suffix is vestigial under ZFS — you grow a pool by adding vdevs, not by spawning siblings — but vestigial-but-familiar beat clever-but-new.

## tnreplicate

The dedicated kodiak-side service user that receives TrueNAS Replication Task pushes. Self-documenting: **t**rue**n**as **replicate** target. Not the Debian-default `backup` user (uid 34, owned by the OS for archive snapshots), and not `ldavis` (one human's day-to-day account). Its sole purpose is to terminate `zfs recv` streams on `backups-00/saratoga`.

## kodiak / saratoga

The hosts. Pre-existing names, kept. Saratoga is the NAS; kodiak is the backup host. Both named after places significant to the operator; like good furniture, they don't need explaining and don't get renamed.

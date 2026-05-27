# ADR-004: Kodiak-side service user for A2 (`tourbillon`)

**Status:** Accepted, 2026-05-26.
**Supersedes (in spirit):** the implicit "A2 runs as ldavis" assumption baked into the implementation of ADR-001 and ADR-002 — never an explicit decision, just where the cron entries and SSH keys landed because that's the shell I was working in.
**Pairs with:** the existing `tnreplicate` user (A1 runtime, doc/NAMING.md).

---

## Context

We have three backup subsystems live on kodiak:

| Subsystem | Direction | Kodiak runtime user (prior to this ADR) |
|---|---|---|
| **A1** — saratoga DR (TrueNAS ZFS replication) | push (TrueNAS → kodiak) | **`tnreplicate`** — dedicated service user, owns `/var/lib/tnreplicate`, sole purpose: terminate `zfs recv` streams. |
| **A2-repos** — github + bitbucket mirroring | pull (kodiak → providers) | **`ldavis`** — the operator's interactive account. |
| **A2-hosts** — rsync from linux/mac/windows targets | pull (kodiak → targets) | **`ldavis`** — same. |

For A1 we explicitly decided "the runtime that handles backups should not be the operator's interactive account" — that's why `tnreplicate` exists. (Bonus: `backup`, the obvious name, is taken by Debian default uid 34.)

For A2 the principle was never carried over. The cron entries got added to ldavis's crontab, the per-host SSH keys landed in `~ldavis/.ssh/`, ZFS dataset paths under `/kodiak00/backups-00/{repos,hosts}` ended up owned by `ldavis:ldavis`, and `~ldavis/.config/tourbillon/env` holds the github + bitbucket tokens.

This drifted into being for two reasons:

1. I was building incrementally inside an interactive shell as ldavis, and each commit just used whatever paths already existed.
2. The principle was never stated as a constraint in ADR-002 or ADR-003 — they spoke at length about *target-side* service accounts (multi-user mode) but said nothing about the kodiak side.

The operator surfaced this during the arrow-iii bootstrap session ("we made a decision that ldavis is NOT the user of the backups, didn't we?"). They were right; we just hadn't enforced it.

---

## Decision

**Create a kodiak-side service user `tourbillon` that owns all A2 runtime state.** Symmetric with `tnreplicate` for A1.

### Why `tourbillon` and not a kodiak-specific name

The naming overlap with the *target-side* service user (also `tourbillon`) and the CLI binary (`bin/tourbillon`) is intentional, not a collision:

- **The CLI** (`bin/tourbillon`) is the tool.
- **Kodiak's `tourbillon` user** is what runs the tool — the local end of the backup mechanism.
- **Each target's `tourbillon` user** is what the tool connects *to* — the remote end of the same mechanism.

One concept, three manifestations. Reading `sudo -u tourbillon bin/tourbillon hosts sync` doesn't require knowing two different user names; reading "tourbillon@arrow-iii" doesn't require knowing whether that's a kodiak thing or a target thing. The connection is always tourbillon-to-tourbillon. Simpler mental model than introducing a kodiak-only name.

Considered and rejected:
- **`mainspring`** — fits the watch metaphor (mainspring drives a tourbillon) but adds a name to remember for no gain. We already have kodiak/saratoga/tourbillon/tnreplicate.
- **`tnpull`** — pairs structurally with `tnreplicate` (push receive vs. active pull) but misleading: tourbillon also pulls from github + bitbucket + linux + mac, not just TrueNAS-shaped things.
- **Repurposing `tnreplicate`** — A1's user already exists. Wide-namespacing it to cover all backups muddies its single-purpose naming (per NAMING.md, "Self-documenting: **t**rue**n**as **replicate** target. … Its sole purpose is to terminate `zfs recv` streams"). One-purpose users are easier to reason about, especially when retiring or rotating credentials.

### What moves to `tourbillon`

| Item | From | To |
|---|---|---|
| Token env | `~ldavis/.config/tourbillon/env` | `~tourbillon/.config/tourbillon/env` |
| Per-repo state (40 repos) | `~ldavis/.local/state/tourbillon/repos/` | `~tourbillon/.local/state/tourbillon/repos/` |
| Per-host state | `~ldavis/.local/state/tourbillon/hosts/` | `~tourbillon/.local/state/tourbillon/hosts/` |
| Per-host SSH keys (future) | `~ldavis/.ssh/id_ed25519_tourbillon_*` | `~tourbillon/.ssh/id_ed25519_tourbillon_*` |
| ZFS dataset paths | `/kodiak00/backups-00/{repos,hosts}` owned `ldavis:ldavis` | owned `tourbillon:tourbillon` |
| Cron entries (A2) | ldavis's crontab (`*/30` repos, `5,35` hosts) | tourbillon's crontab |

### What stays with `ldavis`

| Item | Why |
|---|---|
| The git repo (`~/development/server-backups/`) | The operator edits, commits, and pushes from here. tourbillon reads/executes via standard `755`-traverse perms; no need to relocate code. |
| Saratoga env (`~/.config/saratoga/env`) | TrueNAS API token. Used by `tests/check-saratoga-replication.sh`, which is *monitoring* (alerts the operator if A1 stalls), not running backups. |
| `0 8 * * * check-saratoga-replication.sh` cron entry | Same: it's a monitoring job whose output mails the operator. Operator gets the mail; operator's crontab. |

A1's `tnreplicate` user is unaffected: it terminates ZFS replication streams; this ADR has nothing to do with it.

### What goes away (orphaned by the migration)

- `~ldavis/.ssh/id_ed25519_tourbillon_arrow-iii{,.pub}` — the per-host keypair for arrow-iii. Made unusable by the operator's `cleanup-tourbillon-host.sh` run on arrow-iii (the public half is no longer in any authorized_keys file). Will be regenerated fresh under `~tourbillon/.ssh/` when arrow-iii gets re-bootstrapped.

---

## Mechanics

### User creation

```sh
sudo useradd -r -m -d /var/lib/tourbillon -s /bin/bash \
    -c 'kodiak A2 runtime (repos + host pulls)' tourbillon
sudo passwd -l tourbillon   # locked; access only via sudo -u tourbillon
```

System uid (`-r`), real home (`-m`), bash shell (so an operator can `sudo -u tourbillon -s` to debug), password locked. No interactive login — `sudo -u tourbillon` from ldavis is the way in. SSH-into-kodiak-as-tourbillon is intentionally not enabled.

### Cron migration

Both A2 cron entries move from ldavis to tourbillon. `MAILTO=ldavis` preserved on tourbillon's crontab so failure mails still reach the operator. The A1 monitoring entry (`check-saratoga-replication.sh`) stays on ldavis.

### Refactored bootstrap scripts

The operator's surface for adding a new host stays one command, but the script now:

1. Accepts an optional `<ip>` argument: `bin/bootstrap-from-kodiak.sh <hostname> [<ip>]`. If hostname doesn't already resolve and `<ip>` is given, writes `<ip> <hostname>` to `/etc/hosts` (via sudo) before proceeding.
2. Passes `-o StrictHostKeyChecking=accept-new` to `ssh-copy-id` and all subsequent ssh calls. Eliminates the manual `ssh-keyscan` step the operator hit during the arrow-iii session.
3. Runs as `tourbillon` from the start: `sudo -u tourbillon ssh-keygen ...`, key lands in `~tourbillon/.ssh/`, etc.

The target-side script (`bootstrap-tourbillon-user.sh`) is unchanged — runs on the target as root, no network resolution involved.

---

## Consequences

### Good

- **A2 stops sharing blast radius with the operator's interactive account.** A compromise of ldavis (e.g., a malicious VS Code extension, a bad shell history grep) no longer hands the attacker the github + bitbucket API tokens or the per-host SSH private keys for the backup fleet.
- **The kodiak-side architecture is now consistent across subsystems.** A1 has a service user; A2 has a service user. Future subsystems (e.g., M365 calendar backup, photo library mirror) follow the same template.
- **Onboarding a new host is one command** (after this migration): `bin/bootstrap-from-kodiak.sh <name> <ip>` — DNS-or-hosts gets handled automatically, host-key TOFU gets handled automatically, key lands in the right user's home.

### Costs

- **`sudo -u tourbillon` to invoke the CLI manually.** Slightly more typing for the operator. Acceptable for ad-hoc invocations (the common case is cron).
- **Tourbillon needs read access to the repo path** (`/home/ldavis/development/server-backups/`). Relies on default home perms (`/home/ldavis` mode 755). If the operator ever locks down `/home/ldavis` to 700, A2 cron would break with permission-denied. Acceptable; not a realistic risk on a personal workstation.
- **Token env moves to a path the operator no longer owns** (`~tourbillon/.config/tourbillon/env`). To rotate a token: `sudo -u tourbillon vim ~tourbillon/.config/tourbillon/env`. Documented in CREDENTIALS.md.

### Migration window risk

The migration touches: cron entries (brief disable window on ldavis, enable on tourbillon), ZFS dataset ownership (one `chown -R`), and state files (`mv`). None are destructive — at any point during the migration, if something breaks the operator can chown back to ldavis. Existing repo mirror data (`/kodiak00/backups-00/repos/` ~278MB) is untouched in content; only the ownership flips.

---

## Alternatives considered

1. **Keep A2 running as ldavis.** Rejected — inconsistent with A1; flagged by the operator as wrong; bad security shape (operator account holding backup credentials).
2. **Repurpose `tnreplicate` for all backup subsystems.** Rejected — covered above. Single-purpose service users beat multi-purpose ones for personal infra (easier to reason about, retire, rotate).
3. **A new name (`mainspring`, `tnpull`, etc.).** Rejected — covered above. The same name as the CLI and target-side user is a feature, not a collision.
4. **Run A2 in an isolated container/jail (`systemd-nspawn`, podman) instead of as a separate user.** Overkill for the threat model. A separate uid + filesystem ownership gets the compartmentalization payoff at ~10% of the operational complexity. Containerization stays available if the threat model ever sharpens.

---

## Out of scope / future

- **Per-subsystem environments.** A2-repos and A2-hosts both run as `tourbillon` here. If we ever want different blast radius (e.g., repos credentials separate from host SSH keys), split into two service users at that point.
- **PAM/SSH lockdown of the `tourbillon` account.** Currently `passwd -l`'d + no `~/.ssh/authorized_keys`. Could go further (set login shell to `nologin` and require `sudo -u tourbillon -s` to debug — but loses casual operator visibility). Acceptable as-is.
- **Auditd hooks on `/var/lib/tourbillon`.** Out of scope for personal infra.

---

## Implementation slices

1. **ADR-004** (this doc).
2. **Create `tourbillon` user on kodiak**, locked.
3. **Migrate runtime state** from ldavis to tourbillon (env, state, dataset ownership).
4. **Migrate cron entries** (remove from ldavis, install on tourbillon).
5. **Refactor bootstrap scripts** (IP capture, StrictHostKeyChecking=accept-new, run as tourbillon).
6. **Update docs** (CREDENTIALS, CHANGELOG, README, PLAYBOOK; cross-references from ADR-002/003 to here).
7. **Re-bootstrap arrow-iii** under the new model. End-to-end validation that the refactor works for a fresh host.

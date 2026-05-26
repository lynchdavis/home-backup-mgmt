# ADR-003: Host backups — multi-user vs single-user modes

**Status:** Proposed, 2026-05-26.
**Builds on:** ADR-002 (linux host backups, multi-user shape). Generalizes the design to handle Mac + Windows targets, which are essentially single-user systems where a dedicated service account is the wrong shape.
**First targets it enables:** any single-user macOS host (LynchMBP), any Windows host once OpenSSH Server + cwRsync are installed.

---

## Context

ADR-002 designed the linux host backup subsystem assuming each target is a multi-user system. The bootstrap creates a dedicated `tourbillon` service account, grants narrow sudo for `rsync --server`, and backs up `/home/*` so any user's data lands in the mirror.

This is correct shape for the kind of linux machine that's *plausibly* multi-user even if only one person uses it day-to-day. It's the wrong shape for two other classes of host:

- **Mac**: macOS is structurally single-user. Creating a separate `tourbillon` service account would be uncanny — operating system conventions, key locations, and access control all assume "the user is the operator." A dedicated service account costs a lot of setup friction for no architectural payoff.
- **Windows**: same. Windows accounts are heavyweight (registry entries, profile dirs, ACLs). Creating a service account just to read the operator's `C:\Users\<self>\` is overkill. The operator's existing account already has all the access we need.

The operator's existing user account, with a per-host SSH key in their existing `~/.ssh/authorized_keys`, is the natural shape on these platforms.

---

## Decision

### Two modes, one config knob

Per-host configs distinguish modes via a single boolean: **`sudo_required`**.

| Mode | `sudo_required` | What target-side rsync does | When |
|---|---|---|---|
| **Multi-user** (current linux design) | `true` (default) | `sudo /usr/bin/rsync --server …` via `--rsync-path` | Hosts with a dedicated `tourbillon` service account that needs sudo to read `/home/*` |
| **Single-user** (Mac, Windows, single-user linux) | `false` | Plain `rsync --server …` as the operator's own user | Hosts where the user IS the operator and reads their own home directly |

Tourbillon's `rsync_one_path` reads this field and adds (or omits) `--rsync-path='sudo /usr/bin/rsync'` accordingly. No mode-string parsing, no enum — one boolean does the work.

### Declarative defaults

Every settable field appears in `configs/hosts/defaults.toml` with its default value and a one-line comment explaining purpose + override guidance. **No defaults hidden in code.** Operator-readability beats minimalism in personal infra.

This reverses one decision from ADR-002's first implementation: I had `ssh_key` derived in code (`~/.ssh/id_ed25519_tourbillon_<config-name>`) when the field was absent. That violated the principle. Now the default IS in the file, as a template:

```toml
ssh_key = "~/.ssh/id_ed25519_tourbillon_{host}"
```

Tourbillon substitutes `{host}` with the per-host config's basename at runtime. The default is visible; the substitution mechanic is explicit.

### Per-platform exclude files

Three exclude files, one per platform shape:

- `configs/hosts/excludes/linux-user.txt` — multi-user linux hosts. Existing.
- `configs/hosts/excludes/mac-user.txt` — macOS single-user. Ports `~/development/data-organizer/excludes/lynchmbp.txt` wholesale (battle-tested during the migration) and adds tourbillon-specific section header for new additions.
- `configs/hosts/excludes/windows-user.txt` — Windows single-user. Not implemented in this slice; documented as Future Work.

Each per-host config points at the right one via `excludes_file`. The macOS and linux excludes overlap heavily (language toolchains, IDE caches) but are kept separate because the OS-specific sections differ enough that one file with conditional comments would be more confusing than two files with shared content.

### Single-user bootstrap

A wrapper script on kodiak handles the single-user bootstrap end-to-end:

```bash
bin/bootstrap-from-kodiak-single-user.sh <hostname> <existing-user>
```

What it does:
1. Generates `~/.ssh/id_ed25519_tourbillon_<hostname>` if not present.
2. Runs `ssh-copy-id` — pushes the public key into `<existing-user>@<hostname>:~/.ssh/authorized_keys`. Interactive: prompts for the user's existing password.
3. Verifies key-based auth via a `ssh -o BatchMode=yes ... true` check.
4. Prints the per-host config template the operator should put in `configs/hosts/<hostname>.toml`.

No `passwd -l` step — the user's password is the operator's own to keep using interactively. Unlike the multi-user flow's temporary-password-then-lock dance, there's no temporary credential to dispose of.

### Windows readiness

Windows isn't built in this slice — no Windows host exists in the fleet yet. The plan is documented so the moment one comes online, the lift is small. Specifics:

**Pre-requisites on the Windows target** (operator's one-time setup):
- Settings → Apps → Optional Features → **OpenSSH Server**. Toggle on; auto-starts as a Windows service.
- Install **cwRsync** (Cygwin's rsync, MSI installer). Adds `rsync.exe` and exposes Windows paths as `/cygdrive/c/...`. Lighter than WSL2 for a backup-target use case.
- Confirm the operator's user has an existing `C:\Users\<user>\.ssh\authorized_keys` file (create empty if not). Permissions matter — OpenSSH Server is strict about it not being world-readable; use `icacls` if a permission error surfaces.

**Then on kodiak**: same `bootstrap-from-kodiak-single-user.sh` script as Mac. Same per-host config shape, just different `paths`:
```toml
paths = ["/cygdrive/c/Users/lynch"]
excludes_file = "configs/hosts/excludes/windows-user.txt"
```

The expected loss-of-fidelity items (NTFS ACLs, alternate data streams, sub-second timestamps) are accepted — we're backing up content, not booting from the mirror. Captured in the ADR's "Consequences" so it's not a surprise during restore.

---

## Consequences

### Good

- **One boolean covers both modes.** No mode-string parsing, no enum. Tourbillon code stays linear.
- **Defaults are visible** in `defaults.toml`. Operator can edit confidently without re-reading the source.
- **Per-host single-user setup is trivial**: one wrapper script + a tiny per-host config (host + ssh_user + sudo_required=false + paths + excludes_file). No service account, no sudoers, no password dance.
- **Windows is a documented planning checklist**, not a deferred design problem. When a Windows host shows up, the operator follows the checklist.

### Cost

- **Two exclude files (linux-user.txt + mac-user.txt) overlap.** Maintenance cost when a new "skip this language's cache" entry shows up — has to be added to both. Mitigation: write the overlap once as a comment header pointing to the other file.
- **Single-user mode loses uid/gid preservation** in the backup (rsync runs as the user, files are owned by them on the mirror). For single-user platforms this matches reality (one user, no point preserving "different" uids). For Mac/Windows it's a non-issue. For someone trying to use single-user mode on a true multi-user linux box: don't.
- **Bootstrap requires the user's existing password once** (the ssh-copy-id step). On Mac this is the operator's interactive password — typed once, then key-only.

### Neutral but worth naming

- **Single-user `restore` path is straightforward**: kodiak's tourbillon user has the per-host private key, can reverse-rsync to bring data back. Documented in `LINUX_RESTORE.md` (covers all platforms with caveats per platform).
- **No support for the user account being different on different hosts**: e.g., `lynch@mac1` and `ldavis@mac2`. The per-host config's `ssh_user` is exactly the way to handle this — no design impact.

---

## Alternatives considered

1. **Always use a `tourbillon` service account, even on Mac**. Rejected — macOS doesn't reward dedicated service accounts; the user IS the system, and creating a separate one is a fight with conventions for no architectural payoff.
2. **Mode enum (`mode = "multi" | "single"`) instead of `sudo_required` boolean**. Rejected — the *behavioral* difference is whether rsync needs sudo on the target. `sudo_required` says that directly; `mode` indirects through a label that the code has to map back to a behavior anyway.
3. **Single config file per platform** (`defaults-linux.toml`, `defaults-mac.toml`). Rejected — too many files for too little payoff. Per-host config + excludes file pointer covers the variation cleanly.
4. **Make `~/.tourbillon/extras-excludes.txt` mechanism part of v1**. Deferred (see Future Work).

---

## Future work (documented, not built)

### User-controlled excludes via `~/.tourbillon/`

The operator floated this and it's a real future capability. The mechanism:

1. At sync time, before the main rsync, kodiak attempts a small rsync to fetch the file:
   ```
   rsync -q --timeout=5 -e "ssh -i $KEY -o BatchMode=yes" \
     ${SSH_USER}@${HOST}:~/.tourbillon/extras-excludes.txt \
     /tmp/tourbillon-extras-${HOST}.txt 2>/dev/null
   ```
2. If the fetch succeeds: append the contents to the main rsync's exclude list (or pass as a second `--exclude-from`).
3. If the file doesn't exist on the target (`No such file or directory`): silent no-op, proceed with the main rsync.

Cost: one short rsync call per sync per host. Cheap. Lets a user-on-target opt into more aggressive excludes without bothering the operator.

**Why deferred**: for the operator's current fleet, the operator IS the user on every host. Editing `configs/hosts/<host>.toml` in this repo is the same effort as editing `~/.tourbillon/extras-excludes.txt` on the target. The mechanism earns its keep when there's a non-operator user on a target who wants control — which there isn't today.

Implementation slot when needed: ~30 lines of code in `rsync_one_path`, no schema change.

### Windows excludes file

`configs/hosts/excludes/windows-user.txt` — not in this slice. Implementation = when the first Windows host appears. Starting content sketched in the Windows readiness section above; we'll firm it up against a real `C:\Users\` tree the day we onboard.

---

## Implementation plan (slice 4)

1. **Revise `configs/hosts/defaults.toml`** — declarative form, every field listed with a one-line comment + default value. Includes `sudo_required = true` and `ssh_key = "~/.ssh/id_ed25519_tourbillon_{host}"`.
2. **`configs/hosts/excludes/mac-user.txt`** — port `~/development/data-organizer/excludes/lynchmbp.txt` wholesale + macOS-specific additions section.
3. **`bin/tourbillon`** — `resolve_ssh_key()` does `{host}` substitution explicitly (no more code-only default); `rsync_one_path()` honors `sudo_required` (conditionally adds `--rsync-path='sudo /usr/bin/rsync'`).
4. **`bin/bootstrap-from-kodiak-single-user.sh`** — new wrapper script.
5. **`doc/CREDENTIALS.md`** — note the single-user variant: same per-host key model, just no target-side service-account/sudoers (key lives in operator's existing `~/.ssh/authorized_keys`).
6. **CHANGELOG.md** — slice 4 entry.

No actual single-user host needs to exist yet. Code + docs land; first real Mac/Windows host onboards when convenient.

Slice 5 (still on deck): sanoid policy for `backups-00/hosts/*`, cron entry for `hosts sync --quiet`, and `doc/LINUX_RESTORE.md`. Independent of slice 4; works for both multi-user and single-user hosts.

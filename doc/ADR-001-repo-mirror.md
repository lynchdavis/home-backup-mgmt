# ADR-001: Repository mirroring (GitHub + Bitbucket → kodiak)

**Status:** Proposed, 2026-05-25.
**Decision drivers:** the operator has active code in repos on both providers; provider outages or account loss would otherwise mean losing the canonical history. This is the smallest concrete piece of A2 (multi-source backup), and an early opportunity to exercise tourbillon's source abstraction.

---

## Context

Backup the operator's git repositories from GitHub and Bitbucket onto kodiak so the local mirror is independently restorable from either provider's outage, takedown, or account loss.

Specific constraints in this environment:

- Some repos are **actively developed** (need tight cadence — hourly-ish), most are dormant (daily is plenty).
- Repos exist across **two providers**, with no single naming/auth/API model.
- The operator wants **per-repo override**, with sensible defaults so new repos don't require manual configuration to start being mirrored.
- Orphaned local mirrors (upstream deleted) must be **flagged, not auto-pruned** — explicit operator action only.
- Fits into the broader tourbillon model: each "source" exposes status, run-on-demand, logs.

This ADR doesn't pin down tourbillon itself — only the repo-mirror subsystem that tourbillon will eventually surface.

---

## Decision

### Discovery: API-driven, with override files

On each sync cycle, tourbillon queries the providers' APIs to enumerate what *should* be mirrored. The list of repos isn't kept in a hand-maintained file — it's derived from upstream and reconciled against local state.

- **GitHub**: `GET /user/repos?affiliation=owner&per_page=100` (paginate). Default scope = owner-only; collaborator and org-member repos are a config switch (`include_collaborator`, `include_organization`) on the provider settings, off by default.
- **Bitbucket Cloud**: `GET /2.0/repositories/{workspace}` for the operator's personal workspace. (One workspace; resolved 2026-05-25 — if a second workspace ever surfaces, `defaults.toml.bitbucket.workspaces` becomes a list.)

For each repo discovered, tourbillon looks up its config (see below). If no config exists, it auto-creates a minimal one with default values, **commits it**, then proceeds. Auto-created configs are intentionally small (just enough to record "this repo is known to us") so the human-meaningful diff in git history is the moment a new repo entered the system.

### Config: layered, declarative, git-tracked

```
configs/repos/
  defaults.toml                              # global defaults
  {provider}/{owner_or_workspace}/{repo}.toml   # per-repo override (only diffs from defaults)
```

`defaults.toml`:
```toml
interval = "24h"                       # how often to sync
include_collaborator = false
include_organization = false
target_dataset = "backups-00/repos"    # ZFS dataset to live under
on_orphan = "warn"                     # warn | error
```

Per-repo override (only fields that differ from defaults). Example for an active project:
```toml
interval = "1h"
```

Example forcing inclusion of an org repo where the org-wide flag is off:
```toml
include = true   # explicit allow, overrides discovery rules
```

A repo with no per-repo file just inherits everything from `defaults.toml`.

### State: separate, mutable, kodiak-local

```
~/.local/state/tourbillon/repos/
  {provider}/{owner_or_workspace}/{repo}.json
```

Per-repo state file shape:
```json
{
  "first_seen_at":   "2026-05-25T14:00:00Z",
  "last_attempt_at": "2026-05-26T02:01:13Z",
  "last_success_at": "2026-05-26T02:01:48Z",
  "last_duration_s": 35,
  "last_size_bytes": 12345678,
  "upstream_present": true,
  "last_error": null
}
```

State is **never** committed to git. It's per-host mutable; if kodiak's filesystem is lost, state rebuilds from scratch on next sync (no harm — sync always tries the upstream as source of truth).

### Storage: ZFS dataset, bare repos

- Dataset: `backups-00/repos` (`canmount=noauto` like the saratoga datasets; `recordsize=128K` since the workload is many small object files).
- One bare repo per source: `/kodiak00/backups-00/repos/{provider}/{owner}/{repo}.git/`.
- Mechanic: `git clone --mirror <url> <path>` for first sync; `git remote update --prune` for subsequent.
- ZFS snapshot policy: a daily recursive snapshot on `backups-00/repos`, **30-day retention**. Repos churn slowly, so retention is cheap (small deltas per snapshot) — 30 days is generous without being expensive. Easy to extend to 60/90 if we want deeper history later; nothing in the design constrains it.

### Authentication

Bearer tokens for both providers — same shape as the existing TrueNAS API token pattern. No username/password combos, no provider-specific auth shapes to remember.

- **GitHub**: classic PAT with `repo` scope (read-only). Used as a bearer token for the REST API and embedded as `x-access-token` for `git clone`.
- **Bitbucket**: API token (scoped to read access on the personal workspace). Used as a bearer token for the REST API and embedded as `x-token-auth` for `git clone`.
- Both stored separately from the TrueNAS token: `~/.config/tourbillon/env` (separate from `~/.config/saratoga/env` — different blast radius if either is rotated/leaked). Mirrors the `~/.config/saratoga/env` pattern we already use; sourced by tourbillon before any provider call.

```bash
# ~/.config/tourbillon/env  (mode 600, not in git)
export GITHUB_TOKEN='ghp_...'
export BITBUCKET_TOKEN='ATBB...'
```

Git clone URLs constructed at runtime:
```
https://x-access-token:${GITHUB_TOKEN}@github.com/{owner}/{repo}.git
https://x-token-auth:${BITBUCKET_TOKEN}@bitbucket.org/{workspace}/{repo}.git
```

`tourbillon` fails fast (and clearly) if it tries to hit a provider whose token isn't in the environment. (App passwords on Bitbucket Cloud are deprecated and were briefly considered for this design; bearer tokens are the better path and keep our auth model uniform.)

### Orphan handling

Four states the reconciler can find a repo in, and the behavior for each:

| Upstream | Local config | Local mirror | Action |
|---|---|---|---|
| present | present | present | normal sync per interval |
| present | absent | absent | auto-create config from defaults; clone the mirror; commit the new config file |
| present | absent | present | bug (shouldn't happen). Auto-recover by creating config; warn |
| **absent** | **present** | **present** | **ORPHAN warning. Keep local mirror. Skip sync. Never auto-delete.** Operator runs `tourbillon repos prune <name>` to remove explicitly. |
| absent | present | absent | STALE-CONFIG warning. Most likely cause: repo renamed upstream. Surface in status; operator decides — `prune` or rename the config to match. |
| absent | absent | present | UNCATALOGED warning. Most likely cause: human dropped a clone there. Surface, ignore. |

`tourbillon repos status` shows everything; `tourbillon repos issues` filters to just the warnings.

### Cadence and "due"-ness

Each repo has an `interval` (from its config or defaults). A repo is **due** when `now - state.last_success_at > interval`. The sync command walks all known repos and processes due ones in any order. Concurrency = 1 (sequential) for the first version; revisit if it becomes a bottleneck.

Cron entry on kodiak (`ldavis` crontab):
```
# repo mirror: sync any due repos hourly. Hourly granularity supports interval=1h overrides.
*/30 * * * *  . $HOME/.config/saratoga/env && . $HOME/.config/tourbillon/env && $HOME/development/server-backups/bin/tourbillon repos sync --quiet
```

(`saratoga/env` because tourbillon's status display may also touch the TrueNAS API; cheap to source both.)

### Tourbillon surface for repos

```
tourbillon repos status                   # one line per repo: name, last success, age, state, size
tourbillon repos status <name>            # detail for one
tourbillon repos issues                   # only the flagged ones
tourbillon repos sync [--quiet] [--name]  # sync due repos (or one specified); cron-friendly with --quiet
tourbillon repos discover                 # rescan upstream lists; detect new/orphan; don't sync
tourbillon repos prune <name>             # explicit removal of local mirror; requires confirmation
tourbillon repos show <name>              # branches, last-commit-per-branch, sizing
```

---

## Consequences

### Good

- **Idempotent and self-healing.** Re-running `tourbillon repos sync` against a clean kodiak after a disk loss does the right thing: discovers, clones what's missing, picks up where state left off.
- **New repos onboard with zero manual work.** Push a new repo on GitHub; next sync auto-creates the config, clones the mirror, commits the config addition. The git history of `configs/repos/` becomes a passive log of "what came into scope when."
- **Per-repo override is opt-in and minimal.** A repo file only exists when the operator deviates from defaults. Easy to scan what's been hand-tuned.
- **Orphan handling is explicit and reversible.** Never destroys a mirror without the operator typing.
- **ZFS snapshots are the time-machine.** No separate per-repo backup-of-backups; one daily recursive snapshot on `backups-00/repos` covers all of them.

### Bad / costs

- **Auto-committing config additions** makes the cron a writer to git. If the repo has a remote that gets pushed, the operator needs `push` perms set up or accept that the local commits stay local until pushed manually. Mitigation: tourbillon commits to working tree but does NOT push automatically. Operator pushes when ready.
- **API rate limits.** GitHub's authenticated rate limit is 5k req/hr — well clear for an hourly cron with ~50 repos. Bitbucket's per-user limit is similar. Not currently a constraint; flag if either limit changes.
- **Token rotation is a one-time chore.** When a PAT expires, sync silently auth-fails until tourbillon shows the broken-token warning. Mitigation: status display surfaces consecutive auth failures as a separate issue category.

### Neutral but worth naming

- **No mirror-of-mirror.** This is one tier. If kodiak dies AND github+bitbucket both go down, the repos are gone. Acceptable risk for now; the off-site tier is a separate ADR when motivated.
- **No support for non-git providers** (gitea, gitlab, etc.). Adding one is "another `provider/` module"; not preemptively built.

### Not in scope (explicit)

The operator has an existing historical archive at saratoga `tank/archive/RepositoryBackups` — older snapshots of repos collected pre-migration, **not** maintained as a live mirror. That tree:
- Continues to ride along with the saratoga → backups-00 ZFS replication (A1). No special action.
- May contain git-LFS objects, but no updates are being pulled there — so LFS handling isn't needed for that tree.
- Is **distinct** from `backups-00/repos/` (this ADR's output), which is for live upstream-tracked mirrors only.

Don't conflate the two. The historical archive is data-at-rest; the new mirror is a continuously-updated reflection of upstream.

---

## Alternatives considered

1. **Hand-maintained list of repos to mirror.** Rejected: doesn't scale; new repos get forgotten; the human is the wrong source of truth for "what exists upstream."
2. **Single config file enumerating all repos with all overrides inline.** Rejected: every cron tick that adds a discovered repo would diff the same monolithic file; reading the file becomes a one-shot wall of mostly-default entries.
3. **Provider-side webhook trigger** ("new repo created → ping kodiak to mirror"). Rejected: too much infrastructure for a personal-scale problem; cron polling at 30-min granularity is fine.
4. **Storing state in the same TOML as config.** Rejected (briefly tempting): would put mutable last-run timestamps in git history, generating diff noise every cycle. State files are intentionally not git-tracked.
5. **Hard tier of "active repos" vs "archive repos" with different storage paths.** Rejected: same dataset works for both; cadence override is enough differentiation. Adding a tier later is cheap if it ever matters.
6. **Auto-pruning orphaned mirrors after N days of no upstream.** Rejected emphatically: this whole project exists *because* git history can be lost. Auto-deleting backups of lost-from-upstream repos defeats the purpose.

---

## Decisions resolved during initial review (2026-05-25)

1. **Bitbucket workspace enumeration**: single personal workspace, hardcoded in `defaults.toml`. List-shape preserved for future flexibility but not needed today.
2. **LFS objects on actively-mirrored repos**: not currently expected (the historical `archive/RepositoryBackups` tree may contain LFS but is out of scope — see "Not in scope" above). Skip `git lfs fetch --all` in the initial mirror flow. Revisit if any actively-tracked repo turns out to be missing files in its mirror.
3. **Push behavior on auto-committed config additions**: **local-only commits**. tourbillon writes the new config file and `git commit` in the local tree; never `git push`. Operator reviews and pushes manually.
4. **Snapshot retention for `backups-00/repos`**: **30 days daily.** Cheap on slow-churn data; extensible without design changes if we want deeper history later.

## Future questions

(None pinned today. Things that may surface during implementation will land here as they arise — each becoming either a follow-up ADR or a small revision to this one.)

---

## Implementation artifacts (what gets added when this is built)

```
bin/tourbillon                                # main CLI; first non-stub subcommand: repos
src/tourbillon/                               # if we end up splitting from a single file
  providers/github.py
  providers/bitbucket.py
  repos.py                                   # discovery + reconcile + sync
  state.py                                   # state-file read/write
  config.py                                  # defaults + per-repo override read

configs/repos/
  defaults.toml                              # initial defaults; committed
  {provider}/{owner}/{repo}.toml             # one per repo, committed as they auto-create

~/.config/tourbillon/env                     # PAT + Bitbucket app password (mode 600, not in git)

doc/                                         # this directory
  ADR-001-repo-mirror.md                     # this file
  ADR-NNN-...                                # future decisions land as siblings
```

State (kodiak-local, not in repo):
```
~/.local/state/tourbillon/repos/
  {provider}/{owner}/{repo}.json
~/.local/state/tourbillon/logs/
  repos.log
```

---

## Implementation plan

Once this ADR is accepted, work proceeds in order:

1. Bootstrap `bin/tourbillon` with `argparse` subparser skeleton — `tourbillon repos` is a real noun, other nouns are stubs that print "not implemented yet."
2. Provider modules: GitHub list-repos + clone + remote-update. Bitbucket same. Both stdlib-only (`urllib.request`).
3. Reconciler: discover → walk state → identify due/orphan/stale → action.
4. `tourbillon repos status` + `tourbillon repos issues` so we can see results.
5. Wire the cron entry.
6. After a week of running, revisit: cadence, retention, anything that surfaced.

Each of those is a separate commit. PRs encouraged in spirit if not in practice.

# ADR-009: Dashboard repo management — Discover button + manual add

**Status:** Accepted, 2026-09-30.
**Builds on:** ADR-008 (the auth foundation and write-route pattern this
extends to a second resource — repos, not just hosts).

---

## Context

Repos aren't individually curated in this system — `tourbillon repos
discover` enumerates every repo the GitHub token's account owns and every
repo in the configured Bitbucket workspace, and auto-creates a config for
each one not already catalogued. There was no dashboard-facing way to run
this, and no way to register a repo outside those two providers at all
(`public_clone_url()`/`git_auth_header_for()` hardcode github/bitbucket
specifically — any other provider value raises).

The operator asked for "a way to add new repos" on `/config`. That split
into two different asks on inspection: (1) trigger discovery for the two
providers that already work, and (2) handle a repo discover fundamentally
can't find — a different git host, or a genuinely local-only repo. The
second case itself splits further: a remote repo on an unsupported host
is still a mirror problem (just needs a clone URL); a repo that only ever
existed locally isn't a mirror problem at all — it has no remote to clone
from, and belongs to the A2 host-backup mechanism (an rsync'd path) if it
belongs anywhere in this system.

## Decision

**`repos discover` gets a `--json` mode and a dashboard button.** New
`POST /api/repos/discover` (auth-gated, per ADR-008) shells out to
`tourbillon repos discover --json`, same principle as every other
dashboard route — never re-implementing the discovery logic. Auto-commits
by default, matching the CLI's own default (local-only, never pushed, per
the original ADR-001 decision this doesn't change).

**A new `tourbillon repos add <slug> <clone_url>` command handles "discover
can't find this."** Rather than hardcode a third provider (GitLab, a
self-hosted Gitea, whatever's next), the config gains an optional
`clone_url` field that, when set, is used as-is by `sync_one_repo()` —
no `http.extraHeader` auth injection, since there's no generic
magic-username convention across arbitrary git hosts the way there is for
GitHub/Bitbucket specifically. Credentials for a private repo on another
host are expected embedded directly in the URL
(`https://user:token@host/owner/repo.git`); a public repo needs none. The
slug's first segment becomes a free-form organizing label (shows up as
its own group in the dashboard's provider-grouped repos panel), not a
providers-list membership check. `repos discover` never touches these
configs — it only creates/orphan-checks for the two providers it has API
integration with.

**Local-only repos are explicitly out of scope for this feature.** A repo
with no remote isn't something `git clone --mirror`/`git remote update`
can act on at all. If one ever needs backing up, it belongs in an
existing host's `paths` list (A2's rsync mechanism), not the repos-mirror
system — flagged in the ADR-008 discussion as a different shape of
problem, not built here.

## What testing this surfaced (not a separate decision, but load-bearing)

Building this against the *actual* deployed dashboard (running as
`tourbillon`, not as the operator's own account) — rather than a local
dev server run as `ldavis`, which is how every prior write route had
actually been verified — surfaced two real, previously-latent bugs:

1. **`configs/` and `.git/` are `ldavis:ldavis`-owned with no grant for
   `tourbillon`.** Every dashboard write route added so far, including
   ADR-008's mail toggle shipped as "verified live," silently failed with
   `PermissionError` when actually exercised as `tourbillon` — a gap that
   testing via a local ldavis-owned dev server masked completely. Fixed
   with a scoped POSIX ACL (`setfacl -R -m u:tourbillon:rwX -d -m
   u:tourbillon:rwX`) on exactly `configs/` and `.git/` — deliberately
   *not* broad group membership, to keep tourbillon's grant as narrow as
   the rest of this codebase's service-user model (ADR-004). Added to
   `postinst` so future installs get this automatically; ADR-008's mail
   toggle is retroactively actually-verified now, not just believed to be.
2. **Bitbucket's `role=owner` API filter silently returns zero results**
   with this account's current Atlassian API token (a scoped-token
   migration quirk — the same token lists every repo fine with no role
   filter). This made `repos discover` report all 24 real Bitbucket repos
   as "orphaned" — a false positive, never actually run in anger before
   since discover has always been manual-only. Fixed by dropping the role
   filter (`BITBUCKET_WORKSPACE` already scopes the query to the
   operator's own workspace, making the filter redundant anyway).

Also: wiring the GitHub/Bitbucket tokens into the dashboard's environment
repeated GAPS.md §4.5's exact incident (an `EnvironmentFile=`
format mismatch causing systemd to log full token values to the journal)
— see GAPS.md §4.6 for that specific failure and fix.

## Consequences

**Good**
- Discovering new repos and registering an out-of-band one both go
  through the dashboard now, same auth/write pattern as ADR-008.
- The `clone_url` escape hatch means a third provider never requires a
  code change — just a per-repo config field.
- The permission-model gap is closed generally (any *future* write route
  touching `configs/` or `.git/` inherits a working grant), not just
  patched for this one feature.

**Costs**
- `sync_one_repo()` now has two code paths (provider-derived URL+auth vs.
  explicit `clone_url`, no auth injection) — a small but real branch to
  keep in mind when touching that function again.
- The POSIX ACL is invisible to `ls -la` (needs `getfacl` to see) —
  worth remembering before assuming a permission problem is purely
  ownership/mode-bit based on this checkout specifically.
- Verification here was thorough for the write mechanics (mail toggle,
  add, discover, all re-tested as the actual `tourbillon` user this
  time) but not for the two credential-exposure incidents' downstream
  risk — rotation of the exposed GitHub/Bitbucket tokens is an open
  operator decision, not resolved by this ADR.

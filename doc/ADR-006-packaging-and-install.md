# ADR-006: Versioned packaging — `VERSION` + `Taskfile.yml` + `.deb`

**Status:** Accepted, 2026-09-23.
**Triggered by:** the 2026-09-23 incident — moving the repo checkout from
`~/development/server-backups` to `~/development/systems-tools/server-backups`
silently broke every hardcoded absolute path in cron, systemd-adjacent
scripts, and doc examples. Patched the paths that day; this ADR is the
structural fix.
**Builds on:** ADR-004 (kodiak-side `tourbillon` service user — reused here,
not replaced).
**Enables:** ADR-007 (backup status dashboard), deployed through this
mechanism rather than a parallel, throwaway one.

---

## Context

The whole backup system runs out of a git checkout under a developer's home
directory. Cron entries, the tourbillon-invoking systemd-adjacent scripts,
and doc usage examples all reference that checkout by absolute path. Nothing
enforces the checkout staying put — and it moved, breaking the daily
saratoga-replication check, the monthly restore drills, the weekly summary,
the iDrive clone refresh, and both tourbillon cron entries, all at once,
silently (cron mailed nothing because the commands failed to even be found,
not because they ran and reported an error).

**Historical note:** `CHANGELOG.md`'s 2026-05-24 entry records that a
`Taskfile.yml` (alongside `pyproject.toml`, a `src/` package layout, and a
`servers/` directory) was deliberately *removed* from this exact repo —
tourbillon's predecessor, torn out as "framework design out of scope for
targeted personal infra" in favor of the current single-script CLI. This
ADR reintroduces `Taskfile.yml`, deliberately, for a narrower purpose: it
drives *deployment/packaging only*. `bin/tourbillon` remains exactly the
single script it is today — no `src/` layout, no `pyproject.toml`, no test
framework beyond the existing `tests/*.sh`. The two efforts solve different
problems; this one isn't a reversal of that one.

## Decision

Adopt the packaging model already proven in `~/development/bundler-proto`
(a sibling project), trimmed for this repo's shape: pure Python (no compile
step, no cross-arch builds), single Debian host (no RPM).

- **`VERSION`** — bare semver (`0.1.0` to start).
- **`Taskfile.yml`** — `vet` (syntax-check), `test` (run
  `tests/test-restore-drill.sh`), `package:deb` (stage + `dpkg-deb --build`),
  `version:bump:{major,minor,patch}` + `version:tag` (copied near-verbatim
  from bundler-proto — generic, no adaptation needed), `clean`.
- **`.deb` install layout** — `/opt/server-backups/{bin,dashboard,doc}` is
  the versioned, packaged payload. Installing/upgrading the package is now
  how `bin/tourbillon` and the dashboard code move onto kodiak, independent
  of wherever the dev checkout happens to live.
- **`configs/` is deliberately never packaged.** Host TOMLs, exclude files,
  and cron dumps are live, git-tracked, frequently hand-edited operational
  state (e.g. adding a host, tweaking an exclude). Packaging them into an
  immutable `.deb` payload would mean a rebuild+reinstall for every such
  edit — replacing today's incident with a milder, recurring version of the
  same friction. Instead, `postinst` symlinks
  `/opt/server-backups/configs -> <dev checkout>/configs`. Editing a config
  is still a plain, immediate, git-tracked change with no packaging step.
- **Reuse the existing `tourbillon` service user** (ADR-004) for ownership
  of `/opt/server-backups` and for running the dashboard service, rather
  than inventing a new one — consistent with this codebase's own documented
  principle that personal-infra subsystems get dedicated service users,
  never the operator's account.
- **`git_commit_paths()` fix (`bin/tourbillon`):** `repos discover`'s
  auto-commit used to assume `REPO_ROOT` (the script's own parent directory)
  was the git root. Under the packaged layout, `REPO_ROOT` is
  `/opt/server-backups`, which is *not* a git working tree — only
  `configs/`, reached through the symlink, resolves into one. Fixed to
  resolve the actual git root from the paths being committed
  (`git rev-parse --show-toplevel`) instead of assuming it.
- **Cron entries move with the install.** Mechanism is unchanged (still
  `crontab configs/cron/*`, not dpkg-managed), but script paths are
  re-pointed from the dev checkout to `/opt/server-backups/bin/...` as part
  of rolling this out — the same class of fix as the 2026-09-23 incident,
  this time toward a location that isn't expected to move.

## Consequences

**Good**
- Moving or reorganizing the dev checkout again can no longer break cron —
  the installed, versioned code at `/opt/server-backups` doesn't care where
  development happens.
- Config edits remain zero-ceremony (no rebuild, no reinstall) — only code
  changes require a `task package:deb` + reinstall.
- `task version:tag` gives every install a traceable git tag.

**Costs**
- One more moving piece (`dpkg -i` after `task package:deb`) between editing
  code and it taking effect on kodiak, versus editing the checkout directly.
  Acceptable for a home system with infrequent code changes; would need
  reconsidering if `bin/tourbillon` started changing multiple times a day.

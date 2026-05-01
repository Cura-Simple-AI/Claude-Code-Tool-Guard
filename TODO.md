# Tool-guard TODO

Backlog of planned improvements. Open an issue / PR if you'd like to
take one on.

## ✅ Completed

### `gh` (GitHub CLI) tool-guard — Phase A done (v0.1.0)

Phase A shipped: stub + policy + POLICY.md + 46-test smoke suite.
`defaultMode: "allow"` with deny rules for credential / resource
destruction, claude-only warns for sensitive mutations, and PR-body
autoclose-keyword detection. See CHANGELOG `## [Unreleased]` for the
full feature list.

Phase B (caching layer for `gh pr/issue/run list/view`) is still
**deferred** — see "Medium" section below if you'd like to take it on.

## High value

### Phase B: gh caching layer (optional)

Optional caching layer for `gh pr/issue/run list/view` invocations to
reduce GitHub GraphQL rate-limit pressure. Phase A (the policy guard)
is complete and provides full safety; Phase B is purely a performance
optimisation.

**Suggested approach**

- New `gh/cache.py` module imported by `gh/wrapper.py` BEFORE the
  engine delegate. For known cacheable read commands (configurable
  list, with `pr list`, `pr view`, `issue list`, `issue view`,
  `run list`, `run view` as defaults), check cache first and return
  cached output if fresh.
- TTL configurable via `GH_TG_CACHE_TTL` (default 60s for most
  endpoints, 15s for CI-status endpoints like `actions/runs` where
  staleness causes wrong cancel decisions).
- Mutations (`pr merge`, `issue edit`, `secret set`, …) invalidate
  the cache for the affected resource family.
- Cache files at `/tmp/gh-tool-guard-cache/<sha>.json`.

**Acceptance criteria**

- [ ] `gh/cache.py` module that wraps `subprocess.run([REAL_GH, ...])`
  with a TTL cache for known read commands
- [ ] `gh.config.json` extended with optional `cache: {...}` section
  declaring TTL overrides per endpoint pattern
- [ ] Mutations invalidate cache (test: write to cache → run mutation
  → confirm cache cleared)
- [ ] Tests in `_tests/gh-cache.test.sh` covering hit / miss /
  invalidation / TTL expiry

The engine itself stays caching-agnostic — `cache.py` is a per-tool
optional module.

## Medium

- **`tg config add/remove`** subcommands — programmatic edit of
  `<tool>.config.json` without hand-editing JSON. Tricky because we'd
  want to preserve comments and ordering; `json` module loses both.
  Consider `commentjson` or a roll-your-own minimal JSON-with-comments
  parser.
- **`tg log` filtering** — `--decision deny`, `--since 1h`,
  `--rule "*delete*"`, `--exit-code N`. Currently only `-n N` (tail).
- **`tg log-summary`** subcommand — aggregate counts by decision /
  rule / caller, replacing the per-tool `log-summary.sh` (or have
  `tg log-summary` delegate to it for backward compat).
- **JSON Schema for the config files** — formalise the schema so
  editors can validate + autocomplete. Currently the structure is
  only documented prose-wise.
- **`pip install tool-guard`** — package as a real Python distribution
  so users can `pip install tool-guard` without `git clone`. Would
  bundle the CLI + engine; `install.sh` becomes optional.

## Low / nice-to-have

- **Generic numeric guard** — generalise the sleep wrapper into a
  rule type the engine handles
  (`{"type": "numeric", "arg": 0, "max": 30}`). Sleep, timeout, and
  similar one-offs would then be config rather than separate stubs.
- **Per-agent rules** — gate rules on an agent name set via env var
  (`<TOOL>_TG_AGENT=foo`) in addition to `claude_only`. Useful for
  teams with multiple AI roles.
- **Audit log shipping** — optional integration to ship JSONL events
  to syslog / OpenTelemetry / a SIEM, instead of (or in addition to)
  the local file.
- **Windows support** — the engine assumes `/proc` for ancestor
  detection and `/usr/local/bin/` for installation. Nothing else is
  POSIX-specific; could be ported with a few `os.name`-gated
  branches.

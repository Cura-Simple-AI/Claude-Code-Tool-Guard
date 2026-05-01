# Changelog

All notable changes to **tool-guard** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (BREAKING — pre-1.0)
- Renamed package from "wrapper(s)" to "tool-guard(s)" everywhere:
  - Directory: `scripts/wrappers/` → `scripts/tool-guard/`
  - Config dir: `.wrappers/` → `.tool-guard/`
  - Config files: `<tool>-wrapper.config.json` → `<tool>.config.json`
  - Env vars: `<TOOL>_WRAPPER_*` → `<TOOL>_TG_*` (e.g.
    `AZ_WRAPPER_REAL_BIN` → `AZ_TG_REAL_BIN`,
    `_AZ_WRAPPER_ACTIVE` → `_AZ_TG_ACTIVE`)
  - Log dir: `/tmp/wrapper-logs/<tool>/` → `/tmp/tool-guard-logs/<tool>/`
  - Code identifiers: `_find_wrappers_dir` → `_find_guards_dir`, etc.
  Migration: rename your `.wrappers/` directory to `.tool-guard/`,
  drop the `-wrapper` suffix from config filenames, and rename any
  `<TOOL>_WRAPPER_*` env vars in your shell profile to `<TOOL>_TG_*`.
  The internal stub filename `wrapper.py` and the installed engine
  path `/usr/local/lib/tool-guard/` are unchanged.

### Added
- `tg` management CLI (installs to `/usr/local/bin/tg`) with commands:
  `list`, `status`, `check`, `log`, `config show/init/edit/validate`,
  `add`, `install/uninstall`, `test`, `version`, `help`.
- Both per-tool stubs (`az`, `git`) fail-fast with exit 127 + clear
  remedy message if the engine module can't be imported (previously
  produced an uncaught Python traceback).
- [TODO.md](TODO.md) listing the planned `gh` tool-guard POC and
  other backlog items.

### Added — `gh` tool-guard (Phase A complete)
- `gh/wrapper.py` (engine delegate, ~30-line stub).
- `examples/.tool-guard/gh.config.json` policy:
  - `defaultMode: "allow"` (gh is mostly safe reads + benign mutations).
  - **Always-deny** on credential / resource destruction: `auth
    logout`, `repo delete`, `secret delete`, `variable delete`,
    `ssh-key delete`, `gpg-key delete`, `release delete`.
  - **Claude-only warn** on sensitive mutations: `pr merge`, `pr close`,
    `issue close`, `release create`.
  - **PR-body autoclose check** — warns when `gh pr create --body`
    contains `[Ff]ix(es) #N` / `[Cc]lose(s) #N` / `[Rr]esolve(s) #N`.
    GitHub auto-closes the linked issue at merge time, regardless of
    whether the issue's DoD is met. The warning suggests `Part of #N`
    or `Addresses #N` instead. Six character-class patterns cover the
    capitalized + lowercase variants; all-caps `FIXES #` would slip
    through (see TODO for `case_insensitive: true` engine flag).
- `gh/POLICY.md` with rationale per rule + override + per-user override
  recipes.
- `_tests/gh.smoke.test.sh` — 46 tests covering all categories +
  fail-fast missing-engine handling. Mirrors `az.smoke.test.sh` and
  `git.smoke.test.sh` structure.

### Fixed
- Engine: `_env_prefix(tool_name)` now validates tool_name against
  `^[a-zA-Z][a-zA-Z0-9-]*$`. Invalid names (containing dots, slashes,
  leading digits, etc.) raise `ValueError` early — previously they
  produced invalid POSIX env var names like `FOO.BAR_TG_ACTIVE` that
  didn't propagate through sub-shells, causing recursion-sentinel
  failures.
- Engine: `claude_only` field now requires a JSON `boolean`. String
  values like `"false"` were silently truthy in Python and would
  unexpectedly gate the rule. Strings now print a warning and the
  rule is treated as if `claude_only` were not set.
- `tg config init / edit` were creating `<tool>-wrapper.config.json`
  (pre-rename filename) instead of `<tool>.config.json`. Engine never
  found those files at runtime.
- `tg add <name>` now rejects reserved names (`examples`, `_tests`,
  `tg`, `install`, `lib`, etc.) and names with leading/trailing
  dashes — previously could create wrappers that collided with the
  package layout.
- `tg list` and `tg status` now correctly identify `/usr/local/bin/<name>`
  as ours only if the file's first 2 KB contain a Python shebang +
  `tool_guard`/`WRAPPER_ACTIVE` reference. Previously any executable
  with the matching name was reported as installed.
- `az`, `git` (and now `gh`) stubs fail-fast with exit 127 + clear
  remedy message if `tool_guard` engine can't be imported (was an
  uncaught `ModuleNotFoundError` traceback).

## [0.1.0] — 2026-05-01

### Added
- Generic policy-enforcement engine (`tool_guard.py`) shared by all wrappers.
- Per-tool stub pattern (~25 lines per tool-guard): declares `tool_name`,
  `real_bin`, and `secret_flags`, delegates to the engine for everything
  else (config loading, classification, prompt, redaction, logging,
  recursion defence, force override, dry-run).
- Three severity tiers: `deny` (block + exit 13), `warn` (advisory +
  proceed), `allow` (silent + proceed). Plus `prompt` defaultMode for
  interactive TTY confirmation with auto-save to local config; non-TTY
  callers auto-deny.
- Layered config files: `<tool>.config.json` (shared, committed) +
  `<tool>.config.local.json` (per-user, gitignored, populated by
  prompt's "save" actions) + `_defaults.json` (cross-cutting rules
  applied to every tool).
- Per-rule metadata: `pattern` (fnmatch glob), optional `message` (custom
  text on deny/warn), optional `claude_only: true` (rule fires only under
  a Claude Code ancestor process).
- JSONL audit log per call to `/tmp/tool-guard-logs/<tool>/calls-YYYY-MM.jsonl`
  with redaction of secret-flag values (`--password`, `--token`, etc.).
- Recursion defence via env-var sentinel (`_<TOOL>_TG_ACTIVE`).
- Three built-in tool-guard:
  - **az** — Azure CLI, `defaultMode: prompt`, default-deny + interactive
    confirm, custom messages on high-blast-radius rules (group delete,
    keyvault secret purge, ad sp delete, etc.).
  - **git** — `defaultMode: allow` with always-deny on push to main/master
    (covers all flag combinations + branch-name false-positive avoidance)
    and claude-only warns on force-push, --no-verify, reset --hard,
    checkout --, blind merge strategies, rebase -i.
  - **sleep** — numeric guard (not pattern-matched). Blocks `sleep > 30s`
    under a Claude ancestor; correctly sums multi-arg invocations
    (`sleep 1m 30s`) and degrades gracefully on invalid env vars or
    missing real binary.
- Orchestrator scripts: `install.sh` (installs engine to
  `/usr/local/lib/tool-guard/` + each per-tool stub to
  `/usr/local/bin/<name>`), `uninstall.sh` (symmetric).
- Test suite: 167 passing tests across engine + per-tool smoke tests.
  Engine tests use a synthesized "testtool" stub + fake binary so the
  suite runs anywhere without external deps.

### Notable bug-fix history (during development)
- Engine: validate JSON config is a dict at top level (rejects strings,
  arrays, numbers).
- Engine: validate rule list is an array (rejects accidental string
  forms like `"allow": "foo*"`).
- Engine: validate rule pattern is a string (rejects `{"pattern": 42}`
  and `{"pattern": null}`).
- Engine: validate `defaultMode` against `{deny, allow, warn, prompt}` —
  unknown values previously silently auto-allowed.
- Engine: clear deny / warn message when `defaultMode` matches with no
  rule (was showing confusing `<unknown>`).
- Engine: warn when `<TOOL>_TG_CONFIG` points to a missing file.
- Engine: detect non-executable / directory `real_bin` early with clear
  error (was producing uncaught traceback).
- Sleep: sum all duration args (was checking only `args[0]`, letting
  `sleep 5 999` through).
- Sleep: defensive parsing of `SLEEP_TG_MAX` (was crashing on typo).
- Git: tighten `push origin main*` patterns to avoid false positives on
  `push origin main:hotfix-branch` and `push origin main-feature` while
  also catching previously-missed cases like `push -u origin main` and
  `push origin main --force`.

[Unreleased]: ../../compare/v0.1.0...HEAD
[0.1.0]: ../../releases/tag/v0.1.0

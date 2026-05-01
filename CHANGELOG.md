# Changelog

All notable changes to **tool-guard** are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Pre-1.0 minor versions may include breaking changes.

## [0.1.0] — 2026-05-01

Initial public release.

### Engine (`tool_guard.py`)

- Pure-stdlib Python 3.9+ policy enforcement engine, ~600 lines.
- Three severity tiers (`deny` / `warn` / `allow`) plus `prompt`
  defaultMode for interactive TTY confirmation; non-TTY callers
  auto-deny.
- Layered config: `<tool>.config.json` (shared, committed),
  `<tool>.config.local.json` (per-user, gitignored, populated by
  prompt's "save" action), `_defaults.json` (cross-cutting).
- `fnmatch` glob patterns by default; opt into `re.search` via
  `"type": "regex"`. `tg config validate` warns about deny regex
  rules without a `^` anchor.
- Per-rule metadata: `pattern`, optional `message`, optional
  `claude_only: true` (rule active only under a Claude Code
  ancestor process — Linux-only `/proc` walk).
- JSONL audit log per call to `/tmp/tool-guard/<tool>_YYYYMMDD.log`
  (one file per tool per day) with case-insensitive redaction of
  secret-flag values.
- Config files load with UTF-8 BOM stripping (Windows editors).
- `defaultMode` accepts case + whitespace variations ("DENY",
  " deny ", "deny\n" all map to "deny").
- 4-level config-dir discovery: `$TOOL_GUARD_DIR` (test-mode-gated),
  cwd walk-up, `~/.config/tool-guard/`, `~/.tool-guard/`. Home
  fallbacks let MCP servers (running with `cwd=/usr/bin/`) find a
  policy.

### Built-in tool guards

- **az** — Azure CLI. `defaultMode: prompt`, default-deny + interactive
  confirm. Custom messages on high-blast-radius rules (group delete,
  keyvault secret purge, ad sp delete). Auth-token allow rule for MCP
  integration.
- **gh** — GitHub CLI. `defaultMode: allow` for safe reads.
  Always-deny on credential / resource destruction (auth logout,
  repo delete, secret/variable/ssh-key/gpg-key/release delete).
  Claude-only warns on sensitive mutations (pr merge/close, issue
  close, release create). Warns when PR-body contains autoclose
  keywords (Fix(es) / Close(s) / Resolve(s) #N).
- **git** — `defaultMode: allow` with always-deny on push to
  main/master (covers all flag combinations + branch-name
  false-positive avoidance) and Claude-only warns on force-push,
  --no-verify, reset --hard, checkout --, blind merge strategies,
  rebase -i.
- **sleep** — numeric guard (not engine-based). Blocks `sleep > 30s`
  under a Claude ancestor; correctly sums multi-arg invocations
  (`sleep 1m 30s`). `SLEEP_TG_MAX` env override hard-capped at 300s.

### Management CLI (`tg`)

- `tg list` / `status` / `check` / `log` / `version` / `help`
- `tg install` / `uninstall` — pre-flight `which -a` discovery,
  REAL_BIN baking into stubs, conflict detection (refuses to
  overwrite a real binary at `/usr/local/bin/<name>` — suggests
  `mv to <name>-real` workaround).
- `tg config show / init / edit / validate` — `init` and `edit`
  anchor at cwd (walk-up only, no home fallback) so files land
  where the operator is.
- `tg add <name>` — scaffold a new tool guard from canonical templates.
- `tg test` — run the full test suite.

### Install / orchestration

- `install.sh` — installs engine to `/usr/local/lib/tool-guard/`,
  per-tool stubs and the `tg` CLI to `/usr/local/bin/`. Honors
  `TG_INSTALL_DIR` / `TG_ENGINE_DIR` env overrides; auto-skips
  `sudo` when the target is writable.
- Pre-install PATH check (verifies `/usr/local/bin` precedes
  `/usr/bin`) — fails BEFORE writing stubs to avoid half-installed
  state.
- `uninstall.sh` — symmetric; refuses to remove non-tool-guard
  binaries.
- Bootstrap script (`tool-guard-install.sh` in the consumer repo) —
  clones from GitHub + execs `tg install`. Supports
  `TOOL_GUARD_REF` for tag/branch/SHA pinning and
  `TOOL_GUARD_EXPECTED_SHA` for working-tree integrity verification.

### Security

- **Test-mode env vars are file-gated.** `TOOL_GUARD_DIR`,
  `TOOL_GUARD_ENGINE_DIR`, and `<TOOL>_TG_FAKE_CLAUDE` are honored
  only when `TG_TEST_MODE=1` is set AND
  `/etc/tool-guard/test-mode-enabled` exists (sudo to create). An
  AI agent can set env vars but cannot create the file in passing.
- **`publish.sh` guards.** Refuses to publish from non-`main`
  branches (`TG_PUBLISH_BRANCHES` to allow others), refuses on a
  dirty working tree (catches untracked + modified), rejects empty
  subtree splits. `TG_PUBLISH_FORCE=1` requires
  `/etc/tool-guard/publish-force-allowed` for the same reason as
  test mode.
- **Canonical stub markers** (`# TOOL_GUARD_STUB_v1`,
  `# TG_REAL_BIN_DEFAULT`) for deterministic detection across
  `tg`'s `_is_our_wrapper` / `_guard_installed` and the install
  scripts. Drift-detection tests in `_tests/tg.test.sh`.
- **Secret-flag redaction** is case-insensitive (`--Password=secret`
  no longer leaks).
- **REAL_BIN substitution attempts** (e.g. `AZ_TG_REAL_BIN=/usr/bin/bash`)
  are recorded in the audit log + warned to stderr when the override's
  basename doesn't match the tool name.
- **`derive_pattern("*")` requires explicit `YES` confirmation** in
  the interactive prompt before persisting an allow-everything rule.

### Tests

- ~500 tests across 7 suites (`tool_guard.test.sh`, `tg.test.sh`,
  `install.test.sh`, `az.smoke.test.sh`, `gh.smoke.test.sh`,
  `git.smoke.test.sh`, `sleep.test.sh`).
- All suites green on Python 3.9 / 3.10 / 3.11 / 3.12.
- CI workflow at `.github/workflows/test.yml` runs every suite
  on every push + PR.
- Engine→tg log round-trip integration test asserts schema stability
  between writer and reader.

[0.1.0]: ../../releases/tag/v0.1.0

# Claude Code Tool Guard

[![tests](../../actions/workflows/test.yml/badge.svg)](../../actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python: 3.9+](https://img.shields.io/badge/Python-3.9+-blue.svg)](https://www.python.org/)

> **Generic policy enforcement for CLI tools — built for AI agents
> like Claude Code.** Drop-in tool-guards for `az`, `git`, `gh`,
> `sleep`, … with allow / warn / deny rules, custom messages,
> structured audit logs, an interactive prompt for unknown commands,
> and a shared engine that's <600 lines of pure-stdlib Python.

The package short-name is `tool-guard` (the engine module, the
management CLI `tg`, the install path `/usr/local/lib/tool-guard/`).
The full project name is **Claude Code Tool Guard** — designed
explicitly to give AI agents a guardrail for destructive shell
commands while staying out of the way for benign reads.

---

## The problem

CLI tools are a quiet blast-radius nightmare. A typo in
`az group delete --name <prod-rg>`, a stray `git push --force origin
main`, or an AI agent looping on `sleep 9999` can ruin your day.

You can:
- **Lock everything down** at the IAM / OS layer — slow to set up,
  fragile, blocks legitimate work.
- **Hope nobody types the wrong thing** — works until it doesn't.
- **Wrap the CLIs** with a per-tool policy that lives in your repo,
  reviewed by the team, applied to humans and AI agents alike. ← this
  is `tool-guard`.

## The shape of it

```
       PATH:    /usr/local/bin/az  ← tool-guard stub (shadows /usr/bin/az)
                ↓
       stub: import tool_guard
             ↓
             tool_guard.run(tool="az",
                            real_bin="/usr/bin/az",
                            secret_flags={…})
             ↓
             load .tool-guard/_defaults.json + az.config.json
                 + .tool-guard/az.config.local.json
             classify against allow / warn / deny lists
             ↓
             ├─ deny   → log + stderr message + exit 13
             ├─ warn   → log + stderr advisory + exec real az
             ├─ allow  → log + exec real az
             └─ prompt → ask user [a/A/d/D] (TTY); auto-deny (non-TTY)
```

The engine handles config loading, classification, prompt with
auto-save to local config, redaction of secret-flag values, JSONL
audit logging, recursion defence, force override, and dry-run mode.
**Each per-tool tool-guard is ~25 lines** — just declares the tool name,
real binary path, and any secret flags to redact.

## Quickstart

```bash
# 1. Clone (or extract via git subtree split — see EXTRACT.md)
git clone https://github.com/<your-org>/tool-guard.git
cd tool-guard

# 2. Run the test suite to verify (167+ tests, ~2s)
bash _tests/tool_guard.test.sh
bash _tests/az.smoke.test.sh
bash _tests/git.smoke.test.sh
bash _tests/sleep.test.sh
# (or with the management CLI: `tg test`)

# 3. Set up a starter policy in your project
cd /path/to/your/project
mkdir -p .tool-guard
cp /path/to/tool-guard/examples/.tool-guard/* .tool-guard/

# 4. Install everything: engine, tool-guard, and the `tg` management CLI
bash /path/to/tool-guard/install.sh

# 5. Try it
az group delete --name something
# → tool-guard: ❌ blocked by policy rule '* delete *'.
#     Generic destructive '* delete *' is blocked by the global guard rails.
#     Override (only if you know what you're doing):
#       AZ_TG_FORCE=1 az group delete --name something
```

That's it. Everything below is detail.

## The `tg` management CLI

`tg` is installed alongside the tool-guards and provides convenient
inspection, dry-run, and management commands:

```bash
tg list                                      # what tool-guards are installed
tg status [tool]                             # install + config + log status
tg check az repos pr create --title "test"   # dry-run classify (allow/deny/warn/prompt)
tg log az -n 20                              # last 20 log entries, colored
tg config show git                           # print merged effective config
tg add gh                                    # scaffold a new tool-guard
tg test                                      # run all test suites
tg install [name...]                         # install engine + tool-guards
tg uninstall [name...]                       # uninstall (engine removed only on full uninstall)
tg help [command]                            # help (general or per-command)
```

The most useful day-to-day command is `tg check`:

```text
$ tg check az group delete --name foo
Checking: az group delete --name foo

  ❌ DENIED
     rule:         group delete*
     under Claude: True
     message:      Resource group deletion cascades to every resource inside it.
                   This is the most blast-radius operation in Azure CLI.
                   Verify the group name twice and confirm with the team.

  Would exit with code 13. Override:
      AZ_TG_FORCE=1 az group delete --name foo
```

This lets you ask "would this be allowed?" without actually running
the command — useful for documentation, scripts, and AI agents that
want to pre-check before invoking destructive operations.

## Built-in tool-guard

| Tool-guard | Real binary    | defaultMode | Notes                                      |
|---------|---------------|-------------|--------------------------------------------|
| `az`    | `/usr/bin/az` | `prompt`    | Default-deny + interactive prompt with auto-save to local config. Custom messages on high-blast-radius rules (group delete, keyvault secret purge, ad sp delete, …). |
| `git`   | `/usr/bin/git`| `allow`     | Always-deny on push to `main`/`master` (covers all flag combinations). Claude-only warns on force-push, --no-verify, reset --hard, checkout --, blind merge strategies, rebase -i. |
| `gh`    | `/usr/bin/gh` | `allow`     | Always-deny on credential / resource destruction (`auth logout`, `repo delete`, `secret delete`, `ssh-key delete`, `release delete`). Claude-only warns on `pr merge`, `pr close`, `release create`. **PR-body autoclose check** — warns when `gh pr create --body` contains `Fix(es) #N` / `Close(s) #N` / `Resolve(s) #N` (GitHub auto-closes the linked issue at merge). |
| `sleep` | `/usr/bin/sleep` | n/a      | Numeric guard (not pattern-matched). Blocks `sleep > 30s` under a Claude Code ancestor; correctly sums multi-arg invocations like `sleep 1m 30s`. Self-contained stub — does NOT use the engine. |

Adding a new tool-guard is ~30 lines + a JSON config — see
[CONTRIBUTING.md](CONTRIBUTING.md#adding-a-new-tool-guard).

## Configuration model

### Layered configs

The engine merges three files at load time:

| File                                              | Role                                          | Committed? |
|---------------------------------------------------|-----------------------------------------------|------------|
| `<repo>/.tool-guard/<tool>.config.json`      | Shared, team-wide policy                      | ✅ yes     |
| `<repo>/.tool-guard/<tool>.config.local.json`| Per-user overrides + prompt-saved decisions   | ❌ no (gitignored) |
| `<repo>/.tool-guard/_defaults.json`                  | Cross-cutting rules applied to every tool     | ✅ yes     |

Discovery walks up from cwd looking for a `.tool-guard/` directory
(mirrors how git locates `.git/`). Per-tool rules come first;
defaults serve as a backstop.

Override the merged set entirely with
`<TOOL>_TG_CONFIG=/path/to/file.json` (handy for tests and
ad-hoc experiments).

### Categories

| Category   | Effect |
|------------|--------|
| `allow`    | Log + exec real binary. The "explicitly approved" list. |
| `warn`     | Stderr advisory + log + exec. Same as allow with a notice. |
| `deny`     | Log + stderr error + exit 13. Real binary is not called. |
| `defaultMode` | What to do for unmatched: `deny`, `allow`, `warn`, or `prompt`. |

Precedence: **`deny` > `warn` > `allow` > `defaultMode`**. First
match within each category wins.

### Rule schema

A rule is either a plain string (the glob pattern) or an object with
metadata:

```jsonc
"deny": [
  "logout*",                                          // simple form
  {"pattern": "group delete*",                        // expanded form
   "message": "Resource group deletion cascades..."},
  {"pattern": "push --force *",
   "claude_only": true,                               // only fires under Claude
   "message": "Force push under Claude — careful"}
]
```

| Field         | Required | Meaning |
|---------------|----------|---------|
| `pattern`     | yes      | `fnmatch` glob matched against argv joined with spaces |
| `message`     | no       | Custom message printed when this rule matches |
| `claude_only` | no       | If `true`, only fires under a Claude Code ancestor process |

### The interactive prompt (defaultMode: "prompt")

When a call matches no rule and `defaultMode: "prompt"`:

```
az-tool-guard: 'az foo bar baz' is not in the policy.
  Suggested pattern: 'foo bar baz*'
  [a] allow once   [A] allow always (save pattern to local config)
  [d] deny once    [D] deny always  (save pattern to local config)
  Choice [a/A/d/D]:
```

`[A]` / `[D]` append to `.tool-guard/<tool>.config.local.json`
(gitignored). Non-TTY callers (CI, scripts, AI agents without a TTY)
get an automatic deny instead of hanging.

## Environment variables

For each wrapped tool (prefix = `<TOOL>_WRAPPER_`, e.g. `AZ_WRAPPER_`):

| Variable                            | Purpose |
|-------------------------------------|---------|
| `<TOOL>_TG_REAL_BIN`           | Override the real binary path (e.g. for snap installs) |
| `<TOOL>_TG_FORCE=1`            | Emergency bypass — ignore deny rules |
| `<TOOL>_TG_DRYRUN=1`           | Print classification + exit; do not exec |
| `<TOOL>_TG_DISABLE=1`          | Disable logging (the call still runs) |
| `<TOOL>_TG_NONINTERACTIVE=1`   | Treat stdin as non-TTY (auto-deny on prompt) |
| `<TOOL>_TG_FAKE_CLAUDE=0\|1`   | Force `claude_only` rules off (`0`) or on (`1`) — for tests |
| `<TOOL>_TG_CONFIG=/path/...`   | Single-file config override (replaces all layers) |
| `<TOOL>_TG_LOG_DIR=/path/...`  | Override log dir (default `/tmp/tool-guard-logs/<tool>`) |
| `_<TOOL>_TG_ACTIVE=1`          | Internal recursion sentinel (do not set manually) |

## How install.sh works

```
scripts/tool-guard/tool_guard.py     →  /usr/local/lib/tool-guard/tool_guard.py  (shared engine, install once)
scripts/tool-guard/az/wrapper.py     →  /usr/local/bin/az                        (per-tool stub)
scripts/tool-guard/git/wrapper.py    →  /usr/local/bin/git
scripts/tool-guard/sleep/wrapper.py  →  /usr/local/bin/sleep
```

`/usr/local/bin/` precedes `/usr/bin/` on standard Debian/Ubuntu, so
plain `az` resolves to the tool-guard without touching anyone's shell
config. Each stub hard-codes `/usr/bin/<name>` as the real binary
(overridable via `<TOOL>_TG_REAL_BIN`) to avoid PATH-recursion.

The installer:
- Refuses to overwrite a binary at `/usr/local/bin/<name>` that's not
  a Python tool-guard script (so it won't clobber a real CLI someone
  installed there manually).
- Verifies PATH order (`which az` must resolve to `/usr/local/bin/az`).
- Uses `sudo` for the writes — must be run by a human user.

```bash
bash install.sh         # engine + all tool-guards
bash install.sh az      # engine + just az
bash uninstall.sh       # symmetric removal
```

## FAQ

### Does this break my shell?

No. The tool-guard inherits stdin/stdout/stderr transparently and exec's
the real binary on `allow` (and `warn`, with a stderr notice first).
Interactive flows like `az login` (browser dance) and `git rebase -i`
work normally.

### What's exit 13?

The tool-guard's "blocked by policy" exit code, distinct from 0
(success), 1 (real binary error), and 127 (binary not found).

### How does `claude_only` work?

The engine walks `/proc/<pid>/status` upward looking for an ancestor
process whose `cmdline` basename is `claude`. If found, rules with
`claude_only: true` activate. This is a Linux-only heuristic — see
[SECURITY.md](SECURITY.md#known-limitations) for what it is and isn't.

For tests, set `<TOOL>_TG_FAKE_CLAUDE=0` (force off) or
`<TOOL>_TG_FAKE_CLAUDE=1` (force on).

### Can I bypass the tool-guard?

Yes — by design. `tool-guard` is a guardrail, not a sandbox. See
[SECURITY.md](SECURITY.md#what-it-does-not-do) for the threat model.
Setting `<TOOL>_TG_FORCE=1` is the documented escape hatch for
emergencies.

### What about `gh` (GitHub CLI)?

Not a built-in tool-guard yet, but the engine handles it the same way —
write a 25-line stub plus a config (see [CONTRIBUTING.md](CONTRIBUTING.md)).
PRs welcome.

### What languages does this work for?

Any CLI that's invoked via `PATH` (so any compiled binary or shell
script). The tool-guard logic itself is Python 3.9+ stdlib.

## Project status

- 0.1.0 (initial public release)
- 167 tests, all green
- Used in production at one company; battle-tested for a couple of
  weeks at the time of release
- Pre-1.0 — public API is the `run()` signature in `tool_guard.py`,
  treat with caution; minor versions may include breaking changes
  until 1.0

See [CHANGELOG.md](CHANGELOG.md) for history.

## Per-tool-guard details

- [az](az/POLICY.md) — Azure CLI, design notes
- [git](git/POLICY.md) — git tool-guard, design notes
- [sleep](sleep/POLICY.md) — sleep tool-guard, design notes

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports, new tool-guard PRs,
and policy-template improvements are all welcome.

## License

[MIT](LICENSE) — do whatever you want with this, including using it
commercially. Attribution appreciated but not required.

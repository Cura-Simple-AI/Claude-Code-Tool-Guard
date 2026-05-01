# az-tool guard policy — design notes

The `.tool-guard/az.config.json` file controls what `az`
invocations the tool guard at `/usr/local/bin/az` allows or blocks.
**Default posture: deny** — an unmatched call triggers an interactive
prompt (when stdin is a TTY) or an automatic deny (when it is not, e.g.
Claude / scripts / CI).

The tool guard itself is a ~25-line stub that delegates to the shared
engine at `scripts/tool-guard/tool_guard.py`. All policy logic lives
there — see `scripts/tool-guard/README.md` for the system architecture.

## File location + merge

Three config files are merged at load time:

| File | Role | Committed? |
|------|------|------------|
| `<repo>/.tool-guard/az.config.json` | Shared, team-wide policy | ✅ yes |
| `<repo>/.tool-guard/az.config.local.json` | Per-user overrides + prompt-saved decisions | ❌ no (gitignored) |
| `<repo>/.tool-guard/_defaults.json` | Cross-cutting rules applied to ALL tools | ✅ yes |

Discovery walks up from cwd looking for a `.tool-guard/` directory
(mirrors how git locates `.git/`). Files in that directory are loaded
and merged: per-tool `allow` / `warn` / `deny` arrays come first,
defaults serve as a backstop. `defaultMode` from the local file
overrides the shared one if both set it.

Override the merged set entirely with `AZ_TG_CONFIG=/path/to/file.json`
(used by the test suite — also useful for ad-hoc experiments).

If no `.tool-guard/` is found, the engine falls back to a **restrictive
embedded default** (`defaultMode: "deny"`, empty rule lists). Better to
break than to silently fail open.

## Categories

| Category | Effect |
|----------|--------|
| `allow` | Log + exec real `az`. The "explicitly approved" list. |
| `warn` | Print stderr advisory + log + exec. Same as allow but noisy. |
| `deny` | Log + print stderr message + exit 13. Real `az` is not called. |
| `defaultMode` | What to do for unmatched: `deny` (auto-deny) or `prompt` (TTY → interactive [a/A/d/D]; non-TTY → deny). |

## Precedence

Patterns are evaluated in this order; first match wins:

```
deny → warn → allow → defaultMode
```

Within each category, rules from layered files are evaluated in this
sequence: shared per-tool → local per-tool → cross-cutting defaults.

## Rule schema

A rule is either a plain string (the glob pattern) or an object with
metadata:

```jsonc
"deny": [
  "logout*",                                          // simple form
  {"pattern": "group delete*",                        // expanded form
   "message": "Resource group deletion cascades..."},
  {"pattern": "push --force *",                       // (git uses this)
   "claude_only": true,                               // only fires under Claude
   "message": "Force push under Claude — careful"}
]
```

| Field | Required | Meaning |
|-------|----------|---------|
| `pattern` | yes | `fnmatch` glob matched against argv joined with spaces |
| `message` | no | Custom message printed when this rule matches (overrides default) |
| `claude_only` | no | If `true`, only fires when running under a Claude ancestor process |

## Pattern syntax

`fnmatch`-style globs (`*` = any chars, `?` = single char, `[abc]` =
char class). Match against the full argv joined with spaces — e.g.
`account show --output json` is one string.

Patterns are case-sensitive. Wrap with `*` if you want to match a verb
that may have leading global flags:

- ❌ `account show` — won't match `--output json account show`
- ✅ `* account show*` — matches any leading flags + trailing flags

For most az commands the verb path is the first 1–3 args (`account
show`, `boards work-item show`, `keyvault secret delete`). Patterns
following that pattern work without leading wildcards because az
typically puts the verb first.

## The interactive prompt (defaultMode: "prompt")

When a call matches no rule:

```
az-tool-guard: 'az foo bar baz' is not in the policy.
  Suggested pattern: 'foo bar baz*'
  [a] allow once   [A] allow always (save pattern to local config)
  [d] deny once    [D] deny always  (save pattern to local config)
  Choice [a/A/d/D]:
```

- `[a]` / `[d]` — apply once for this invocation, do not modify config.
- `[A]` / `[D]` — append the suggested pattern to the per-user
  `.tool-guard/az.config.local.json` so future calls match the
  rule without re-prompting. The shared, committed config is never
  touched automatically — promotion to the team policy is a manual
  edit.

The suggested pattern is derived by taking the leading non-flag
arguments (the verb path) and appending `*`. Examples:

| Input | Suggested pattern |
|-------|-------------------|
| `az logout` | `logout*` |
| `az boards work-item show --id 9` | `boards work-item show*` |
| `az --version` | `--version` |
| `az account get-access-token --r ?` | `account get-access-token*` |

If you want a different pattern, hit `[d]` (deny once), then add the
pattern by hand to either config file.

### Non-interactive callers

If stdin is not a TTY (Claude, scripts, CI) or
`AZ_TG_NONINTERACTIVE=1` is set, the tool guard **denies
automatically without prompting** — otherwise it would hang waiting on
input that never comes. The deny message includes the suggested pattern
+ instructions on which file to edit and how to override.

## Why these specific entries?

### `allow`

Read-only and append-only verbs across the surfaces we actively use:
work items (boards), pull requests (repos), pipelines, extensions,
config-read, signed-in-user info, plus the meta-commands (`version`,
`--help`, `--version`) and the credential-helper polling
(`account get-access-token`).

`account get-access-token*` deserves a note: it's fired by the git
credential helper for every fetch / push against `dev.azure.com`. It
runs frequently. We log it anyway for audit value — if the log volume
becomes a problem, filter it out at log-summary time.

### `deny`

Three buckets, with custom messages on the most consequential:

1. **Auth / context mutation** — `logout`, `account clear`, `account
   set`, `config set`. These can break the credential helper or
   silently change which subscription/tenant a subsequent command
   targets.
2. **Specific high-blast-radius** — service-principal / app / user /
   group deletions, key-vault material deletions, resource-group
   deletions, pipeline-run cancellations, PR abandonment.
3. **Cross-cutting catch-alls** — `* delete *`, `* purge *`, `* destroy
   *` are NOT here; they live in `_defaults.json` and apply to every
   wrapped tool.

Conservative on purpose. Add to it as the prompt-mode logs reveal new
patterns that turn out to be destructive in practice.

## How to test the policy

### Dry-run (no exec, no log, no prompt)

```bash
# allow → would run real az
AZ_TG_DRYRUN=1 az boards work-item show --id 9758
# → DRYRUN: classify=allow rule="boards work-item show*" — would log + run real binary

# deny → would block (note the custom message in the actual output)
AZ_TG_DRYRUN=1 az group delete --name foo
# → DRYRUN: classify=deny rule="group delete*" — would block (exit 13) ...

# unmatched → would prompt (or auto-deny if non-TTY)
AZ_TG_DRYRUN=1 az foo bar
# → DRYRUN: classify=prompt rule=<defaultMode> — would prompt user (TTY) or
#   auto-deny (non-TTY); suggested pattern: 'foo bar*'
```

### Test suite

```bash
bash scripts/tool-guard/_tests/tool_guard.test.sh   # engine
bash scripts/tool-guard/_tests/az.smoke.test.sh     # az + config end-to-end
```

## Editing the policy

The repo file `.tool-guard/az.config.json` is the source of truth
for the team. Edit it like any other code change (PR, review, merge).

The per-user file `.tool-guard/az.config.local.json` is gitignored
— created automatically by the prompt's `[A]` / `[D]` actions, but you
can also write to it by hand. Use it for:

- Personal experiments (allow a verb you're testing, without committing
  the rule)
- Tightening: add an explicit `deny` for something the shared policy
  allows but you don't want to risk firing
- Loosening: add an `allow` for a verb that's prompt-gated by default

When a local pattern proves useful for the whole team, copy it into the
shared config and delete it from the local one (or just leave it — the
union doesn't care).

## Phase 3 — when this replaces the harness deny

Once the policy has run for a while and we trust it, the `Bash(az:*)`
deny in `.claude/settings.json` can be removed. At that point Claude
calls `az` via the tool guard, and **the tool guard's `deny` list +
default-deny posture become the authoritative gate** instead of the
harness's.

Until then, the tool guard's policy is informational for Claude — Claude's
bash calls to `az` are blocked at the harness layer before they reach
the tool-guard. Only humans + non-Claude scripts exercise the policy
today.

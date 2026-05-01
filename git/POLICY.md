# git tool guard policy — design notes

The `.tool-guard/git.config.json` file controls what `git`
invocations the tool guard at `/usr/local/bin/git` blocks (with `deny`),
warns about (with `warn`), or allows silently (with `allow` or
`defaultMode: "allow"`).

Pattern follows common git-safety conventions: hard-deny push to
main/master always; advisory warn on destructive operations only when
running under a Claude ancestor process.

## Default posture: allow

Unlike `az`, the git tool guard uses `defaultMode: "allow"`. Most git
commands are safe (status, log, diff, fetch, pull, branch, …) and
prompting on every unknown verb would be unbearable in interactive use.
The list of `deny` and `warn` rules is the policy — everything else
runs without ceremony.

## The `claude_only` flag

Many destructive git operations (force push, --no-verify, reset --hard,
checkout --) are perfectly normal in an interactive shell — a developer
who types `git reset --hard HEAD~3` knows what they want. But the same
command issued by Claude during an autonomous task is a much higher
risk: the agent might be in a confused state, and the user can't see
the command before it runs.

`claude_only: true` on a rule means it only fires when running under a
Claude ancestor process (detected by walking `/proc` upward and
matching `cmdline` basenames). Same rule, different sensitivity
depending on who's at the keyboard.

## Categories

| Category | Effect | Used for |
|----------|--------|----------|
| `deny` (always) | Block + exit 13 | `push origin main`, `push --force origin main` — never OK regardless of who runs it |
| `warn` (claude_only) | Stderr advisory + run anyway | force-push, --no-verify, reset --hard, checkout --, blind merge strategies |
| `allow` | Silent + run | (not used here — defaultMode handles it) |
| `defaultMode: "allow"` | Silent + run | Everything else |

## Why these specific rules?

### Always-deny (`deny`)

- **`push origin main` / `push origin master`** — main is typically the
  production branch. Most teams have an explicit rule: "Never commit
  directly to main". Direct push bypasses CI, code review, and the
  integration branch.
- **`push --force origin main` / `... master`** — the only thing worse
  than a normal push to main is rewriting its history.

### Claude-only warn (`warn` + `claude_only: true`)

- **`push --force *`** — destructive on any branch. The warning under
  Claude reminds the agent to confirm no-one else has pushed. Prefer
  `--force-with-lease` (separate rule, same warning).
- **`commit --no-verify` / `commit -n` / `push --no-verify`** —
  bypasses pre-commit / pre-push hooks. Most teams' contributing
  guides treat this as forbidden unless explicitly requested. Fix
  the failing hook instead of skipping it.
- **`reset --hard*`** — discards uncommitted changes permanently. Easy
  to use accidentally during a confused recovery flow.
- **`checkout -- <files>`** — same; discards uncommitted changes in
  those files.
- **`checkout --theirs` / `merge -X theirs`** — blanket-accepts one
  side at every conflict. The "right" side is context-dependent (during
  rebase `theirs` = upstream; during merge `theirs` = the merged
  branch). Blind use can silently delete work.
- **`rebase -i *`** — interactive rebase needs editor input that Claude
  cannot provide. Better caught early than left to fail confusingly.

## Pattern syntax

Same as az — `fnmatch`-style globs against the full argv joined with
spaces. See `scripts/tool-guard/az/POLICY.md` for details.

A subtlety with git: many git commands accept a leading `-C <dir>` or
`--git-dir <path>` global flag. Patterns that should match regardless
of these flags need a leading `*`:

- ❌ `push origin main` — won't match `-C ../other-repo push origin main`
- ✅ `push origin main*` — matches the verb chain itself, but a leading
  `-C` would still bypass it. If you care about that, prefix the
  pattern with `* push origin main*`.

For now we accept the leading-flag gap as low-risk: a deliberate `-C
../other-repo push origin main` is a contortion that's unlikely to
happen by accident.

## Override

Same env vars as the engine:

```bash
# Disable logging (debug):
GIT_TG_DISABLE=1 git status

# See what would happen without running:
GIT_TG_DRYRUN=1 git push --force origin some-branch

# Emergency bypass for a single call (e.g. hotfix to main):
/usr/bin/git push origin main
```

## Per-user overrides

Edit `.tool-guard/git.config.local.json` (gitignored) for personal
adjustments — e.g. relax a warn you find too chatty, or add a
project-specific deny while you're working in a sensitive area.

```json
{
  "warn": [
    {"pattern": "checkout main*", "message": "You're switching off your feature branch — sure?"}
  ]
}
```

## How to test the policy

```bash
# What would happen (no exec, no log):
GIT_TG_DRYRUN=1 python3 scripts/tool-guard/git/wrapper.py push origin main
# → DRYRUN: classify=deny rule="push origin main*" — would block

GIT_TG_DRYRUN=1 python3 scripts/tool-guard/git/wrapper.py status
# → DRYRUN: classify=allow rule=<defaultMode> under_claude=False — would log + run

# Run the test suite:
bash scripts/tool-guard/_tests/git.smoke.test.sh
```

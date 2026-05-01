# gh tool guard policy — design notes

The `.tool-guard/gh.config.json` file controls what `gh` (GitHub CLI)
invocations the tool guard at `/usr/local/bin/gh` blocks (with
`deny`), warns about (with `warn`), or allows silently (with `allow`
or `defaultMode: "allow"`).

Pattern follows common gh-safety conventions: hard-deny destructive
verbs (`repo delete`, `secret delete`, `auth logout`); claude-only
warnings on mutations (`pr merge`, `issue close`, `release create`);
and PR-body validation that warns when GitHub auto-close keywords
(`Fixes #`, `Closes #`, `Resolves #`) appear in `gh pr create --body`
text.

## Default posture: allow

Like `git`, the `gh` tool guard uses `defaultMode: "allow"`. The
overwhelming majority of `gh` invocations are read-only or benign
mutations (`pr list`, `issue create`, `pr comment`, `auth status`,
`run view`). Prompting on every unknown verb would be unbearable.
The `deny` and `warn` lists encode the actual risks.

## Categories

| Category | Effect | Used for |
|----------|--------|----------|
| `deny` (always) | Block + exit 13 | Credential clearing (`auth logout`), resource deletion (`repo delete`, `secret delete`, `ssh-key delete`, `release delete`, …) |
| `warn` (claude_only) | Stderr advisory + run anyway | Mutations under Claude that should be human-confirmed (`pr merge`, `pr close`, `issue close`, `release create`) |
| `warn` (always) | Stderr advisory + run anyway | PR-body autoclose keywords — GitHub auto-closes referenced issues at merge time, regardless of whether your DoD is met |
| `allow` | Silent + run | (not used here — defaultMode handles it) |
| `defaultMode: "allow"` | Silent + run | Everything else |

## The PR-body autoclose check

GitHub matches keywords case-insensitively for issue auto-close at
merge time:

```
fix #NNN, fixes #NNN, fixed #NNN
close #NNN, closes #NNN, closed #NNN
resolve #NNN, resolves #NNN, resolved #NNN
```

When merged, the linked issue is auto-closed — even if your DoD
checklist isn't fully ticked. This is a frequent footgun for teams
that use the issue body / comments as the source of truth for
"is this done?".

The tool guard scans `gh pr create --body <text>` and warns if any of
these keywords appear with a `#NNN` suffix. The PR is still created
(this is a `warn` rule, not `deny`); the user can edit the body
afterwards if they want to break the auto-close link.

We recommend using `Part of #NNN`, `Addresses #NNN`, or just plain
`See #NNN` to reference issues without auto-closing them.

### Coverage

The autoclose check fires for both `gh pr create` and `gh pr edit`
(both can introduce or change the autoclose link), and recognises
all three argument forms:

- `--body "Fixes #N"` (long form, space-separated value)
- `--body=Fixes #N`   (long form, equals-separated value — `[ =]` char class)
- `-b "Fixes #N"`     (short form)

Issue commands (`issue create`, `issue edit`, `issue comment`) are
**not** flagged: issue bodies don't trigger PR-merge auto-close.
Adding a `Fixes #N` to an issue body or comment is harmless; the rules
are scoped with a `pr create*` / `pr edit*` prefix to avoid the false
positive.

### Pattern matching limitation

`fnmatch` is case-sensitive on Linux, so the rules use character
classes like `[Ff]ix #*` and `[Ff]ixes #*` to catch the two most
common case variants (capitalized + lowercase). All-caps `FIXES #` or
mixed-case `FixEs #` would slip through. If your team writes those,
add explicit patterns to the local config:

```json
{
  "warn": [
    {"pattern": "pr create*--body[ =]*FIXES #*", "message": "..."},
    {"pattern": "pr create*--body[ =]*FIXED #*", "message": "..."}
  ]
}
```

A future engine improvement would be a `case_insensitive: true` flag
per rule — see TODO.md.

## Why these specific rules?

### Always-deny (`deny`)

- **`auth logout`** — clears the cached credential. Subsequent gh
  calls (and any tooling that uses `gh auth token`) would prompt for
  re-authentication. Almost never intentional from a script.
- **`repo delete`** — permanently deletes a GitHub repository. This
  cascades to all forks, issues, PRs, Actions runs, and packages.
  Some teams enforce 2-person approval for this in the GitHub UI; the
  CLI bypasses that.
- **`secret delete` / `variable delete`** — silently breaks any CI
  workflow that depends on the secret/variable. The break only
  manifests on the next workflow run, which can be much later.
- **`ssh-key delete` / `gpg-key delete`** — revokes a key's git or
  signature access. Useful for off-boarding but coordinate first.
- **`release delete`** — removes the release page + uploaded assets.
  Users who pinned to that release URL lose access.

### Claude-only warn (`warn` + `claude_only: true`)

- **`pr merge`** — merging is generally fine but should be human-
  confirmed under Claude. Especially the `--admin` variant which
  bypasses required reviews.
- **`pr close` / `issue close`** — closing-without-merging or
  closing-as-completed should be intentional. The advisory reminds
  the agent + user that this affects shared state.
- **`release create`** — publishes a release that's visible to all
  users + cuts a tag. Title typos, wrong target branch, missing
  assets all need a human eye.

### Always warn (`warn`) — PR-body autoclose keywords

Six patterns covering `[Ff]ix #`, `[Ff]ixes #`, `[Cc]lose #`,
`[Cc]loses #`, `[Rr]esolve #`, `[Rr]esolves #`. The warning fires
during `gh pr create` and tells the user to use neutral phrasing
instead.

## Override

Same env vars as the engine:

```bash
# Disable logging (debug):
GH_TG_DISABLE=1 gh auth status

# See what would happen without running:
GH_TG_DRYRUN=1 gh pr merge 1234

# Emergency bypass: invoke real gh directly (skips the wrapper via PATH)
/usr/bin/gh repo delete some-old-fork

# Or use the management CLI:
tg check gh pr create --title "fix x" --body "Fixes #999"
```

## Per-user overrides

Edit `.tool-guard/gh.config.local.json` (gitignored) for personal
adjustments — e.g. add additional autoclose-keyword variants your
team uses, or tighten a `warn` to a `deny`:

```json
{
  "deny": [
    {"pattern": "pr merge --admin*",
     "message": "--admin bypass requires written approval — even off-hours."}
  ]
}
```

## How to test the policy

```bash
# Dry-run via tg:
tg check gh repo delete my-fork
tg check gh pr create --title "x" --body "Fixes #1234"
tg check gh pr merge 5678 --admin

# Or directly:
GH_TG_DRYRUN=1 python3 scripts/tool-guard/gh/wrapper.py auth logout

# Run the smoke test suite:
bash scripts/tool-guard/_tests/gh.smoke.test.sh
```

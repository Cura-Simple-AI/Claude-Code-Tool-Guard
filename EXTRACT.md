# Extracting tool guard as a standalone repository

This package was developed as `scripts/tool-guard/` inside a larger
project. To spin it off as its own GitHub repo (or any standalone
location) with full git history but no parent-project files:

## One-command extract

```bash
# From the parent repo's root:
git subtree split --prefix=scripts/tool-guard/ -b tool-guard-export
```

That creates a new local branch `tool-guard-export` containing only
the contents of `scripts/tool-guard/`, with full per-file history
preserved.

## Push to the new repo

```bash
# Create the new repo on GitHub first (empty, no README).
git remote add tool-guard git@github.com:<your-org>/tool-guard.git

# Push the extracted branch as 'main' on the new repo:
git push tool-guard tool-guard-export:main
```

## What ships in the extracted repo

After extraction, the standalone repo's root looks like this:

```
.
├── LICENSE                ← MIT
├── README.md              ← project pitch + quickstart
├── CONTRIBUTING.md
├── CHANGELOG.md
├── SECURITY.md
├── EXTRACT.md             ← this file (you can delete it post-extract)
├── .gitignore
├── .github/
│   └── workflows/
│       └── test.yml       ← CI activates automatically post-extract
├── tool_guard.py          ← the shared engine
├── install.sh             ← orchestrator
├── uninstall.sh           ← orchestrator
├── az/
│   ├── wrapper.py
│   ├── POLICY.md
│   └── log-summary.sh
├── git/
│   ├── wrapper.py
│   └── POLICY.md
├── sleep/
│   ├── wrapper.py
│   └── POLICY.md
├── examples/
│   └── .tool-guard/
│       ├── _defaults.json
│       ├── az.config.json
│       └── git.config.json
└── _tests/
    ├── tool_guard.test.sh
    ├── az.smoke.test.sh
    ├── git.smoke.test.sh
    └── sleep.test.sh
```

## What does NOT ship (and why)

The parent repo's actual `.tool-guard/<tool>.config.json` files —
those are the parent project's policy data, not part of the tool guard
package. Users of the standalone repo bring their own configs, using
`examples/.tool-guard/` as a starting template.

## CI activation

The workflow file lives at `.github/workflows/test.yml` post-extract
(it was at `scripts/tool-guard/.github/workflows/test.yml` inside the
parent repo, where GitHub Actions does NOT auto-discover it — only
top-level `.github/` is scanned). Once extracted, GitHub will pick it
up on the next push.

## Verification

After pushing to the new repo, verify:

1. CI runs and passes on the new `main`.
2. README displays correctly with the right links.
3. `git clone` + `bash _tests/tool_guard.test.sh` works on a fresh
   machine with only Python 3.9+ and bash.

## Maintenance after split

You have two options for keeping the standalone repo in sync with the
parent's `scripts/tool-guard/` directory:

### Option A — One-way fork

Treat the standalone repo as the canonical source. Re-extract it from
the parent only at major releases (or never again). Bug fixes
upstream into the standalone repo via normal PRs; cherry-pick back to
the parent if needed.

### Option B — Two-way subtree sync

Use `git subtree push` to send parent-side fixes upstream, and
`git subtree pull` to bring standalone changes back into the parent:

```bash
# Pull standalone updates back into the parent repo:
git subtree pull --prefix=scripts/tool-guard/ tool-guard main --squash

# Push parent-side fixes to the standalone repo:
git subtree push --prefix=scripts/tool-guard/ tool-guard main
```

This is more work but keeps both copies in lockstep. Most projects
end up with Option A after the first few syncs.

## After-extract cleanup

Once the standalone repo is established, you can:

1. Delete this `EXTRACT.md` file (it's only relevant for the initial
   split).
2. Update `README.md` if the project pitch should differ in the
   standalone presentation (e.g. drop references to "this is part of
   X").
3. Tag the initial release: `git tag v0.1.0 && git push --tags`.
4. Enable branch protection on `main` in GitHub Settings.

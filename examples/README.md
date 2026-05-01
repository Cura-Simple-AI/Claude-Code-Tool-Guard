# Example configurations

These are starter templates for the policy files that `tool-guard`
loads from the `.tool-guard/` directory at your project root.

## Layout

```
examples/.tool-guard/
├── _defaults.json                    cross-cutting deny rules (all tools)
├── az.config.json            Azure CLI starter
└── git.config.json           git starter
```

## How to use

Copy these files to your project's repo root, then edit:

```bash
mkdir -p .tool-guard
cp examples/.tool-guard/_defaults.json                    .tool-guard/
cp examples/.tool-guard/az.config.json            .tool-guard/
cp examples/.tool-guard/git.config.json           .tool-guard/
```

Then commit them:

```bash
git add .tool-guard/
git commit -m "chore: add tool-guard policy"
```

## Per-user overrides

Per-user policy lives in `.tool-guard/<tool>.config.local.json`
and is gitignored. Add this to your `.gitignore`:

```
.tool-guard/*.local.json
```

The local file is created automatically when you press `[A]` (allow
always) or `[D]` (deny always) at the tool-guard's interactive prompt.

## What goes in `_defaults.json`?

Cross-cutting rules that apply to every wrapped tool. The shipped
template denies anything matching `* delete *`, `* purge *`, or
`* destroy *` — global guard rails for destructive operations,
regardless of which tool is invoked. Edit if your team has different
absolute-block conventions.

## What goes in `<tool>.config.json`?

Per-tool policy:
- `defaultMode`: what to do for unmatched calls (`deny`, `allow`,
  `warn`, or `prompt` for interactive confirmation).
- `allow`, `warn`, `deny`: lists of glob patterns or rule objects.

Each rule entry can be a plain string or an object:
```json
{"pattern": "boards work-item show*", "message": "...", "claude_only": false}
```

See `../README.md` and `../<tool>/POLICY.md` for the full schema.

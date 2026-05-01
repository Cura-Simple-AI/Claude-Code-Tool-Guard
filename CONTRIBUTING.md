# Contributing to tool guard

Thanks for your interest in contributing! This is a small Python +
shell project with a focused scope (CLI policy enforcement) — most
contributions land in a single PR.

## Quick dev setup

```bash
git clone https://github.com/<your-fork>/tool-guard.git
cd tool-guard

# No deps to install — the engine is pure stdlib Python (3.9+).
# The orchestrator is bash + sudo + /usr/local/bin/.

# Run the test suite (no setup required):
bash _tests/tool_guard.test.sh
bash _tests/az.smoke.test.sh
bash _tests/git.smoke.test.sh
bash _tests/sleep.test.sh
```

All 167 tests should pass on a fresh clone.

## Adding a new tool guard

A new pattern-matched tool tool guard is ~30 lines of stub code + a JSON
config file + an optional POLICY.md. Walkthrough:

### 1. Create the stub

`<tool>/wrapper.py`:

```python
#!/usr/bin/env python3
"""<tool> tool-guard — delegates to tool_guard engine."""
import os, sys

TOOL = "<tool>"
REAL = os.environ.get("<TOOL>_TG_REAL_BIN", "/usr/bin/<tool>")

if os.environ.get("_<TOOL>_TG_ACTIVE"):
    os.execv(REAL, [REAL] + sys.argv[1:])
os.environ["_<TOOL>_TG_ACTIVE"] = "1"

for _cand in ("/usr/local/lib/tool-guard",
              os.path.dirname(os.path.dirname(os.path.abspath(__file__)))):
    if os.path.exists(os.path.join(_cand, "tool_guard.py")):
        sys.path.insert(0, _cand)
        break
from tool_guard import run  # noqa: E402

sys.exit(run(
    tool_name=TOOL,
    real_bin=REAL,
    secret_flags={"--token", "..."},  # per-tool secret flags for redaction
))
```

(For non-pattern guards like `sleep` — numeric input validation —
write a self-contained stub instead. See `sleep/wrapper.py` for an
example.)

### 2. Create the example policy

`examples/.tool-guard/<tool>.config.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "_comment": "Description of this tool's policy.",
  "defaultMode": "prompt",
  "allow": ["safe-verb*"],
  "warn":  [{"pattern": "destructive*", "claude_only": true, "message": "..."}],
  "deny":  [{"pattern": "very-destructive*", "message": "..."}]
}
```

### 3. (Optional) Document the rationale

`<tool>/POLICY.md` explaining:
- Default posture (prompt/allow/deny) and why
- Why each `deny` rule is there (reasoning, not just the rule)
- Tool-specific quirks (e.g. argv parsing differences)

### 4. Add a smoke test

`_tests/<tool>.smoke.test.sh` should verify the example config
loads and a few representative commands classify correctly. Use the
same template as `az.smoke.test.sh` and `git.smoke.test.sh`.

### 5. Update the docs

- Add the tool to the README's "Built-in tool guards" table.
- Add a CHANGELOG entry under `## [Unreleased]`.

## Code style

- Python: PEP 8, type hints encouraged. We use `from __future__
  import annotations` so unions like `dict | None` work on 3.9.
- Shell: `set -uo pipefail` for tests (NOT `-e` — assertions handle
  their own exit codes); `set -euo pipefail` for orchestration.
- No external Python dependencies. Engine and tests are pure stdlib.
- Tests should not depend on network, the real wrapped binaries, or
  any external state beyond `/tmp` and `mktemp -d`.

## Testing philosophy

- **Engine tests** (`_tests/tool_guard.test.sh`) cover the engine in
  isolation using a synthesized "testtool" stub. They should pass
  without `az`, `git`, or any other CLI installed.
- **Smoke tests** (`_tests/<tool>.smoke.test.sh`) cover a tool's
  shipped example config end-to-end. They should classify a
  representative set of commands without invoking real binaries
  (use `/bin/true` as the fake real binary).
- **Both kinds use bash assertions** with explicit exit codes and
  stderr matching. No frameworks.

When you find a bug, write a failing test first, then fix the code.
Every bug-fix commit in our history follows this pattern.

## PR checklist

- [ ] All four test suites pass locally (`for t in _tests/*.sh; do
      bash "$t" || break; done`).
- [ ] CHANGELOG entry added under `## [Unreleased]`.
- [ ] Public API (`run()` signature) unchanged, OR documented as a
      breaking change in CHANGELOG.
- [ ] No new external dependencies.
- [ ] Documentation updated for any user-facing behaviour change.

## Discussion

For larger changes (new severity tier, schema changes, additional
matcher types like numeric-validator generalisation), please open an
issue first to discuss the approach before sending a PR.

#!/usr/bin/env python3
"""gh tool-guard — thin stub that delegates to the shared tool_guard engine.

All policy enforcement lives in scripts/tool-guard/tool_guard.py.
See scripts/tool-guard/gh/POLICY.md for gh-specific policy notes
(in particular the PR-body autoclose-keyword warnings).
"""
import os
import sys

TOOL = "gh"
REAL = os.environ.get("GH_TG_REAL_BIN", "/usr/bin/gh")

# Recursion shortcut removed (security review P1). See az/wrapper.py.

_test_mode = os.environ.get("TG_TEST_MODE") == "1"
_engine_dirs = ([os.environ["TOOL_GUARD_ENGINE_DIR"]]
                if (_test_mode and os.environ.get("TOOL_GUARD_ENGINE_DIR"))
                else ["/usr/local/lib/tool-guard",
                      os.path.dirname(os.path.dirname(os.path.abspath(__file__)))])
for _cand in _engine_dirs:
    if os.path.exists(os.path.join(_cand, "tool_guard.py")):
        sys.path.insert(0, _cand)
        break

try:
    from tool_guard import run  # noqa: E402
except ImportError as e:
    sys.stderr.write(
        f"{TOOL}-tool-guard: ❌ tool_guard engine not found ({e}).\n"
        "  Expected at /usr/local/lib/tool-guard/tool_guard.py (installed)\n"
        "  or alongside this file (dev/test).\n"
        "  Run scripts/tool-guard/install.sh to (re)install.\n"
        f"  To bypass the guard for this call only: {REAL} <args>\n"
    )
    sys.exit(127)

# gh secret flags: --token (gh auth login --token), -p (no — gh uses
# different short flags), and any others that ship a credential value.
sys.exit(run(
    tool_name=TOOL,
    real_bin=REAL,
    secret_flags={"--token", "--with-token"},
))

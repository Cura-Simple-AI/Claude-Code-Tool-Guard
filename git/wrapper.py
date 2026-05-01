#!/usr/bin/env python3
"""git tool-guard — thin stub that delegates to the shared tool_guard engine.

All policy enforcement lives in scripts/tool-guard/tool_guard.py.
See scripts/tool-guard/git/POLICY.md for git-specific policy notes.
"""
import os
import sys

TOOL = "git"
REAL = os.environ.get("GIT_TG_REAL_BIN", "/usr/bin/git")

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
    # Fail-fast on missing engine. Falling through to the real binary
    # would silently disable policy enforcement — exactly the wrong
    # behaviour for a guard. Exit 127 (same as "binary not found")
    # with a clear remedy.
    sys.stderr.write(
        f"{TOOL}-tool-guard: ❌ tool_guard engine not found ({e}).\n"
        "  Expected at /usr/local/lib/tool-guard/tool_guard.py (installed)\n"
        "  or alongside this file (dev/test).\n"
        "  Run scripts/tool-guard/install.sh to (re)install.\n"
        f"  To bypass the guard for this call only: {REAL} <args>\n"
    )
    sys.exit(127)

# git secret flags are conservative — credential helpers usually go via
# /run/credentials, not argv. Add patterns here if future workflows pass
# tokens on the command line.
sys.exit(run(
    tool_name=TOOL,
    real_bin=REAL,
    secret_flags=frozenset(),
))

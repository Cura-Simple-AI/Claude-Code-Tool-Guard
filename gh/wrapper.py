#!/usr/bin/env python3
"""gh tool-guard — thin stub that delegates to the shared tool_guard engine.

See gh/POLICY.md for gh-specific notes (PR-body autoclose-keyword warnings).
"""
# TOOL_GUARD_STUB_v1 — canonical magic line.
import os
import sys

TOOL = "gh"
REAL = os.environ.get("GH_TG_REAL_BIN", "/usr/bin/gh")  # TG_REAL_BIN_DEFAULT

_test_mode = (os.environ.get("TG_TEST_MODE") == "1"
              and os.path.isfile("/etc/tool-guard/test-mode-enabled"))
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
        "  Run scripts/tool-guard/install.sh to (re)install.\n"
        f"  Bypass for one call: {REAL} <args>\n"
    )
    sys.exit(127)

sys.exit(run(
    tool_name=TOOL,
    real_bin=REAL,
    secret_flags={"--token", "--with-token"},
))

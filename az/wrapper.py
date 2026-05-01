#!/usr/bin/env python3
"""az tool-guard — thin stub that delegates to the shared tool_guard engine.

Per-tool constants only (tool name, real binary path, secret-bearing
flags). All policy enforcement lives in tool_guard.py.
"""
# TOOL_GUARD_STUB_v1 — canonical magic line. Detection helpers
# (_is_our_wrapper / _guard_installed in tg, install.sh's overwrite
# check) match on this exact comment.
import os
import sys

TOOL = "az"
REAL = os.environ.get("AZ_TG_REAL_BIN", "/usr/bin/az")  # TG_REAL_BIN_DEFAULT

# TOOL_GUARD_ENGINE_DIR honored only in test mode (TG_TEST_MODE=1 +
# /etc/tool-guard/test-mode-enabled file). See SECURITY.md.
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
    # Fail-fast on missing engine. Falling through to the real binary
    # would silently disable policy enforcement.
    sys.stderr.write(
        f"{TOOL}-tool-guard: ❌ tool_guard engine not found ({e}).\n"
        "  Expected at /usr/local/lib/tool-guard/tool_guard.py.\n"
        "  Run scripts/tool-guard/install.sh to (re)install.\n"
        f"  Bypass for one call: {REAL} <args>\n"
    )
    sys.exit(127)

sys.exit(run(
    tool_name=TOOL,
    real_bin=REAL,
    secret_flags={
        "--password",
        "-p",
        "--client-secret",
        "--secret",
        "--token",
        "--certificate-password",
        "--admin-password",
        "--sas-token",
    },
))

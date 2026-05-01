#!/usr/bin/env python3
"""az tool-guard — thin stub that delegates to the shared tool_guard engine.

All policy enforcement (config loading, classification, prompt, log,
redact, force-override, dry-run, recursion defence) lives in
scripts/tool-guard/tool_guard.py. This file just declares the per-tool
constants (tool name, real binary path, secret-bearing flags) and calls
into the engine.

See scripts/tool-guard/README.md for the system architecture and
scripts/tool-guard/az/POLICY.md for az-specific policy notes.
"""
import os
import sys

TOOL = "az"
REAL = os.environ.get("AZ_TG_REAL_BIN", "/usr/bin/az")

# Recursion defence — fast path before importing the engine.
if os.environ.get("_AZ_TG_ACTIVE"):
    os.execv(REAL, [REAL] + sys.argv[1:])
os.environ["_AZ_TG_ACTIVE"] = "1"

# Locate engine: installed location first, then source-relative for dev/test.
for _cand in ("/usr/local/lib/tool-guard",
              os.path.dirname(os.path.dirname(os.path.abspath(__file__)))):
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

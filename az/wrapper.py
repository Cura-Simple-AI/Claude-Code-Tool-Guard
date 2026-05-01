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

# NOTE: previously used env-var sentinel _AZ_TG_ACTIVE for a
# recursion shortcut. Removed (security review P1 finding): env vars
# are inheritable + user-poisonable, so trusting any sentinel value
# created a bypass vector. Engine always runs policy now; recursion
# cost is ~1ms (well below noise) and most CLIs don't self-invoke.

# Locate engine. TOOL_GUARD_ENGINE_DIR (single dir) overrides if set —
# useful for tests and for pointing at a checked-out engine. Otherwise:
# installed location first, then source-relative for dev.
_engine_dirs = ([os.environ["TOOL_GUARD_ENGINE_DIR"]]
                if os.environ.get("TOOL_GUARD_ENGINE_DIR")
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

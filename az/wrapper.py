#!/usr/bin/env python3
"""az tool-guard — thin stub that delegates to the shared tool_guard engine.

All policy enforcement (config loading, classification, prompt, log,
redact, dry-run) lives in scripts/tool-guard/tool_guard.py. This file
just declares the per-tool constants (tool name, real binary path,
secret-bearing flags) and calls into the engine.

See scripts/tool-guard/README.md for the system architecture and
scripts/tool-guard/az/POLICY.md for az-specific policy notes.
"""
# TOOL_GUARD_STUB_v1 — canonical magic line. Detection helpers (tg's
# _is_our_wrapper, _guard_installed, install.sh's overwrite check)
# look for this exact comment to identify our stubs. Do NOT remove or
# change without updating those callers in lockstep.
import os
import sys

TOOL = "az"
REAL = os.environ.get("AZ_TG_REAL_BIN", "/usr/bin/az")  # TG_REAL_BIN_DEFAULT

# NOTE: previously used env-var sentinel _AZ_TG_ACTIVE for a
# recursion shortcut. Removed (security review P1 finding): env vars
# are inheritable + user-poisonable, so trusting any sentinel value
# created a bypass vector. Engine always runs policy now; recursion
# cost is ~1ms (well below noise) and most CLIs don't self-invoke.

# Locate engine. TOOL_GUARD_ENGINE_DIR is honored ONLY when TG_TEST_MODE=1
# is also set (P1 finding: an unguarded override would let an attacker
# substitute their own engine and execute arbitrary Python). Production
# never sets TG_TEST_MODE; tests do.
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

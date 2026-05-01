#!/usr/bin/env bash
# Test suite for the sleep tool-guard.
#
# Sleep is a self-contained numeric-validator stub (NOT delegating to
# tool_guard.py). Tests verify: duration parsing, multi-arg sum,
# Claude-ancestor branch, FORCE override, defensive parsing of env vars,
# missing real_bin handling.
#
# Real binary substituted with /bin/true so tests don't actually wait.
# Claude-ancestor detection is monkey-patched per-test (the tool-guard
# itself is entirely standalone and doesn't expose a FAKE_CLAUDE env var).
#
# Run: bash scripts/tool-guard/_tests/sleep.test.sh

set -uo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLEEP_WRAPPER="$PKG_ROOT/sleep/wrapper.py"
SLEEP_DIR="$(dirname "$SLEEP_WRAPPER")"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1${2:+ — $2}"; }

# Run tool-guard directly (no Claude monkey-patch — real ancestor detection).
# Usage: tt VAR=v1 VAR2=v2 -- arg1 arg2
tt() {
  local -a env_vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_vars+=("$1"); shift
  done
  shift  # drop --
  env "${env_vars[@]}" python3 "$SLEEP_WRAPPER" "$@"
}

# Run tool-guard with monkey-patched is_claude_ancestor()
# Usage: tt_claude 0|1 VAR=v1 -- arg1 arg2
tt_claude() {
  local claude="$1"; shift
  local -a env_vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_vars+=("$1"); shift
  done
  shift  # drop --
  env "${env_vars[@]}" python3 - "$@" <<PYEOF
import os, sys
sys.path.insert(0, "$SLEEP_DIR")
import wrapper
wrapper.is_claude_ancestor = lambda: $([[ "$claude" == "1" ]] && echo True || echo False)
sys.argv = ['sleep'] + sys.argv[1:]
sys.exit(wrapper.main())
PYEOF
}

assert_exit() {
  local desc="$1" expected="$2"; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then pass "$desc (exit $actual)"
  else fail "$desc" "expected $expected, got $actual"; fi
}

assert_stderr() {
  local desc="$1" needle="$2"; shift 2
  local err
  err=$("$@" 2>&1 >/dev/null) || true
  if printf '%s' "$err" | grep -qF -- "$needle"; then pass "$desc"
  else fail "$desc" "stderr missing '$needle'. Got: $(printf '%s' "$err" | head -3 | tr '\n' '|')"; fi
}

echo ""
echo "════════════════════════════════════════════════════════════"
echo " sleep tool-guard — test suite"
echo "════════════════════════════════════════════════════════════"

# ─── 1. parse_duration unit tests ────────────────────────────────────
echo ""
echo "── 1. parse_duration() ──"
python3 - <<PYEOF
import sys
sys.path.insert(0, "$SLEEP_DIR")
from wrapper import parse_duration

assert parse_duration("30") == 30.0
assert parse_duration("0") == 0.0
assert parse_duration("0.5") == 0.5

assert parse_duration("30s") == 30.0
assert parse_duration("2m") == 120.0
assert parse_duration("1h") == 3600.0
assert parse_duration("1d") == 86400.0
assert parse_duration("1.5h") == 5400.0

assert parse_duration("abc") is None
assert parse_duration("") is None
assert parse_duration("--help") is None
assert parse_duration("30x") is None
assert parse_duration("-5") is None
assert parse_duration("5min") is None

assert parse_duration("  30  ") == 30.0
assert parse_duration("30s\n") == 30.0
print("OK")
PYEOF
[[ $? -eq 0 ]] && pass "parse_duration() — 16 sub-cases" || fail "parse_duration() unit test"

# ─── 2. sum_durations unit tests ─────────────────────────────────────
echo ""
echo "── 2. sum_durations() — multi-arg sum ──"
python3 - <<PYEOF
import sys
sys.path.insert(0, "$SLEEP_DIR")
from wrapper import sum_durations

assert sum_durations(["30"]) == 30.0
assert sum_durations(["1", "2", "3"]) == 6.0
assert sum_durations(["5", "999"]) == 1004.0
assert sum_durations(["1m", "30s"]) == 90.0
assert sum_durations(["1h", "30m", "30s"]) == 5430.0

assert sum_durations(["30", "--invalid", "5"]) == 35.0

assert sum_durations(["--help"]) is None
assert sum_durations(["abc", "def"]) is None
assert sum_durations([]) is None
print("OK")
PYEOF
[[ $? -eq 0 ]] && pass "sum_durations() — 9 sub-cases" || fail "sum_durations() unit test"

# ─── 3. Tool-guard behavior — outside Claude ────────────────────────────
echo ""
echo "── 3. Outside Claude — always passes through ──"
# Note: must use tt_claude 0 even when "outside Claude" — the test suite
# itself runs inside Claude Code, so real ancestor detection sees claude.
assert_exit "sleep 5 → passes through" 0 \
  tt_claude 0 SLEEP_TG_REAL_BIN=/bin/true -- 5

assert_exit "sleep 999 → passes through (no Claude)" 0 \
  tt_claude 0 SLEEP_TG_REAL_BIN=/bin/true -- 999

assert_exit "sleep 5 999 → passes through (no Claude)" 0 \
  tt_claude 0 SLEEP_TG_REAL_BIN=/bin/true -- 5 999

# /bin/true with no args exits 0 — tool-guard just exec's it
assert_exit "no args → passes through to real_bin" 0 \
  tt_claude 0 SLEEP_TG_REAL_BIN=/bin/true --

# ─── 4. Tool-guard behavior — under Claude ──────────────────────────────
echo ""
echo "── 4. Under Claude — guard kicks in ──"

assert_exit "sleep 5 (≤ max) under Claude → passes through" 0 \
  tt_claude 1 SLEEP_TG_MAX=30 SLEEP_TG_REAL_BIN=/bin/true -- 5

assert_exit "sleep 60 (> max) under Claude → blocked + exit 1" 1 \
  tt_claude 1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- 60

assert_stderr "blocked sleep stderr message" "blocked sleep" \
  tt_claude 1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- 60

# Multi-arg sum > max → blocked (regression test for the bug we fixed)
assert_exit "sleep 5 999 → sums to 1004s, blocked" 1 \
  tt_claude 1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- 5 999

assert_stderr "multi-arg block message includes total" "1004s" \
  tt_claude 1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- 5 999

# Unit-suffix sum
assert_exit "sleep 1m 30s → sums to 90s, blocked" 1 \
  tt_claude 1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- 1m 30s

assert_stderr "unit-suffix block message includes total" "90s" \
  tt_claude 1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- 1m 30s

# Unparseable args → passes through (real sleep would error, but tool-guard doesn't second-guess)
assert_exit "sleep --help (unparseable) → passes through" 0 \
  tt_claude 1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- --help

# ─── 5. SLEEP_TG_FORCE override ─────────────────────────────────
echo ""
echo "── 5. SLEEP_TG_FORCE override ──"
assert_exit "FORCE=1 bypasses guard even under Claude" 0 \
  tt_claude 1 SLEEP_TG_FORCE=1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- 999

# Without FORCE the same call would block (sanity check the previous test isn't accidentally passing for another reason)
assert_exit "without FORCE the same call blocks" 1 \
  tt_claude 1 SLEEP_TG_MAX=10 SLEEP_TG_REAL_BIN=/bin/true -- 999

# ─── 6. Defensive env var handling ───────────────────────────────────
echo ""
echo "── 6. Defensive env var handling ──"
assert_stderr "invalid SLEEP_TG_MAX → warning + fallback to default" "invalid SLEEP_TG_MAX" \
  tt SLEEP_TG_MAX=invalid SLEEP_TG_REAL_BIN=/bin/true -- 5

assert_exit "invalid SLEEP_TG_MAX → still works (falls to 30s default)" 0 \
  tt SLEEP_TG_MAX=invalid SLEEP_TG_REAL_BIN=/bin/true -- 5

assert_exit "missing real_bin → exit 127" 127 \
  tt SLEEP_TG_REAL_BIN=/nonexistent/path -- 5

assert_stderr "missing real_bin → clear error message" "real sleep binary not found" \
  tt SLEEP_TG_REAL_BIN=/nonexistent/path -- 5

# ─── 7. Recursion sentinel ───────────────────────────────────────────
echo ""
echo "── 7. Recursion sentinel ──"
assert_exit "_SLEEP_TG_ACTIVE=1 → execv real (no guard)" 0 \
  tt _SLEEP_TG_ACTIVE=1 SLEEP_TG_REAL_BIN=/bin/true -- 999

# Without sentinel + outside Claude (monkey-patched) → also passes through
assert_exit "without sentinel + outside Claude → passes through" 0 \
  tt_claude 0 SLEEP_TG_REAL_BIN=/bin/true -- 999

# ─── Result ──────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  RESULT: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

#!/usr/bin/env bash
# tg CLI test suite. Covers:
#   - tg list — source-tree mode (lists wrapper.py subdirs)
#   - tg list — installed mode (lists OUR wrappers in INSTALL_DIR)
#   - tg log <tool> -n {N, 0, -1} validation
#   - tg check <tool> ... in both source and installed mode
#   - tg version reports paths
#   - tg config validate happy path
#
# All tests use mktemp dirs + TG_INSTALL_DIR / TG_ENGINE_DIR / TG_LOG_DIR
# overrides so they don't depend on / pollute the real install.

set -uo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TG="$PKG_ROOT/tg"

if [[ ! -x "$TG" ]]; then
  echo "FATAL: $TG not executable" >&2
  exit 1
fi

PASS=0
FAIL=0
fail() {
  local what="$1" why="${2-}"
  echo "  ❌ $what: $why" >&2
  FAIL=$((FAIL + 1))
}
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }

assert_eq() {
  local what="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then pass "$what"
  else fail "$what" "expected '$expected', got '$got'"
  fi
}

assert_contains() {
  local what="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then pass "$what"
  else fail "$what" "expected to contain '$needle', got: $(echo "$haystack" | head -3)"
  fi
}

echo "════════════════════════════════════════════════════════════"
echo " tg CLI tests"
echo "════════════════════════════════════════════════════════════"

# ─── tg version ──────────────────────────────────────────────────────
echo ""
echo "── tg version ──"
out=$("$TG" version 2>&1)
assert_contains "version output" "tool-guard" "$out"
assert_contains "version reports package path" "package:" "$out"

# ─── tg list (source-tree mode) ──────────────────────────────────────
echo ""
echo "── tg list (source-tree mode) ──"
out=$("$TG" list 2>&1)
assert_contains "lists az from source-tree" "az" "$out"
assert_contains "lists git from source-tree" "git" "$out"
assert_contains "header is 'in package' in source mode" "in package" "$out"

# ─── tg list (installed mode) — simulated via INSTALL_DIR override ───
echo ""
echo "── tg list (installed mode, simulated) ──"
TMP_INSTALL=$(mktemp -d)
TMP_ENGINE=$(mktemp -d)
# Drop a fake "wrapper" file that looks like ours (Python + tool_guard token)
cat > "$TMP_INSTALL/foo" <<'EOF'
#!/usr/bin/env python3
# Token that _guard_installed() looks for: tool_guard
import sys; sys.exit(0)
EOF
chmod +x "$TMP_INSTALL/foo"
# Drop a non-wrapper binary that should NOT be listed
cat > "$TMP_INSTALL/notmine" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP_INSTALL/notmine"
# Engine dir needs the engine file to make _engine_installed() truthy
touch "$TMP_ENGINE/tool_guard.py"

# Run tg in installed mode by copying it to TMP_INSTALL (so PKG_ROOT==INSTALL_DIR)
cp "$TG" "$TMP_INSTALL/tg"
chmod +x "$TMP_INSTALL/tg"
out=$(TG_INSTALL_DIR="$TMP_INSTALL" TG_ENGINE_DIR="$TMP_ENGINE" \
      "$TMP_INSTALL/tg" list 2>&1)
assert_contains "installed-mode header" "Installed tool-guards" "$out"
assert_contains "installed-mode lists 'foo' wrapper" "foo" "$out"
if echo "$out" | grep -qE "^\s*notmine\s"; then
  fail "installed-mode skips non-wrappers" "but listed 'notmine'"
else
  pass "installed-mode skips non-wrappers"
fi
rm -rf "$TMP_INSTALL" "$TMP_ENGINE"

# ─── tg log -n validation ────────────────────────────────────────────
echo ""
echo "── tg log -n validation ──"
TMP_LOG=$(mktemp -d)
mkdir -p "$TMP_LOG/testtool"
cat > "$TMP_LOG/testtool/calls-2026-05.jsonl" <<'EOF'
{"ts":"2026-05-01T10:00:00+0000","tool":"testtool","argv":["v"],"exit":0,"duration_ms":1,"policy":{"decision":"allow","rule":"v"}}
{"ts":"2026-05-01T10:01:00+0000","tool":"testtool","argv":["v"],"exit":0,"duration_ms":2,"policy":{"decision":"allow","rule":"v"}}
{"ts":"2026-05-01T10:02:00+0000","tool":"testtool","argv":["x"],"exit":13,"duration_ms":0,"policy":{"decision":"deny","rule":"x"}}
EOF

# -n 5 → tails all 3 entries
out=$(TG_LOG_DIR="$TMP_LOG" "$TG" log testtool -n 5 2>&1)
ec=$?
assert_eq "log -n 5 exit code" "0" "$ec"
n_lines=$(echo "$out" | grep -c "testtool" || true)
assert_eq "log -n 5 returns all 3 entries" "3" "$n_lines"

# -n 1 → tails 1 entry (the most recent)
out=$(TG_LOG_DIR="$TMP_LOG" "$TG" log testtool -n 1 2>&1)
n_lines=$(echo "$out" | grep -c "testtool" || true)
assert_eq "log -n 1 returns 1 entry" "1" "$n_lines"
assert_contains "log -n 1 returns the LAST entry" "deny" "$out"

# -n 0 → exits 0 with NO output (used for "is there a log?" scripts)
out=$(TG_LOG_DIR="$TMP_LOG" "$TG" log testtool -n 0 2>&1)
ec=$?
assert_eq "log -n 0 exit code" "0" "$ec"
if [[ -z "$out" ]]; then pass "log -n 0 produces no output"
else fail "log -n 0 produces no output" "got: $out"; fi

# -n -1 → REJECTED with exit 2
out=$(TG_LOG_DIR="$TMP_LOG" "$TG" log testtool -n -1 2>&1)
ec=$?
assert_eq "log -n -1 exit code" "2" "$ec"
assert_contains "log -n -1 error message" "non-negative" "$out"

rm -rf "$TMP_LOG"

# ─── tg check (source-tree mode) ─────────────────────────────────────
echo ""
echo "── tg check (source-tree mode) ──"
out=$("$TG" check az version 2>&1)
ec=$?
assert_eq "check exit code" "0" "$ec"
assert_contains "check shows ALLOWED for az version" "ALLOWED" "$out"
assert_contains "check shows matched rule" "rule:" "$out"

# tg check unknown-tool → error
out=$("$TG" check noexist version 2>&1)
ec=$?
assert_eq "check unknown tool exit code" "1" "$ec"
assert_contains "check unknown tool error" "no tool-guard" "$out"

# ─── tg config validate ──────────────────────────────────────────────
echo ""
echo "── tg config validate ──"
# Use the package's example .tool-guard/ — copy to a tmp dir so we test
# from a known cwd
TMP_CFG=$(mktemp -d)
mkdir -p "$TMP_CFG/.tool-guard"
cp "$PKG_ROOT/examples/.tool-guard/"*.json "$TMP_CFG/.tool-guard/" 2>/dev/null || true
out=$(cd "$TMP_CFG" && "$TG" config validate 2>&1)
ec=$?
assert_eq "config validate exit code on examples" "0" "$ec"
assert_contains "config validate reports az.config.json" "az.config.json" "$out"

# Invalid config → non-zero
echo '{"defaultMode":"bogus"}' > "$TMP_CFG/.tool-guard/bad.config.json"
out=$(cd "$TMP_CFG" && "$TG" config validate 2>&1)
ec=$?
if [[ $ec -ne 0 ]]; then pass "config validate fails on invalid file"
else fail "config validate fails on invalid file" "exit was 0"; fi
assert_contains "config validate error mentions defaultMode" "defaultMode" "$out"
rm -rf "$TMP_CFG"

# ─── Result ──────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
  echo "  RESULT: $PASS passed, 0 failed"
  echo "════════════════════════════════════════════════════════════"
  exit 0
else
  echo "  RESULT: $PASS passed, $FAIL failed"
  echo "════════════════════════════════════════════════════════════"
  exit 1
fi

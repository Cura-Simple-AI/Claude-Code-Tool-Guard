#!/usr/bin/env bash
# Test suite for the generic tool_guard engine.
#
# Tests run against the engine using a synthesized "testtool" stub.
# Real binary is /bin/true so tests don't depend on az / git / gh being
# installed. All invocations cd to a temp dir whose `.tool-guard/` is
# under our control — so the engine's walk-up discovery doesn't escape
# into the real repo's `.tool-guard/`.
#
# Bash assertion conventions: pass/fail counters, single-line summary,
# explicit exit codes (set -uo pipefail, NOT -e). No frameworks.
#
# Run:  bash scripts/tool-guard/_tests/tool_guard.test.sh

set -uo pipefail  # NOT -e — assertions handle their own exit codes

# Resolve PKG_ROOT relative to this script (one level up from _tests/).
# Works both inside a parent repo (scripts/tool-guard/) and post-split
# as a standalone repo (extracted root). The engine, stubs, and
# examples/ all live under PKG_ROOT in both layouts.
PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$PKG_ROOT"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

GUARDS_DIR="$TEST_TMP/.tool-guard"
WORK_DIR="$TEST_TMP/work"
TESTTOOL_DIR="$TEST_TMP/tool-guard/testtool"
mkdir -p "$GUARDS_DIR" "$WORK_DIR" "$TESTTOOL_DIR"

cat > "$TESTTOOL_DIR/wrapper.py" << 'PYEOF'
#!/usr/bin/env python3
"""testtool — throwaway stub for engine tests."""
import os, sys

TOOL = "testtool"
REAL = os.environ.get("TESTTOOL_TG_REAL_BIN", "/bin/true")

if os.environ.get("_TESTTOOL_TG_ACTIVE"):
    os.execv(REAL, [REAL] + sys.argv[1:])
os.environ["_TESTTOOL_TG_ACTIVE"] = "1"

ENGINE_DIR = os.environ["TOOL_GUARD_ENGINE_DIR"]
sys.path.insert(0, ENGINE_DIR)
from tool_guard import run

sys.exit(run(
    tool_name=TOOL,
    real_bin=REAL,
    secret_flags={"--password", "-p", "--token", "--secret"},
))
PYEOF
chmod +x "$TESTTOOL_DIR/wrapper.py"

TESTTOOL="$TESTTOOL_DIR/wrapper.py"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1${2:+ — $2}"; }

# Run the test stub from WORK_DIR (so engine walks up into TEST_TMP/.tool-guard).
# Always sets NONINTERACTIVE=1 + FAKE_CLAUDE=0 + ENGINE_DIR; per-test env vars
# can be passed as extra arguments before --, then argv after --.
# Usage: tt [VAR=value...] -- arg1 arg2 ...
tt() {
  local -a env_vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_vars+=("$1"); shift
  done
  shift  # drop --
  ( cd "$WORK_DIR" && env \
      TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" \
      TESTTOOL_TG_NONINTERACTIVE=1 \
      TESTTOOL_TG_FAKE_CLAUDE=0 \
      TESTTOOL_TG_REAL_BIN=/bin/true \
      "${env_vars[@]}" \
      python3 "$TESTTOOL" "$@" )
}

# Run tt and assert exit code
assert_exit() {
  local desc="$1" expected="$2"; shift 2
  local actual=0
  tt "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then pass "$desc (exit $actual)"
  else fail "$desc" "expected exit $expected, got $actual"; fi
}

# Run tt and assert stderr contains needle (using grep -F for literal match)
assert_stderr() {
  local desc="$1" needle="$2"; shift 2
  local err
  err=$(tt "$@" 2>&1 >/dev/null) || true
  if printf '%s' "$err" | grep -qF -- "$needle"; then pass "$desc"
  else fail "$desc" "stderr missing '$needle'. Got: $(printf '%s' "$err" | head -2 | tr '\n' '|')"; fi
}

# Run tt and assert stdout contains needle
assert_stdout() {
  local desc="$1" needle="$2"; shift 2
  local out
  out=$(tt "$@" 2>/dev/null) || true
  if printf '%s' "$out" | grep -qF -- "$needle"; then pass "$desc"
  else fail "$desc" "stdout missing '$needle'. Got: $(printf '%s' "$out" | head -2 | tr '\n' '|')"; fi
}

write_config()        { echo "$1" > "$GUARDS_DIR/testtool.config.json"; }
write_local_config()  { echo "$1" > "$GUARDS_DIR/testtool.config.local.json"; }
write_defaults()      { echo "$1" > "$GUARDS_DIR/_defaults.json"; }
clear_configs()       { rm -f "$GUARDS_DIR"/*.json; }

echo ""
echo "════════════════════════════════════════════════════════════"
echo " tool_guard engine — test suite"
echo "════════════════════════════════════════════════════════════"

# ─── 1. Classification basics ────────────────────────────────────────
echo ""
echo "── 1. Classification basics (dry-run) ──"
clear_configs
write_config '{"defaultMode":"prompt","allow":["safe*"],"warn":[],"deny":["dangerous*"]}'

assert_stderr "deny rule matched" 'classify=deny rule="dangerous*"' \
  TESTTOOL_TG_DRYRUN=1 -- dangerous foo

assert_stderr "allow rule matched" 'classify=allow rule="safe*"' \
  TESTTOOL_TG_DRYRUN=1 -- safe foo

assert_stderr "unmatched → defaultMode prompt" 'classify=prompt rule=<defaultMode>' \
  TESTTOOL_TG_DRYRUN=1 -- something else

# ─── 2. Precedence ───────────────────────────────────────────────────
echo ""
echo "── 2. Precedence: deny > warn > allow > defaultMode ──"
clear_configs
write_config '{
  "defaultMode":"allow",
  "allow":["foo *"],
  "warn":[{"pattern":"foo *","message":"this is a warn"}],
  "deny":[{"pattern":"foo *","message":"this is a deny"}]
}'
assert_stderr "deny wins over warn + allow" "classify=deny" \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

clear_configs
write_config '{
  "defaultMode":"deny",
  "allow":["foo *"],
  "warn":[{"pattern":"foo *","message":"warn"}]
}'
assert_stderr "warn wins over allow" "classify=warn" \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

clear_configs
write_config '{"defaultMode":"deny","allow":["foo *"]}'
assert_stderr "allow wins over defaultMode=deny" "classify=allow" \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

# ─── 3. Custom messages on deny ──────────────────────────────────────
echo ""
echo "── 3. Custom messages on deny ──"
clear_configs
write_config '{"defaultMode":"deny","deny":[{"pattern":"boom*","message":"BOOM goes the dynamite"}]}'

assert_stderr "custom deny message rendered" "BOOM goes the dynamite" \
  -- boom now

assert_exit "deny exits with 13" 13 \
  -- boom now

clear_configs
write_config '{"defaultMode":"deny","deny":["boom*"]}'
assert_stderr "default deny message" "blocked by policy rule 'boom*'" \
  -- boom now

# ─── 4. claude_only rules ────────────────────────────────────────────
echo ""
echo "── 4. claude_only rules ──"
clear_configs
write_config '{"defaultMode":"allow","warn":[{"pattern":"risky*","claude_only":true,"message":"only under Claude"}]}'

assert_stderr "claude_only fires under Claude" "classify=warn" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=1 -- risky operation

assert_stderr "claude_only skipped not-under-Claude" "classify=allow rule=<defaultMode>" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=0 -- risky operation

# ─── 6. Recursion sentinel ───────────────────────────────────────────
echo ""
echo "── 6. Recursion sentinel ──"
clear_configs
write_config '{"defaultMode":"deny"}'  # would deny if engine ran

# When _TESTTOOL_TG_ACTIVE=1, stub execv's real_bin without engine
assert_stdout "recursion sentinel → execv real_bin" "hello recursion" \
  _TESTTOOL_TG_ACTIVE=1 TESTTOOL_TG_REAL_BIN=/bin/echo -- hello recursion

# ─── 7. Logging ──────────────────────────────────────────────────────
echo ""
echo "── 7. Logging ──"
clear_configs
write_config '{"defaultMode":"allow","allow":["*"]}'

LOG_DIR=$(mktemp -d)
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- version >/dev/null 2>&1
LOG_FILE=$(ls "$LOG_DIR"/*.log 2>/dev/null | head -1)
if [[ -f "$LOG_FILE" ]]; then pass "log file created"
else fail "log file not created" "$LOG_DIR was empty"; fi

if [[ -f "$LOG_FILE" ]] && python3 -c "import json; [json.loads(l) for l in open('$LOG_FILE')]" 2>/dev/null; then
  pass "log file is valid JSONL"
else
  fail "log file is not valid JSONL"
fi

LOG_DIR=$(mktemp -d)
tt TESTTOOL_TG_DISABLE=1 TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- version >/dev/null 2>&1
if [[ -z "$(ls "$LOG_DIR"/*.log 2>/dev/null)" ]]; then
  pass "DISABLE=1 → no log written"
else
  fail "DISABLE=1 → log unexpectedly written"
fi

# ─── 8. Redaction ────────────────────────────────────────────────────
echo ""
echo "── 8. Redaction of secret-flag values ──"
clear_configs
write_config '{"defaultMode":"allow","allow":["*"]}'

LOG_DIR=$(mktemp -d)
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- auth --password supersecret --user me >/dev/null 2>&1
LOG_FILE=$(ls "$LOG_DIR"/*.log 2>/dev/null | head -1)
if [[ -f "$LOG_FILE" ]] && grep -qF -- '<redacted>' "$LOG_FILE" && ! grep -qF -- 'supersecret' "$LOG_FILE"; then
  pass "secret-flag value redacted in log"
else
  fail "secret-flag value not redacted" "log: $(cat "$LOG_FILE" 2>/dev/null | head -1 | head -c 200)"
fi

LOG_DIR=$(mktemp -d)
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- auth --password=supersecret >/dev/null 2>&1
LOG_FILE=$(ls "$LOG_DIR"/*.log 2>/dev/null | head -1)
if [[ -f "$LOG_FILE" ]] && grep -qF -- '--password=<redacted>' "$LOG_FILE" && ! grep -qF -- 'supersecret' "$LOG_FILE"; then
  pass "--password=value form redacted"
else
  fail "--password=value form not redacted" "log: $(cat "$LOG_FILE" 2>/dev/null | head -1 | head -c 200)"
fi

# ─── 9. Non-interactive auto-deny on prompt ──────────────────────────
echo ""
echo "── 9. Non-interactive auto-deny when defaultMode=prompt ──"
clear_configs
write_config '{"defaultMode":"prompt"}'

assert_exit "auto-deny exits 13" 13 \
  -- unknown command

assert_stderr "auto-deny mentions stdin not TTY" "stdin is not a TTY" \
  -- unknown command

assert_stderr "auto-deny suggests pattern" "Suggested pattern: 'unknown command*'" \
  -- unknown command

# ─── 10. Config layering ─────────────────────────────────────────────
echo ""
echo "── 10. Config layering (shared + local + defaults) ──"
clear_configs
write_config '{"defaultMode":"prompt","allow":["shared-allow*"],"deny":["shared-deny*"]}'
write_local_config '{"allow":["local-allow*"],"deny":["local-deny*"]}'
write_defaults '{"deny":[{"pattern":"global-deny*","message":"global"}]}'

assert_stderr "shared allow visible" 'classify=allow rule="shared-allow*"' \
  TESTTOOL_TG_DRYRUN=1 -- shared-allow foo

assert_stderr "local allow visible" 'classify=allow rule="local-allow*"' \
  TESTTOOL_TG_DRYRUN=1 -- local-allow foo

assert_stderr "shared deny visible" 'classify=deny rule="shared-deny*"' \
  TESTTOOL_TG_DRYRUN=1 -- shared-deny foo

assert_stderr "local deny visible" 'classify=deny rule="local-deny*"' \
  TESTTOOL_TG_DRYRUN=1 -- local-deny foo

assert_stderr "defaults deny visible" 'classify=deny rule="global-deny*"' \
  TESTTOOL_TG_DRYRUN=1 -- global-deny foo

# Shared takes precedence over defaults — both have "x *" but per-tool
# message should win (per-tool merged before defaults).
clear_configs
write_config '{"defaultMode":"deny","deny":[{"pattern":"x *","message":"per-tool message"}]}'
write_defaults '{"deny":[{"pattern":"x *","message":"defaults message"}]}'
assert_stderr "per-tool deny ranks above defaults deny" "per-tool message" \
  -- x foo

# ─── 11. <TOOL>_TG_CONFIG single-file override ──────────────────
echo ""
echo "── 11. <TOOL>_TG_CONFIG single-file override ──"
clear_configs
write_config '{"defaultMode":"deny","deny":["from-shared*"]}'
write_local_config '{"deny":["from-local*"]}'
write_defaults '{"deny":["from-defaults*"]}'

EXPLICIT_CFG="$TEST_TMP/explicit.json"
echo '{"defaultMode":"allow","allow":["explicit*"]}' > "$EXPLICIT_CFG"

assert_stderr "explicit config replaces all layers" 'classify=allow rule="explicit*"' \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_CONFIG="$EXPLICIT_CFG" -- explicit foo

# Shared's "from-shared*" should NOT match when explicit override is set
assert_stderr "explicit config: shared rule does NOT match" "classify=allow rule=<defaultMode>" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_CONFIG="$EXPLICIT_CFG" -- from-shared foo

# Explicit config pointing to a missing file → warning + deny-all fallback
clear_configs
write_config '{"defaultMode":"allow","allow":["everything*"]}'  # would normally allow

assert_stderr "explicit config missing → warning to stderr" "does not exist" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_CONFIG=/nonexistent/typo.json -- everything

assert_stderr "explicit config missing → falls to deny-all (not shared!)" 'classify=deny' \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_CONFIG=/nonexistent/typo.json -- everything

assert_stderr "explicit config missing → mentions env var name" "TESTTOOL_TG_CONFIG" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_CONFIG=/nonexistent/typo.json -- everything

# ─── 12. Pattern derivation ──────────────────────────────────────────
echo ""
echo "── 12. Pattern derivation in non-interactive deny ──"
clear_configs
write_config '{"defaultMode":"prompt"}'

assert_stderr "verb-only → '<verb>*'" "Suggested pattern: 'logout*'" \
  -- logout

assert_stderr "multi-word verb → 'words*'" "Suggested pattern: 'boards work-item show*'" \
  -- boards work-item show --id 9

assert_stderr "leading flag → '<flag>'" "Suggested pattern: '--version'" \
  -- --version

# ─── 13b. tool_name validation ───────────────────────────────────────
echo ""
echo "── 13b. tool_name validation in _env_prefix() ──"
( cd "$WORK_DIR" && python3 - <<PYEOF
import sys
sys.path.insert(0, "$ENGINE_DIR")
from tool_guard import _env_prefix

# Valid names
assert _env_prefix("az") == "AZ"
assert _env_prefix("foo-bar") == "FOO_BAR"
assert _env_prefix("a") == "A"  # single char
assert _env_prefix("Tool123") == "TOOL123"  # mixed case + digits

# Invalid names raise ValueError
for bad in ["foo.bar", "foo/bar", "1abc", "_foo", "", "foo bar", "foo!bar"]:
    try:
        _env_prefix(bad)
        print(f"  FAIL: {bad!r} should have raised ValueError")
        sys.exit(1)
    except ValueError:
        pass
print("OK")
PYEOF
) 2>&1 | tail -2 | grep -q "^OK$"
if [[ $? -eq 0 ]]; then
  pass "_env_prefix() validates tool_name (4 valid + 7 invalid)"
else
  fail "_env_prefix() validation"
fi

# ─── 13c. Regex rule type ────────────────────────────────────────────
echo ""
echo "── 13c. Regex rule type (type: 'regex') ──"
clear_configs
write_config '{"defaultMode":"allow","deny":[{"type":"regex","pattern":"\\b[Ff]ixes #\\d+","message":"matches with word boundary"}]}'

# Word boundary works — matches "Fixes #1" but NOT "prefixes #1"
assert_stderr "regex matches at word boundary" 'classify=deny' \
  TESTTOOL_TG_DRYRUN=1 -- something "Fixes #1234"

assert_stderr "regex does NOT match substring (prefixes)" 'classify=allow rule=<defaultMode>' \
  TESTTOOL_TG_DRYRUN=1 -- something "prefixes #1234"

# Demonstrate case-sensitivity by default — pattern uses literal F (no [Ff])
clear_configs
write_config '{"defaultMode":"allow","deny":[{"type":"regex","pattern":"\\bFixes #\\d+"}]}'
assert_stderr "regex case-sensitive: uppercase F matches" 'classify=deny' \
  TESTTOOL_TG_DRYRUN=1 -- something "Fixes #1"
assert_stderr "regex case-sensitive: lowercase f does NOT match" 'classify=allow rule=<defaultMode>' \
  TESTTOOL_TG_DRYRUN=1 -- something "fixes #1"

# Restore the [Ff] pattern for the rest of the section
clear_configs
write_config '{"defaultMode":"allow","deny":[{"type":"regex","pattern":"\\b[Ff]ixes #\\d+"}]}'

# (?i) inline flag for case-insensitive
clear_configs
write_config '{"defaultMode":"allow","deny":[{"type":"regex","pattern":"(?i)\\b(fix|fixes)\\b #\\d+"}]}'
assert_stderr "regex (?i) catches lowercase" 'classify=deny' \
  TESTTOOL_TG_DRYRUN=1 -- something "fixes #1"

# Default rule type is glob (omitting type doesn't auto-promote regex syntax)
clear_configs
write_config '{"defaultMode":"allow","deny":[{"pattern":"\\b[Ff]ixes #*"}]}'
assert_stderr "default type is glob (regex syntax not interpreted)" 'classify=allow rule=<defaultMode>' \
  TESTTOOL_TG_DRYRUN=1 -- something "Fixes #1"

# Explicit type: "glob" works
clear_configs
write_config '{"defaultMode":"allow","deny":[{"type":"glob","pattern":"foo*","message":"glob test"}]}'
assert_stderr "explicit type=glob" 'classify=deny rule="foo*"' \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

# Invalid regex → warning + no-match (doesn't crash wrapper)
clear_configs
write_config '{"defaultMode":"allow","deny":[{"type":"regex","pattern":"[unclosed","message":"broken"}]}'
assert_stderr "invalid regex → warning to stderr" "invalid regex" \
  TESTTOOL_TG_DRYRUN=1 -- anything

assert_stderr "invalid regex → falls through to defaultMode" 'classify=allow' \
  TESTTOOL_TG_DRYRUN=1 -- anything

# Unknown type → falls back to glob with warning
clear_configs
write_config '{"defaultMode":"allow","deny":[{"type":"posix","pattern":"foo*"}]}'
assert_stderr "unknown type → warning + falls back to glob" "type must be 'glob' or 'regex'" \
  TESTTOOL_TG_DRYRUN=1 -- foo bar
assert_stderr "unknown type fallback still matches glob pattern" 'classify=deny' \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

# ─── 13. Edge cases ──────────────────────────────────────────────────
echo ""
echo "── 13. Edge cases ──"
clear_configs
write_config '{"defaultMode":"allow"}'
assert_exit "missing real_bin → exit 127" 127 \
  TESTTOOL_TG_REAL_BIN=/nonexistent/path -- anything

# real_bin is a directory → exit 127 with clear message (not uncaught traceback)
REAL_BIN_DIR=$(mktemp -d)
assert_exit "real_bin is a directory → exit 127" 127 \
  TESTTOOL_TG_REAL_BIN="$REAL_BIN_DIR" -- anything
assert_stderr "real_bin directory message" "is a directory, not an executable" \
  TESTTOOL_TG_REAL_BIN="$REAL_BIN_DIR" -- anything

# real_bin is a non-executable file → exit 127 with clear message
NON_EXEC=$(mktemp)
chmod -x "$NON_EXEC"
assert_exit "real_bin not executable → exit 127" 127 \
  TESTTOOL_TG_REAL_BIN="$NON_EXEC" -- anything
assert_stderr "real_bin not-exec message" "is not executable (permissions)" \
  TESTTOOL_TG_REAL_BIN="$NON_EXEC" -- anything

# real_bin is a broken symlink → exit 127
BROKEN_LINK="$TEST_TMP/broken-link"
ln -sf /nonexistent/target "$BROKEN_LINK"
assert_exit "real_bin broken symlink → exit 127" 127 \
  TESTTOOL_TG_REAL_BIN="$BROKEN_LINK" -- anything

# real_bin is a working symlink → still works
GOOD_LINK="$TEST_TMP/good-link"
ln -sf /bin/true "$GOOD_LINK"
assert_exit "real_bin working symlink → executes" 0 \
  TESTTOOL_TG_REAL_BIN="$GOOD_LINK" -- anything

rm -rf "$REAL_BIN_DIR" "$NON_EXEC"

# Malformed config → falls back to permissive default WITHOUT crashing
clear_configs
echo 'this is not json' > "$GUARDS_DIR/testtool.config.json"
assert_exit "malformed config → tool-guard still runs (no crash)" 13 \
  -- anything
# Falls back to defaultMode=deny (restrictive embedded default), exits 13

# Empty argv → defaultMode applies (cmd = empty string)
clear_configs
write_config '{"defaultMode":"allow"}'
assert_exit "empty argv → defaultMode allow → exits 0" 0 \
  --

# Real binary exiting non-zero → exit code propagated
clear_configs
write_config '{"defaultMode":"allow"}'
assert_exit "real_bin exit code propagated" 42 \
  TESTTOOL_TG_REAL_BIN=/usr/bin/env -- bash -c 'exit 42'

# Config that's valid JSON but wrong top-level type → ignored gracefully
clear_configs
echo '"a string"' > "$GUARDS_DIR/testtool.config.json"
assert_stderr "wrong-type config (string) → warning to stderr" "is valid JSON but the top level is not an object" \
  -- something
assert_exit "wrong-type config → falls back to embedded default-deny" 13 \
  -- something

clear_configs
echo '[1, 2, 3]' > "$GUARDS_DIR/testtool.config.json"
assert_stderr "wrong-type config (array) → warning to stderr" "got list" \
  -- something

clear_configs
echo '42' > "$GUARDS_DIR/testtool.config.json"
assert_stderr "wrong-type config (number) → warning to stderr" "got int" \
  -- something

clear_configs
echo 'null' > "$GUARDS_DIR/testtool.config.json"
assert_stderr "wrong-type config (null) → warning to stderr" "got NoneType" \
  -- something

# Wrong-type rule list (allow as string) → ignored gracefully, no rule attribution bug
clear_configs
write_config '{"defaultMode":"prompt","allow":"foo*"}'
assert_stderr "wrong-type allow (string) → warning to stderr" "rule list must be an array" \
  TESTTOOL_TG_DRYRUN=1 -- f anything

assert_stderr "wrong-type allow → falls to defaultMode" 'classify=prompt rule=<defaultMode>' \
  TESTTOOL_TG_DRYRUN=1 -- f anything

# Rule with non-string pattern → skipped at config-load time, no fnmatch crash
clear_configs
write_config '{"defaultMode":"prompt","deny":[{"pattern":42}]}'
assert_stderr "non-string pattern → warning to stderr" "rule pattern must be a string" \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

assert_stderr "non-string pattern → rule skipped (falls to defaultMode)" 'classify=prompt rule=<defaultMode>' \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

# Rule with null pattern → skipped
clear_configs
write_config '{"defaultMode":"prompt","deny":[{"pattern":null}]}'
assert_stderr "null pattern → warning + skipped" "rule pattern must be a string" \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

# Mix: invalid skipped, valid kept
clear_configs
write_config '{"defaultMode":"prompt","deny":[{"pattern":"foo*"},{"pattern":42},{"pattern":"bar*"}]}'
assert_stderr "valid 'foo*' still matches when followed by invalid entry" 'classify=deny rule="foo*"' \
  TESTTOOL_TG_DRYRUN=1 -- foo something
assert_stderr "valid 'bar*' still matches" 'classify=deny rule="bar*"' \
  TESTTOOL_TG_DRYRUN=1 -- bar something

# claude_only must be boolean — string values are rejected with warning
# (since "false" is truthy in Python and would silently gate the rule)
clear_configs
write_config '{"defaultMode":"allow","deny":[{"pattern":"foo*","claude_only":"false"}]}'
assert_stderr "claude_only as string → warning to stderr" "claude_only must be true/false (boolean)" \
  TESTTOOL_TG_DRYRUN=1 -- foo bar
# After the warning, the rule should be treated as NOT claude-only,
# so it fires regardless of claude state.
assert_stderr "claude_only string fallback → rule fires (under_claude=False)" 'classify=deny rule="foo*"' \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=0 -- foo bar
assert_stderr "claude_only string fallback → rule fires (under_claude=True)" 'classify=deny rule="foo*"' \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=1 -- foo bar

# Same for "true" as string
clear_configs
write_config '{"defaultMode":"allow","deny":[{"pattern":"foo*","claude_only":"true"}]}'
assert_stderr "claude_only as 'true' string → also rejected" "claude_only must be true/false (boolean)" \
  TESTTOOL_TG_DRYRUN=1 -- foo bar

# Bool true/false still work
clear_configs
write_config '{"defaultMode":"allow","deny":[{"pattern":"foo*","claude_only":true}]}'
assert_stderr "claude_only=true (bool) → fires only under Claude" 'classify=deny' \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=1 -- foo bar
assert_stderr "claude_only=true (bool) → skipped not under Claude" "classify=allow rule=<defaultMode>" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=0 -- foo bar

# defaultMode=deny + no rule matched → clearer message (not '<unknown>')
clear_configs
write_config '{"defaultMode":"deny"}'  # no allow/deny rules
assert_stderr "default-deny no-rule message: 'no allow rule matched'" "no allow rule matched" \
  -- some unmatched command
assert_stderr "default-deny no-rule suggests pattern" "Suggested allow pattern: 'some unmatched command*'" \
  -- some unmatched command
assert_stderr_no_unknown() {
  local desc="$1"; shift
  local err
  err=$(tt "$@" 2>&1 >/dev/null) || true
  if printf '%s' "$err" | grep -qF -- "<unknown>"; then
    fail "$desc" "stderr contained '<unknown>' (UX regression)"
  else
    pass "$desc"
  fi
}
assert_stderr_no_unknown "default-deny no-rule does NOT show '<unknown>'" \
  -- some unmatched command

# ─── 14. defaultMode=allow (auto-allow) ──────────────────────────────
echo ""
echo "── 14. defaultMode='allow' auto-allows unmatched ──"
clear_configs
write_config '{"defaultMode":"allow","deny":["explicit-deny*"]}'

assert_stderr "unmatched + defaultMode=allow → allow" "classify=allow rule=<defaultMode>" \
  TESTTOOL_TG_DRYRUN=1 -- whatever new command

assert_stderr "explicit deny still wins over defaultMode=allow" 'classify=deny rule="explicit-deny*"' \
  TESTTOOL_TG_DRYRUN=1 -- explicit-deny me

assert_exit "defaultMode=allow → exits 0 (real_bin ran)" 0 \
  -- some unrecognized command

# ─── 15. claude_only on allow + deny rules ───────────────────────────
echo ""
echo "── 15. claude_only on allow + deny rules ──"
# allow rule with claude_only:true should only fire under Claude
clear_configs
write_config '{"defaultMode":"prompt","allow":[{"pattern":"only-allowed*","claude_only":true}]}'

assert_stderr "claude_only allow fires under Claude" "classify=allow" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=1 -- only-allowed task

assert_stderr "claude_only allow skipped no-Claude → falls to prompt" "classify=prompt" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=0 -- only-allowed task

# claude_only on deny should only fire under Claude
clear_configs
write_config '{"defaultMode":"allow","deny":[{"pattern":"only-blocked*","claude_only":true}]}'

assert_stderr "claude_only deny fires under Claude" "classify=deny" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=1 -- only-blocked task

assert_stderr "claude_only deny skipped no-Claude → falls to allow" "classify=allow rule=<defaultMode>" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=0 -- only-blocked task

# Explicit claude_only:false behaves like the field not being set
clear_configs
write_config '{"defaultMode":"allow","deny":[{"pattern":"always-blocked*","claude_only":false}]}'
assert_stderr "claude_only:false fires regardless of Claude" "classify=deny" \
  TESTTOOL_TG_DRYRUN=1 TESTTOOL_TG_FAKE_CLAUDE=0 -- always-blocked task

# ─── 16. Local config defaultMode override ───────────────────────────
echo ""
echo "── 16. Local config defaultMode overrides shared ──"
clear_configs
write_config '{"defaultMode":"prompt"}'
write_local_config '{"defaultMode":"allow"}'

assert_stderr "local defaultMode wins over shared" "classify=allow rule=<defaultMode>" \
  TESTTOOL_TG_DRYRUN=1 -- some unmatched command

clear_configs
write_config '{"defaultMode":"allow"}'
write_local_config '{"defaultMode":"deny"}'

assert_stderr "local can tighten shared (allow → deny)" "classify=deny rule=<defaultMode>" \
  TESTTOOL_TG_DRYRUN=1 -- some unmatched command

# ─── 17. Warn rule with custom message ───────────────────────────────
echo ""
echo "── 17. Warn rule custom message rendering ──"
clear_configs
write_config '{
  "defaultMode":"allow",
  "warn":[{"pattern":"risky*","message":"Risky operation — be aware"}]
}'

assert_stderr "warn message printed to stderr" "Risky operation — be aware" \
  -- risky thing

assert_exit "warn rule still runs (exits 0)" 0 \
  -- risky thing

# ─── 18. Multi-line custom message rendering ─────────────────────────
echo ""
echo "── 18. Multi-line custom message rendering ──"
clear_configs
write_config '{"defaultMode":"deny","deny":[{"pattern":"big-block*","message":"Line one\nLine two\nLine three"}]}'

# All three lines should appear in stderr
err=$(tt -- big-block now 2>&1 >/dev/null) || true
if printf '%s' "$err" | grep -qF "Line one" && \
   printf '%s' "$err" | grep -qF "Line two" && \
   printf '%s' "$err" | grep -qF "Line three"; then
  pass "all three lines of multi-line message rendered"
else
  fail "multi-line message lines missing" "got: $(printf '%s' "$err" | head -10 | tr '\n' '|')"
fi

# Each line should be indented with two spaces
if printf '%s' "$err" | grep -qE "^  Line one"; then
  pass "multi-line message indented"
else
  fail "multi-line message not indented"
fi

# ─── 19. append_to_local_config (Python unit test) ───────────────────
echo ""
echo "── 19. append_to_local_config preserves existing entries ──"
clear_configs

# Pre-existing local config
cat > "$GUARDS_DIR/testtool.config.local.json" << 'EOF'
{
  "_comment": "preserved",
  "allow": ["existing-allow*"],
  "deny": ["existing-deny*"]
}
EOF

# Call append_to_local_config directly via python
( cd "$WORK_DIR" && python3 - <<PYEOF
import sys
sys.path.insert(0, "$ENGINE_DIR")
from tool_guard import append_to_local_config
import json

p = append_to_local_config("testtool", "newly-added*", "allow")
print(f"saved to: {p}")

with open(p) as f:
    cfg = json.load(f)

assert cfg.get("_comment") == "preserved", f"_comment lost: {cfg}"
assert "existing-allow*" in cfg.get("allow", []), f"existing-allow lost: {cfg}"
assert "newly-added*" in cfg.get("allow", []), f"newly-added not present: {cfg}"
assert "existing-deny*" in cfg.get("deny", []), f"existing-deny lost: {cfg}"

# Same pattern again should NOT duplicate
p = append_to_local_config("testtool", "newly-added*", "allow")
with open(p) as f:
    cfg = json.load(f)
assert cfg["allow"].count("newly-added*") == 1, f"duplicate: {cfg['allow']}"

# Different decision (deny) appends to deny list
p = append_to_local_config("testtool", "another-pattern*", "deny")
with open(p) as f:
    cfg = json.load(f)
assert "another-pattern*" in cfg["deny"], f"deny append failed: {cfg}"
print("OK")
PYEOF
) 2>&1 | tail -3 | grep -q "^OK$"
if [[ $? -eq 0 ]]; then
  pass "append_to_local_config preserves + dedupes + handles both decisions"
else
  fail "append_to_local_config unit test failed"
fi

# Brand-new local config gets created with _comment header
clear_configs
( cd "$WORK_DIR" && python3 - <<PYEOF
import sys, json
sys.path.insert(0, "$ENGINE_DIR")
from tool_guard import append_to_local_config

p = append_to_local_config("testtool", "first*", "allow")
with open(p) as f:
    cfg = json.load(f)
assert "_comment" in cfg, f"_comment missing: {cfg}"
assert "first*" in cfg.get("allow", []), f"allow missing: {cfg}"
print("OK")
PYEOF
) 2>&1 | tail -2 | grep -q "^OK$"
if [[ $? -eq 0 ]]; then
  pass "append_to_local_config creates new file with comment + entry"
else
  fail "append_to_local_config new-file unit test failed"
fi

# ─── 20. redact() unit tests ─────────────────────────────────────────
echo ""
echo "── 20. redact() — direct unit tests ──"
( cd "$WORK_DIR" && python3 - <<PYEOF
import sys
sys.path.insert(0, "$ENGINE_DIR")
from tool_guard import redact

S = {"--password", "-p", "--token"}

# Basic: --password value
r = redact(["login", "--password", "secret"], S)
assert r == ["login", "--password", "<redacted>"], r

# --password=value form
r = redact(["login", "--password=secret"], S)
assert r == ["login", "--password=<redacted>"], r

# Multiple secrets
r = redact(["auth", "--password", "p1", "--token", "t1", "--user", "u"], S)
assert r == ["auth", "--password", "<redacted>", "--token", "<redacted>", "--user", "u"], r

# Short flag -p
r = redact(["login", "-p", "secret"], S)
assert r == ["login", "-p", "<redacted>"], r

# Non-secret flag with = is preserved
r = redact(["foo", "--user=me"], S)
assert r == ["foo", "--user=me"], r

# Empty argv
r = redact([], S)
assert r == [], r

# No secrets present
r = redact(["foo", "bar", "--baz"], S)
assert r == ["foo", "bar", "--baz"], r

# Edge: --password at end of argv with no value (real az would error but redact shouldn't crash)
r = redact(["login", "--password"], S)
assert r == ["login", "--password"], r  # nothing follows to redact

# Edge: --password value --password value (multiple instances)
r = redact(["foo", "--password", "p1", "--password", "p2"], S)
assert r == ["foo", "--password", "<redacted>", "--password", "<redacted>"], r

print("OK")
PYEOF
) 2>&1 | tail -2 | grep -q "^OK$"
if [[ $? -eq 0 ]]; then
  pass "redact() handles all cases (8 sub-assertions)"
else
  fail "redact() unit test failed" "$( cd "$WORK_DIR" && python3 - <<PYEOF
import sys
sys.path.insert(0, "$ENGINE_DIR")
from tool_guard import redact
print(redact(["foo", "--password", "secret"], {"--password"}))
PYEOF
)"
fi

# ─── 21. derive_pattern() unit tests ─────────────────────────────────
echo ""
echo "── 21. derive_pattern() — direct unit tests ──"
( cd "$WORK_DIR" && python3 - <<PYEOF
import sys
sys.path.insert(0, "$ENGINE_DIR")
from tool_guard import derive_pattern

assert derive_pattern([]) == "*"
assert derive_pattern(["logout"]) == "logout*"
assert derive_pattern(["boards", "work-item", "show", "--id", "9"]) == "boards work-item show*"
assert derive_pattern(["--version"]) == "--version"
assert derive_pattern(["-h"]) == "-h"
assert derive_pattern(["account", "get-access-token", "--resource", "x"]) == "account get-access-token*"
# Edge: only flags after a positional
assert derive_pattern(["a", "b", "--c", "d"]) == "a b*"
print("OK")
PYEOF
) 2>&1 | tail -2 | grep -q "^OK$"
if [[ $? -eq 0 ]]; then
  pass "derive_pattern() handles all cases"
else
  fail "derive_pattern() unit test failed"
fi

# ─── 21b. defaultMode validation ─────────────────────────────────────
echo ""
echo "── 21b. defaultMode validation ──"
clear_configs
write_config '{"defaultMode":"garbage"}'
assert_stderr "invalid defaultMode → warning to stderr" "invalid defaultMode='garbage'" \
  -- something
assert_exit "invalid defaultMode → falls back to deny (exit 13)" 13 \
  -- something

# All four valid modes accepted
for mode in deny allow warn prompt; do
  clear_configs
  write_config "{\"defaultMode\":\"$mode\"}"
  out=$(tt TESTTOOL_TG_DRYRUN=1 -- whatever 2>&1) || true
  if printf '%s' "$out" | grep -qF "classify=$mode"; then
    pass "valid defaultMode='$mode' accepted"
  else
    fail "valid defaultMode='$mode'" "got: $out"
  fi
done

# defaultMode value-types: not a string
clear_configs
write_config '{"defaultMode":42}'
assert_stderr "non-string defaultMode → warning + fallback" "invalid defaultMode" \
  -- something

# defaultMode='warn' with no rule matched → clean message (not '<unknown>')
clear_configs
write_config '{"defaultMode":"warn"}'
assert_stderr "warn no-rule message: 'no rule matched'" "no rule matched" \
  -- some unmatched cmd
assert_stderr "warn no-rule mentions defaultMode is 'warn'" "defaultMode is 'warn'" \
  -- some unmatched cmd
err=$(tt -- some unmatched cmd 2>&1 >/dev/null) || true
if printf '%s' "$err" | grep -qF -- "<unknown>"; then
  fail "warn no-rule contains '<unknown>'" "UX regression"
else
  pass "warn no-rule does NOT show '<unknown>'"
fi
# warn no-rule still proceeds to exec (exit 0)
assert_exit "warn no-rule still execs (exit 0)" 0 \
  -- some unmatched cmd

# ─── 22. _normalize_rules() unit tests ───────────────────────────────
echo ""
echo "── 22. _normalize_rules() — handles malformed entries ──"
( cd "$WORK_DIR" && python3 - <<PYEOF
import sys
sys.path.insert(0, "$ENGINE_DIR")
from tool_guard import _normalize_rules

# String → dict
r = _normalize_rules(["foo*"])
assert r == [{"pattern": "foo*"}], r

# Dict with pattern → kept as-is
r = _normalize_rules([{"pattern": "foo*", "message": "msg"}])
assert r == [{"pattern": "foo*", "message": "msg"}], r

# Mixed
r = _normalize_rules(["a*", {"pattern": "b*", "message": "m"}])
assert len(r) == 2 and r[0] == {"pattern": "a*"}, r

# Malformed entries silently dropped (None, ints, dicts without pattern)
r = _normalize_rules(["valid*", None, 123, {"no_pattern_key": "x"}, {"pattern": "ok*"}])
assert r == [{"pattern": "valid*"}, {"pattern": "ok*"}], r

# Empty / None input
assert _normalize_rules([]) == []
assert _normalize_rules(None) == []

# Wrong type (string instead of list) → returns [] with stderr warning,
# does NOT iterate the string char-by-char
import io, contextlib
err = io.StringIO()
with contextlib.redirect_stderr(err):
    r = _normalize_rules("foo*")
assert r == [], f"expected [] for string input, got {r!r}"
assert "rule list must be an array" in err.getvalue(), err.getvalue()

# Wrong type (dict instead of list)
err = io.StringIO()
with contextlib.redirect_stderr(err):
    r = _normalize_rules({"pattern": "foo*"})
assert r == [], f"expected [] for dict input, got {r!r}"

# Rule entry with non-string pattern → skipped with warning
err = io.StringIO()
with contextlib.redirect_stderr(err):
    r = _normalize_rules([{"pattern": 42}])
assert r == [], f"expected [] for int pattern, got {r!r}"
assert "rule pattern must be a string" in err.getvalue(), err.getvalue()

# Rule entry with None pattern → skipped
err = io.StringIO()
with contextlib.redirect_stderr(err):
    r = _normalize_rules([{"pattern": None}])
assert r == [], f"expected [] for None pattern, got {r!r}"

# Mixed: invalid pattern skipped, valid pattern kept
err = io.StringIO()
with contextlib.redirect_stderr(err):
    r = _normalize_rules([{"pattern": "valid*"}, {"pattern": 42}, "string-form*"])
assert len(r) == 2, f"expected 2 valid rules, got {r!r}"
assert r[0] == {"pattern": "valid*"} and r[1] == {"pattern": "string-form*"}, r
print("OK")
PYEOF
) 2>&1 | tail -2 | grep -q "^OK$"
if [[ $? -eq 0 ]]; then
  pass "_normalize_rules() handles strings, dicts, and malformed input"
else
  fail "_normalize_rules() unit test failed"
fi

# ─── 23. Logging path layout + per-decision schema ───────────────────
echo ""
echo "── 23. Logging — filename layout ──"
clear_configs
write_config '{"defaultMode":"allow","allow":["*"]}'

LOG_DIR=$(mktemp -d)
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- version >/dev/null 2>&1
LOG_FILE=$(ls "$LOG_DIR"/*.log 2>/dev/null | head -1)
expected_name="testtool_$(date +%Y%m%d).log"
actual_name=$(basename "$LOG_FILE" 2>/dev/null)
if [[ "$actual_name" == "$expected_name" ]]; then
  pass "log filename matches <tool>_YYYYMMDD.log pattern"
else
  fail "log filename pattern" "expected '$expected_name', got '$actual_name'"
fi

# Default log dir (no TESTTOOL_TG_LOG_DIR override) is /tmp/tool-guard/.
# We can't easily test against the real /tmp/tool-guard/ without race
# conditions from other test runs, so just verify the engine's
# _log_file() picks the right base path.
default_path=$(TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" python3 -c "
import sys; sys.path.insert(0, '$ENGINE_DIR')
from tool_guard import _log_file
print(_log_file('testtool'))
")
case "$default_path" in
  /tmp/tool-guard/testtool_*.log) pass "default log path is /tmp/tool-guard/<tool>_*.log" ;;
  *) fail "default log path" "got: $default_path" ;;
esac

echo ""
echo "── 24. Logging — every decision is recorded ──"
clear_configs
write_config '{
  "defaultMode": "prompt",
  "allow": ["good*"],
  "warn":  [{"pattern":"warny*","message":"heads up"}],
  "deny":  [{"pattern":"bad*","message":"nope"}]
}'

LOG_DIR=$(mktemp -d)
# allow → exit 0 + logged
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- good --action >/dev/null 2>&1
# warn → fall through to real binary (/bin/true exit 0) + logged
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- warny --action >/dev/null 2>&1
# deny → exit 13 + logged (no real binary call)
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- bad --action >/dev/null 2>&1
# unmatched + defaultMode=prompt + non-TTY → auto-deny exit 13 + logged
# with the special <no-match,non-interactive> rule
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- mystery --action >/dev/null 2>&1

LOG_FILE=$(ls "$LOG_DIR"/*.log 2>/dev/null | head -1)
n=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
assert_eq() { local what="$1" exp="$2" got="$3"; if [[ "$got" == "$exp" ]]; then pass "$what"; else fail "$what" "expected '$exp', got '$got'"; fi; }
assert_eq "4 calls produce 4 log entries" "4" "$n"

# Verify each call's decision is recorded by parsing JSON
result=$(python3 - "$LOG_FILE" << 'PYEOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
decisions = [e["policy"]["decision"] for e in events]
print(",".join(decisions))
PYEOF
)
if [[ "$result" == "allow,warn,deny,deny" ]]; then
  pass "decisions logged in order: allow, warn, deny, deny(auto)"
else
  fail "decisions logged out-of-order" "got: $result"
fi

# Verify the auto-deny entry has the special <no-match,non-interactive> rule
auto_rule=$(python3 - "$LOG_FILE" << 'PYEOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(events[3]["policy"]["rule"])
PYEOF
)
if [[ "$auto_rule" == "<no-match,non-interactive>" ]]; then
  pass "auto-deny entry has <no-match,non-interactive> rule"
else
  fail "auto-deny rule field" "got: $auto_rule"
fi

# Schema integrity — every entry has the expected keys
result=$(python3 - "$LOG_FILE" << 'PYEOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
required = {"ts","tool","argv","cwd","exit","duration_ms","ppid","parent_cmd","user","policy"}
for i, e in enumerate(events):
    missing = required - set(e.keys())
    if missing:
        print(f"entry-{i}-missing:{','.join(sorted(missing))}"); sys.exit(1)
    if "decision" not in e["policy"]:
        print(f"entry-{i}-missing-decision"); sys.exit(1)
print("ok")
PYEOF
)
assert_eq "every entry has required schema keys" "ok" "$result"

echo ""
echo "── 25. Logging — appends, never overwrites ──"
clear_configs
write_config '{"defaultMode":"allow","allow":["*"]}'

LOG_DIR=$(mktemp -d)
for i in 1 2 3 4 5; do
  tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- call$i >/dev/null 2>&1
done
LOG_FILE=$(ls "$LOG_DIR"/*.log 2>/dev/null | head -1)
n=$(wc -l < "$LOG_FILE")
assert_eq "5 sequential calls → 5 entries (append, not overwrite)" "5" "$n"

# argv arg appears in matching call only
for i in 1 2 3 4 5; do
  if grep -q "\"call$i\"" "$LOG_FILE"; then
    pass "call$i appears in log"
  else
    fail "call$i missing from log"
  fi
done

echo ""
echo "── 26. Logging — exit code captured for both success and failure ──"
clear_configs
write_config '{"defaultMode":"allow","allow":["*"]}'

LOG_DIR=$(mktemp -d)
# allow + /bin/true → exit 0
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" TESTTOOL_TG_REAL_BIN=/bin/true -- ok >/dev/null 2>&1
# allow + /bin/false → exit 1
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" TESTTOOL_TG_REAL_BIN=/bin/false -- fails >/dev/null 2>&1
LOG_FILE=$(ls "$LOG_DIR"/*.log 2>/dev/null | head -1)
codes=$(python3 - "$LOG_FILE" << 'PYEOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(",".join(str(e["exit"]) for e in events))
PYEOF
)
assert_eq "exit codes captured: 0 then 1" "0,1" "$codes"

# duration_ms is an integer ≥ 0
durations_ok=$(python3 - "$LOG_FILE" << 'PYEOF'
import json, sys
for e in [json.loads(l) for l in open(sys.argv[1]) if l.strip()]:
    d = e.get("duration_ms")
    if not isinstance(d, int) or d < 0:
        print(f"bad-duration:{d}"); sys.exit(1)
print("ok")
PYEOF
)
assert_eq "duration_ms is non-negative int" "ok" "$durations_ok"

echo ""
echo "── 27. Logging — TG_LOG_DIR mkdir -p when missing ──"
clear_configs
write_config '{"defaultMode":"allow","allow":["*"]}'

LOG_DIR_BASE=$(mktemp -d)
LOG_DIR="$LOG_DIR_BASE/nested/deeper/path"  # does not yet exist
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- version >/dev/null 2>&1
if [[ -d "$LOG_DIR" ]] && ls "$LOG_DIR"/*.log >/dev/null 2>&1; then
  pass "engine creates missing log dir tree"
else
  fail "engine did not create $LOG_DIR" "$(ls -la "$LOG_DIR_BASE" 2>&1 | head -3)"
fi
rm -rf "$LOG_DIR_BASE"

echo ""
echo "── 28. Logging — ts is ISO-8601-ish + parent_cmd populated ──"
clear_configs
write_config '{"defaultMode":"allow","allow":["*"]}'

LOG_DIR=$(mktemp -d)
tt TESTTOOL_TG_LOG_DIR="$LOG_DIR" -- version >/dev/null 2>&1
LOG_FILE=$(ls "$LOG_DIR"/*.log 2>/dev/null | head -1)
ts_ok=$(python3 - "$LOG_FILE" << 'PYEOF'
import json, sys, re
e = json.loads(open(sys.argv[1]).readline())
ts = e["ts"]
# YYYY-MM-DDTHH:MM:SS+HHMM (or -HHMM)
if re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}$", ts):
    print("ok")
else:
    print(f"bad-ts:{ts}")
PYEOF
)
assert_eq "ts matches ISO-8601 with timezone" "ok" "$ts_ok"

parent_ok=$(python3 - "$LOG_FILE" << 'PYEOF'
import json, sys
e = json.loads(open(sys.argv[1]).readline())
print("ok" if e.get("parent_cmd") else "missing-parent_cmd")
PYEOF
)
assert_eq "parent_cmd populated" "ok" "$parent_ok"

# ─── 29. Config-dir discovery — fallback to ~/.config/tool-guard ─────
echo ""
echo "── 29. _find_guards_dir() — fallback chain ──"

# Set up a fake $HOME with ~/.config/tool-guard/ + an az config there.
# Run the engine with cwd=/tmp (no walk-up will find anything) and
# verify it picks up the home fallback.
FAKE_HOME=$(mktemp -d)
mkdir -p "$FAKE_HOME/.config/tool-guard"
cat > "$FAKE_HOME/.config/tool-guard/testtool.config.json" <<'EOF'
{"defaultMode":"prompt","allow":["from-home-config*"]}
EOF

# Use python -c to exercise _find_guards_dir() directly
result=$(HOME="$FAKE_HOME" TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" python3 -c "
import os, sys; sys.path.insert(0, '$ENGINE_DIR')
os.chdir('/tmp')  # cwd-walk-up will fail
from tool_guard import _find_guards_dir
d = _find_guards_dir()
print(str(d) if d else 'None')
")
expected="$FAKE_HOME/.config/tool-guard"
assert_eq "~/.config/tool-guard fallback fires when walk-up fails" "$expected" "$result"

# Verify ~/.tool-guard/ also works (legacy fallback)
FAKE_HOME2=$(mktemp -d)
mkdir -p "$FAKE_HOME2/.tool-guard"
result=$(HOME="$FAKE_HOME2" TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" python3 -c "
import os, sys; sys.path.insert(0, '$ENGINE_DIR')
os.chdir('/tmp')
from tool_guard import _find_guards_dir
print(_find_guards_dir())
")
expected="$FAKE_HOME2/.tool-guard"
assert_eq "~/.tool-guard legacy fallback fires" "$expected" "$result"

# Verify TOOL_GUARD_DIR env var beats walk-up AND home fallback
EXPLICIT_DIR=$(mktemp -d)/somewhere
mkdir -p "$EXPLICIT_DIR"
result=$(HOME="$FAKE_HOME" TOOL_GUARD_DIR="$EXPLICIT_DIR" \
         TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" python3 -c "
import sys; sys.path.insert(0, '$ENGINE_DIR')
from tool_guard import _find_guards_dir
print(_find_guards_dir())
")
assert_eq "TOOL_GUARD_DIR overrides everything" "$EXPLICIT_DIR" "$result"

# Verify walk-up still beats home fallback (precedence: explicit > walk > home)
result=$(HOME="$FAKE_HOME" TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" python3 -c "
import os, sys; sys.path.insert(0, '$ENGINE_DIR')
os.chdir('$WORK_DIR')  # has a real .tool-guard/ from the test setup
from tool_guard import _find_guards_dir
print(_find_guards_dir())
")
expected="$GUARDS_DIR"
assert_eq "cwd walk-up wins over ~/.config fallback" "$expected" "$result"

# Verify TOOL_GUARD_DIR pointed at non-existent dir → None (don't silently fall back)
result=$(TOOL_GUARD_DIR=/nonexistent/path TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" \
         python3 -c "
import sys; sys.path.insert(0, '$ENGINE_DIR')
from tool_guard import _find_guards_dir
print(_find_guards_dir())
")
assert_eq "TOOL_GUARD_DIR=/nonexistent → None (no silent fallback)" "None" "$result"

rm -rf "$FAKE_HOME" "$FAKE_HOME2" "$EXPLICIT_DIR"

echo ""
echo "── 30. End-to-end: config from ~/.config/tool-guard works for /usr/bin invocations ──"
# Simulates the MCP scenario: az is invoked from a cwd that has no
# .tool-guard/ ancestor. Without the home fallback this would deny;
# with it the home config's allow rule should match.
FAKE_HOME=$(mktemp -d)
mkdir -p "$FAKE_HOME/.config/tool-guard"
cat > "$FAKE_HOME/.config/tool-guard/testtool.config.json" <<'EOF'
{"defaultMode":"deny","allow":["mcp-style-call*"]}
EOF
LOG_DIR=$(mktemp -d)

# Run with cwd=/tmp (no walk-up will find anything) and HOME=fake
out=$(cd /tmp && HOME="$FAKE_HOME" TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" \
      TESTTOOL_TG_LOG_DIR="$LOG_DIR" \
      python3 "$TESTTOOL" mcp-style-call --arg foo 2>&1)
ec=$?
assert_eq "mcp-from-/tmp scenario → allow (exit 0)" "0" "$ec"

# And verify a non-matching call from same cwd is still denied
out=$(cd /tmp && HOME="$FAKE_HOME" TOOL_GUARD_ENGINE_DIR="$ENGINE_DIR" \
      TESTTOOL_TG_LOG_DIR="$LOG_DIR" \
      python3 "$TESTTOOL" forbidden --arg foo 2>&1)
ec=$?
assert_eq "non-matching call still denied via home config" "13" "$ec"

rm -rf "$FAKE_HOME" "$LOG_DIR"

# ─── Result ──────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  RESULT: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

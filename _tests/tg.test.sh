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

# ─── tg shebang ──────────────────────────────────────────────────────
# Regression: tool-guard-install.sh exec'd tg via `bash $CACHE/tg`,
# which tried to interpret the Python source as bash and hung. Catch
# any future drift to a non-Python shebang.
echo ""
echo "── tg shebang ──"
shebang=$(head -1 "$TG")
if [[ "$shebang" == "#!/usr/bin/env python3" ]] || [[ "$shebang" == "#!"*python* ]]; then
  pass "tg has python shebang ($shebang)"
else
  fail "tg shebang must be Python" "got: $shebang"
fi

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
# New layout: flat dir, /tmp/tool-guard/<tool>_YYYYMMDD.log
cat > "$TMP_LOG/testtool_20260501.log" <<'EOF'
{"ts":"2026-05-01T10:00:00+0000","tool":"testtool","argv":["v"],"exit":0,"duration_ms":1,"policy":{"decision":"allow","rule":"v"}}
{"ts":"2026-05-01T10:01:00+0000","tool":"testtool","argv":["v"],"exit":0,"duration_ms":2,"policy":{"decision":"allow","rule":"v"}}
{"ts":"2026-05-01T10:02:00+0000","tool":"testtool","argv":["x"],"exit":13,"duration_ms":0,"policy":{"decision":"deny","rule":"x"}}
EOF

# -n 5 → tails all 3 entries. Count by ISO-timestamp prefix (one per
# entry) rather than tool name (which appears multiple places per line
# and would pass even if rendering broke — Scott P1-A finding).
out=$(TG_LOG_DIR="$TMP_LOG" "$TG" log testtool -n 5 2>&1)
ec=$?
assert_eq "log -n 5 exit code" "0" "$ec"
n_lines=$(echo "$out" | grep -cE "^2026-05-01T1[0-9]:" || true)
assert_eq "log -n 5 returns all 3 entries (counted by ts prefix)" "3" "$n_lines"

# Verify SPECIFIC rendered fields appear, not just generic tokens
assert_contains "log renders timestamp from each entry" "2026-05-01T10:00:00" "$out"
assert_contains "log renders rule field" "rule=v" "$out"
assert_contains "log renders exit field" "exit=0" "$out"
assert_contains "log renders duration_ms" "1ms" "$out"

# -n 1 → tails 1 entry (the most recent)
out=$(TG_LOG_DIR="$TMP_LOG" "$TG" log testtool -n 1 2>&1)
n_lines=$(echo "$out" | grep -cE "^2026-05-01T1[0-9]:" || true)
assert_eq "log -n 1 returns 1 entry" "1" "$n_lines"
# Most recent is the deny entry — verify both the decision AND the
# specific argv from THAT entry are present.
assert_contains "log -n 1 returns the deny entry (decision)" "deny" "$out"
assert_contains "log -n 1 returns the deny entry (argv 'x')" "testtool x" "$out"
if echo "$out" | grep -qE "10:00:00"; then
  fail "log -n 1 leaked older entries" "should only show 10:02:00"
else
  pass "log -n 1 doesn't include older entries"
fi

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

# -n abc → argparse rejects with usage error, no traceback (P2-A)
out=$(TG_LOG_DIR="$TMP_LOG" "$TG" log testtool -n abc 2>&1)
ec=$?
assert_eq "log -n abc — exit 2 (argparse)" "2" "$ec"
if echo "$out" | grep -q "Traceback"; then
  fail "log -n abc shows Python traceback" "should be argparse error"
else
  pass "log -n abc → no Python traceback (clean argparse error)"
fi

rm -rf "$TMP_LOG"

# ─── Engine → tg log integration (round-trip schema test) ───────────
# Scott P1-B: schema gaps between _build_event (writer) and cmd_log
# (reader) wouldn't be caught by the hand-crafted JSONL fixture above.
# This test runs the actual engine producing real JSONL, then reads it
# back via `tg log`, asserting that specific engine-emitted fields
# appear in the rendered output. Catches drift between writer + reader.
echo ""
echo "── engine ↔ tg log round-trip integration ──"
RT_TMP=$(mktemp -d)
mkdir -p "$RT_TMP/.tool-guard"
cat > "$RT_TMP/.tool-guard/rttool.config.json" <<'EOF'
{"defaultMode":"deny","allow":["allowed-cmd*"],"warn":[],"deny":[{"pattern":"deny-cmd*","message":"nope"}]}
EOF
mkdir -p "$RT_TMP/rttool"
cat > "$RT_TMP/rttool/wrapper.py" <<EOF
#!/usr/bin/env python3
# TOOL_GUARD_STUB_v1
import os, sys
TOOL = "rttool"
REAL = os.environ.get("RTTOOL_TG_REAL_BIN", "/usr/bin/rttool")  # TG_REAL_BIN_DEFAULT
sys.path.insert(0, os.environ["TOOL_GUARD_ENGINE_DIR"])
from tool_guard import run
sys.exit(run(tool_name=TOOL, real_bin=REAL, secret_flags=set()))
EOF
RT_LOG=$(mktemp -d)
ENGINE_PATH="$PKG_ROOT"  # source-tree

# Produce 2 real engine events: one allow (calls /bin/true → exit 0),
# one deny (rule match → exit 13).
( cd "$RT_TMP" && env \
    TG_TEST_MODE=1 \
    TOOL_GUARD_ENGINE_DIR="$ENGINE_PATH" \
    RTTOOL_TG_NONINTERACTIVE=1 \
    RTTOOL_TG_LOG_DIR="$RT_LOG" \
    RTTOOL_TG_REAL_BIN=/bin/true \
    python3 "$RT_TMP/rttool/wrapper.py" allowed-cmd arg1 arg2 ) >/dev/null 2>&1
ec1=$?
( cd "$RT_TMP" && env \
    TG_TEST_MODE=1 \
    TOOL_GUARD_ENGINE_DIR="$ENGINE_PATH" \
    RTTOOL_TG_NONINTERACTIVE=1 \
    RTTOOL_TG_LOG_DIR="$RT_LOG" \
    RTTOOL_TG_REAL_BIN=/bin/true \
    python3 "$RT_TMP/rttool/wrapper.py" deny-cmd should-not-run ) >/dev/null 2>&1
ec2=$?
assert_eq "round-trip: allowed-cmd → exit 0" "0" "$ec1"
assert_eq "round-trip: deny-cmd → exit 13 (DENY_EXIT_CODE)" "13" "$ec2"

# Now read back via tg log — every field that the engine emits AND
# tg log is supposed to render must appear.
out=$(TG_LOG_DIR="$RT_LOG" "$TG" log rttool -n 5 2>&1)
ec=$?
assert_eq "tg log read engine-produced JSONL — exit 0" "0" "$ec"
n=$(echo "$out" | grep -cE "^2[0-9]{3}-")
assert_eq "round-trip: tg log shows 2 entries from engine" "2" "$n"
assert_contains "round-trip: allow rule rendered" "rule=allowed-cmd*" "$out"
assert_contains "round-trip: deny rule rendered" "rule=deny-cmd*" "$out"
assert_contains "round-trip: argv from real call rendered" "rttool allowed-cmd arg1 arg2" "$out"
assert_contains "round-trip: deny argv rendered" "rttool deny-cmd should-not-run" "$out"
assert_contains "round-trip: exit code from real call (allow → 0)" "exit=0" "$out"
assert_contains "round-trip: exit code from deny (13)" "exit=13" "$out"

# Bonus: schema completeness — verify every field _build_event emits is
# either rendered by tg log or explicitly known to be silently ignored.
# Aksel + Scott P1-B: this catches drift if a field is added to
# _build_event without a corresponding update path in cmd_log.
LOG_FILE=$(ls "$RT_LOG"/*.log 2>/dev/null | head -1)
expected_keys="ts tool argv cwd exit duration_ms ppid parent_cmd user claude_session policy"
result=$(python3 - "$LOG_FILE" "$expected_keys" << 'PYEOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
expected = set(sys.argv[2].split())
for i, e in enumerate(events):
    actual = set(e.keys()) - {"real_bin"}  # real_bin is conditional
    if actual != expected:
        missing = expected - actual; extra = actual - expected
        print(f"DRIFT at entry {i}: missing={sorted(missing)} extra={sorted(extra)}")
        sys.exit(1)
print("schema-stable")
PYEOF
)
assert_eq "round-trip: engine-emitted schema matches expected keys exactly" "schema-stable" "$result"

rm -rf "$RT_TMP" "$RT_LOG"

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

# ─── tg install — pre-flight discovery + REAL_BIN patching ──────────
echo ""
echo "── tg install — pre-flight discovery (dry-fakes install.sh) ──"

# Build a sandbox PKG_ROOT that contains a fake install.sh + a fake
# tool-guard subdir (some-tool/wrapper.py). install.sh just echoes args
# and exit 0 — we're testing the pre-flight + patching, not the actual
# sudo-install path.
SANDBOX=$(mktemp -d)
cp "$TG" "$SANDBOX/tg"
chmod +x "$SANDBOX/tg"
# Fake engine file (some commands need it to exist as a sentinel)
touch "$SANDBOX/tool_guard.py"
# Fake install.sh that records what it was called with
cat > "$SANDBOX/install.sh" <<'EOF'
#!/bin/bash
echo "FAKE_INSTALL_SH_CALLED_WITH:$*"
EOF
chmod +x "$SANDBOX/install.sh"

# Make a tool-guard called 'fakeguard' that points at /bin/echo (always
# exists) so pre-flight discovery succeeds + REAL_BIN patching has
# something real to point to.
mkdir -p "$SANDBOX/fakeguard"
cat > "$SANDBOX/fakeguard/wrapper.py" <<'EOF'
#!/usr/bin/env python3
"""fakeguard — tool guard test stub."""
import os, sys
TOOL = "fakeguard"
REAL = os.environ.get("FAKEGUARD_TG_REAL_BIN", "/usr/bin/fakeguard")  # TG_REAL_BIN_DEFAULT
if os.environ.get("_FAKEGUARD_TG_ACTIVE"):
    os.execv(REAL, [REAL] + sys.argv[1:])
os.environ["_FAKEGUARD_TG_ACTIVE"] = "1"
EOF
chmod +x "$SANDBOX/fakeguard/wrapper.py"

# Make a second tool guard 'noexisttool' that points at a binary that's
# not on PATH — pre-flight should skip it with an install hint.
mkdir -p "$SANDBOX/noexisttool"
cat > "$SANDBOX/noexisttool/wrapper.py" <<'EOF'
#!/usr/bin/env python3
"""noexisttool — tool guard test stub for missing-binary case."""
import os, sys
TOOL = "noexisttool"
REAL = os.environ.get("NOEXISTTOOL_TG_REAL_BIN", "/usr/bin/noexisttool")
EOF
chmod +x "$SANDBOX/noexisttool/wrapper.py"

# Need a tmpdir for INSTALL_DIR so we don't touch /usr/local/bin
TMP_INSTALL=$(mktemp -d)
TMP_ENGINE=$(mktemp -d)
# Engine sentinel file (so _engine_installed is truthy, makes some commands not error)
touch "$TMP_ENGINE/tool_guard.py"

# Constrained PATH that contains /bin (where /bin/echo lives, our
# stand-in real binary for fakeguard) but NOT a path that has
# noexisttool — and NOT TMP_INSTALL (so we're testing the "not yet
# installed" code path).
RUN_PATH="/bin:/usr/bin"

run_tg_install() {
  TG_INSTALL_DIR="$TMP_INSTALL" TG_ENGINE_DIR="$TMP_ENGINE" \
    PATH="$RUN_PATH" "$SANDBOX/tg" install "$@" 2>&1
}

# 1. fakeguard exists (via /bin/echo simulating /usr/bin/fakeguard)
#    → patches stub + delegates to install.sh
# But wait — fakeguard isn't actually a binary on RUN_PATH. We need
# it to exist somewhere _which_all looks. Easiest: copy /bin/echo as
# /tmp/fake-binary-dir/fakeguard, prepend that dir to PATH.
FAKE_BIN_DIR=$(mktemp -d)
cp /bin/echo "$FAKE_BIN_DIR/fakeguard"
RUN_PATH="$FAKE_BIN_DIR:$RUN_PATH"

out=$(run_tg_install fakeguard 2>&1)
ec=$?
assert_eq "fakeguard install — exit code" "0" "$ec"
assert_contains "fakeguard discovered real binary" "real binary found at $FAKE_BIN_DIR/fakeguard" "$out"
assert_contains "fakeguard patched stub" "patched stub default" "$out"
assert_contains "delegates to install.sh" "FAKE_INSTALL_SH_CALLED_WITH:fakeguard" "$out"

# Verify the stub was actually patched (REAL_BIN now points at FAKE_BIN_DIR/fakeguard)
if grep -qF "$FAKE_BIN_DIR/fakeguard" "$SANDBOX/fakeguard/wrapper.py"; then
  pass "stub file content reflects patched REAL_BIN"
else
  fail "stub file not patched" "content: $(cat $SANDBOX/fakeguard/wrapper.py)"
fi

# 2. noexisttool — pre-flight finds nothing → skip with install hint,
#    install.sh NOT called for it
out=$(run_tg_install noexisttool 2>&1)
ec=$?
assert_eq "noexisttool install — exit code (no survivors → 1)" "1" "$ec"
assert_contains "noexisttool — install hint shown" "not installed on this system" "$out"
if echo "$out" | grep -qF "FAKE_INSTALL_SH_CALLED_WITH"; then
  fail "install.sh should not have been called" "got: $out"
else
  pass "install.sh NOT called when no tools survive pre-flight"
fi

# 3. INSTALL_DIR/<name> exists and is a non-wrapper binary → refuse + suggest mv
echo "fake real binary, not a wrapper" > "$TMP_INSTALL/fakeguard"
chmod +x "$TMP_INSTALL/fakeguard"
out=$(run_tg_install fakeguard 2>&1)
ec=$?
assert_eq "conflict — exit code" "1" "$ec"
assert_contains "conflict — suggests mv to -real" "sudo mv $TMP_INSTALL/fakeguard $TMP_INSTALL/fakeguard-real" "$out"
rm -f "$TMP_INSTALL/fakeguard"

# 4. INSTALL_DIR/<name>-real already exists → use it as REAL_BIN
cp /bin/echo "$TMP_INSTALL/fakeguard-real"
# Restore stub so we can re-patch
cat > "$SANDBOX/fakeguard/wrapper.py" <<'EOF'
#!/usr/bin/env python3
"""fakeguard — tool guard test stub."""
import os, sys
TOOL = "fakeguard"
REAL = os.environ.get("FAKEGUARD_TG_REAL_BIN", "/usr/bin/fakeguard")  # TG_REAL_BIN_DEFAULT
if os.environ.get("_FAKEGUARD_TG_ACTIVE"):
    os.execv(REAL, [REAL] + sys.argv[1:])
os.environ["_FAKEGUARD_TG_ACTIVE"] = "1"
EOF
out=$(run_tg_install fakeguard 2>&1)
assert_contains "<name>-real is preferred over PATH lookup" "real binary found at $TMP_INSTALL/fakeguard-real" "$out"
rm -f "$TMP_INSTALL/fakeguard-real"

# 5. Running from /usr/local/bin (installed mode) is rejected with a
#    helpful message — install needs the source tree.
INSTALLED_TG=$(mktemp -d)
cp "$TG" "$INSTALLED_TG/tg"
chmod +x "$INSTALLED_TG/tg"
# Force PKG_ROOT to look like the installed location
out=$(TG_INSTALL_DIR="$INSTALLED_TG" TG_ENGINE_DIR="$TMP_ENGINE" \
      "$INSTALLED_TG/tg" install fakeguard 2>&1)
ec=$?
assert_eq "installed-mode install — exit 1" "1" "$ec"
assert_contains "installed-mode install — clear error" "already running from" "$out"
rm -rf "$INSTALLED_TG"

# 6. Auto-discover (no args): all tool guards in PKG_ROOT get pre-flight
# Restore stub default
cat > "$SANDBOX/fakeguard/wrapper.py" <<'EOF'
#!/usr/bin/env python3
"""fakeguard — tool guard test stub."""
import os, sys
TOOL = "fakeguard"
REAL = os.environ.get("FAKEGUARD_TG_REAL_BIN", "/usr/bin/fakeguard")  # TG_REAL_BIN_DEFAULT
EOF
out=$(run_tg_install 2>&1)
assert_contains "auto-discover sees fakeguard" "fakeguard" "$out"
assert_contains "auto-discover sees noexisttool" "noexisttool" "$out"

rm -rf "$SANDBOX" "$TMP_INSTALL" "$TMP_ENGINE" "$FAKE_BIN_DIR"

echo ""
echo "── tg install — bug-hunt regressions ──"

# Re-import tg as a Python module to test internal helpers directly.
# Copy to a non-tg name so import works (importing a file named 'tg' is awkward).
TG_PYMOD=$(mktemp -d)/tgmod.py
cp "$TG" "$TG_PYMOD"

# Bug H regression: _patch_real_bin must NOT raise on read-only stub
RO_TMP=$(mktemp -d)
RO_STUB="$RO_TMP/wrapper.py"
cat > "$RO_STUB" <<'EOF'
#!/usr/bin/env python3
# TOOL_GUARD_STUB_v1
import os
REAL = os.environ.get("FOO_TG_REAL_BIN", "/usr/bin/foo")  # TG_REAL_BIN_DEFAULT
EOF
chmod 0444 "$RO_STUB"
result=$(python3 -c "
import sys; sys.path.insert(0, '$(dirname "$TG_PYMOD")')
import tgmod, pathlib
patched, msg = tgmod._patch_real_bin(pathlib.Path('$RO_STUB'), 'foo', '/opt/foo')
print(f'patched={patched}|msg={msg}')
" 2>&1)
case "$result" in
  patched=False*read-only*) pass "_patch_real_bin: read-only stub returns (False, msg) instead of raising" ;;
  *) fail "_patch_real_bin on read-only stub" "got: $result" ;;
esac
chmod 0644 "$RO_STUB"
rm -rf "$RO_TMP"

# Bug J regression: _which_all skips relative PATH entries (would otherwise
# bake a cwd-dependent path into the stub).
WHICH_TMP=$(mktemp -d)
ABSDIR="$WHICH_TMP/absbin"
mkdir -p "$ABSDIR"
cp /bin/echo "$ABSDIR/onlytool"
# Also drop a relative-path candidate by setting PATH entry to "."
# and putting onlytool in cwd
RELDIR="$WHICH_TMP/reldir"
mkdir -p "$RELDIR"
cp /bin/echo "$RELDIR/onlytool"

# Use python3 by absolute path so we can manipulate PATH freely without
# breaking the interpreter lookup.
PY3=$(command -v python3)
TGMOD_DIR="$(dirname "$TG_PYMOD")"

# Test 1: with PATH containing only an absolute dir → finds it
result=$(cd "$RELDIR" && PATH="$ABSDIR" "$PY3" -c "
import sys; sys.path.insert(0, '$TGMOD_DIR')
import tgmod
print(tgmod._which_all('onlytool'))
" 2>&1)
case "$result" in
  *"$ABSDIR/onlytool"*) pass "_which_all finds absolute PATH entries" ;;
  *) fail "_which_all absolute" "got: $result" ;;
esac

# Test 2: with PATH=. and cwd has onlytool → SKIPPED (relative)
result=$(cd "$RELDIR" && PATH="." "$PY3" -c "
import sys; sys.path.insert(0, '$TGMOD_DIR')
import tgmod
r = tgmod._which_all('onlytool')
print('FOUND' if r else 'EMPTY', r)
" 2>&1)
case "$result" in
  EMPTY*) pass "_which_all skips relative PATH entries (would bake cwd-dependent path)" ;;
  *) fail "_which_all should skip relative entries" "got: $result" ;;
esac

# Test 3: empty entries in PATH (leading/trailing colon) → no crash
result=$(PATH=":$ABSDIR:" "$PY3" -c "
import sys; sys.path.insert(0, '$TGMOD_DIR')
import tgmod
print(tgmod._which_all('onlytool'))
" 2>&1)
case "$result" in
  *"$ABSDIR/onlytool"*) pass "_which_all handles empty PATH entries gracefully" ;;
  *) fail "_which_all empty PATH entries" "got: $result" ;;
esac

rm -rf "$WHICH_TMP"

# Bug G follow-up: _discover_real_binary skips symlinks pointing at our wrapper
DISC_TMP=$(mktemp -d)
INST_DIR="$DISC_TMP/install"; PATHA="$DISC_TMP/patha"; PATHB="$DISC_TMP/pathb"
mkdir -p "$INST_DIR" "$PATHA" "$PATHB"
cat > "$INST_DIR/foo" <<'EOF'
#!/usr/bin/env python3
# tool_guard wrapper
EOF
chmod +x "$INST_DIR/foo"
ln -s "$INST_DIR/foo" "$PATHA/foo"
cp /bin/echo "$PATHB/foo"

result=$(TG_INSTALL_DIR="$INST_DIR" PATH="$PATHA:$PATHB" "$PY3" -c "
import sys; sys.path.insert(0, '$TGMOD_DIR')
import tgmod, os, pathlib
tgmod.INSTALL_DIR = pathlib.Path(os.environ['TG_INSTALL_DIR'])
print(tgmod._discover_real_binary('foo'))
" 2>&1)
case "$result" in
  *"$PATHB/foo") pass "_discover_real_binary skips symlinks pointing at our wrapper" ;;
  *) fail "_discover_real_binary symlink-skip" "got: $result (expected $PATHB/foo)" ;;
esac
rm -rf "$DISC_TMP"

rm -rf "$(dirname "$TG_PYMOD")"

# ─── tg add — scaffold a new tool-guard ──────────────────────────────
echo ""
echo "── tg add — scaffold validation ──"

# Build a writable PKG_ROOT (the real one is read-only when run from CI)
ADD_SANDBOX=$(mktemp -d)
cp "$TG" "$ADD_SANDBOX/tg"
chmod +x "$ADD_SANDBOX/tg"
touch "$ADD_SANDBOX/tool_guard.py"  # sentinel so engine helpers don't error

# Happy path
out=$("$ADD_SANDBOX/tg" add newtool 2>&1)
ec=$?
assert_eq "tg add newtool — exit 0" "0" "$ec"
[[ -f "$ADD_SANDBOX/newtool/wrapper.py" ]] && pass "tg add — wrote stub" || fail "stub missing"
[[ -f "$ADD_SANDBOX/newtool/POLICY.md" ]] && pass "tg add — wrote POLICY.md" || fail "POLICY.md missing"
[[ -f "$ADD_SANDBOX/examples/.tool-guard/newtool.config.json" ]] && pass "tg add — wrote example config" || fail "example config missing"

# Generated stub has python shebang
sb=$(head -1 "$ADD_SANDBOX/newtool/wrapper.py")
case "$sb" in
  '#!/usr/bin/env python3') pass "generated stub has correct shebang" ;;
  *) fail "generated stub shebang" "got: $sb" ;;
esac

# Generated example config is valid JSON + has expected fields
result=$(python3 -c "
import json
d = json.load(open('$ADD_SANDBOX/examples/.tool-guard/newtool.config.json'))
print('OK' if d.get('defaultMode') and 'allow' in d else 'BAD')
" 2>&1)
assert_eq "generated example config is valid + has defaultMode + allow" "OK" "$result"

# Refuse if dir already exists
out=$("$ADD_SANDBOX/tg" add newtool 2>&1)
ec=$?
assert_eq "tg add already-exists — exit 1" "1" "$ec"
assert_contains "already-exists error message" "already exists" "$out"

# Refuse reserved names. Some reserved names contain `_` which trips the
# alphanumeric validator first — but the goal is just "rejected", with
# any reason. Both error paths are acceptable.
for reserved in tg examples _tests __pycache__ tool_guard install uninstall; do
  out=$("$ADD_SANDBOX/tg" add "$reserved" 2>&1)
  ec=$?
  if [[ $ec -eq 1 ]] && echo "$out" | grep -qE "reserved|invalid tool name"; then
    pass "tg add $reserved — rejected"
  else
    fail "tg add $reserved" "ec=$ec out=$out"
  fi
done

# Refuse invalid names
for bad in "" "-foo" "foo-" "foo bar" "foo/bar" "foo.bar"; do
  out=$("$ADD_SANDBOX/tg" add "$bad" 2>&1)
  ec=$?
  if [[ $ec -ne 0 ]]; then
    pass "tg add '$bad' — rejected"
  else
    fail "tg add '$bad'" "should be rejected, got ec=$ec"
  fi
done

# Bug R regression: tg add must refuse in installed mode (was crashing
# with Python traceback when run from /usr/local/bin/tg).
INSTALLED_PKG=$(mktemp -d)
cp "$TG" "$INSTALLED_PKG/tg"
chmod +x "$INSTALLED_PKG/tg"
out=$(TG_INSTALL_DIR="$INSTALLED_PKG" "$INSTALLED_PKG/tg" add foo 2>&1)
ec=$?
assert_eq "tg add in installed mode — clean exit 1" "1" "$ec"
assert_contains "tg add installed mode — actionable message" "Run from a source clone" "$out"
if echo "$out" | grep -q "Traceback"; then
  fail "tg add installed mode" "regressed to Python traceback"
else
  pass "tg add installed mode — no Python traceback (was Bug R)"
fi
rm -rf "$INSTALLED_PKG"

rm -rf "$ADD_SANDBOX"

# ─── tg uninstall — installed-mode handling ──────────────────────────
echo ""
echo "── tg uninstall — installed mode ──"

# Bug S regression: tg uninstall in installed mode previously gave
# "uninstall.sh not found at /usr/local/bin/uninstall.sh" — confusing
# (the real uninstall.sh is in the source clone). Should detect mode
# and point at the cache.
INSTALLED_PKG=$(mktemp -d)
cp "$TG" "$INSTALLED_PKG/tg"
chmod +x "$INSTALLED_PKG/tg"
out=$(TG_INSTALL_DIR="$INSTALLED_PKG" "$INSTALLED_PKG/tg" uninstall 2>&1)
ec=$?
assert_eq "tg uninstall in installed mode — exit 1" "1" "$ec"
assert_contains "tg uninstall installed mode — points at source clone" "tool-guard-source" "$out"
rm -rf "$INSTALLED_PKG"

# tg uninstall in source mode — delegates to uninstall.sh (we use a
# fake uninstall.sh that just records the args; we don't want the test
# to actually sudo-rm anything).
UNINSTALL_SANDBOX=$(mktemp -d)
cp "$TG" "$UNINSTALL_SANDBOX/tg"
chmod +x "$UNINSTALL_SANDBOX/tg"
touch "$UNINSTALL_SANDBOX/tool_guard.py"  # source-mode sentinel
cat > "$UNINSTALL_SANDBOX/uninstall.sh" <<'EOF'
#!/bin/bash
echo "FAKE_UNINSTALL_SH:$*"
EOF
chmod +x "$UNINSTALL_SANDBOX/uninstall.sh"
out=$("$UNINSTALL_SANDBOX/tg" uninstall onetool twotool 2>&1)
assert_contains "tg uninstall delegates to uninstall.sh with names" "FAKE_UNINSTALL_SH:onetool twotool" "$out"
rm -rf "$UNINSTALL_SANDBOX"

# ─── tg config init ──────────────────────────────────────────────────
echo ""
echo "── tg config init ──"

INIT_SANDBOX=$(mktemp -d)
cp "$TG" "$INIT_SANDBOX/tg"
chmod +x "$INIT_SANDBOX/tg"
mkdir -p "$INIT_SANDBOX/examples/.tool-guard"
cat > "$INIT_SANDBOX/examples/.tool-guard/widget.config.json" <<'EOF'
{"defaultMode":"prompt","allow":["safe*"],"warn":[],"deny":[]}
EOF

# Run from a tmp cwd so config init creates a fresh .tool-guard/ there
INIT_CWD=$(mktemp -d)
out=$(cd "$INIT_CWD" && "$INIT_SANDBOX/tg" config init widget 2>&1)
ec=$?
assert_eq "tg config init — exit 0" "0" "$ec"
[[ -f "$INIT_CWD/.tool-guard/widget.config.json" ]] && pass "config init — wrote .tool-guard/widget.config.json" || fail "missing config file"

# Refuses on existing without --force
out=$(cd "$INIT_CWD" && "$INIT_SANDBOX/tg" config init widget 2>&1)
ec=$?
assert_eq "tg config init — refuses existing" "1" "$ec"
assert_contains "config init refusal message" "already exists" "$out"

# --force overwrites
out=$(cd "$INIT_CWD" && "$INIT_SANDBOX/tg" config init widget --force 2>&1)
ec=$?
assert_eq "tg config init --force — exit 0" "0" "$ec"

# Unknown tool
out=$(cd "$INIT_CWD" && "$INIT_SANDBOX/tg" config init unknownthing 2>&1)
ec=$?
assert_eq "tg config init unknown — exit 1" "1" "$ec"
assert_contains "config init unknown error" "no example template" "$out"

rm -rf "$INIT_SANDBOX" "$INIT_CWD"

# ─── tg config show ──────────────────────────────────────────────────
echo ""
echo "── tg config show ──"

# Use the real PKG_ROOT (has the engine for merge), but a tmp cwd with
# its own .tool-guard/
SHOW_CWD=$(mktemp -d)
mkdir -p "$SHOW_CWD/.tool-guard"
cat > "$SHOW_CWD/.tool-guard/myshow.config.json" <<'EOF'
{"defaultMode":"deny","allow":["status*"],"warn":[],"deny":[{"pattern":"force-push*","message":"no"}]}
EOF
out=$(cd "$SHOW_CWD" && "$TG" config show myshow 2>&1)
ec=$?
assert_eq "tg config show — exit 0" "0" "$ec"
assert_contains "config show — header" "Resolved config for myshow" "$out"
assert_contains "config show — shows shared layer marker" "shared" "$out"
assert_contains "config show — includes pattern from config" "status*" "$out"
assert_contains "config show — includes deny rule" "force-push*" "$out"

# config show with no .tool-guard/ anywhere → fail
out=$(cd /tmp && TOOL_GUARD_DIR=/nonexistent HOME=/nonexistent "$TG" config show myshow 2>&1)
ec=$?
assert_eq "tg config show — no .tool-guard/ exits 1" "1" "$ec"
assert_contains "config show — clear error" "no .tool-guard" "$out"
rm -rf "$SHOW_CWD"

# ─── tg status ───────────────────────────────────────────────────────
echo ""
echo "── tg status ──"

# tg status with explicit tool name + a real .tool-guard/ in cwd
STATUS_CWD=$(mktemp -d)
mkdir -p "$STATUS_CWD/.tool-guard"
cat > "$STATUS_CWD/.tool-guard/az.config.json" <<'EOF'
{"defaultMode":"prompt","allow":["version"],"warn":[],"deny":[]}
EOF
out=$(cd "$STATUS_CWD" && "$TG" status az 2>&1)
ec=$?
assert_eq "tg status az — exit 0" "0" "$ec"
assert_contains "tg status — shows config dir" "Config dir" "$out"
assert_contains "tg status — shows az config marker" "shared cfg" "$out"
assert_contains "tg status — shows shared cfg path" "az.config.json" "$out"

# tg status (no tool arg) — lists all installed
out=$(cd "$STATUS_CWD" && "$TG" status 2>&1)
ec=$?
assert_eq "tg status (no arg) — exit 0" "0" "$ec"
# Should at least show one of the installed tool guards
if echo "$out" | grep -qE "(az|gh|sleep)"; then
  pass "tg status (no arg) lists installed tool-guards"
else
  fail "tg status no-arg" "no tools listed: $out"
fi

# tg status with no .tool-guard/ anywhere — should NOT crash, just say "not found"
out=$(cd /tmp && TOOL_GUARD_DIR=/nonexistent HOME=/nonexistent "$TG" status az 2>&1)
ec=$?
# Returns 0 (status is informational, can't really fail) but reports clearly
assert_contains "tg status — no .tool-guard reports clearly" "not found" "$out"
rm -rf "$STATUS_CWD"

# ─── tg help ─────────────────────────────────────────────────────────
echo ""
echo "── tg help ──"
out=$("$TG" help 2>&1)
ec=$?
assert_eq "tg help — exit 0" "0" "$ec"
assert_contains "tg help — lists commands section" "Commands" "$out"
assert_contains "tg help — lists 'check' command" "check" "$out"
assert_contains "tg help — lists 'log' command" "log" "$out"

# tg help <command> — per-command help
out=$("$TG" help check 2>&1)
ec=$?
assert_eq "tg help check — exit 0" "0" "$ec"
assert_contains "tg help check — shows usage line for check" "check" "$out"

# tg help unknownsubcommand — should fail gracefully
out=$("$TG" help noexistsubcmd 2>&1)
# Either prints help or errors, but must NOT traceback
if echo "$out" | grep -q "Traceback"; then
  fail "tg help unknown" "Python traceback"
else
  pass "tg help unknown — no traceback"
fi

# tg --help (argparse standard) also works
out=$("$TG" --help 2>&1)
ec=$?
assert_eq "tg --help — exit 0" "0" "$ec"
assert_contains "tg --help — argparse usage" "usage" "$out"

# ─── tg config edit ──────────────────────────────────────────────────
echo ""
echo "── tg config edit ──"

# Run config edit with EDITOR=true (no-op editor that just exits 0).
# Verifies the file is created from template and EDITOR is invoked.
EDIT_SANDBOX=$(mktemp -d)
cp "$TG" "$EDIT_SANDBOX/tg"
chmod +x "$EDIT_SANDBOX/tg"
mkdir -p "$EDIT_SANDBOX/examples/.tool-guard"
cat > "$EDIT_SANDBOX/examples/.tool-guard/widget.config.json" <<'EOF'
{"defaultMode":"prompt","allow":["safe*"]}
EOF
EDIT_CWD=$(mktemp -d)

# config edit (shared) — copies template + invokes EDITOR
out=$(cd "$EDIT_CWD" && EDITOR=true "$EDIT_SANDBOX/tg" config edit widget 2>&1)
ec=$?
assert_eq "tg config edit widget — exit 0" "0" "$ec"
[[ -f "$EDIT_CWD/.tool-guard/widget.config.json" ]] && pass "config edit — created shared config" || fail "no config file"

# config edit --local — creates the .local.json file
out=$(cd "$EDIT_CWD" && EDITOR=true "$EDIT_SANDBOX/tg" config edit widget --local 2>&1)
ec=$?
assert_eq "tg config edit --local — exit 0" "0" "$ec"
[[ -f "$EDIT_CWD/.tool-guard/widget.config.local.json" ]] && pass "config edit --local — created .local.json" || fail "no local config"

# Bug-prevention: edit anchors at cwd (walk-up only, not home fallback).
# Even if HOME has a .tool-guard symlink, init lands at cwd.
HOME_FALLBACK=$(mktemp -d)
mkdir -p "$HOME_FALLBACK/.config/tool-guard"
NEW_CWD=$(mktemp -d)
out=$(cd "$NEW_CWD" && HOME="$HOME_FALLBACK" EDITOR=true "$EDIT_SANDBOX/tg" config edit widget 2>&1)
[[ -f "$NEW_CWD/.tool-guard/widget.config.json" ]] && pass "config edit anchors at cwd, not ~/.config/" || fail "config edit went to home fallback"
[[ -f "$HOME_FALLBACK/.config/tool-guard/widget.config.json" ]] && fail "config edit polluted home fallback" || pass "home fallback NOT touched by edit"

rm -rf "$EDIT_SANDBOX" "$EDIT_CWD" "$HOME_FALLBACK" "$NEW_CWD"

# ─── tg config validate — regex anchor warning (P2 from quinn) ───────
echo ""
echo "── tg config validate — regex deny without ^ anchor warns ──"
ANCHOR_TMP=$(mktemp -d)
mkdir -p "$ANCHOR_TMP/.tool-guard"
# Unanchored regex deny — substring-matches, weaker than likely intended
cat > "$ANCHOR_TMP/.tool-guard/myanchor.config.json" <<'EOF'
{"defaultMode":"prompt","allow":[],"warn":[],"deny":[{"pattern":"foo$","type":"regex","message":"x"}]}
EOF
out=$(cd "$ANCHOR_TMP" && "$TG" config validate 2>&1)
ec=$?
if [[ $ec -eq 1 ]] && echo "$out" | grep -qF "without an explicit '^' anchor"; then
  pass "unanchored regex deny → warning + non-zero exit"
else
  fail "regex anchor warning" "ec=$ec out=$out"
fi

# Properly anchored regex deny — passes
cat > "$ANCHOR_TMP/.tool-guard/myanchor.config.json" <<'EOF'
{"defaultMode":"prompt","allow":[],"warn":[],"deny":[{"pattern":"^foo.*","type":"regex","message":"x"}]}
EOF
out=$(cd "$ANCHOR_TMP" && "$TG" config validate 2>&1)
ec=$?
assert_eq "anchored regex deny passes validate" "0" "$ec"

# Glob deny rules NOT subject to the warning (they're already bounded)
cat > "$ANCHOR_TMP/.tool-guard/myanchor.config.json" <<'EOF'
{"defaultMode":"prompt","allow":[],"warn":[],"deny":["foo*"]}
EOF
out=$(cd "$ANCHOR_TMP" && "$TG" config validate 2>&1)
ec=$?
assert_eq "glob deny rules not subject to anchor warning" "0" "$ec"
rm -rf "$ANCHOR_TMP"

# ─── tg test command coverage (Scott P2-C) ──────────────────────────
echo ""
echo "── tg test command ──"

# Build a sandbox PKG_ROOT with a minimal _tests/ dir
TEST_SANDBOX=$(mktemp -d)
cp "$TG" "$TEST_SANDBOX/tg"; chmod +x "$TEST_SANDBOX/tg"
mkdir -p "$TEST_SANDBOX/_tests"

# Test 1: all-pass exit 0
cat > "$TEST_SANDBOX/_tests/passing.test.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TEST_SANDBOX/_tests/passing.test.sh"
out=$("$TEST_SANDBOX/tg" test 2>&1)
ec=$?
assert_eq "tg test all-pass → exit 0" "0" "$ec"
assert_contains "tg test reports 'All N suites passed'" "All 1 suites passed" "$out"

# Test 2: with failure → exit 1, reports failed count
cat > "$TEST_SANDBOX/_tests/failing.test.sh" <<'EOF'
#!/bin/bash
exit 7
EOF
chmod +x "$TEST_SANDBOX/_tests/failing.test.sh"
out=$("$TEST_SANDBOX/tg" test 2>&1)
ec=$?
assert_eq "tg test with failure → exit 1" "1" "$ec"
assert_contains "tg test reports failed count" "1/2 suite(s) failed" "$out"

# Test 3: no _tests dir → graceful error, no traceback
NO_TESTS_DIR=$(mktemp -d)
cp "$TG" "$NO_TESTS_DIR/tg"; chmod +x "$NO_TESTS_DIR/tg"
out=$("$NO_TESTS_DIR/tg" test 2>&1)
ec=$?
assert_eq "tg test no _tests dir → exit 1" "1" "$ec"
if echo "$out" | grep -q "Traceback"; then
  fail "tg test no _tests dir" "Python traceback"
else
  pass "tg test no _tests dir → no Python traceback"
fi
rm -rf "$NO_TESTS_DIR"

# Test 4: installed mode (PKG_ROOT == INSTALL_DIR) → hint at source
INSTALLED_TG_TMP=$(mktemp -d)
cp "$TG" "$INSTALLED_TG_TMP/tg"; chmod +x "$INSTALLED_TG_TMP/tg"
out=$(TG_INSTALL_DIR="$INSTALLED_TG_TMP" "$INSTALLED_TG_TMP/tg" test 2>&1)
if echo "$out" | grep -qF "tool-guard-source" || echo "$out" | grep -qF "source clone"; then
  pass "tg test installed-mode points at source cache"
else
  fail "tg test installed-mode hint" "$(echo "$out" | head -3)"
fi
rm -rf "$INSTALLED_TG_TMP" "$TEST_SANDBOX"

# ─── Stub canonical-marker drift detection (Aksel P1) ───────────────
echo ""
echo "── stub template drift detection ──"

# Every production stub MUST carry the TOOL_GUARD_STUB_v1 magic line
# AND the TG_REAL_BIN_DEFAULT marker on its REAL_BIN assignment.
# Without these, _is_our_wrapper / _guard_installed silently misclassify
# (false negatives → install.sh refuses to overwrite our own stubs;
# false positives → we overwrite a real binary).
PROD_STUBS_DIR="$(dirname "$TG")"
for stub_dir in az gh git sleep; do
  stub_path="$PROD_STUBS_DIR/$stub_dir/wrapper.py"
  [[ -f "$stub_path" ]] || continue
  if grep -qF "TOOL_GUARD_STUB_v1" "$stub_path"; then
    pass "production stub '$stub_dir' has TOOL_GUARD_STUB_v1 marker"
  else
    fail "stub '$stub_dir' missing magic line" "$(head -3 "$stub_path")"
  fi
  if grep -qF "TG_REAL_BIN_DEFAULT" "$stub_path"; then
    pass "production stub '$stub_dir' has TG_REAL_BIN_DEFAULT marker"
  else
    fail "stub '$stub_dir' missing REAL_BIN marker"
  fi
done

# tg add must emit a stub WITH both markers (was a P1: scaffolded
# stubs were stale and lacked the security model of production stubs).
ADD_DRIFT_SANDBOX=$(mktemp -d)
cp "$TG" "$ADD_DRIFT_SANDBOX/tg"
chmod +x "$ADD_DRIFT_SANDBOX/tg"
touch "$ADD_DRIFT_SANDBOX/tool_guard.py"
"$ADD_DRIFT_SANDBOX/tg" add scaffoldcheck >/dev/null 2>&1
GENERATED="$ADD_DRIFT_SANDBOX/scaffoldcheck/wrapper.py"
if [[ -f "$GENERATED" ]]; then
  if grep -qF "TOOL_GUARD_STUB_v1" "$GENERATED"; then
    pass "tg add scaffold has TOOL_GUARD_STUB_v1 marker"
  else
    fail "tg add scaffold missing magic line" "$(head -10 "$GENERATED")"
  fi
  if grep -qF "TG_REAL_BIN_DEFAULT" "$GENERATED"; then
    pass "tg add scaffold has TG_REAL_BIN_DEFAULT marker"
  else
    fail "tg add scaffold missing REAL_BIN marker"
  fi
  # Critical regression: scaffold must NOT contain the removed
  # _<TOOL>_TG_ACTIVE recursion sentinel pattern (was a P1 bypass).
  if grep -qE "_SCAFFOLDCHECK_TG_ACTIVE" "$GENERATED"; then
    fail "tg add scaffold STILL contains removed sentinel pattern" "regression"
  else
    pass "tg add scaffold does NOT have removed sentinel pattern"
  fi
  # Must contain the TG_TEST_MODE gating
  if grep -qF "TG_TEST_MODE" "$GENERATED"; then
    pass "tg add scaffold gates TOOL_GUARD_ENGINE_DIR behind TG_TEST_MODE"
  else
    fail "tg add scaffold missing TG_TEST_MODE gating"
  fi
fi
rm -rf "$ADD_DRIFT_SANDBOX"

# _patch_real_bin must work for both REAL and REAL_SLEEP variable names
PATCH_TMP=$(mktemp -d)
cp "$TG" "$PATCH_TMP/tgmod.py"
for varname in REAL REAL_SLEEP; do
  STUB_FILE="$PATCH_TMP/wrapper-$varname.py"
  cat > "$STUB_FILE" <<EOF
#!/usr/bin/env python3
# TOOL_GUARD_STUB_v1
import os
$varname = os.environ.get("MYTOOL_TG_REAL_BIN", "/usr/bin/mytool")  # TG_REAL_BIN_DEFAULT
EOF
  result=$("$PY3" -c "
import sys, pathlib; sys.path.insert(0, '$PATCH_TMP')
import tgmod
patched, msg = tgmod._patch_real_bin(pathlib.Path('$STUB_FILE'), 'mytool', '/opt/mytool')
print(f'patched={patched}|msg={msg}')
")
  case "$result" in
    patched=True*) pass "_patch_real_bin works with var name '$varname'" ;;
    *) fail "_patch_real_bin var name '$varname'" "$result" ;;
  esac
  # Verify variable name preserved in the patched line
  if grep -qE "^${varname} = os.environ.get" "$STUB_FILE"; then
    pass "  → variable name '$varname' preserved"
  else
    fail "  → variable name '$varname' clobbered" "$(grep TG_REAL_BIN_DEFAULT "$STUB_FILE")"
  fi
done
rm -rf "$PATCH_TMP"

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

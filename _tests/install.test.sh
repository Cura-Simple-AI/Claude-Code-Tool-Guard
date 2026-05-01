#!/usr/bin/env bash
# Tests for install.sh + uninstall.sh — the orchestrator scripts that
# tg install delegates to. Previously untested (Scott P1-C finding):
# the overwrite-protection branches and the engine/tg install logic
# only ran in production, so a regression in the grep guards or PATH
# checks would silently land.
#
# Tests use TG_INSTALL_DIR + TG_ENGINE_DIR overrides to direct install
# at a tmp dir (no sudo). PATH check is auto-skipped when
# TG_INSTALL_DIR is set.

set -uo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$PKG_ROOT/install.sh"
UNINSTALL_SH="$PKG_ROOT/uninstall.sh"

[[ -x "$INSTALL_SH" ]] || { echo "FATAL: $INSTALL_SH not executable" >&2; exit 1; }
[[ -x "$UNINSTALL_SH" ]] || { echo "FATAL: $UNINSTALL_SH not executable" >&2; exit 1; }

PASS=0
FAIL=0
fail() { local what="$1" why="${2-}"; echo "  ❌ $what: $why" >&2; FAIL=$((FAIL + 1)); }
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
  else fail "$what" "expected to contain '$needle'"
  fi
}

echo "════════════════════════════════════════════════════════════"
echo " install.sh + uninstall.sh — orchestrator tests"
echo "════════════════════════════════════════════════════════════"

# ─── Happy path: install az + uninstall az ─────────────────────────
echo ""
echo "── happy path: install + uninstall az ──"
INSTALL_TMP=$(mktemp -d)
ENGINE_TMP=$(mktemp -d)

out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$INSTALL_SH" az 2>&1)
ec=$?
assert_eq "install az → exit 0" "0" "$ec"
[[ -f "$ENGINE_TMP/tool_guard.py" ]] && pass "engine installed at TG_ENGINE_DIR" || fail "engine missing"
[[ -x "$INSTALL_TMP/az" ]] && pass "az stub installed at TG_INSTALL_DIR" || fail "az stub missing"
[[ -x "$INSTALL_TMP/tg" ]] && pass "tg CLI installed alongside" || fail "tg CLI missing"
assert_contains "install reports engine path in summary" "Engine installed: $ENGINE_TMP/tool_guard.py" "$out"

# Re-run is idempotent — overwrites our own wrapper without complaint
out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$INSTALL_SH" az 2>&1)
ec=$?
assert_eq "re-install → exit 0 (idempotent)" "0" "$ec"
assert_contains "re-install reports overwriting our existing stub" "existing tool-guard at" "$out"

# Uninstall just az (engine kept)
out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$UNINSTALL_SH" az 2>&1)
ec=$?
assert_eq "uninstall az → exit 0" "0" "$ec"
[[ -f "$INSTALL_TMP/az" ]] && fail "az stub still present after uninstall" || pass "az stub removed"
[[ -f "$ENGINE_TMP/tool_guard.py" ]] && pass "engine kept (partial uninstall)" || fail "engine wrongly removed"

rm -rf "$INSTALL_TMP" "$ENGINE_TMP"

# ─── P1-C: install.sh refuses to overwrite a non-Python binary ──────
echo ""
echo "── install.sh refuses to overwrite non-Python binary at INSTALL_DIR/<name> ──"
INSTALL_TMP=$(mktemp -d)
ENGINE_TMP=$(mktemp -d)
# Place a fake bash binary at the install destination — install.sh
# must refuse, not silently overwrite (would shadow real az).
cat > "$INSTALL_TMP/az" <<'EOF'
#!/usr/bin/env bash
echo "I am the real az, please don't shadow me"
EOF
chmod +x "$INSTALL_TMP/az"

out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$INSTALL_SH" az 2>&1)
ec=$?
if [[ $ec -ne 0 ]]; then
  pass "install.sh refuses non-Python binary (non-zero exit)"
else
  fail "install.sh overwrote non-Python binary" "exit was 0"
fi
assert_contains "refusal mentions 'Refusing to overwrite'" "Refusing to overwrite" "$out"
# The real binary should still be there
if grep -q "I am the real az" "$INSTALL_TMP/az"; then
  pass "non-Python binary preserved (not overwritten)"
else
  fail "non-Python binary CLOBBERED" "$(cat "$INSTALL_TMP/az")"
fi
rm -rf "$INSTALL_TMP" "$ENGINE_TMP"

# ─── P1-C: install.sh refuses Python script that's not our wrapper ──
echo ""
echo "── install.sh refuses non-tool-guard Python script ──"
INSTALL_TMP=$(mktemp -d)
ENGINE_TMP=$(mktemp -d)
cat > "$INSTALL_TMP/az" <<'EOF'
#!/usr/bin/env python3
"""I am someone else's az script, please don't overwrite me."""
import sys
sys.exit(0)
EOF
chmod +x "$INSTALL_TMP/az"

out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$INSTALL_SH" az 2>&1)
ec=$?
if [[ $ec -ne 0 ]]; then
  pass "install.sh refuses non-tool-guard Python script"
else
  fail "install.sh overwrote unrelated Python script" "exit was 0"
fi
assert_contains "refusal explains it's a Python but not tool-guard" "does not look like a tool-guard" "$out"
# Original Python content preserved
if grep -q "someone else's az script" "$INSTALL_TMP/az"; then
  pass "non-tool-guard Python preserved"
else
  fail "non-tool-guard Python clobbered"
fi
rm -rf "$INSTALL_TMP" "$ENGINE_TMP"

# ─── uninstall.sh equivalents ──────────────────────────────────────
echo ""
echo "── uninstall.sh refuses non-Python binary ──"
INSTALL_TMP=$(mktemp -d)
ENGINE_TMP=$(mktemp -d)
cat > "$INSTALL_TMP/az" <<'EOF'
#!/usr/bin/env bash
echo "real az"
EOF
chmod +x "$INSTALL_TMP/az"

out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$UNINSTALL_SH" az 2>&1)
ec=$?
if [[ $ec -ne 0 ]]; then
  pass "uninstall.sh refuses non-Python (would delete real CLI)"
else
  fail "uninstall.sh removed non-Python binary" "exit was 0"
fi
[[ -f "$INSTALL_TMP/az" ]] && pass "non-Python preserved on refused uninstall" || fail "non-Python deleted"
rm -rf "$INSTALL_TMP" "$ENGINE_TMP"

echo ""
echo "── uninstall.sh refuses non-tool-guard Python ──"
INSTALL_TMP=$(mktemp -d)
ENGINE_TMP=$(mktemp -d)
cat > "$INSTALL_TMP/az" <<'EOF'
#!/usr/bin/env python3
"""custom az tool, not ours"""
EOF
chmod +x "$INSTALL_TMP/az"

out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$UNINSTALL_SH" az 2>&1)
ec=$?
if [[ $ec -ne 0 ]]; then
  pass "uninstall.sh refuses non-tool-guard Python"
else
  fail "uninstall.sh removed unrelated Python script"
fi
[[ -f "$INSTALL_TMP/az" ]] && pass "non-tool-guard Python preserved on uninstall" || fail "deleted"
rm -rf "$INSTALL_TMP" "$ENGINE_TMP"

# ─── Full uninstall (no args) removes engine + tg ──────────────────
echo ""
echo "── uninstall.sh (no args) removes engine + tg ──"
INSTALL_TMP=$(mktemp -d)
ENGINE_TMP=$(mktemp -d)
TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
  bash "$INSTALL_SH" az >/dev/null 2>&1
# Calling uninstall.sh with no args = uninstall ALL + remove engine
out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$UNINSTALL_SH" 2>&1)
ec=$?
assert_eq "uninstall (no args) → exit 0" "0" "$ec"
[[ -f "$ENGINE_TMP/tool_guard.py" ]] && fail "engine still present after full uninstall" || pass "engine removed by full uninstall"
[[ -f "$INSTALL_TMP/tg" ]] && fail "tg CLI still present after full uninstall" || pass "tg CLI removed by full uninstall"
[[ -f "$INSTALL_TMP/az" ]] && fail "az stub still present after full uninstall" || pass "az stub removed by full uninstall"
rm -rf "$INSTALL_TMP" "$ENGINE_TMP"

# ─── P1-D: tool-guard-install.sh bootstrap smoke test ──────────────
# The OSS bootstrap (scripts/tool-guard-install.sh in the parent repo)
# clones from github + execs tg install. Previously zero coverage —
# Scott P1-D. Test points TOOL_GUARD_REPO_URL at a local bare clone
# so we don't hit github at all, then verifies the bootstrap clones,
# invokes tg install, and propagates the exit code.
echo ""
echo "── tool-guard-install.sh bootstrap ──"
# The bootstrap script lives one level up from the package, in the
# parent repo's scripts/. May not exist when running in a standalone
# checkout of the OSS package — skip gracefully if so.
BOOTSTRAP_SH="$(cd "$PKG_ROOT/.." && pwd)/tool-guard-install.sh"
if [[ ! -f "$BOOTSTRAP_SH" ]]; then
  echo "  (skipped — bootstrap script not in this checkout: $BOOTSTRAP_SH)"
else
  # Build a fixture remote — copy the package into a fresh git repo so
  # we don't depend on PKG_ROOT being its own git repo (it isn't —
  # it's a subdirectory of KonsolidatorAI). Bare clone of that fresh
  # repo becomes our "remote".
  FIXTURE_WORKTREE=$(mktemp -d)
  cp -a "$PKG_ROOT"/. "$FIXTURE_WORKTREE/"
  ( cd "$FIXTURE_WORKTREE" && git init -q -b main && git add -A \
      && git -c user.email=test@example.com -c user.name=test commit -q -m "fixture" ) >/dev/null 2>&1
  BOOTSTRAP_REMOTE=$(mktemp -d)/tool-guard-fixture.git
  git clone --bare --quiet "$FIXTURE_WORKTREE" "$BOOTSTRAP_REMOTE" 2>&1 | grep -v "^$" || true
  BOOTSTRAP_CACHE=$(mktemp -d)/cache
  BOOTSTRAP_INSTALL=$(mktemp -d)
  BOOTSTRAP_ENGINE=$(mktemp -d)

  # Run the bootstrap. It will: ensure git ✓, clone our local fixture
  # to BOOTSTRAP_CACHE, exec tg install (which does pre-flight + calls
  # install.sh, which writes to BOOTSTRAP_INSTALL via TG_INSTALL_DIR).
  out=$(TOOL_GUARD_REPO_URL="$BOOTSTRAP_REMOTE" \
        TOOL_GUARD_CACHE_DIR="$BOOTSTRAP_CACHE" \
        TG_INSTALL_DIR="$BOOTSTRAP_INSTALL" \
        TG_ENGINE_DIR="$BOOTSTRAP_ENGINE" \
        bash "$BOOTSTRAP_SH" az 2>&1)
  ec=$?
  assert_eq "bootstrap exit code" "0" "$ec"
  [[ -d "$BOOTSTRAP_CACHE/.git" ]] && pass "bootstrap cloned to TOOL_GUARD_CACHE_DIR" || fail "bootstrap clone missing"
  [[ -x "$BOOTSTRAP_CACHE/tg" ]] && pass "cached package has tg" || fail "no tg in cache"
  [[ -x "$BOOTSTRAP_INSTALL/az" ]] && pass "bootstrap installed az to test sandbox" || fail "az not installed"
  [[ -f "$BOOTSTRAP_ENGINE/tool_guard.py" ]] && pass "bootstrap installed engine to test sandbox" || fail "engine not installed"

  # Re-run with --no-update: should NOT re-clone, but should re-install
  out=$(TOOL_GUARD_REPO_URL="$BOOTSTRAP_REMOTE" \
        TOOL_GUARD_CACHE_DIR="$BOOTSTRAP_CACHE" \
        TG_INSTALL_DIR="$BOOTSTRAP_INSTALL" \
        TG_ENGINE_DIR="$BOOTSTRAP_ENGINE" \
        bash "$BOOTSTRAP_SH" --no-update az 2>&1)
  ec=$?
  assert_eq "bootstrap --no-update exit code" "0" "$ec"
  assert_contains "bootstrap --no-update skips clone" "Using cached clone" "$out"

  # Bootstrap with corrupt cache (dir exists but no .git/) → clear error
  CORRUPT_CACHE=$(mktemp -d)
  out=$(TOOL_GUARD_REPO_URL="$BOOTSTRAP_REMOTE" \
        TOOL_GUARD_CACHE_DIR="$CORRUPT_CACHE" \
        TG_INSTALL_DIR="$BOOTSTRAP_INSTALL" \
        TG_ENGINE_DIR="$BOOTSTRAP_ENGINE" \
        bash "$BOOTSTRAP_SH" az 2>&1)
  ec=$?
  if [[ $ec -ne 0 ]]; then
    pass "bootstrap rejects corrupt cache (non-empty dir without .git)"
  else
    fail "bootstrap should reject corrupt cache" "exit was 0"
  fi
  assert_contains "corrupt-cache error mentions remediation" "rm -rf" "$out"

  rm -rf "$FIXTURE_WORKTREE" "$(dirname "$BOOTSTRAP_REMOTE")" \
         "$(dirname "$BOOTSTRAP_CACHE")" "$BOOTSTRAP_INSTALL" \
         "$BOOTSTRAP_ENGINE" "$CORRUPT_CACHE"
fi

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

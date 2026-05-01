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

  echo ""
  echo "── bootstrap supply-chain hardening (Dan P0+P1) ──"
  # Fixture: a tiny git repo with a known SHA we can pin to + verify
  FIXTURE2_WT=$(mktemp -d)
  cp -a "$PKG_ROOT"/. "$FIXTURE2_WT/"
  ( cd "$FIXTURE2_WT" && git init -q -b main && git add -A \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "fixture-v1" ) >/dev/null 2>&1
  FIXTURE2_SHA=$( cd "$FIXTURE2_WT" && git rev-parse HEAD )
  FIXTURE2_BARE=$(mktemp -d)/bare.git
  git clone --bare --quiet "$FIXTURE2_WT" "$FIXTURE2_BARE" 2>&1 | grep -v "^$" || true

  # Test: TOOL_GUARD_EXPECTED_SHA matches → install proceeds
  CACHE2=$(mktemp -d)/cache
  INSTALL2=$(mktemp -d); ENGINE2=$(mktemp -d)
  out=$(TOOL_GUARD_REPO_URL="$FIXTURE2_BARE" \
        TOOL_GUARD_CACHE_DIR="$CACHE2" \
        TOOL_GUARD_EXPECTED_SHA="$FIXTURE2_SHA" \
        TG_INSTALL_DIR="$INSTALL2" \
        TG_ENGINE_DIR="$ENGINE2" \
        bash "$BOOTSTRAP_SH" az 2>&1)
  ec=$?
  assert_eq "EXPECTED_SHA matches → install proceeds" "0" "$ec"
  assert_contains "EXPECTED_SHA verified message" "SHA + working-tree integrity verified" "$out"
  rm -rf "$(dirname "$CACHE2")" "$INSTALL2" "$ENGINE2"

  # Test: TOOL_GUARD_EXPECTED_SHA does NOT match → install refused
  CACHE3=$(mktemp -d)/cache
  INSTALL3=$(mktemp -d); ENGINE3=$(mktemp -d)
  out=$(TOOL_GUARD_REPO_URL="$FIXTURE2_BARE" \
        TOOL_GUARD_CACHE_DIR="$CACHE3" \
        TOOL_GUARD_EXPECTED_SHA="0000000000000000000000000000000000000000" \
        TG_INSTALL_DIR="$INSTALL3" \
        TG_ENGINE_DIR="$ENGINE3" \
        bash "$BOOTSTRAP_SH" az 2>&1)
  ec=$?
  if [[ $ec -ne 0 ]]; then
    pass "EXPECTED_SHA mismatch → install refused"
  else
    fail "EXPECTED_SHA mismatch should refuse" "exit was 0"
  fi
  assert_contains "SHA mismatch message" "SHA verification failed" "$out"
  # Most important: az should NOT have been installed
  [[ -x "$INSTALL3/az" ]] && fail "az installed despite SHA mismatch" || pass "az NOT installed on SHA mismatch"
  rm -rf "$(dirname "$CACHE3")" "$INSTALL3" "$ENGINE3"

  # Test: corrupt .git/ (exists but empty dir) is caught with clear msg
  CORRUPT2=$(mktemp -d)
  mkdir -p "$CORRUPT2/.git"  # exists but empty → not a real git repo
  out=$(TOOL_GUARD_REPO_URL="$FIXTURE2_BARE" \
        TOOL_GUARD_CACHE_DIR="$CORRUPT2" \
        TG_INSTALL_DIR=$(mktemp -d) \
        TG_ENGINE_DIR=$(mktemp -d) \
        bash "$BOOTSTRAP_SH" az 2>&1)
  ec=$?
  if [[ $ec -ne 0 ]]; then
    pass "partial-clone .git/ (empty dir) is caught"
  else
    fail "partial-clone .git/ should be caught" "exit was 0"
  fi
  assert_contains "partial-clone error has remediation hint" "rm -rf" "$out"
  rm -rf "$CORRUPT2" "$FIXTURE2_WT" "$(dirname "$FIXTURE2_BARE")"

  # ─── quinn round-2 P1+P2: working-tree integrity + REF validation ─
  echo ""
  echo "── bootstrap quinn round-2 hardening ──"

  # Build a fixture, clone, then tamper with a working-tree file
  # without changing HEAD. SHA check passes, working-tree check fails.
  FIXTURE_TAMPER_WT=$(mktemp -d)
  cp -a "$PKG_ROOT"/. "$FIXTURE_TAMPER_WT/"
  ( cd "$FIXTURE_TAMPER_WT" && git init -q -b main && git add -A \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "fixture-v2" ) >/dev/null 2>&1
  TAMPER_SHA=$( cd "$FIXTURE_TAMPER_WT" && git rev-parse HEAD )
  TAMPER_BARE=$(mktemp -d)/bare.git
  git clone --bare --quiet "$FIXTURE_TAMPER_WT" "$TAMPER_BARE" 2>&1 | grep -v "^$" || true

  # Clone, then modify a file post-clone (simulating attacker tampering)
  CACHE_TAMPER=$(mktemp -d)/cache
  git clone --quiet "$TAMPER_BARE" "$CACHE_TAMPER" 2>&1 | grep -v "^$" || true
  echo "TAMPERED" > "$CACHE_TAMPER/tg"  # post-clone modification

  out=$(TOOL_GUARD_REPO_URL="$TAMPER_BARE" \
        TOOL_GUARD_CACHE_DIR="$CACHE_TAMPER" \
        TOOL_GUARD_EXPECTED_SHA="$TAMPER_SHA" \
        TG_INSTALL_DIR=$(mktemp -d) \
        TG_ENGINE_DIR=$(mktemp -d) \
        bash "$BOOTSTRAP_SH" --no-update az 2>&1)
  ec=$?
  if [[ $ec -ne 0 ]]; then
    pass "working-tree tamper detected (SHA passes but diff fails)"
  else
    fail "tampered file not detected" "exit was 0"
  fi
  assert_contains "working-tree tamper error" "Working-tree integrity" "$out"
  rm -rf "$(dirname "$CACHE_TAMPER")" "$(dirname "$TAMPER_BARE")" "$FIXTURE_TAMPER_WT"

  # TOOL_GUARD_REF validation — reject option-injection attempts
  for bad_ref in '--orphan' '-x' 'main;rm' 'main\$(whoami)'; do
    out=$(TOOL_GUARD_REPO_URL="dummy" \
          TOOL_GUARD_CACHE_DIR=$(mktemp -d) \
          TG_INSTALL_DIR=$(mktemp -d) \
          TG_ENGINE_DIR=$(mktemp -d) \
          TOOL_GUARD_REF="$bad_ref" \
          bash "$BOOTSTRAP_SH" 2>&1)
    ec=$?
    if [[ $ec -ne 0 ]] && echo "$out" | grep -qF "invalid characters"; then
      pass "TOOL_GUARD_REF='$bad_ref' rejected"
    else
      fail "TOOL_GUARD_REF='$bad_ref' should be rejected" "ec=$ec"
    fi
  done
fi

# ─── publish.sh quinn round-2: glob in TG_PUBLISH_BRANCHES + force gate ─
echo ""
echo "── publish.sh quinn round-2 hardening ──"
PUBLISH_SH="$(cd "$PKG_ROOT/.." && pwd)/tool-guard-publish.sh"
if [[ -f "$PUBLISH_SH" ]]; then
  PUB_TMP2=$(mktemp -d)
  mkdir -p "$PUB_TMP2/scripts/tool-guard"
  cp "$PUBLISH_SH" "$PUB_TMP2/scripts/tool-guard-publish.sh"
  chmod +x "$PUB_TMP2/scripts/tool-guard-publish.sh"
  echo "test" > "$PUB_TMP2/scripts/tool-guard/file.txt"
  ( cd "$PUB_TMP2" && git init -q -b main \
    && git -c user.email=t@e.com -c user.name=t commit --allow-empty -q -m "init" \
    && git add -A && git -c user.email=t@e.com -c user.name=t commit -q -m "subtree" \
    && git remote add cctg "https://github.com/Cura-Simple-AI/Claude-Code-Tool-Guard.git" \
    && git checkout -q -b feature ) >/dev/null 2>&1

  # Glob characters in TG_PUBLISH_BRANCHES → rejected
  for bad in '*' 'feature*' 'main?'; do
    out=$(cd "$PUB_TMP2" && TG_PUBLISH_BRANCHES="$bad" bash "$PUB_TMP2/scripts/tool-guard-publish.sh" 2>&1)
    ec=$?
    if [[ $ec -ne 0 ]] && echo "$out" | grep -qF "glob characters"; then
      pass "TG_PUBLISH_BRANCHES='$bad' rejected (glob)"
    else
      fail "glob in TG_PUBLISH_BRANCHES not rejected" "ec=$ec out=$(echo "$out" | head -1)"
    fi
  done

  # TG_PUBLISH_FORCE without sentinel file → rejected
  # (file path is hardcoded; we test by setting TG_PUBLISH_FORCE without
  # /etc/tool-guard/publish-force-allowed existing — assumes test env
  # doesn't have the file)
  if [[ ! -f /etc/tool-guard/publish-force-allowed ]]; then
    out=$(cd "$PUB_TMP2" && TG_PUBLISH_FORCE=1 \
          TG_PUBLISH_BRANCHES="main" \
          bash "$PUB_TMP2/scripts/tool-guard-publish.sh" 2>&1)
    ec=$?
    if [[ $ec -ne 0 ]] && echo "$out" | grep -qF "publish-force-allowed"; then
      pass "TG_PUBLISH_FORCE=1 without sentinel file → rejected"
    else
      fail "TG_PUBLISH_FORCE without sentinel" "ec=$ec out=$(echo "$out" | head -2)"
    fi
  else
    echo "  (skipped — /etc/tool-guard/publish-force-allowed exists in test env)"
  fi

  rm -rf "$PUB_TMP2"
fi

# ─── Pre-install PATH check (Dan P1) ────────────────────────────────
echo ""
echo "── install.sh pre-install PATH check ──"
# When TG_INSTALL_DIR is unset, install.sh must verify PATH order
# BEFORE installing stubs. Hard to test with the real PATH in CI;
# verify the early-exit path by setting TG_INSTALL_DIR=/dev/null/x
# (a path guaranteed not to be in PATH). Without TG_INSTALL_DIR, we
# can also verify the post-install confirmation still works.
INSTALL_TMP=$(mktemp -d)
ENGINE_TMP=$(mktemp -d)
# With override → PATH check skipped, install succeeds even though
# the temp dir isn't on $PATH.
out=$(TG_INSTALL_DIR="$INSTALL_TMP" TG_ENGINE_DIR="$ENGINE_TMP" \
      bash "$INSTALL_SH" az 2>&1)
ec=$?
assert_eq "install with TG_INSTALL_DIR override skips PATH check" "0" "$ec"
[[ -x "$INSTALL_TMP/az" ]] && pass "stub installed under override (no PATH check)" || fail "stub missing"
rm -rf "$INSTALL_TMP" "$ENGINE_TMP"

# ─── publish.sh guards (Dan P0) ─────────────────────────────────────
echo ""
echo "── publish.sh wrong-branch + dirty-tree guards ──"
PUBLISH_SH="$(cd "$PKG_ROOT/.." && pwd)/tool-guard-publish.sh"
if [[ ! -f "$PUBLISH_SH" ]]; then
  echo "  (skipped — publish.sh not in this checkout)"
else
  # Build a fake git repo + copy publish.sh into it so REPO_ROOT
  # resolves to the sandbox (publish.sh cd's to its own parent dir).
  PUB_TMP=$(mktemp -d)
  mkdir -p "$PUB_TMP/scripts/tool-guard"
  cp "$PUBLISH_SH" "$PUB_TMP/scripts/tool-guard-publish.sh"
  chmod +x "$PUB_TMP/scripts/tool-guard-publish.sh"
  echo "test" > "$PUB_TMP/scripts/tool-guard/file.txt"
  ( cd "$PUB_TMP" && git init -q -b main \
    && git -c user.email=test@example.com -c user.name=test commit --allow-empty -q -m "init" \
    && git add -A \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "subtree content" \
    && git remote add cctg "https://github.com/Cura-Simple-AI/Claude-Code-Tool-Guard.git" \
    ) >/dev/null 2>&1
  PUB_SH_LOCAL="$PUB_TMP/scripts/tool-guard-publish.sh"

  # Test 1: wrong branch → refused
  ( cd "$PUB_TMP" && git checkout -q -b feature-wip ) >/dev/null 2>&1
  out=$(bash "$PUB_SH_LOCAL" 2>&1)
  ec=$?
  assert_eq "publish from non-main → exit 1" "1" "$ec"
  assert_contains "publish wrong-branch error" "Refusing to publish from branch" "$out"

  # Test 2: TG_PUBLISH_BRANCHES override → allowed
  echo "uncommitted" > "$PUB_TMP/scripts/tool-guard/uncommitted.txt"
  out=$(TG_PUBLISH_BRANCHES="feature-wip" bash "$PUB_SH_LOCAL" 2>&1)
  ec=$?
  # Should NOT fail on branch but WILL fail on dirty tree
  if echo "$out" | grep -qF "Refusing to publish from branch"; then
    fail "publish branch override didn't allow feature-wip" "$out"
  else
    pass "TG_PUBLISH_BRANCHES override allows non-main"
  fi

  # Test 3: dirty tree → refused (continues from above with uncommitted file)
  if [[ $ec -ne 0 ]] && echo "$out" | grep -qF "Uncommitted changes"; then
    pass "publish dirty-tree → refused"
  else
    fail "publish dirty-tree should refuse" "ec=$ec out=$(echo "$out" | head -3)"
  fi

  # Test 4: clean tree on allowed branch → guards pass (push fails on
  # fake remote URL, but guards shouldn't have fired)
  ( cd "$PUB_TMP" && git add -A \
    && git -c user.email=test@example.com -c user.name=test commit -q -m "commit uncommitted" ) >/dev/null 2>&1
  out=$(TG_PUBLISH_BRANCHES="feature-wip" bash "$PUB_SH_LOCAL" 2>&1)
  if echo "$out" | grep -qF "Refusing to publish from branch" \
     || echo "$out" | grep -qF "Uncommitted changes"; then
    fail "publish guards still firing after fix" "$out"
  else
    pass "publish guards pass when branch + tree are clean"
  fi
  rm -rf "$PUB_TMP"
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

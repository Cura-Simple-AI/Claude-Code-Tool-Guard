#!/usr/bin/env bash
# Smoke tests for the git tool-guard end-to-end against the real
# .tool-guard/git.config.json + .tool-guard/_defaults.json.
#
# All tests use AZ_TG_FAKE_CLAUDE to flip the claude_only branch
# explicitly (so tests work both inside Claude and outside).
#
# Run: bash scripts/tool-guard/_tests/git.smoke.test.sh

set -uo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GIT_WRAPPER="$PKG_ROOT/git/wrapper.py"
EXAMPLES_DIR="$PKG_ROOT/examples"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1${2:+ — $2}"; }

assert_classify() {
  local desc="$1" claude="$2" args="$3" expected="$4"
  local out
  # shellcheck disable=SC2086
  out=$(cd "$EXAMPLES_DIR" && TG_TEST_MODE=1 GIT_TG_DRYRUN=1 GIT_TG_FAKE_CLAUDE="$claude" \
        python3 "$GIT_WRAPPER" $args 2>&1) || true
  if echo "$out" | grep -q "classify=$expected"; then
    pass "$desc → $expected"
  else
    fail "$desc" "expected $expected, got: $(echo "$out" | head -1)"
  fi
}

echo ""
echo "════════════════════════════════════════════════════════════"
echo " git tool-guard — smoke tests against real shared config"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "── always-deny rules (regardless of claude_only) ──"
assert_classify "push origin main (no claude)"             "0" "push origin main"                  "deny"
assert_classify "push origin main (under claude)"          "1" "push origin main"                  "deny"
assert_classify "push origin master (no claude)"           "0" "push origin master"                "deny"
assert_classify "push --force origin main"                 "0" "push --force origin main"          "deny"
assert_classify "push --force origin master"               "0" "push --force origin master"        "deny"
# Newly caught by the tightened patterns:
assert_classify "push -u origin main"                      "0" "push -u origin main"               "deny"
assert_classify "push --set-upstream origin main"          "0" "push --set-upstream origin main"   "deny"
assert_classify "push origin main --force (suffix flag)"   "0" "push origin main --force"          "deny"
assert_classify "push origin main --no-verify"             "0" "push origin main --no-verify"      "deny"
assert_classify "push --force-with-lease origin main"      "0" "push --force-with-lease origin main" "deny"
assert_classify "push main (implicit origin)"              "0" "push main"                         "deny"

echo ""
echo "── false-positives that the OLD pattern denied (should now ALLOW) ──"
assert_classify "push origin main:hotfix (push main TO hotfix)" "0" "push origin main:hotfix-branch" "allow"
assert_classify "push origin main-feature (different branch)"   "0" "push origin main-feature"       "allow"
assert_classify "push origin main-staging"                       "0" "push origin main-staging"      "allow"
assert_classify "push origin main-integration"                   "0" "push origin main-integration"  "allow"
assert_classify "push origin master:topic"                       "0" "push origin master:topic"      "allow"

echo ""
echo "── claude_only warns: skipped when not under Claude ──"
assert_classify "force push some branch (no claude) → allow" "0" "push --force origin feat/x"  "allow"
assert_classify "no-verify commit (no claude) → allow"        "0" "commit --no-verify -m foo"   "allow"
assert_classify "reset --hard (no claude) → allow"            "0" "reset --hard HEAD"           "allow"
assert_classify "checkout -- (no claude) → allow"             "0" "checkout -- README.md"       "allow"

echo ""
echo "── claude_only warns: fire when under Claude ──"
assert_classify "force push some branch (under claude)"   "1" "push --force origin feat/x"  "warn"
assert_classify "no-verify commit (under claude)"          "1" "commit --no-verify -m foo"   "warn"
assert_classify "reset --hard (under claude)"              "1" "reset --hard HEAD"           "warn"
assert_classify "checkout -- (under claude)"               "1" "checkout -- README.md"       "warn"
assert_classify "checkout --theirs (under claude)"         "1" "checkout --theirs file.txt"  "warn"
assert_classify "merge -X theirs (under claude)"           "1" "merge -X theirs other"       "warn"
assert_classify "rebase -i (under claude)"                 "1" "rebase -i HEAD~3"            "warn"

echo ""
echo "── defaultMode=allow → most commands pass through ──"
assert_classify "git status"                          "0" "status"                    "allow"
assert_classify "git log"                             "0" "log --oneline -5"          "allow"
assert_classify "git fetch"                           "0" "fetch origin"              "allow"
assert_classify "git diff"                            "0" "diff HEAD~1"               "allow"
assert_classify "git push to feature branch"          "0" "push origin feat/x"        "allow"

echo ""
echo "── claude_only stays allow when not under Claude ──"
# Even under Claude, unrelated commands aren't warned
assert_classify "git status (under claude)"           "1" "status"                    "allow"
assert_classify "git log (under claude)"              "1" "log --oneline -5"          "allow"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  RESULT: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

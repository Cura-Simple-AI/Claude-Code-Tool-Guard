#!/usr/bin/env bash
# Smoke tests for the gh tool-guard end-to-end against the real
# .tool-guard/gh.config.json + .tool-guard/_defaults.json.
#
# Uses /bin/true as fake real gh so tests don't depend on GitHub CLI
# being installed. Real gh is only required for full integration
# testing (which we leave to the operator after install.sh).
#
# Coverage areas:
#   - deny rules: auth logout, repo delete, secret delete, ssh-key delete,
#     gpg-key delete, variable delete, release delete
#   - claude_only warns: pr merge, pr close, issue close, release create
#   - PR-body autoclose warns: Fix(es), Close(s), Resolve(s) + lowercase
#   - defaultMode=allow for benign reads
#
# Run: bash scripts/tool-guard/_tests/gh.smoke.test.sh

set -uo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GH_WRAPPER="$PKG_ROOT/gh/wrapper.py"
EXAMPLES_DIR="$PKG_ROOT/examples"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1${2:+ — $2}"; }

assert_classify() {
  local desc="$1" claude="$2" args="$3" expected="$4"
  local out
  # shellcheck disable=SC2086
  out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE="$claude" \
        python3 "$GH_WRAPPER" $args 2>&1) || true
  if echo "$out" | grep -q "classify=$expected"; then
    pass "$desc → $expected"
  else
    fail "$desc" "expected $expected, got: $(echo "$out" | head -1)"
  fi
}

# Variant that uses an explicit body string (handles quoting)
assert_body_classify() {
  local desc="$1" body="$2" expected="$3"
  local out
  out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE=0 \
        python3 "$GH_WRAPPER" pr create --title test --body "$body" 2>&1) || true
  if echo "$out" | grep -q "classify=$expected"; then
    pass "$desc → $expected"
  else
    fail "$desc" "expected $expected, got: $(echo "$out" | head -1)"
  fi
}

echo ""
echo "════════════════════════════════════════════════════════════"
echo " gh tool-guard — smoke tests against shipped policy"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "── deny rules: credential / resource destruction ──"
assert_classify "auth logout (no claude)"          "0" "auth logout"                          "deny"
assert_classify "auth logout (under claude)"       "1" "auth logout"                          "deny"
assert_classify "repo delete"                      "0" "repo delete owner/repo"               "deny"
assert_classify "repo delete --confirm"            "0" "repo delete owner/repo --confirm"     "deny"
assert_classify "secret delete (repo scope)"       "0" "secret delete TOKEN --repo a/b"       "deny"
assert_classify "secret delete (org scope)"        "0" "secret delete TOKEN --org a"          "deny"
assert_classify "variable delete"                  "0" "variable delete VAR --repo a/b"       "deny"
assert_classify "ssh-key delete"                   "0" "ssh-key delete 12345"                 "deny"
assert_classify "gpg-key delete"                   "0" "gpg-key delete 67890"                 "deny"
assert_classify "release delete"                   "0" "release delete v1.0 --repo a/b"      "deny"

echo ""
echo "── claude_only warns: skipped when not under Claude ──"
assert_classify "pr merge (no claude) → allow"     "0" "pr merge 123"                         "allow"
assert_classify "pr close (no claude) → allow"     "0" "pr close 456"                         "allow"
assert_classify "issue close (no claude) → allow"  "0" "issue close 789"                      "allow"
assert_classify "release create (no claude) → allow" "0" "release create v1.0"               "allow"

echo ""
echo "── claude_only warns: fire under Claude ──"
assert_classify "pr merge (under claude)"          "1" "pr merge 123"                         "warn"
assert_classify "pr merge --admin (under claude)"  "1" "pr merge 123 --admin"                 "warn"
assert_classify "pr close (under claude)"          "1" "pr close 456"                         "warn"
assert_classify "issue close (under claude)"       "1" "issue close 789"                      "warn"
assert_classify "release create (under claude)"    "1" "release create v1.0 --notes test"     "warn"

echo ""
echo "── PR-body autoclose: warn (always, not claude_only) ──"
assert_body_classify "body 'Fixes #1234'"          "Fixes #1234"                              "warn"
assert_body_classify "body 'Closes #99'"           "Closes #99"                               "warn"
assert_body_classify "body 'Resolves #5'"          "Resolves #5"                              "warn"
assert_body_classify "body 'Fix #1' (singular)"    "Fix #1"                                   "warn"
assert_body_classify "body 'Close #2' (singular)"  "Close #2"                                 "warn"
assert_body_classify "body 'Resolve #3' (singular)" "Resolve #3"                              "warn"
assert_body_classify "body 'fixes #1' (lowercase)" "fixes #1"                                 "warn"
assert_body_classify "body 'closes #2' (lowercase)" "closes #2"                               "warn"
assert_body_classify "body 'resolves #3' (lowercase)" "resolves #3"                           "warn"
assert_body_classify "body 'fix #4' (lowercase)"   "fix #4"                                   "warn"

echo ""
echo "── PR-body autoclose: alternate forms (--body=, -b shorthand, pr edit) ──"
# --body=value form (no space)
out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE=0 \
      python3 "$GH_WRAPPER" pr create --title test "--body=Fixes #1234" 2>&1) || true
if echo "$out" | grep -q 'classify=warn'; then pass "--body=value form caught"
else fail "--body=value not caught" "got: $(echo "$out" | head -1)"; fi

# -b shorthand
out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE=0 \
      python3 "$GH_WRAPPER" pr create --title test -b "Closes #5" 2>&1) || true
if echo "$out" | grep -q 'classify=warn'; then pass "-b shorthand caught"
else fail "-b shorthand not caught" "got: $(echo "$out" | head -1)"; fi

# pr edit (different verb)
out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE=0 \
      python3 "$GH_WRAPPER" pr edit 123 --body "Fixes #1" 2>&1) || true
if echo "$out" | grep -q 'classify=warn'; then pass "pr edit --body caught"
else fail "pr edit --body not caught"; fi

# pr edit with --body= form
out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE=0 \
      python3 "$GH_WRAPPER" pr edit 123 "--body=Fixes #1" 2>&1) || true
if echo "$out" | grep -q 'classify=warn'; then pass "pr edit --body= form caught"
else fail "pr edit --body= form not caught"; fi

echo ""
echo "── False-positive avoidance: issue body should NOT trigger autoclose check ──"
# issue create / edit / comment with same keywords — issues don't auto-close at PR-merge
out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE=0 \
      python3 "$GH_WRAPPER" issue create --title test --body "Fixes #1" 2>&1) || true
if echo "$out" | grep -q 'classify=allow'; then pass "issue create --body 'Fixes #N' allowed (no PR-merge auto-close on issue body)"
else fail "issue create false positive" "got: $(echo "$out" | head -1)"; fi

out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE=0 \
      python3 "$GH_WRAPPER" issue comment 1 --body "Closes #5" 2>&1) || true
if echo "$out" | grep -q 'classify=allow'; then pass "issue comment --body allowed (not a PR)"
else fail "issue comment false positive"; fi

echo ""
echo "── Trailing-wildcard collision avoidance ──"
# These hypothetical 'verb-suffix' commands shouldn't be denied
for cmd in "repo delete-tag foo" "secret delete-something" "auth logout-helper" "release delete-asset 1"; do
  out=$(cd "$EXAMPLES_DIR" && GH_TG_DRYRUN=1 GH_TG_FAKE_CLAUDE=0 \
        python3 "$GH_WRAPPER" $cmd 2>&1) || true
  if echo "$out" | grep -q 'classify=allow'; then pass "'$cmd' → allow (no false-positive deny)"
  else fail "'$cmd' false positive deny" "got: $(echo "$out" | head -1)"; fi
done

echo ""
echo "── PR-body NEUTRAL phrasing: should NOT warn ──"
assert_body_classify "body 'Part of #100'"         "Part of #100"                             "allow"
assert_body_classify "body 'Addresses #200'"       "Addresses #200"                           "allow"
assert_body_classify "body 'See #50'"              "See #50"                                  "allow"
assert_body_classify "body 'Discussed in #1'"      "Discussed in #1"                          "allow"
assert_body_classify "body without # at all"       "Implements the new feature"               "allow"

echo ""
echo "── defaultMode=allow for benign reads ──"
assert_classify "pr list"                          "0" "pr list"                              "allow"
assert_classify "pr view"                          "0" "pr view 123"                          "allow"
assert_classify "issue list"                       "0" "issue list --state open"              "allow"
assert_classify "issue create"                     "0" "issue create --title test"            "allow"
assert_classify "issue comment"                    "0" "issue comment 123 --body hi"          "allow"
assert_classify "auth status"                      "0" "auth status"                          "allow"
assert_classify "run list"                         "0" "run list"                             "allow"
assert_classify "run view"                         "0" "run view 12345"                       "allow"
assert_classify "repo view"                        "0" "repo view"                            "allow"
assert_classify "api repos/foo/bar/pulls"          "0" "api repos/foo/bar/pulls"              "allow"

echo ""
echo "── stub: fail-fast when tool_guard engine is missing ──"
# Force engine lookup to /nonexistent so the test isolates from any
# system-installed engine at /usr/local/lib/tool-guard/.
STUB_TMP=$(mktemp -d)
mkdir -p "$STUB_TMP/gh"
cp "$GH_WRAPPER" "$STUB_TMP/gh/wrapper.py"
out=$(cd "$STUB_TMP" && TOOL_GUARD_ENGINE_DIR=/nonexistent \
      GH_TG_REAL_BIN=/bin/echo \
      python3 gh/wrapper.py auth status 2>&1)
ec=$?
if [[ $ec -eq 127 ]]; then
  pass "missing engine → exit 127"
else
  fail "missing engine exit code" "expected 127, got $ec"
fi
if echo "$out" | grep -qF "tool_guard engine not found"; then
  pass "missing engine → clear error message"
else
  fail "missing engine error message"
fi
rm -rf "$STUB_TMP"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  RESULT: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

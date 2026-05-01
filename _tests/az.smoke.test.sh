#!/usr/bin/env bash
# Smoke tests for the az tool-guard end-to-end against the real
# .tool-guard/az.config.json + .tool-guard/_defaults.json.
#
# Uses /bin/true as fake real az so tests don't depend on Azure CLI
# being installed. Real az is only required for full integration testing
# (which we leave to the operator after install.sh).
#
# Run: bash scripts/tool-guard/_tests/az.smoke.test.sh

set -uo pipefail

# Resolve PKG_ROOT relative to this script (one level up from _tests/).
# Works both inside a parent repo (scripts/tool-guard/) and post-split
# as a standalone repo. Smoke tests run against examples/.tool-guard/
# which ships with the package, so they're portable across layouts.
PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AZ_WRAPPER="$PKG_ROOT/az/wrapper.py"
EXAMPLES_DIR="$PKG_ROOT/examples"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1${2:+ — $2}"; }

assert_classify() {
  local desc="$1" args="$2" expected="$3"
  local out
  # shellcheck disable=SC2086
  out=$(cd "$EXAMPLES_DIR" && AZ_TG_DRYRUN=1 AZ_TG_FAKE_CLAUDE=0 \
        python3 "$AZ_WRAPPER" $args 2>&1) || true
  if echo "$out" | grep -q "classify=$expected"; then
    pass "$desc → $expected"
  else
    fail "$desc" "expected classify=$expected, got: $(echo "$out" | head -1)"
  fi
}

echo ""
echo "════════════════════════════════════════════════════════════"
echo " az tool-guard — smoke tests against real shared config"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "── allow rules from az.config.json ──"
assert_classify "version (meta)"            "version"                                              "allow"
assert_classify "boards work-item show"     "boards work-item show --id 9758"                      "allow"
assert_classify "boards work-item create"   "boards work-item create --type Bug --title x"         "allow"
assert_classify "repos pr list"             "repos pr list --status active"                        "allow"
assert_classify "pipelines runs list"       "pipelines runs list --branch main"                    "allow"
assert_classify "ad signed-in-user show"    "ad signed-in-user show"                               "allow"
assert_classify "account get-access-token"  "account get-access-token --resource https://foo"      "allow"

echo ""
echo "── deny rules from az.config.json (per-tool) ──"
assert_classify "logout"                    "logout"                                               "deny"
assert_classify "account clear"             "account clear"                                        "deny"
assert_classify "account set"               "account set --subscription foo"                       "deny"
assert_classify "config set"                "config set extension.use_dynamic_install=yes"         "deny"
assert_classify "ad sp delete"              "ad sp delete --id 12345"                              "deny"
assert_classify "keyvault secret delete"    "keyvault secret delete --name foo --vault-name bar"   "deny"
assert_classify "keyvault secret purge"     "keyvault secret purge --name foo"                     "deny"
assert_classify "group delete"              "group delete --name myrg"                             "deny"
assert_classify "pipelines runs cancel"     "pipelines runs cancel --id 12345"                     "deny"

echo ""
echo "── deny rules from _defaults.json (cross-cutting) ──"
assert_classify "* delete *"                "resource delete --ids /subs/foo"                      "deny"
assert_classify "* purge *"                 "keyvault key purge --name foo"                        "deny"

echo ""
echo "── stub: fail-fast when tool_guard engine is missing ──"
# Copy stub to a tmp dir without the engine alongside it. Force the
# wrapper to look only at /nonexistent (TOOL_GUARD_ENGINE_DIR) so the
# test isolates from any system install at /usr/local/lib/tool-guard/.
# Stub should exit 127 with a clear error, NOT a Python traceback.
STUB_TMP=$(mktemp -d)
mkdir -p "$STUB_TMP/az"
cp "$AZ_WRAPPER" "$STUB_TMP/az/wrapper.py"
out=$(cd "$STUB_TMP" && TOOL_GUARD_ENGINE_DIR=/nonexistent \
      AZ_TG_REAL_BIN=/bin/echo \
      python3 az/wrapper.py version 2>&1)
ec=$?
if [[ $ec -eq 127 ]]; then
  pass "missing engine → exit 127"
else
  fail "missing engine exit code" "expected 127, got $ec"
fi
if echo "$out" | grep -qF "tool_guard engine not found"; then
  pass "missing engine → clear error message"
else
  fail "missing engine error message" "got: $(echo "$out" | head -1)"
fi
if echo "$out" | grep -qF "Traceback"; then
  fail "missing engine error contains Python traceback (UX regression)"
else
  pass "missing engine error has no Python traceback"
fi
rm -rf "$STUB_TMP"

echo ""
echo "── unmatched → defaultMode=prompt ──"
assert_classify "no rule matches"           "foo bar baz"                                          "prompt"
assert_classify "unknown verb"              "synapse workspace list"                               "prompt"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  RESULT: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

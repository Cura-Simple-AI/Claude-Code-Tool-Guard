#!/usr/bin/env bash
# Summarise az-tool-guard logs to find candidate deny-filter patterns.
#
# Reads /tmp/tool-guard/az_*.log (override with AZ_TG_LOG_DIR) and prints:
#   - Top 20 most-invoked sub-commands (first 2 args, e.g. "account show")
#   - Top 10 callers (parent_cmd basename)
#   - Total call count + time range
#   - Calls that exited non-zero (often signal of permission/auth issues)
#
# Usage: bash scripts/az-log-summary.sh [--days N]
# Defaults to all logs.

set -euo pipefail

LOG_DIR="${AZ_TG_LOG_DIR:-/tmp/tool-guard}"
LOG_GLOB="$LOG_DIR/az_*.log"

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq not installed. Install: sudo apt-get install -y jq" >&2
  exit 1
fi

if ! ls $LOG_GLOB >/dev/null 2>&1; then
  echo "No log files matching $LOG_GLOB. Either no calls have been made yet, or the tool-guard is not installed."
  exit 0
fi

LOGS="$LOG_GLOB"

echo "═══ az-tool-guard call summary ═══"
echo "Log dir: $LOG_DIR"
echo

TOTAL=$(cat $LOGS 2>/dev/null | wc -l)
echo "Total calls logged: $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
  echo "(empty logs)"
  exit 0
fi

FIRST=$(cat $LOGS | head -1 | jq -r '.ts' 2>/dev/null || echo "?")
LAST=$(cat $LOGS | tail -1 | jq -r '.ts' 2>/dev/null || echo "?")
echo "Time range: $FIRST → $LAST"
echo

echo "── Top 20 sub-commands (argv[0..1]) ──"
cat $LOGS | jq -r '.argv | .[0:2] | join(" ")' 2>/dev/null \
  | sort | uniq -c | sort -rn | head -20

echo
echo "── Top 10 callers (parent_cmd, first token) ──"
cat $LOGS | jq -r '.parent_cmd // "<unknown>" | split(" ")[0]' 2>/dev/null \
  | sort | uniq -c | sort -rn | head -10

echo
echo "── Failed calls (exit != 0) ──"
FAILED=$(cat $LOGS | jq -r 'select(.exit != 0) | "\(.ts)  exit=\(.exit)  \(.argv | join(" "))"' 2>/dev/null)
if [ -z "$FAILED" ]; then
  echo "(none)"
else
  echo "$FAILED" | tail -20
fi

echo
echo "── Slowest 10 calls (duration_ms) ──"
cat $LOGS | jq -r '"\(.duration_ms)\t\(.argv | join(" "))"' 2>/dev/null \
  | sort -rn | head -10

echo
echo "── Calls with redacted secrets (review these for policy decisions) ──"
SECRETS=$(cat $LOGS | jq -r 'select(.argv | tostring | contains("<redacted>")) | "\(.ts)  \(.argv | join(" "))"' 2>/dev/null)
if [ -z "$SECRETS" ]; then
  echo "(none)"
else
  echo "$SECRETS" | head -10
fi

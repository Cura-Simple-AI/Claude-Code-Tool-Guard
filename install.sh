#!/usr/bin/env bash
# Install the shared tool_guard engine + all per-tool tool-guard stubs into
# /usr/local/bin (stubs) and /usr/local/lib/tool-guard (engine).
#
# Convention: each subdirectory of scripts/tool-guard/ that contains a
# wrapper.py becomes an installed binary at /usr/local/bin/<dirname>.
# The shared engine scripts/tool-guard/tool_guard.py installs once to
# /usr/local/lib/tool-guard/tool_guard.py — every stub looks for it
# there first, then falls back to the source-relative location for
# dev/test runs.
#
#   scripts/tool-guard/tool_guard.py           → /usr/local/lib/tool-guard/tool_guard.py
#   scripts/tool-guard/az/wrapper.py           → /usr/local/bin/az
#   scripts/tool-guard/git/wrapper.py          → /usr/local/bin/git
#   scripts/tool-guard/sleep/wrapper.py        → /usr/local/bin/sleep
#
# Each tool-guard's policy config lives in <repo-root>/.tool-guard/<name>.config.json.
# Cross-cutting rules live in <repo-root>/.tool-guard/_defaults.json.
# Logs go to /tmp/tool-guard/<name>_YYYYMMDD.log (created on first call).
#
# Idempotent — re-running overwrites existing tool-guard + engine. Refuses
# to overwrite a binary that is not a Python tool-guard script (so we don't
# clobber a user-installed real CLI).
#
# Usage:
#   bash scripts/tool-guard/install.sh             # install engine + all tool-guards
#   bash scripts/tool-guard/install.sh az          # install engine + only the az tool-guard
#   bash scripts/tool-guard/install.sh az git      # install engine + named tool-guards
#
# Note: must be run by a human user (uses sudo for /usr/local/* writes).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# INSTALL_DIR + ENGINE_DIR can be overridden via env vars — useful for
# test harnesses that don't have sudo (e.g. CI) and for distros that
# prefer a different prefix. When the override resolves to a path
# already writable by the current user, we skip the `sudo` prefix.
INSTALL_DIR="${TG_INSTALL_DIR:-/usr/local/bin}"
ENGINE_DIR="${TG_ENGINE_DIR:-/usr/local/lib/tool-guard}"
ENGINE_SRC="$SCRIPT_DIR/tool_guard.py"
ENGINE_DST="$ENGINE_DIR/tool_guard.py"

# Decide whether to prefix install commands with sudo. If the install
# dir already exists and is writable, OR if the parent dir is writable,
# we skip sudo. Otherwise sudo is needed.
if [ -w "$INSTALL_DIR" ] || { [ ! -e "$INSTALL_DIR" ] && [ -w "$(dirname "$INSTALL_DIR")" ]; }; then
  SUDO=""
else
  SUDO="sudo"
fi

err()  { echo "❌ $*" >&2; exit 1; }
info() { echo "→  $*"; }
ok()   { echo "✅ $*"; }

[ -f "$ENGINE_SRC" ] || err "Engine not found at $ENGINE_SRC"

# Install the `tg` management CLI to /usr/local/bin/tg (always — it's not
# a per-tool tool-guard but a top-level utility that ships alongside the engine).
TG_SRC="$SCRIPT_DIR/tg"
TG_DST="$INSTALL_DIR/tg"

# Determine which tool-guard to install
if [ $# -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=()
  for d in "$SCRIPT_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    # Skip underscore-prefixed dirs (test fixtures, internal subdirs)
    case "$name" in _*) continue ;; esac
    [ -f "$d/wrapper.py" ] || continue
    TARGETS+=("$name")
  done
fi

[ "${#TARGETS[@]}" -gt 0 ] || err "No tool-guards found under $SCRIPT_DIR/*/wrapper.py"

# Install the engine first — every stub needs it.
info "Installing engine: $ENGINE_SRC → $ENGINE_DST"
$SUDO install -d -m 0755 "$ENGINE_DIR"
$SUDO install -m 0644 "$ENGINE_SRC" "$ENGINE_DST"
ok "engine → $ENGINE_DST"

# Install the tg CLI (always)
if [ -f "$TG_SRC" ]; then
  info "Installing tg CLI: $TG_SRC → $TG_DST"
  $SUDO install -m 0755 "$TG_SRC" "$TG_DST"
  ok "tg → $TG_DST"
else
  info "(tg CLI source not found at $TG_SRC — skipping)"
fi
echo

info "Installing tool-guards: ${TARGETS[*]}"
echo

for name in "${TARGETS[@]}"; do
  src="$SCRIPT_DIR/$name/wrapper.py"
  dst="$INSTALL_DIR/$name"

  [ -f "$src" ] || err "$name: source not found at $src"

  if [ -e "$dst" ]; then
    if head -1 "$dst" 2>/dev/null | grep -qE "^#!.*python"; then
      if grep -q "tool-guard" "$dst" 2>/dev/null; then
        info "$name: existing tool-guard at $dst — overwriting"
      else
        err "$name: $dst exists and is a Python script but does not look like a tool-guard. Inspect manually."
      fi
    else
      err "$name: $dst exists and is not a Python tool-guard script. Refusing to overwrite (would shadow real $name CLI). Inspect manually."
    fi
  fi

  $SUDO install -m 0755 "$src" "$dst"
  ok "$name → $dst"
done

# Verify PATH order: install dir must precede the real binary location.
# Skipped when TG_INSTALL_DIR override is set (typically a test sandbox
# that isn't on PATH and doesn't need to be).
if [ -z "${TG_INSTALL_DIR:-}" ]; then
  echo
  for name in "${TARGETS[@]}"; do
    resolved="$(command -v "$name" 2>/dev/null || true)"
    if [ "$resolved" = "$INSTALL_DIR/$name" ]; then
      ok "PATH OK: which $name → $resolved"
    else
      err "PATH check failed for $name: 'which $name' returns '$resolved' instead of $INSTALL_DIR/$name.
           Check your PATH order — $INSTALL_DIR must come before /usr/bin."
    fi
  done
fi

cat <<EOF

────────────────────────────────────────────────────────────
Engine installed: $ENGINE_DST
Tool-guards installed: ${TARGETS[*]}

Per-tool-guard details:
EOF

for name in "${TARGETS[@]}"; do
  cat <<EOF
  $name:
    Binary:      $INSTALL_DIR/$name
    Source:      $SCRIPT_DIR/$name/wrapper.py
    Policy:      <repo>/.tool-guard/${name}.config.json
    Local cfg:   <repo>/.tool-guard/${name}.config.local.json (gitignored)
    Logs:        /tmp/tool-guard/${name}_\$(date +%Y%m%d).log
    Tooling:     $SCRIPT_DIR/$name/

EOF
done

cat <<EOF
Cross-cutting rules: <repo>/.tool-guard/_defaults.json
Engine:              $ENGINE_DST
Uninstall:           bash $SCRIPT_DIR/uninstall.sh [name...]
See:                 $SCRIPT_DIR/README.md
────────────────────────────────────────────────────────────
EOF

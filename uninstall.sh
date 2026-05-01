#!/usr/bin/env bash
# Remove installed CLI tool-guard from /usr/local/bin and the shared
# tool_guard engine from /usr/local/lib/tool-guard.
#
# Refuses to remove a binary at /usr/local/bin/<name> that is not a
# Python tool-guard script — protects against accidentally deleting a real
# CLI that someone manually installed there.
#
# Usage:
#   bash scripts/tool-guard/uninstall.sh           # remove engine + all tool-guards
#   bash scripts/tool-guard/uninstall.sh az        # remove only the az tool-guard (engine stays)
#   bash scripts/tool-guard/uninstall.sh az git    # remove named tool-guards (engine stays)
#
# The engine is removed only when no targets are passed (full uninstall).
# Removing engine while tool-guards still exist would break them.
#
# Does NOT remove:
#   - Per-user policy overrides at .tool-guard/<tool>.config.local.json
#     — they're gitignored personal files; preserve them
#   - Log files (/tmp/tool-guard-logs/<name>/) — kept for forensic value;
#     /tmp is wiped by the OS anyway

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/bin"
ENGINE_DIR="/usr/local/lib/tool-guard"

err()  { echo "❌ $*" >&2; exit 1; }
info() { echo "→  $*"; }
ok()   { echo "✅ $*"; }

REMOVE_ENGINE=false
if [ $# -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=()
  for d in "$SCRIPT_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in _*) continue ;; esac
    [ -f "$d/wrapper.py" ] || continue
    TARGETS+=("$name")
  done
  REMOVE_ENGINE=true
fi

[ "${#TARGETS[@]}" -gt 0 ] || err "No tool-guards found to uninstall."

info "Uninstalling tool-guards: ${TARGETS[*]}"
echo

for name in "${TARGETS[@]}"; do
  dst="$INSTALL_DIR/$name"

  if [ ! -e "$dst" ]; then
    info "$name: nothing at $dst — already absent"
    continue
  fi

  if ! head -1 "$dst" 2>/dev/null | grep -qE "^#!.*python"; then
    err "$name: $dst is not a Python tool-guard script. Refusing to remove (could be the real $name CLI). Inspect manually."
  fi
  if ! grep -q "tool-guard" "$dst" 2>/dev/null; then
    err "$name: $dst is a Python script but does not look like our tool-guard. Refusing to remove. Inspect manually."
  fi

  sudo rm -f "$dst"
  ok "$name removed from $dst"
done

if $REMOVE_ENGINE && [ -d "$ENGINE_DIR" ]; then
  echo
  info "Removing engine: $ENGINE_DIR"
  sudo rm -rf "$ENGINE_DIR"
  ok "engine removed from $ENGINE_DIR"
fi

# Remove the tg CLI when doing a full uninstall
if $REMOVE_ENGINE; then
  TG_DST="$INSTALL_DIR/tg"
  if [ -f "$TG_DST" ]; then
    if head -1 "$TG_DST" 2>/dev/null | grep -qE "^#!.*python" \
       && grep -q "tool-guard" "$TG_DST" 2>/dev/null; then
      info "Removing tg CLI: $TG_DST"
      sudo rm -f "$TG_DST"
      ok "tg removed from $TG_DST"
    else
      info "Skipping $TG_DST — does not look like our tg CLI"
    fi
  fi
fi

cat <<EOF

────────────────────────────────────────────────────────────
Tool-guards uninstalled: ${TARGETS[*]}
$( $REMOVE_ENGINE && echo "Engine uninstalled:    $ENGINE_DIR" )

Preserved (manual cleanup if you want to wipe):
  Local configs: <repo>/.tool-guard/<name>.config.local.json (gitignored)
  Logs:          /tmp/tool-guard-logs/<name>/  (OS clears /tmp on reboot anyway)

Re-install: bash $SCRIPT_DIR/install.sh
────────────────────────────────────────────────────────────
EOF

#!/usr/bin/env bash
# Installs agent-status-hook and agent-bar into ~/.claude/bin and merges the
# hooks into ~/.claude/settings.json (backup: settings.json.bak). Safe to re-run.
#
#   install.sh [--hook-only] [--autostart] [--no-start]
#
# Binaries are taken from the script's directory (release tarball), or from
# ../build/bin (source checkout).
set -euo pipefail

HOOK_ONLY=0 AUTOSTART=0 START=1
for arg in "$@"; do
  case "$arg" in
    --hook-only) HOOK_ONLY=1 ;;
    --autostart) AUTOSTART=1 ;;
    --no-start) START=0 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC=""
for d in "$SCRIPT_DIR" "$SCRIPT_DIR/bin" "$SCRIPT_DIR/../build/bin"; do
  if [[ -x "$d/agent-status-hook" ]]; then SRC="$(cd "$d" && pwd)"; break; fi
done
[[ -n "$SRC" ]] || { echo "agent-status-hook not found next to install.sh or in build/bin; build first" >&2; exit 1; }

CLAUDE_DIR="$HOME/.claude"
BIN="$CLAUDE_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
mkdir -p "$BIN" "$CLAUDE_DIR/agent-status"

copy() { # atomic replace so a running hook/bar never sees a half-written binary
  install -m 755 "$SRC/$1" "$BIN/.$1.new"
  xattr -d com.apple.quarantine "$BIN/.$1.new" 2>/dev/null || true
  mv -f "$BIN/.$1.new" "$BIN/$1"
  echo "installed $BIN/$1"
}

copy agent-status-hook
install -m 755 "$SCRIPT_DIR/uninstall.sh" "$BIN/agent-bar-uninstall" 2>/dev/null ||
  install -m 755 "$SCRIPT_DIR/../scripts/uninstall.sh" "$BIN/agent-bar-uninstall" 2>/dev/null || true
if [[ $HOOK_ONLY -eq 0 ]]; then
  [[ -x "$SRC/agent-bar" ]] || { echo "agent-bar not found in $SRC (use --hook-only to skip)" >&2; exit 1; }
  copy agent-bar
fi

if [[ -f "$SETTINGS" ]]; then
  cp -p "$SETTINGS" "$SETTINGS.bak"
  echo "backup  $SETTINGS.bak"
fi
"$BIN/agent-status-hook" install-hooks --settings "$SETTINGS" --command "$BIN/agent-status-hook"

if [[ $HOOK_ONLY -eq 0 ]]; then
  if [[ $AUTOSTART -eq 1 ]]; then
    "$BIN/agent-bar" --autostart on
  fi
  if [[ $START -eq 1 ]]; then
    # Restart so an upgraded binary takes effect; single-instance lock handles the rest.
    pkill -xf "$BIN/agent-bar" 2>/dev/null && sleep 0.3 || true
    nohup "$BIN/agent-bar" >/dev/null 2>&1 &
    echo "started agent-bar"
  fi
fi

cat <<EOF

Done. Claude Code loads hooks when a session starts: restart open sessions
(including VS Code panels) for them to show up in agent-bar.
EOF

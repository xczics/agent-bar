#!/usr/bin/env bash
# Installed as ~/.claude/bin/agent-bar-uninstall.
# Removes our hooks from ~/.claude/settings.json (backup: settings.json.bak),
# stops agent-bar, removes its login item and the binaries.
#
#   uninstall.sh [--purge]    --purge also deletes ~/.claude/agent-status
set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

CLAUDE_DIR="$HOME/.claude"
BIN="$CLAUDE_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"

if [[ -f "$SETTINGS" && -x "$BIN/agent-status-hook" ]]; then
  cp -p "$SETTINGS" "$SETTINGS.bak"
  "$BIN/agent-status-hook" uninstall-hooks --settings "$SETTINGS"
elif [[ -f "$SETTINGS" ]]; then
  echo "warning: $BIN/agent-status-hook missing; remove the hooks from $SETTINGS by hand" >&2
fi

if [[ -x "$BIN/agent-bar" ]]; then "$BIN/agent-bar" --autostart off >/dev/null 2>&1 || true; fi
rm -f "$HOME/Library/LaunchAgents/dev.agentbar.agent-bar.plist"
pkill -xf "$BIN/agent-bar" 2>/dev/null || true   # only the installed instance
rm -f "$BIN/agent-status-hook" "$BIN/agent-bar" "$BIN/agent-bar-uninstall"
echo "removed binaries from $BIN"

if [[ $PURGE -eq 1 ]]; then
  rm -rf "$CLAUDE_DIR/agent-status"
  echo "removed $CLAUDE_DIR/agent-status"
fi

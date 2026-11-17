#!/usr/bin/env bash
# Removes the app, CLI link and LaunchAgent. Keeps the saved layout in
# ~/Library/Application Support/StageKeeper.
set -euo pipefail
LABEL="local.stagekeeper"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Quit normally first so the app puts the user's wallpaper back.
pgrep -x stagekeeper >/dev/null && osascript -e 'tell application id "local.stagekeeper" to quit' 2>/dev/null && sleep 1 || true
pkill -x stagekeeper 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/stagekeeper"
rm -rf "$HOME/Applications/StageKeeper.app" "$HOME/Applications/StageKeeper Stages"
tccutil reset Accessibility "$LABEL" 2>/dev/null || true
echo "Removed StageKeeper. Saved layout kept in ~/Library/Application Support/StageKeeper."

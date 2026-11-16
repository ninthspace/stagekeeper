#!/usr/bin/env bash
# Removes the app, CLI link and LaunchAgent. Keeps the saved layout in
# ~/Library/Application Support/StageKeeper.
set -euo pipefail
LABEL="local.stagekeeper"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x stagekeeper 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/stagekeeper"
rm -rf "$HOME/Applications/StageKeeper.app"
tccutil reset Accessibility "$LABEL" 2>/dev/null || true
echo "Removed StageKeeper. Saved layout kept in ~/Library/Application Support/StageKeeper."

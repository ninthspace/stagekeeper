#!/usr/bin/env bash
# Builds StageKeeper, installs it to ~/Applications, links the CLI into ~/.local/bin and
# registers a LaunchAgent that opens the menu-bar app at login (which restores the layout).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$HOME/Applications/StageKeeper.app"
AGENT="$HOME/Library/LaunchAgents/local.stagekeeper.plist"
LABEL="local.stagekeeper"

swift build -c release

pkill -x stagekeeper 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp .build/release/stagekeeper "$APP/Contents/MacOS/stagekeeper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad hoc signature unless SIGN_IDENTITY names a certificate. With an ad hoc signature every
# rebuild changes the code hash, so macOS asks for Accessibility permission again.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier "$LABEL" "$APP"

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/stagekeeper" "$HOME/.local/bin/stagekeeper"

mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

"$APP/Contents/MacOS/stagekeeper" skip-restore
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Installed $APP"
echo "CLI: $HOME/.local/bin/stagekeeper"
echo "If the menu bar shows 'Needs Accessibility', allow StageKeeper in System Settings › Privacy & Security › Accessibility."

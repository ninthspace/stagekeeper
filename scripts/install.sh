#!/usr/bin/env bash
# Builds StageKeeper, installs it to ~/Applications, links the CLI into ~/.local/bin and
# registers a LaunchAgent that opens the menu-bar app at login (which restores the layout).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$HOME/Applications/StageKeeper.app"
AGENT="$HOME/Library/LaunchAgents/local.stagekeeper.plist"
LABEL="local.stagekeeper"

swift build -c release

# Quit normally first so the app puts the user's wallpaper back.
pgrep -x stagekeeper >/dev/null && osascript -e 'tell application id "local.stagekeeper" to quit' 2>/dev/null && sleep 1 || true
pkill -x stagekeeper 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp .build/release/stagekeeper "$APP/Contents/MacOS/stagekeeper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Record what was built and from where, for `stagekeeper update` and Check for Updates.
PLIST="$APP/Contents/Info.plist"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
# plutil, not PlistBuddy, which splits a value containing spaces. Before codesign: the signature covers it.
plutil -replace CFBundleShortVersionString -string "${VERSION#v}" "$PLIST"
plutil -replace StageKeeperCommit -string "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "$PLIST"
plutil -replace StageKeeperSourcePath -string "$PWD" "$PLIST"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with SIGN_IDENTITY, else the certificate from make-signing-cert.sh, else ad hoc.
# A certificate keeps the Accessibility permission across reinstalls. With an ad hoc
# signature every rebuild changes the code hash, so macOS asks for the permission again.
LOCAL_CERT="StageKeeper Local Signing"
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "$LOCAL_CERT" >/dev/null 2>&1; then
    SIGN_IDENTITY="$LOCAL_CERT"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier "$LABEL" "$APP"
# Register the stagekeeper:// URL scheme that the Dock apps open.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

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

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Installed $APP"
echo "CLI: $HOME/.local/bin/stagekeeper"
echo "If the menu bar shows 'Needs Accessibility', allow StageKeeper in System Settings › Privacy & Security › Device Control and Data Access (called Accessibility before macOS 27)."

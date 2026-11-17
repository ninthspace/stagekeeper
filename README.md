# StageKeeper

Saves your Stage Manager stages and rebuilds them when you log in. Each stage can have a label and a colour. The menu bar shows the current stage's colour and label, the desktop takes the stage's colour, and labelled stages get keyboard shortcuts and Dock apps that switch to them.

macOS does not save Stage Manager groupings across a restart and has no API for setting them. StageKeeper reads the stages from Stage Manager's accessibility tree and rebuilds them by clicking and shift-clicking the strip thumbnails.

## Install

```bash
./scripts/install.sh
```

This builds the tool and installs:

- `~/Applications/StageKeeper.app`: the menu-bar app.
- `~/.local/bin/stagekeeper`: the command-line tool, a link to the binary inside the app.
- `~/Library/LaunchAgents/local.stagekeeper.plist`: opens the app at login.

When the menu-bar item says "Needs Accessibility", allow StageKeeper in System Settings › Privacy & Security › Device Control and Data Access (called Accessibility before macOS 27). Without a certificate the install is signed ad hoc, so each reinstall changes the code hash and macOS asks again: remove the old entry and add the app again. To keep the permission across reinstalls, run `./scripts/make-signing-cert.sh` once. It creates a self-signed certificate, "StageKeeper Local Signing", in your login keychain, and `install.sh` signs with it from then on. To use a different certificate, set `SIGN_IDENTITY`.

To remove it, run `./scripts/uninstall.sh`. The saved layout is kept.

## Use

1. Arrange your stages.
2. From the menu-bar item, choose **Save Layout**.
3. Optionally, switch to a stage and choose **Label Current Stage…**. Labelling also saves the layout.

At login the app waits 10 seconds, opens any saved app that is not running, waits up to 90 seconds for the saved windows to appear, then rebuilds the stages. It restores once per boot, so quitting and reopening the app does not rearrange your windows. **Restore Layout** in the menu runs a restore at any time.

The menu lists every stage by its label (or by its apps when it has no label). Choose one to switch to it.

### Colours

Switch to a stage and choose a colour from **Colour Current Stage**. While that stage is current:

- the menu bar shows a dot in that colour before the label (a stage with no label shows its app names);
- every screen's wallpaper is that colour.

On a stage with no colour, and when StageKeeper quits, your own wallpaper comes back. StageKeeper records it the first time it sets a colour; if you change your wallpaper while on a stage with no colour, it records the new one.

### Keyboard shortcuts

Labelled stages get ⌃⌥1 to ⌃⌥9, in alphabetical order of label. The menu shows each stage's shortcut. Adding, removing or renaming a label can change the numbers. A shortcut does nothing when its stage has no open windows. macOS has no shortcuts of its own for switching to a particular stage.

### Dock apps

Each labelled stage has a small app in `~/Applications/StageKeeper Stages`, named after the label, with an icon in the stage's colour. Drag one to the Dock; clicking it switches to that stage. **Show Dock Apps** opens the folder.

Each app finds its stage by an ID, not by the label. Renaming a stage renames its app in the same place, so a Dock item for it keeps working. Removing a label deletes the app.

### Command line

The command-line tool needs Accessibility permission for the terminal that runs it.

```
stagekeeper save                Save every stage (labels are kept).
stagekeeper restore [--wait N]  Open saved apps and rebuild the stages.
stagekeeper list                Show the current stages and their labels.
stagekeeper label "<name>"      Label the current stage ("" removes the label).
stagekeeper colour <colour>     Colour the current stage: a palette name, #RRGGBB, or none.
stagekeeper switch <label|n>    Switch to a labelled stage by label or shortcut number.
stagekeeper agent               Run the menu-bar item.
```

## Files

- Layout: `~/Library/Application Support/StageKeeper/layout.json`. The previous save is in `layout.previous.json`.
- Agent state (the boot it last restored, and your own wallpaper for each screen): `state.json` in the same folder.
- Colour wallpapers: `Wallpapers/` in the same folder.
- Dock apps: `~/Applications/StageKeeper Stages`. `uninstall.sh` removes them.
- Log: `~/Library/Logs/StageKeeper.log`.

The app icon's source is `Resources/AppIcon.svg`. After changing it, run `swift scripts/make-icon.swift` to rebuild `Resources/AppIcon.icns`.

## How it works

**Reading stages.** Each thumbnail in the Stage Manager strip is an accessibility button with an `AXWindowsIDs` attribute that lists the window IDs in that stage. The current stage is the set of on-screen standard windows that are not in the strip. The strip shows only a limited number of stages, so a window in neither place is an overflow window. Its grouping cannot be read, so it is saved as a stage of its own, one stage per app. Window titles, positions and sizes come from each app's accessibility windows. The private `_AXUIElementGetWindow` call maps each accessibility window to its window ID.

**Matching windows after a restart.** Window IDs change on every boot, so each saved window is matched to a live one in three passes:

1. The same window ID, only within the boot it was saved in.
2. The same app and the same title.
3. The same app and any window not yet matched.

Each live window is used at most once.

**Rebuilding.** Stages are built in reverse saved order, so the strip ends in its saved order and the saved current stage ends current. For each stage:

1. Click the thumbnail of the stage that holds its first window.
2. Shift-click the thumbnail of each further window to add it.
3. Set each window's saved position and size.

Before each click the pointer touches the left screen edge so the strip shows, and afterwards it returns to where it was. A window beyond the strip is brought forward by activating its app, and the stage being built is then shift-clicked back in.

Stage Manager on macOS 27 also offers `AXPress` and `AXAddToStage` actions on the thumbnails. It reports them as successful but does not act on them, which is why StageKeeper clicks.

## Limits

- Stage Manager cannot split a stage. If two saved stages' windows are already grouped together when you restore, they stay together, and the restore message names the window to drag to the strip. After a restart this does not happen, because apps open into separate stages.
- Matching by title fails when a window opens with a different title, for example a browser window with a different active tab. Pass 3 then matches the app's windows in screen order, which can swap two windows of the same app between stages.
- A window that its app does not reopen at login cannot be restored. The restore message lists these windows.
- The pointer moves during a restore. Leave the mouse alone until the menu-bar item stops showing "Restoring…".
- Only the main display has been tested.

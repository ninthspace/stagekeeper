# StageKeeper

Window stages for macOS, kept by StageKeeper itself. A stage is a group of windows; one stage shows at a time and the others are put out of the way. Stages can have a label and a colour. The menu bar shows the current stage, the desktop takes its colour, and labelled stages get keyboard shortcuts and Dock apps that switch to them. A round menu, opened with a four-finger click or tap, switches stages, moves and tiles windows.

StageKeeper needs Stage Manager turned off (System Settings › Desktop & Dock › Stage Manager). While Stage Manager is on, it puts its hidden windows back on screen, shows "Stage Manager is on" in the menu bar, and does nothing else until Stage Manager is turned off.

## Install

```bash
./scripts/install.sh
```

This builds the tool and installs:

- `~/Applications/StageKeeper.app`: the menu-bar app.
- `~/.local/bin/stagekeeper`: the command-line tool, a link to the binary inside the app.
- `~/Library/LaunchAgents/local.stagekeeper.plist`: opens the app at login.

When the menu-bar item says "Needs Accessibility", allow StageKeeper in System Settings › Privacy & Security › Device Control and Data Access (called Accessibility before macOS 27). Without a certificate the install is signed ad hoc, so each reinstall changes the code hash and macOS asks again: remove the old entry and add the app again. To keep the permission across reinstalls, run `./scripts/make-signing-cert.sh` once. It creates a self-signed certificate, "StageKeeper Local Signing", in your login keychain, and `install.sh` signs with it from then on. To use a different certificate, set `SIGN_IDENTITY`. If an ad hoc build was allowed before, its entry stays switched on but no longer applies to the signed app, and switching it off and on again does not help. Run `tccutil reset Accessibility local.stagekeeper` once, then reopen StageKeeper and allow it again.

Reinstalling restarts the app: it puts every hidden window back on screen, then hides the other stages' windows again.

To remove it, run `./scripts/uninstall.sh`. The saved layouts are kept.

## Stages

- **Switching** moves the current stage's windows into the bottom-right corner of the rightmost screen, with one point showing, and moves the new stage's windows back to where they were. Switch with the radial menu, the menu-bar menu, All stages, the shortcuts or the Dock apps.
- **New windows** join the current stage within about half a second. A new tab of an app with native tabs (Ghostty, Finder) joins its tab group's stage. A new window that opens mostly off screen (apps place a new window by their last one, which may be hidden) is moved to the middle of the screen.
- **Bringing a hidden window forward** yourself (⌘Tab, the Dock, an app's Window menu, Mission Control) switches to its stage.
- **Moving a window** to another stage, or to a new stage of its own: Move in the radial menu, or **Move Front Window To** in the menu-bar menu. Background tabs of the window go with it.
- **Closing** every window of a labelled stage keeps the label as a stage with no open windows. Move a window into it to use it again, or choose it in the menu-bar menu to forget it, which removes its label, colour, shortcut and Dock app.
- Every two seconds StageKeeper checks that the screen matches the stages, and hides or shows any window that is out of step: after a display is connected or removed, an app that did not answer during a switch, or the first visit to a desktop.
- When StageKeeper quits, or Stage Manager is turned on, hidden windows are put back on screen. `stagekeeper reveal` does the same by hand.

### Saving and restarting

**Save Layout** saves the stages of the desktop you are on, with their labels and colours. Labelling or colouring a stage also saves. Within one boot the stages are kept as they are; the save is for after a restart.

After a restart StageKeeper rebuilds each desktop's stages from its last save the first time it reads that desktop, matching windows by app and title. Windows that appear later join the current stage.

**Restore Layout** (or `stagekeeper restore`) rebuilds this desktop's stages from its last save: it opens saved apps that are not running, waits up to 90 seconds for their windows, matches them to the saved ones by app and title, and puts each window back in its saved stage at its saved position and size. Windows not in the save stay together in the stages they were in.

## Radial menu

Click or tap the trackpad with four fingers to open a round menu at the pointer. It does not take focus, so the app you were using stays in front. Tile, Bookmark and Move act on the window of the current stage that was under the pointer when the menu opened, or on the front window when the pointer was not over one. Esc, a click outside, or another four-finger click or tap closes it.

- **Inner ring:** this desktop's stages (up to eight), most recently used first. A labelled stage shows its label on a tile in its colour; a stage without a label shows its position in the ring, and the box under the menu names its apps. The current stage is outlined in white. Click one to switch to it. Hold ⌥ to move the window instead.
- **Windows:** rest the pointer on a stage for a moment and the outer ring shows that stage's windows in place of the actions (up to eight), each with its app's icon and title. They stay while the pointer crosses other stages or the centre on its way to one. Click a window to switch to its stage and bring it to the front.
- **Outer ring**, clockwise from the top: Tile, Bookmark, Fetch Bookmarked Windows, other desktops' stages, Move, Colour, Label, Save. Other desktops and Colour replace the inner ring with their choices; the centre then goes back.
- **Move:** every stage you can move the window to appears in arcs of eight across the bottom half of the menu, outside the actions ring: New stage first, then the other stages by recent use, then labelled stages with no open windows (greyed). Each further eight adds an arc further out, up to 24 stages. The box naming what you point at moves above the menu.
- **Tile:** pointing at Tile opens an arc across the top half with nine positions for the window: halves, quarters and Maximise. The arc stays open while you cross the outer ring towards it, and closes when you move back into the inner ring.
- **Centre:** opens All stages.

macOS has no public way to count the fingers on a trackpad, so StageKeeper reads them through the private MultitouchSupport framework, as BetterTouchTool does, and takes the four-finger click out of the event stream so the app under the pointer does not see it. macOS sends no event for a tap of more than two fingers, so StageKeeper recognises a tap itself: four fingers down and lifted within 0.3 seconds without moving.

## All stages

A four-finger swipe down, or the centre of the radial menu, shows every stage on this desktop as a small screen with its windows drawn as boxes at their position and size, each with its app's icon and title, most recently used first. Click one to switch to it; swipe down again or press Esc to close it. The swipe works only while App Exposé is not set to a four-finger swipe down in System Settings › Trackpad › More Gestures.

Mission Control shows hidden windows too, small, because they sit in the screen's corner. Turning on System Settings › Desktop & Dock › Mission Control › "Group windows by application" lays them out larger.

## Bookmarked windows

**Bookmark <App> Window** bookmarks the window you are working in. **Fetch Bookmarked Windows** (⌃⌥0, available while a window is bookmarked) moves bookmarked windows from other stages into the stage you are in. **Bookmarked Windows** lists the bookmarks; choose one to remove it. A closed window loses its bookmark, and bookmarks are matched by app and window title after a restart. Bookmarked windows stay on their own desktop.

## Desktops

Each desktop has its own stages and its own saved layout.

- **Save Layout** saves the desktop you are on and leaves the others alone.
- The menu lists the stages of the desktop you are on, then the labelled stages of your other desktops under "Desktop 2" and so on.
- Shortcuts and Dock apps work for stages on any desktop. For a stage on another desktop, StageKeeper presses that desktop's "Switch to Desktop N" shortcut when you have turned it on (System Settings › Keyboard › Keyboard Shortcuts › Mission Control), and otherwise ⌃← or ⌃→ until that desktop shows.
- With a separate desktop per display, StageKeeper manages the windows of the desktop that is active.

## Colours

Switch to a stage and choose a colour from **Colour Current Stage**, or Colour in the radial menu. While that stage is current:

- the menu bar shows a dot in that colour before the label (a stage with no label shows its app names);
- every screen's wallpaper is a darker, quieter version of that colour.

On a stage with no colour, and when StageKeeper quits, your own wallpaper comes back. StageKeeper records it the first time it sets a colour, per screen and desktop.

## Keyboard shortcuts

By default, labelled stages get ⌃⌥1 to ⌃⌥9: desktop 1's labelled stages first, in alphabetical order of label, then desktop 2's, and so on. The menu shows each stage's shortcut. Adding, removing or renaming a label can change these numbers; a shortcut chosen in Settings does not change. A shortcut does nothing when its stage has no open windows.

## Settings

**Settings…** (⌘, while the menu is open) opens a window with three tabs:

- **Stages:** every labelled stage on every desktop. Click a label to rename it (a label another stage has is refused). Set its colour from the palette or with any colour, and record its shortcut: click the shortcut, then press a key with ⌃, ⌥ or ⌘ (a function key works on its own; Esc cancels). The menu beside it sets the stage back to Automatic (the next free ⌃⌥1–9) or to no shortcut.
- **Palette:** rename, recolour, add and remove the colours offered for stages. Restore Defaults puts back the ten built-in colours. Changing a palette colour does not recolour stages that already use it.
- **Shortcuts:** the shortcut for Fetch Bookmarked Windows (⌃⌥0 by default), or none.

`open stagekeeper://settings` also opens the window.

## Dock apps

Each labelled stage has a small app in `~/Applications/StageKeeper Stages`, named after the label, with an icon in the stage's colour. Drag one to the Dock; clicking it switches to that stage. **Show Dock Apps** opens the folder. Each app finds its stage by an ID, so renaming a stage keeps its Dock item working. Removing a label deletes the app.

## Command line

The command-line tool needs Accessibility permission for the terminal that runs it.

```
stagekeeper save                Save every stage on this desktop (labels are kept).
stagekeeper list                Show this desktop's stages and their labels.
stagekeeper label "<name>"      Label the current stage ("" removes the label).
stagekeeper colour <colour>     Colour the current stage: a palette name, #RRGGBB, or none.
stagekeeper switch <label|n>    Switch to a labelled stage by label or shortcut number.
stagekeeper reveal              Put every hidden window back on screen.
stagekeeper restore [--wait N]  Open saved apps and rebuild this desktop's stages from the save.
stagekeeper agent               Run the menu-bar item.
```

## Files

All in `~/Library/Application Support/StageKeeper/` unless noted:

- `Desktops/`: the saved layout of each desktop, named after the desktop's ID (`main.json` for the first), with the previous save in `<name>.previous.json`.
- `engine.json`: StageKeeper's stages: each desktop's stages, the current one, and the frames of hidden windows. Thrown away after a restart, when the stages are rebuilt from the saved layouts. A file that cannot be read is kept as `engine.unreadable.json`.
- `settings.json`: palette and shortcuts.
- `state.json`: bookmarks and your own wallpaper for each screen and desktop.
- `Wallpapers/`: the colour wallpapers.
- `~/Applications/StageKeeper Stages`: the Dock apps. `uninstall.sh` removes them.
- `~/Library/Logs/StageKeeper.log`: the log.

The app icon's source is `Resources/AppIcon.svg`. After changing it, run `swift scripts/make-icon.swift` to rebuild `Resources/AppIcon.icns`.

## How it works

**Windows.** Window titles, positions and sizes come from each app's accessibility windows; the private `_AXUIElementGetWindow` call maps each one to its window ID. Only windows on the active desktop count (`SLSCopySpacesForWindows`). A window leaves its stage only when the window server no longer has it, so an app that briefly lists no windows, as after waking from sleep, does not lose its stages.

**Hiding.** macOS has no public way to hide one window, so a hidden window is moved to the bottom-right corner of the rightmost screen, and its frame is recorded so it can go back. Switching plans the moves under a lock and carries them out after, so a slow app does not hold up the menu.

**Following focus.** When the focused window belongs to another stage, StageKeeper switches to that stage, except for 1.5 seconds after it has switched or moved windows itself.

**Labels.** Each stage records which saved stage it is, so a label stays with its stage when windows move between stages.

## Limits

- Restore matches windows by app and title. A window that opens with a different title, such as a browser window with a different active tab, may land in the wrong stage.
- StageKeeper does not open apps at login; Restore Layout does.
- Hidden windows sit in a corner of the screen, so they show in Mission Control and can be found by apps that list windows.
- Only one display arrangement at a time has been tested.

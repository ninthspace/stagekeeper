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

The menu lists every stage by its label (or by its apps when it has no label). Choose one to switch to it. A labelled stage none of whose windows are open on this desktop (they were closed, or moved to another desktop) is listed as "(no open windows)"; choose it to forget the stage, which removes its label, colour, shortcut and Dock app. If its windows come back into one stage, the label matches them again without forgetting.

### Moving a window to another stage

**Move Front Window To** moves the front window of the current stage into another stage on this desktop. It also lists labelled stages with no open windows. Stage Manager has no empty stages, so this works only for a window that is alone in its stage: the stage takes the label, colour and shortcut. Stage Manager gives StageKeeper no way to split a window off into a new stage: the strip hides while a dragged window covers it, even with the pointer held at the left edge, and a minimised window rejoins the current stage when it is restored. StageKeeper switches to that stage, then drags the window's preview out of the strip into it, as you would by hand, and puts the window back at its original position and size. The window list gives each thumbnail's previews in the same order as Stage Manager lists the stage's windows, so the window's preview is the one at its position. As a check, a wider window must have a wider preview; if that fails, StageKeeper does not drag and says so.

Your windows move aside for about a second while it works (see How it works).

### Windows that show on every stage

Some windows, such as Outlook's reminders, stay on screen whichever stage is showing. Once StageKeeper has seen a window in three different stages it treats it as showing everywhere: it is not saved with a stage, does not count when matching labels, and is never taken as the front window. Until then, such a window can make a stage take the label of the stage it was saved with.

### Radial menu

Click or tap the trackpad with four fingers to open a round menu at the pointer. It does not take focus, so the app you were using stays in front. Tile, Bookmark and Move act on the window of the current stage that was under the pointer when the menu opened, or on the front window when the pointer was not over one. Esc, a click outside, another four-finger click or tap, or the centre closes it.

- **Inner ring:** this desktop's stages (up to eight), most recently used first. A labelled stage shows its label under a dot of its colour; a stage without a label shows its position in the ring, and the box under the menu names its apps. The current stage is outlined in white. Click one to switch to it. Hold ⌥ while clicking to move the front window there instead.
- **Windows:** rest the pointer on a stage for a moment and the outer ring shows that stage's windows in place of the actions (up to eight), the first next to the stage, each with its app's icon and its title under it. The windows stay while the pointer crosses other stages or the centre on its way to one; resting on another stage shows its windows, and resting on or clicking the centre brings the actions back. Click a window to switch to its stage and bring it to the front. Use this rather than Mission Control to reach a window hidden behind others: picking a window in Mission Control takes it out of its stage.
- **Outer ring**, clockwise from the top: Tile, Bookmark, Fetch Bookmarked Windows, other desktops' stages, Move, Colour, Label, Save. Other desktops, Move and Colour replace the inner ring with their choices; the centre then goes back.
- **Move:** the inner ring lists stages most recently used first, then labelled stages with no open windows (up to four), which keep their slots however many stages there are.
- **Tile:** pointing at Tile opens an arc outside the menu with nine positions for the window: halves, quarters and Maximise. The arc stays open while you cross the outer ring towards it, and closes when you move back into the inner ring. The window fills that part of the screen, using its full width; Stage Manager then hides the strip until you move the pointer to the left edge.
- The box under the menu names what you are pointing at.

macOS has no public way to count the fingers on a trackpad, so StageKeeper reads them through the private MultitouchSupport framework, as BetterTouchTool does, and takes the four-finger click out of the event stream so the app under the pointer does not see it. macOS sends no event for a tap of more than two fingers, so StageKeeper recognises a tap itself: four fingers down and lifted within 0.3 seconds without moving. A four-finger swipe moves the fingers, so it does not count as a tap.

### Bookmarked windows

**Bookmark <App> Window** bookmarks the window you are working in. **Fetch Bookmarked Windows** (⌃⌥0, available while a window is bookmarked) brings bookmarked windows from other stages into the stage you are in: for each one, StageKeeper goes to the stage holding it, brings it to the front, switches back, then drags its preview out of the strip into your stage and puts it back at its position and size. **Bookmarked Windows** lists the bookmarks; choose one to remove it. A bookmarked window that is closed loses its bookmark, and bookmarks are matched by app and window title after a restart. Bookmarked windows stay on their own desktop.

Switching stage does not bring bookmarked windows on its own; only ⌃⌥0 does. Each drag of a window preview out of the strip can take the whole stage instead of one window, which merges two stages, and doing that on every switch merged stages in use. If a drag brings other windows along, StageKeeper stops fetching and logs which windows joined.

### Desktops

Stage Manager keeps separate stages on each desktop, and only shows the stages of the desktop you are on. StageKeeper keeps one saved layout per desktop:

- **Save Layout** saves the stages of the desktop you are on and leaves the other desktops' layouts alone.
- At login StageKeeper restores the desktop that is showing. Each other desktop is restored the first time you go to it after a restart.
- The menu lists the stages of the desktop you are on, then the labelled stages of your other desktops under "Desktop 2" and so on.
- Shortcuts and Dock apps work for stages on any desktop. For a stage on another desktop, StageKeeper presses that desktop's "Switch to Desktop N" shortcut when you have turned it on (System Settings › Keyboard › Keyboard Shortcuts › Mission Control), and otherwise ⌃← or ⌃→ ("Move left a space" / "Move right a space" in the same place, on by default) until that desktop shows. If those shortcuts are off, it activates one of the stage's apps instead, which only moves desktops when the app has no windows on the desktop you are on; otherwise StageKeeper says which desktop the stage is on.
- Each desktop can have its own wallpaper; StageKeeper remembers your own wallpaper for each desktop.

### Colours

Switch to a stage and choose a colour from **Colour Current Stage**. While that stage is current:

- the menu bar shows a dot in that colour before the label (a stage with no label shows its app names);
- every screen's wallpaper is that colour.

On a stage with no colour, and when StageKeeper quits, your own wallpaper comes back. StageKeeper records it the first time it sets a colour; if you change your wallpaper while on a stage with no colour, it records the new one.

### Keyboard shortcuts

By default, labelled stages get ⌃⌥1 to ⌃⌥9: desktop 1's labelled stages first, in alphabetical order of label, then desktop 2's, and so on. The menu shows each stage's shortcut. Adding, removing or renaming a label can change these numbers; a shortcut chosen in Settings does not change. A shortcut does nothing when its stage has no open windows. macOS has no shortcuts of its own for switching to a particular stage.

### Settings

**Settings…** (⌘, while the menu is open) opens a window with three tabs:

- **Stages:** every labelled stage on every desktop. Click a label to rename it (Return or leaving the field saves; a label another stage has is refused). Set its colour from the palette or with any colour, and record its shortcut: click the shortcut, then press a key with ⌃, ⌥ or ⌘ (a function key works on its own; Esc cancels). StageKeeper's shortcuts are off while recording. The menu beside it sets the stage back to Automatic (the next free ⌃⌥1–9) or to no shortcut. A shortcut already in use is refused.
- **Palette:** rename, recolour, add and remove the colours offered in Colour Current Stage, the radial menu and the Stages tab. Restore Defaults puts back the ten built-in colours. Changing a palette colour does not recolour stages that already use it.
- **Shortcuts:** the shortcut for Fetch Bookmarked Windows (⌃⌥0 by default), or none.

Settings are kept in `settings.json` beside the layouts. `open stagekeeper://settings` also opens the window.

### Dock apps

Each labelled stage has a small app in `~/Applications/StageKeeper Stages`, named after the label, with an icon in the stage's colour. Drag one to the Dock; clicking it switches to that stage. **Show Dock Apps** opens the folder.

Each app finds its stage by an ID, not by the label. Renaming a stage renames its app in the same place, so a Dock item for it keeps working. Removing a label deletes the app.

### Command line

The command-line tool needs Accessibility permission for the terminal that runs it.

```
stagekeeper save                Save every stage on this desktop (labels are kept).
stagekeeper restore [--wait N]  Open saved apps and rebuild the stages.
stagekeeper list                Show this desktop's stages and their labels.
stagekeeper label "<name>"      Label the current stage ("" removes the label).
stagekeeper colour <colour>     Colour the current stage: a palette name, #RRGGBB, or none.
stagekeeper switch <label|n>    Switch to a labelled stage by label or shortcut number.
stagekeeper agent               Run the menu-bar item.
```

## Without Stage Manager (prototype)

With Stage Manager turned off (System Settings › Desktop & Dock › Stage Manager), StageKeeper keeps the stages itself. A stage is a group of windows. Switching moves the current stage's windows into the bottom-right corner of the screen, with one point showing, and moves the new stage's windows back to where they were. There is no strip: switch with the radial menu, the menu-bar menu, the shortcuts and the Dock apps.

- On first use the stages come from the last save on that desktop. A window StageKeeper has not seen before joins the current stage.
- Move in the radial menu moves a window into any stage, including a labelled stage with no open windows. Its last slot, **New stage**, makes a stage of the window alone.
- Bringing a hidden window forward yourself (⌘Tab, the Dock, a window menu) switches to its stage.
- When StageKeeper quits, or Stage Manager is turned back on, hidden windows are put back on screen. `stagekeeper reveal` does the same by hand.
- A new window joins the current stage within about half a second. One that opens mostly off screen (apps place a new window by their last one, which may be hidden) is moved to the middle of the screen.
- **All stages**, the centre of the radial menu or a four-finger swipe down, shows every stage on this desktop as a small screen with its windows drawn as boxes at their position and size, most recently used first. Click one to switch to it; swipe down again or press Esc to close it. The swipe works only while App Exposé is not set to a four-finger swipe down in System Settings › Trackpad › More Gestures.
- Picking a window from an app's Dock menu, Window menu or Mission Control switches to its stage.
- Mission Control shows hidden windows too, small, because they sit in the screen's corner. Turning on System Settings › Desktop & Dock › Mission Control › "Group windows by application" lays them out larger.
- Restore after a restart is not done yet without Stage Manager.
- The state is in `~/Library/Application Support/StageKeeper/engine.json`.

## Files

- Layouts: `~/Library/Application Support/StageKeeper/Desktops/`, one file per desktop named after the desktop's ID (`main.json` for the first desktop). The previous save of each is in `<name>.previous.json`. A `layout.json` from an earlier version is moved to `Desktops/main.json`.
- Settings (palette and shortcuts): `settings.json` in the same folder.
- Agent state (the boot it last restored, which desktops it has restored, and your own wallpaper for each screen and desktop): `state.json` in the same folder.
- Colour wallpapers: `Wallpapers/` in the same folder.
- Dock apps: `~/Applications/StageKeeper Stages`. `uninstall.sh` removes them.
- Log: `~/Library/Logs/StageKeeper.log`.

The app icon's source is `Resources/AppIcon.svg`. After changing it, run `swift scripts/make-icon.swift` to rebuild `Resources/AppIcon.icns`.

## How it works

**Reading stages.** Each thumbnail in the Stage Manager strip is an accessibility button with an `AXWindowsIDs` attribute that lists the window IDs in that stage. The current stage is the set of on-screen standard windows that are not in the strip. The strip shows only a limited number of stages, so a window in neither place is an overflow window. Its grouping cannot be read, so it is saved as a stage of its own, one stage per app. Window titles, positions and sizes come from each app's accessibility windows. The private `_AXUIElementGetWindow` call maps each accessibility window to its window ID.

**Clicking the strip.** Stage Manager ignores the accessibility actions on strip thumbnails, so StageKeeper uses real clicks and drags. While any window covers the strip's area, Stage Manager slides the strip off the left edge and reports it there, and a simulated pointer at the edge does not bring it back. So before each strip click or drag StageKeeper moves the current stage's windows out of the strip's area, waits for the strip to come back, acts, and moves the windows back. Switching stages does not need the strip: StageKeeper brings one of the stage's windows to the front and Stage Manager follows.

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

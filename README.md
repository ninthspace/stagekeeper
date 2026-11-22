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

### Updates

StageKeeper updates itself from the checkout it was installed from. `install.sh` records the checkout, the commit and the version (`git describe`) in the app, and `stagekeeper version` shows them.

- **Checking:** StageKeeper fetches from origin a minute after it opens and then once a day. When the repository has release tags (`v1.2.0`), an update is a newer tag; without tags, it is any new commit on origin's default branch. When one is found the menu-bar menu says so and shows **Install Update**; otherwise it offers **Check for Updates…**. `stagekeeper update --check` checks from the terminal.
- **Installing:** **Install Update**, or `stagekeeper update`, fast-forwards the checkout to the update and runs `install.sh`. That rebuilds and re-signs the app on this Mac, so it keeps its Accessibility permission, and restarts it. From the menu the build runs in the background and its output goes to `~/Library/Application Support/StageKeeper/update.log`. An update needs a checkout with no uncommitted changes that can fast-forward; otherwise pull and run `install.sh` yourself.

## Stages

- **Switching** moves the current stage's windows into the bottom-right corner of the rightmost screen, with one point showing, and moves the new stage's windows back to where they were. A small window of StageKeeper's covers that corner, painted like the wallpaper, so the hidden windows do not show (see [Hiding windows](#hiding-windows)). Switch with the radial menu, the menu-bar menu, All stages, the shortcuts or the Dock apps.
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

Mission Control shows hidden windows too, small, because they sit in the screen's corner under the cover. Turning on System Settings › Desktop & Dock › Mission Control › "Group windows by application" lays them out larger.

## Bookmarked windows

**Bookmark <App> Window** bookmarks the window you are working in. **Fetch Bookmarked Windows** (⌃⌥0, available while a window is bookmarked) moves bookmarked windows from other stages into the stage you are in. **Bookmarked Windows** lists the bookmarks; choose one to remove it. A closed window loses its bookmark, and bookmarks are matched by app and window title after a restart. Bookmarked windows stay on their own desktop.

## Desktops

Each desktop has its own stages and its own saved layout.

- **Save Layout** saves the desktop you are on and leaves the others alone.
- The menu lists the stages of the desktop you are on, then the labelled stages of your other desktops under "Desktop 2" and so on.
- Shortcuts and Dock apps work for stages on any desktop. For a stage on another desktop, StageKeeper presses that desktop's "Switch to Desktop N" shortcut when you have turned it on (System Settings › Keyboard › Keyboard Shortcuts › Mission Control), and otherwise ⌃← or ⌃→ until that desktop shows.
- With a separate desktop per display, StageKeeper manages the windows of the desktop that is active.

### More than one display

How stages work across displays depends on System Settings › Desktop & Dock › "Displays have separate Spaces". Changing it takes effect after you log out and back in.

- **On** (the macOS default): each display has its own desktop, and so its own stages and saved layout. Switching stages changes only the display you are working on; the windows on the other displays belong to their own desktops' stages and stay where they are. The radial menu, the menu bar and the shortcuts act on the desktop of the display that is active, which is the one holding the focused window.
- **Off:** one desktop spans every display. A stage holds windows on any display, and switching stages changes every display at once.

Hidden windows from every desktop sit in the corner of the rightmost screen, but each still belongs to the desktop that hid it. Bringing one forward from Mission Control, the Dock or a window menu switches to its stage on its own desktop, and the window goes back to its own display.

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
stagekeeper update [--check]    Install the newest version from the checkout (--check only reports it).
stagekeeper version             Show the installed version and the checkout it came from.
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

macOS gives an app no public way to hide one window, count fingers on a trackpad, or tell which desktop a window is on. StageKeeper gets there with Accessibility, a few long-stable private calls, and some workarounds for how macOS behaves. This section lists them, so the reasons for code that looks odd are written down.

### Reading windows

- **Windows and their IDs.** Titles, positions and sizes come from each app's Accessibility windows. The private `_AXUIElementGetWindow` call maps each one to its window ID, which the window server and SkyLight calls use.
- **Which desktop.** The private SkyLight call `SLSCopySpacesForWindows` says which desktop (Space) each window is on, and `SLSGetActiveSpace` and `SLSCopyManagedDisplaySpaces` give the active desktop and the desktops of each display. A desktop is keyed by the UUID macOS stores for it, which survives restarts; the first desktop on the main display has an empty UUID and is called `main`.
- **Windows that seem to vanish.** Accessibility can report no windows, or only some, while the Mac wakes or the screen is locked. A window leaves its stage only when the window server's own list (`CGWindowListCopyWindowInfo`) no longer has it, so stages do not merge or empty after wake.
- **Apps that do not answer.** An app that never answers Accessibility (Solo, for one) costs a one-second timeout on every read. After two misses in a row StageKeeper skips it for 30 seconds, doubling up to 5 minutes, but never while it is the frontmost app. An app that is only busy misses one read and is not skipped.
- **Window IDs after a restart.** macOS reuses window IDs after a restart, so saved IDs are trusted only within the boot they were saved in; otherwise windows are matched by app and title.

### Hiding windows

- **The corner.** A hidden window is moved to the bottom-right corner of the rightmost screen, less one point, and its frame is recorded so it can go back. macOS moves a window back on screen if none of it shows. Hiding the app would hide all its windows, and minimising animates and fills the Dock.
- **What stays visible.** macOS keeps a window's title bar on screen, so each hidden window leaves a strip one point wide and 30 to 65 points tall in the corner, with its shadow around it. StageKeeper covers the corner with a small window of its own, 72 by 150 points, above other windows. It is painted with what the wallpaper shows there: the stage colour, or the matching crop of your wallpaper image placed as macOS places it. It ignores clicks and stays out of Mission Control, and is shown only while windows are hidden. It reads the wallpaper every 0.4 seconds, so a new stage colour reaches it within half a second. With a moving or aerial wallpaper it paints the wallpaper's still image, which may differ a little from what shows.
- **One real screen's corner.** The corner of all screens together can lie on no screen, so the corner of the rightmost screen is used (the lowest, of screens equally far right).
- **Windows already off screen.** A window that is already off screen when hidden has no frame worth keeping, so none is recorded and it comes to the middle of the screen when its stage shows.
- **Slow apps.** Switching plans the moves under a lock and carries them out after, so an app that is slow to move a window does not hold up the menu or the other moves.
- **Putting windows back.** When StageKeeper quits, or Stage Manager is turned on, it puts every hidden window it can reach back. Quitting by signal (`kill`, `install.sh`) skips the normal quit handler, so StageKeeper catches the signals itself. Accessibility lists only the windows of desktops that are showing, so windows hidden on another desktop keep their record and go back when that desktop shows.
- **Screens changing.** When a display is connected, removed or rearranged, hidden windows move to the new corner.

### Hidden windows across displays

With "Displays have separate Spaces" on, each display has its own desktop, and macOS counts a window as on the desktop of the display it touches. Every hidden window touches the rightmost screen, so without the steps below:

- the active desktop lost all its stages but the current one, because their windows counted as on another desktop;
- the rightmost display's desktop took those windows into its own current stage and moved them to the middle of the screen;
- clicking a hidden window in Mission Control or the Dock made the rightmost display's desktop active, so StageKeeper did not switch to the window's stage.

What StageKeeper does instead:

- **Hidden windows belong to the desktop that hid them.** Reading a desktop keeps the windows it hid, wherever they sit, and leaves out the windows other desktops hid. A desktop that took in another desktop's hidden windows gives them up.
- **Switching across displays.** When the focused window is one another desktop hid, and that desktop is showing on its display, StageKeeper switches that desktop's stage. It does this while acting as that desktop, so its reads and moves use that desktop's windows and state although another display is active.

Tried and dropped:

- **Hiding below the desktop's own screen**, so each window stays on its own display's desktop. macOS moves the windows up until their title bars show, which left a strip of windows along the bottom of the screen.
- **Making hidden windows transparent.** Setting another app's window transparency (`SLSSetWindowAlpha`) needs System Integrity Protection off. With it on, macOS accepts the call and does nothing.
- **Hiding apps whose windows are all hidden.** It removes the strip for those apps, but hidden apps leave Mission Control.

### Following focus

- **Polling.** Picking a window from an app's Dock menu or Window menu changes the focused window without activating an app, so no notification arrives. StageKeeper checks the focused window every 0.4 seconds.
- **Settling.** For 1.5 seconds after StageKeeper switches or moves windows itself it does not follow focus: until the new stage's app comes forward, the app you left still reports its now hidden window as focused.
- **Keeping the screen in step.** Every two seconds a cheap read of the window server decides whether any window is out of step with its stage; only then does the full Accessibility read run. It is skipped while the focused window is in another stage, since following focus is about to switch to it.

### Tabs

Apps with native tabs (Ghostty, Finder) make each tab a window of its own, and Accessibility lists only the selected tab. A background tab looks new when it comes forward, so a new window that shares the frame of another window of the same app joins that window's stage; in the hiding corner, where every hidden window shares the corner, the size decides. Moving a window to another stage takes the stage's unlisted windows of the same app with it, as those are its background tabs.

### Desktops

- **Switching desktop.** For a stage on another desktop, StageKeeper presses Mission Control's "Switch to Desktop N" shortcut, which macOS stores as symbolic hot keys 118 to 133, when it is turned on. Otherwise it presses ⌃← or ⌃→ once per desktop between here and there. Failing that, it activates an app from the stage, which macOS follows to a desktop where the app has windows, unless it also has windows on this one.
- **Shortcut numbers.** Automatic shortcuts are numbered per desktop in order, so labelling a stage on one desktop does not renumber another desktop's stages.

### Trackpad

- **Counting fingers.** macOS has no public way to tell how many fingers are down, so StageKeeper reads them through the private MultitouchSupport framework, as BetterTouchTool and MiddleClick do.
- **Four-finger click.** An event tap takes the click, and the drag and release after it, out of the event stream so the app under the pointer does not see it. macOS can turn an event tap off without telling it, for example while the screen is locked, so StageKeeper checks it every few seconds.
- **Four-finger tap and swipe.** macOS sends no event for a tap of more than two fingers, so StageKeeper recognises one from the raw finger data: four fingers down and lifted within 0.3 seconds without moving or pressing. A swipe down is four fingers moving down far enough, more down than sideways.
- **After sleep.** The trackpad stops sending touches after sleep or a screen lock. StageKeeper waits for the driver to come back, then starts listening again; unlock and screen wake can arrive together, so only the last one restarts it.

### Radial menu

- **Not taking focus.** The menu is a non-activating panel, so the app you were using stays in front and its window stays the one Tile, Bookmark and Move act on.
- **Closing.** A choice hides the menu at once rather than animating, because the window moves that follow hold up the main thread and would stop the animation part-way.
- **⌥ for Move.** The ⌥ key is read from the keyboard as it is now, rather than from the last event, so a missed key-up cannot leave the menu in Move.

### Shortcuts, Dock apps and wallpaper

- **Shortcuts** use the Carbon hot-key API, which needs no extra permission. Fetch Bookmarked Windows is registered only while a window is bookmarked, so its key stays free for other apps otherwise.
- **Dock apps** are small apps that open `stagekeeper://switch/<stage id>`. Each finds its stage by the ID in its Info.plist, so a rename renames the app in place. Finder and the Dock show `/` as `:`, and `:` is not allowed in a file name, so both become `-` in the app's name.
- **Wallpaper colours** are 16-pixel PNGs that macOS stretches to fill the screen. macOS sets a wallpaper for the desktop showing on each screen, so your own wallpaper is recorded per screen and desktop.
- **Labels** stay with their stage: each stage records which saved stage it is, so a label stays when windows move between stages.

### Permissions and signing

- Switching stages from the Dock apps and `stagekeeper switch` goes through the menu-bar app (`stagekeeper://switch/<id>`), so those need no Accessibility permission of their own. The other commands read windows themselves and need it for the terminal.
- macOS ties the Accessibility permission to the code signature. An ad hoc signature changes with every build, so `make-signing-cert.sh` creates a self-signed certificate that keeps the permission across reinstalls. An entry allowed for an ad hoc build stays switched on but no longer applies; `tccutil reset Accessibility local.stagekeeper` clears it.

## Limits

- Restore matches windows by app and title. A window that opens with a different title, such as a browser window with a different active tab, may land in the wrong stage.
- StageKeeper does not open apps at login; Restore Layout does.
- Hidden windows sit in a corner of the screen, so they show in Mission Control and can be found by apps that list windows. The cover over the corner also hides anything else you put there.
- Only one display arrangement at a time has been tested. With separate Spaces per display, a stage covers one display only; see [More than one display](#more-than-one-display).

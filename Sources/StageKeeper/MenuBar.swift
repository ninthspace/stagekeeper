import AppKit

struct AgentState: Codable {
    /// Windows that come along when StageKeeper switches stage.
    var pins: [Pin]?
    /// The user's own wallpaper per screen, put back on stages without a colour.
    var originalWallpapers: [String: String]?

    static func load() -> AgentState {
        guard let data = try? Data(contentsOf: Paths.state) else { return AgentState() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode(AgentState.self, from: data)) ?? AgentState()
    }

    func write() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? e.encode(self).write(to: Paths.state, options: .atomic)
    }
}

/// Menu-bar item showing the current stage's colour and label, with save, restore, label,
/// colour and switch. Handles the stage shortcuts and the stagekeeper://switch/<id> links the Dock apps
/// open. Restores the saved layout once per boot when it starts.
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var busy = false
    private var timer: Timer?
    private var followTimer: Timer?
    private var following = false
    /// The newest version origin offers, when it is newer than this one.
    private var update: (target: String, summary: String)?
    private var checkingForUpdates = false
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.symbol
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(desktopChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        Hotkeys.handler = { [weak self] target in
            switch target {
            case .fetch: self?.fetchPinned()
            case .stage(let id): self?.perform { try Actions.switchTo(id: id) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshTitle() }
        startUpdateChecks()

        if !AX.isTrusted(prompt: true) {
            item.button?.title = " Needs Accessibility"
            waitForTrust()
            return
        }
        start()
    }

    private func waitForTrust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if AX.isTrusted(prompt: false) { self?.start() } else { self?.waitForTrust() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Wallpaper.apply(nil)
        Engine.revealAll()
    }

    /// Quitting by signal (install.sh, `kill`) skips applicationWillTerminate, which would leave
    /// hidden windows off screen.
    private var signalSources: [DispatchSourceSignal] = []
    private func revealOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Engine.revealAll(); exit(0) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Links from the Dock apps: stagekeeper://switch/<stage id>.
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "stagekeeper" && $0.host == "settings" }) { showSettings() }
        for url in urls where url.scheme == "stagekeeper" && url.host == "switch" {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            perform { try Actions.switchTo(id: id) }
        }
    }

    private var started = false
    private var radial: RadialMenu?

    private func start() {
        started = true
        revealOnSignals()
        if Engine.active {
            DispatchQueue.global(qos: .userInitiated).async { Engine.reconcile(force: true) }
        } else {
            Log.write("Stage Manager is on, so StageKeeper is paused until it is turned off.")
        }
        // Picking a window from an app's Dock menu or Window menu changes the focused window
        // without activating an app, so no notification comes: check the focused window often.
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.engineTick() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        startRadialMenu()
        DockApps.sync()
        refreshTitle()
    }

    /// Opens the radial menu on a four-finger trackpad click or tap.
    private func startRadialMenu() {
        let menu = RadialMenu(hooks: .init(
            perform: { [weak self] body in self?.perform(body) },
            notify: { [weak self] message in self?.notify(message) },
            labelCurrent: { [weak self] in self?.labelCurrent() },
            refresh: { [weak self] in self?.refreshTitle() }))
        radial = menu
        FourFingerClick.handler = { [weak menu] point in menu?.toggle(at: point) }
        Trackpad.onTap = { [weak menu] in menu?.toggle(at: NSEvent.mouseLocation) }
        Trackpad.onSwipeDown = { [weak menu] in menu?.toggleOverview() }
        if !Trackpad.start() { Log.write("No trackpad found, so the radial menu cannot open.") }
        if !FourFingerClick.install() { Log.write("Could not watch for four-finger clicks.") }
        // The trackpad stops sending touches to StageKeeper after sleep or a screen lock.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(restartTrackpad), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(restartTrackpad), name: .init("com.apple.screenIsUnlocked"), object: nil)
        TrackpadWatch.onChange = { [weak self] in self?.restartTrackpad() }
        TrackpadWatch.start()
    }

    @objc private func restartTrackpad() {
        // Wait for the trackpad driver to come back before asking for its devices. Several
        // causes can arrive together (unlock and screen wake), so only the last one restarts.
        trackpadRestart?.cancel()
        let restart = DispatchWorkItem {
            if Trackpad.start() { Log.write("Restarted the trackpad listener.") }
            else { Log.write("No trackpad found, so the radial menu cannot open.") }
        }
        trackpadRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: restart)
    }

    private var trackpadRestart: DispatchWorkItem?

    @objc private func desktopChanged() {
        if !Engine.active, Engine.hasHidden { DispatchQueue.global(qos: .userInitiated).async { Engine.revealAll() } }
        appActivated()
    }

    private var ticks = 0

    /// Every 0.4 s and on each app activation, off the main thread, one at a time: adds new
    /// windows to a stage, follows focus to another stage, and every 2 s checks the screen still
    /// matches the stages.
    private func engineTick() {
        guard Engine.active, !following else { return }
        following = true
        ticks += 1
        let check = ticks % 5 == 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Engine.noticeNewWindows()
            Engine.follow()
            if check { Engine.reconcile() }
            DispatchQueue.main.async {
                self?.following = false
                CornerCover.shared.update()
            }
        }
    }

    /// Displays came or went, or were rearranged: hidden windows move to the new corner. Stage
    /// Manager turned back on: hidden windows on the desktop that now shows go back.
    @objc private func screensChanged() {
        DispatchQueue.global(qos: .userInitiated).async {
            if Engine.active { Engine.reconcile(force: true) } else if Engine.hasHidden { Engine.revealAll() }
        }
    }

    private static let symbol = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "StageKeeper")

    /// Reads the stages again shortly after an app comes forward, once its windows have moved.
    @objc private func appActivated() {
        engineTick()
        refreshTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshTitle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshTitle() }
    }

    /// Updates the menu-bar title, the wallpaper and the registered shortcuts.
    @objc private func refreshTitle() {
        guard !busy, let button = item.button else { return }
        // StageKeeper pauses while Stage Manager is on, and puts its hidden windows back.
        if !Engine.active {
            if Engine.hasHidden { Engine.revealAll() }
            button.title = " Stage Manager is on"
            button.image = Self.symbol
            return
        }
        let layout = LayoutStore.load()
        Hotkeys.register(Shortcuts.wanted(fetchActive: !Pins.load().isEmpty))
        guard let snapshot = try? Snapshot.take() else {
            button.title = ""
            button.image = Self.symbol
            return
        }
        FocusHistory.note(snapshot)
        let indices = Matcher.savedIndices(layout, snapshot)
        let currentIndex = snapshot.stages.firstIndex { $0.kind == .current }
        let saved = currentIndex.flatMap { indices[$0] }.flatMap { layout?.stages[$0] }
        let name = saved?.label ?? currentIndex.map { appNames(snapshot.stages[$0], snapshot) } ?? ""
        button.title = name.isEmpty ? "" : " \(Self.truncate(name))"
        button.image = saved?.color.map { Palette.dot($0) } ?? Self.symbol
        Wallpaper.apply(saved?.color)
    }

    private func appNames(_ stage: LiveStage, _ snapshot: Snapshot) -> String {
        let apps = stage.windowIDs.compactMap { snapshot.windows[$0]?.appName }
        return apps.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
    }

    private static func truncate(_ text: String, to limit: Int = 32) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if busy {
            menu.addItem(withTitle: "Restoring…", action: nil, keyEquivalent: "")
            return
        }
        let layout = LayoutStore.load()
        let shortcuts = Shortcuts.stages()
        let desktops = Desktops.all()
        let desktop = Desktops.current()
        if desktops.count > 1 {
            menu.addItem(withTitle: "Desktop \(desktop.number)", action: nil, keyEquivalent: "")
        }
        var currentColour: String?
        let moveMenu = NSMenu()
        switch Result(catching: { try Snapshot.take() }) {
        case .success(let snapshot):
            let indices = Matcher.savedIndices(layout, snapshot)
            missingStages = (layout?.stages ?? []).enumerated()
                .filter { $0.element.label != nil && $0.element.id != nil && !indices.contains($0.offset) }
                .map(\.element)
            for (index, stage) in snapshot.stages.enumerated() {
                let saved = indices[index].flatMap { layout?.stages[$0] }
                let apps = appNames(stage, snapshot)
                let entry = NSMenuItem(title: saved?.label ?? apps, action: #selector(switchStage(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = stage.windowIDs.first.map { NSNumber(value: $0) }
                entry.toolTip = apps
                if let id = saved?.id { entry.show(shortcuts[id]) }
                if let colour = saved?.color { entry.image = Palette.dot(colour) }
                if stage.kind == .current {
                    entry.state = .on
                    currentColour = saved?.color
                } else if let first = stage.windowIDs.first {
                    let move = NSMenuItem(title: saved?.label ?? apps, action: #selector(moveFrontWindow(_:)), keyEquivalent: "")
                    move.target = self
                    move.representedObject = NSNumber(value: first)
                    if let colour = saved?.color { move.image = Palette.dot(colour) }
                    moveMenu.addItem(move)
                }
                menu.addItem(entry)
            }
        case .failure(let error):
            missingStages = []
            menu.addItem(withTitle: "\(error)", action: nil, keyEquivalent: "")
        }
        // Labelled stages on this desktop whose windows are not open here (closed, or moved to
        // another desktop). Choosing one offers to forget it.
        for stage in missingStages {
            let entry = NSMenuItem(title: "\(stage.label!) (no open windows)", action: #selector(forgetStage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = stage.id!.uuidString
            entry.toolTip = "None of this stage's windows are open on this desktop. Choose to forget it."
            entry.show(shortcuts[stage.id!])
            if let colour = stage.color { entry.image = Palette.dot(colour) }
            menu.addItem(entry)
            let move = NSMenuItem(title: "\(stage.label!) (no open windows)", action: #selector(moveToEmptyStage(_:)), keyEquivalent: "")
            move.target = self
            move.representedObject = stage.id!.uuidString
            if let colour = stage.color { move.image = Palette.dot(colour) }
            moveMenu.addItem(move)
        }
        // Labelled stages on other desktops.
        for other in LayoutStore.loadAll() where other.desktop != desktop.key {
            let stages = other.stages.filter { $0.label != nil && $0.id != nil }
            guard !stages.isEmpty else { continue }
            menu.addItem(.separator())
            let number = desktops.first { $0.key == other.desktop }?.number
            menu.addItem(withTitle: number.map { "Desktop \($0)" } ?? "Removed desktop", action: nil, keyEquivalent: "")
            for stage in stages {
                let entry = NSMenuItem(title: stage.label!, action: #selector(switchSaved(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = stage.id!.uuidString
                entry.show(shortcuts[stage.id!])
                if let colour = stage.color { entry.image = Palette.dot(colour) }
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        add(menu, "Label Current Stage…", #selector(labelCurrent), "l")
        if let snapshot = try? Snapshot.take(), let front = Actions.frontWindow(snapshot), let window = snapshot.windows[front] {
            let pinned = Pins.isPinned(front, snapshot)
            let pinItem = NSMenuItem(title: "\(pinned ? "Remove Bookmark from" : "Bookmark") \(window.appName) Window", action: #selector(togglePin(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.representedObject = NSNumber(value: front)
            pinItem.toolTip = "Fetch Bookmarked Windows\(Shortcuts.fetch.map { " (\($0.display))" } ?? "") brings bookmarked windows into the stage you are in."
            menu.addItem(pinItem)
        }
        let pins = Pins.load()
        if !pins.isEmpty {
            let fetch = NSMenuItem(title: "Fetch Bookmarked Windows", action: #selector(fetchPinned), keyEquivalent: "")
            fetch.show(Shortcuts.fetch)
            fetch.target = self
            menu.addItem(fetch)
            let pinsMenu = NSMenu()
            for (index, pin) in pins.enumerated() {
                let entry = NSMenuItem(title: "\(pin.appName) — \(pin.title.isEmpty ? "untitled" : pin.title)", action: #selector(unpinListed(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = NSNumber(value: index)
                entry.toolTip = "Choose to remove the bookmark."
                pinsMenu.addItem(entry)
            }
            let pinsItem = NSMenuItem(title: "Bookmarked Windows", action: nil, keyEquivalent: "")
            pinsItem.submenu = pinsMenu
            menu.addItem(pinsItem)
        }
        if !moveMenu.items.isEmpty {
            let moveItem = NSMenuItem(title: "Move Front Window To", action: nil, keyEquivalent: "")
            moveItem.submenu = moveMenu
            menu.addItem(moveItem)
        }
        let colours = NSMenu()
        for (name, hex) in Palette.colours {
            let entry = NSMenuItem(title: name, action: #selector(colourCurrent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = hex
            entry.image = Palette.dot(hex)
            entry.state = currentColour == hex ? .on : .off
            colours.addItem(entry)
        }
        colours.addItem(.separator())
        let none = NSMenuItem(title: "None", action: #selector(colourCurrent(_:)), keyEquivalent: "")
        none.target = self
        none.state = currentColour == nil ? .on : .off
        colours.addItem(none)
        let colourItem = NSMenuItem(title: "Colour Current Stage", action: nil, keyEquivalent: "")
        colourItem.submenu = colours
        menu.addItem(colourItem)
        add(menu, "Save Layout", #selector(saveLayout), "s")
        add(menu, "Restore Layout", #selector(restoreLayout), "r")
        if let layout {
            let saved = DateFormatter.localizedString(from: layout.savedAt, dateStyle: .medium, timeStyle: .short)
            menu.addItem(withTitle: "Saved \(saved)", action: nil, keyEquivalent: "")
        }
        add(menu, "Show Layout File", #selector(showFile), "")
        add(menu, "Settings…", #selector(showSettings), ",")
        add(menu, "Show Dock Apps", #selector(showDockApps), "")
        menu.addItem(.separator())
        if let update {
            add(menu, "Install Update (\(update.summary))…", #selector(installUpdate), "")
        } else {
            add(menu, checkingForUpdates ? "Checking for Updates…" : "Check for Updates…", #selector(checkForUpdatesNow), "")
        }
        if let installed = Updater.installed() {
            menu.addItem(withTitle: "Version \(installed.version)", action: nil, keyEquivalent: "")
        }
        add(menu, "Quit StageKeeper", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target ?? self
        menu.addItem(entry)
    }

    @objc private func switchStage(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        perform {
            let snapshot = try Snapshot.take()
            guard let stage = snapshot.stages.first(where: { $0.windowIDs.contains(id) }) else { return }
            try Actions.switchTo(stage, in: snapshot)
        }
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value, let snapshot = try? Snapshot.take(),
              let window = snapshot.windows[id] else { return }
        if Pins.isPinned(id, snapshot) {
            Pins.unpin(id)
            notify("Removed the bookmark from the \(window.appName) window.")
        } else {
            Pins.pin(window)
            notify("Bookmarked the \(window.appName) window. \(Shortcuts.fetch.map { "Press \($0.display)" } ?? "Choose Fetch Bookmarked Windows") to bring bookmarked windows into the stage you are in.")
        }
    }

    private var missingStages: [SavedStage] = []

    @objc private func forgetStage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw),
              let (layout, index) = Actions.locate(id), let label = layout.stages[index].label else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(label)?"
        alert.informativeText = "None of its windows are open on this desktop. Forgetting it removes its label, colour, shortcut and Dock app. Your windows are not affected."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .modalPanel
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try Actions.forget(id); refreshTitle() } catch { notify("\(error)") }
    }

    @objc private func fetchPinned() {
        perform { try Actions.fetchPinned() }
    }

    @objc private func unpinListed(_ sender: NSMenuItem) {
        guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
        Pins.unpin(at: index)
    }

    @objc private func moveFrontWindow(_ sender: NSMenuItem) {
        guard let target = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        perform { try Actions.moveFrontWindow(toStageWith: target) }
    }

    @objc private func moveToEmptyStage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        perform { try Actions.moveWindow(nil, toEmptyStage: id) }
    }

    @objc private func showSettings() {
        SettingsWindow.show { [weak self] in self?.refreshTitle() }
    }

    @objc private func switchSaved(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        perform { try Actions.switchTo(id: id) }
    }

    /// Runs a switch off the main thread (window moves wait on apps), then
    /// refreshes the title and reports any error.
    private func perform(_ body: @escaping () throws -> Void) {
        guard !busy else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try body() } catch { failure = error }
            DispatchQueue.main.async {
                if let failure { self.notify("\(failure)") }
                self.appActivated()
            }
        }
    }

    @objc private func colourCurrent(_ sender: NSMenuItem) {
        do { try Actions.colourCurrent(sender.representedObject as? String); refreshTitle() } catch { notify("\(error)") }
    }

    @objc private func showDockApps() {
        DockApps.sync()
        NSWorkspace.shared.open(Paths.dockApps)
    }

    @objc private func saveLayout() {
        do { try Actions.save(); notify("Layout saved.") } catch { notify("\(error)") }
    }

    @objc private func restoreLayout() { restore() }

    private func restore() {
        guard !busy else { return }
        busy = true
        item.button?.title = " Restoring…"
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do { message = try Restorer().run().summary } catch { message = "\(error)" }
            DispatchQueue.main.async {
                self.busy = false
                self.refreshTitle()
                self.notify(message)
            }
        }
    }

    @objc private func labelCurrent() {
        let existing: String = {
            guard let snapshot = try? Snapshot.take() else { return "" }
            let labels = Matcher.labels(LayoutStore.load(), snapshot)
            return snapshot.stages.firstIndex { $0.kind == .current }.flatMap { labels[$0] } ?? ""
        }()
        let alert = NSAlert()
        alert.messageText = "Label the current stage"
        alert.informativeText = "Leave empty to remove the label."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = existing
        alert.accessoryView = field
        alert.layout()
        // A panel above normal window level is not treated as a stage of its own.
        alert.window.level = .modalPanel
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try Actions.labelCurrent(field.stringValue); refreshTitle() } catch { notify("\(error)") }
    }

    @objc private func showFile() {
        let file = Paths.layout
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: file.path) ? file : Paths.desktops])
    }

    private func notify(_ message: String) {
        Log.write(message)
        guard let button = item.button else { return }
        let popover = NSPopover()
        let label = NSTextField(wrappingLabelWithString: message)
        label.preferredMaxLayoutWidth = 300
        let controller = NSViewController()
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        // NSPopover takes its size from the view's frame, so size it to the text.
        let text = label.fittingSize
        container.frame = NSRect(x: 0, y: 0, width: min(text.width, 300) + 24, height: text.height + 20)
        controller.view = container
        popover.contentViewController = controller
        popover.contentSize = container.frame.size
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { popover.close() }
    }
}

// MARK: - Updates

extension MenuBarController {
    private static let lastCheckKey = "LastUpdateCheck"

    /// Checks shortly after launch and then once a day. The timer fires hourly so a Mac that slept
    /// through the day still checks soon after it wakes.
    fileprivate func startUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        checkForUpdates(reportResult: false)
    }

    @objc fileprivate func checkForUpdatesNow() { checkForUpdates(reportResult: true) }

    /// A daily check says something only when it finds a version it hasn't mentioned before.
    private func checkForUpdates(reportResult: Bool) {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Updater.check() }
            DispatchQueue.main.async { [self] in
                checkingForUpdates = false
                switch result {
                case .success(.upToDate(let version)):
                    UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                    update = nil
                    if reportResult { notify("StageKeeper \(version) is up to date.") }
                case .success(.available(let target, let summary)):
                    UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                    let isNew = update?.target != target || update?.summary != summary
                    update = (target, summary)
                    if reportResult || isNew { notify("A StageKeeper update is available: \(summary). Choose Install Update in this menu.") }
                case .failure(let error):
                    if reportResult { notify("Could not check for updates. \(error)") } else { Log.write("Update check failed: \(error)") }
                }
            }
        }
    }

    /// Reports a failed install. A successful one quits this app before the deadline.
    private func watchInstall(until deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if let code = Updater.installFailure() {
                self?.notify("The update failed (exit \(code)). StageKeeper was not changed. See \(Updater.log.path).")
            } else if Date() < deadline {
                self?.watchInstall(until: deadline)
            }
        }
    }

    @objc fileprivate func installUpdate() {
        guard let update else { return }
        let alert = NSAlert()
        alert.messageText = "Install the StageKeeper update?"
        alert.informativeText = "\(update.summary). StageKeeper rebuilds itself from its checkout and restarts. Hidden windows come back on screen for a moment and are hidden again. Building takes a minute or so."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .modalPanel
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Updater.installInBackground(target: update.target)
            notify("Building the update. StageKeeper restarts when it is ready.")
            watchInstall(until: Date().addingTimeInterval(15 * 60))
        } catch {
            notify("Could not install the update. \(error)")
        }
    }
}

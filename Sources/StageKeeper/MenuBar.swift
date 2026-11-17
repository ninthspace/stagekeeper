import AppKit

struct AgentState: Codable {
    var lastRestoredBoot: Date?
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
/// colour and switch. Handles ⌃⌥1–9 and the stagekeeper://switch/<id> links the Dock apps
/// open. Restores the saved layout once per boot when it starts.
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var busy = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.symbol
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        Hotkeys.handler = { [weak self] number in self?.switchToNumber(number) }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshTitle() }

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
    }

    /// Links from the Dock apps: stagekeeper://switch/<stage id>.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "stagekeeper" && url.host == "switch" {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            perform { try Actions.switchTo(id: id) }
        }
    }

    private func start() {
        if let layout = LayoutStore.load() { DockApps.sync(layout) }
        refreshTitle()
        var state = AgentState.load()
        guard !System.sameBoot(state.lastRestoredBoot), LayoutStore.load() != nil else { return }
        state.lastRestoredBoot = System.bootTime
        state.write()
        // Give login items time to open their windows before rearranging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.restore() }
    }

    private static let symbol = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "StageKeeper")

    /// A stage switch activates an app before Stage Manager finishes moving the windows,
    /// so read the stages again once the animation is over.
    @objc private func appActivated() {
        refreshTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshTitle() }
    }

    /// Updates the menu-bar title, the wallpaper and the registered shortcuts.
    @objc private func refreshTitle() {
        guard !busy, let button = item.button else { return }
        let layout = LayoutStore.load()
        Hotkeys.register(count: Actions.numbered(layout).count)
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
        var currentColour: String?
        switch Result(catching: { try Snapshot.take() }) {
        case .success(let snapshot):
            let indices = Matcher.savedIndices(layout, snapshot)
            let numbers = Dictionary(uniqueKeysWithValues: Actions.numbered(layout).prefix(9).enumerated().map { ($1.id!, $0 + 1) })
            for (index, stage) in snapshot.stages.enumerated() {
                let saved = indices[index].flatMap { layout?.stages[$0] }
                let apps = appNames(stage, snapshot)
                let entry = NSMenuItem(title: saved?.label ?? apps, action: #selector(switchStage(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = stage.windowIDs.first.map { NSNumber(value: $0) }
                entry.toolTip = apps
                if let id = saved?.id, let number = numbers[id] {
                    entry.keyEquivalent = String(number)
                    entry.keyEquivalentModifierMask = Hotkeys.modifiers
                }
                if let colour = saved?.color { entry.image = Palette.dot(colour) }
                if stage.kind == .current {
                    entry.state = .on
                    currentColour = saved?.color
                }
                menu.addItem(entry)
            }
        case .failure(let error):
            menu.addItem(withTitle: "\(error)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        add(menu, "Label Current Stage…", #selector(labelCurrent), "l")
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
        add(menu, "Show Dock Apps", #selector(showDockApps), "")
        menu.addItem(.separator())
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
            Actions.switchTo(stage, in: snapshot)
        }
    }

    private func switchToNumber(_ number: Int) {
        let list = Actions.numbered(LayoutStore.load())
        guard number >= 1, number <= list.count, let id = list[number - 1].id else { return }
        perform { try Actions.switchTo(id: id) }
    }

    /// Runs a switch off the main thread (strip clicks sleep between mouse events), then
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
        if let layout = LayoutStore.load() { DockApps.sync(layout) }
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
        NSWorkspace.shared.activateFileViewerSelecting([Paths.layout])
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

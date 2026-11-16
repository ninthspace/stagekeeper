import AppKit

struct AgentState: Codable {
    var lastRestoredBoot: Date?

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

/// Menu-bar item showing the current stage's label, with save, restore, label and switch.
/// Restores the saved layout once per boot when it starts.
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var busy = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "StageKeeper")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshTitle), name: NSWorkspace.didActivateApplicationNotification, object: nil)
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

    private func start() {
        refreshTitle()
        var state = AgentState.load()
        guard !System.sameBoot(state.lastRestoredBoot), LayoutStore.load() != nil else { return }
        state.lastRestoredBoot = System.bootTime
        state.write()
        // Give login items time to open their windows before rearranging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.restore() }
    }

    @objc private func refreshTitle() {
        guard !busy, let button = item.button else { return }
        guard let snapshot = try? Snapshot.take() else { button.title = ""; return }
        let labels = Matcher.labels(LayoutStore.load(), snapshot)
        let label = snapshot.stages.firstIndex { $0.kind == .current }.flatMap { labels[$0] }
        button.title = label.map { " \($0)" } ?? ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if busy {
            menu.addItem(withTitle: "Restoring…", action: nil, keyEquivalent: "")
            return
        }
        let layout = LayoutStore.load()
        if let snapshot = try? Snapshot.take() {
            let labels = Matcher.labels(layout, snapshot)
            for (index, stage) in snapshot.stages.enumerated() {
                let apps = stage.windowIDs.compactMap { snapshot.windows[$0]?.appName }
                let unique = apps.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                let name = labels[index] ?? unique.joined(separator: ", ")
                let entry = NSMenuItem(title: name, action: #selector(switchStage(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = stage.windowIDs.first.map { NSNumber(value: $0) }
                entry.toolTip = unique.joined(separator: ", ")
                if stage.kind == .current { entry.state = .on }
                menu.addItem(entry)
            }
        } else {
            menu.addItem(withTitle: "Stage Manager is off or permission is missing", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        add(menu, "Label Current Stage…", #selector(labelCurrent), "l")
        add(menu, "Save Layout", #selector(saveLayout), "s")
        add(menu, "Restore Layout", #selector(restoreLayout), "r")
        if let layout {
            let saved = DateFormatter.localizedString(from: layout.savedAt, dateStyle: .medium, timeStyle: .short)
            menu.addItem(withTitle: "Saved \(saved)", action: nil, keyEquivalent: "")
        }
        add(menu, "Show Layout File", #selector(showFile), "")
        menu.addItem(.separator())
        add(menu, "Quit StageKeeper", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target ?? self
        menu.addItem(entry)
    }

    @objc private func switchStage(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value, let snapshot = try? Snapshot.take() else { return }
        if let strip = snapshot.stripItem(containing: id) {
            StripClick.click(strip.button, shift: false)
        } else if let window = snapshot.windows[id] {
            AX.perform(window.element, kAXRaiseAction)
            NSRunningApplication(processIdentifier: window.pid)?.activate()
        }
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
        controller.view = container
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { popover.close() }
    }
}

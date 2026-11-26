import AppKit

struct SavedRect: Codable, Equatable {
    var x: Double, y: Double, width: Double, height: Double
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.width; height = r.height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct SavedWindow: Codable {
    var bundleID: String
    var appName: String
    var title: String
    var frame: SavedRect
    /// Only meaningful while `Layout.bootTime` equals the current boot time.
    var windowID: UInt32?
}

struct SavedStage: Codable {
    /// Stable identity, kept across saves while the stage keeps its label or colour.
    /// Used by the Dock apps, which survive a rename.
    var id: UUID?
    var label: String?
    /// Hex colour such as "#0090FF": the menu-bar dot, the wallpaper and the Dock app icon.
    var color: String?
    var current: Bool
    var windows: [SavedWindow]

    /// A stage the user has named or coloured; only these carry over between saves.
    var isIdentified: Bool { label != nil || color != nil }
}

/// One desktop's saved stages, current first.
struct Layout: Codable {
    var version = 1
    var savedAt: Date
    var bootTime: Date?
    var stages: [SavedStage]
    /// The desktop these stages are on (see `Desktops`). Set when the layout is loaded.
    var desktop: String? = nil
}

enum Paths {
    static let directory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StageKeeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    /// One layout file per desktop, named after the desktop's key.
    static let desktops: URL = {
        let url = directory.appendingPathComponent("Desktops", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static func layout(for desktop: String) -> URL { desktops.appendingPathComponent("\(desktop).json") }
    static func previousLayout(for desktop: String) -> URL { desktops.appendingPathComponent("\(desktop).previous.json") }
    /// The layout file of the desktop showing now.
    static var layout: URL { layout(for: Desktops.current().key) }
    /// Before per-desktop layouts there was one file; it becomes the main desktop's layout.
    static let legacyLayout = directory.appendingPathComponent("layout.json")
    static let legacyPreviousLayout = directory.appendingPathComponent("layout.previous.json")
    static let state = directory.appendingPathComponent("state.json")
    static let wallpapers: URL = {
        let url = directory.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let dockApps = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/StageKeeper Stages", isDirectory: true)
    static let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StageKeeper.log")
}

enum System {
    static var bootTime: Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&mib, 2, &tv, &size, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    static func sameBoot(_ date: Date?) -> Bool {
        guard let date else { return false }
        return abs(date.timeIntervalSince(bootTime)) < 2
    }
}

enum Log {
    static var echo = true
    static func write(_ message: String) {
        if echo { print(message) }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: Paths.log) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: Paths.log, atomically: true, encoding: .utf8)
        }
    }
}

enum LayoutStore {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The layout of the desktop showing now.
    static func load() -> Layout? { load(Desktops.current().key) }

    /// When this desktop's layout was last saved.
    static var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.layout(for: Desktops.current().key).path))?[.modificationDate] as? Date
    }

    static func load(_ desktop: String) -> Layout? {
        migrateLegacy()
        guard let data = try? Data(contentsOf: Paths.layout(for: desktop)),
              var layout = try? decoder.decode(Layout.self, from: data) else { return nil }
        layout.desktop = desktop
        return layout
    }

    /// Every desktop's layout, including desktops that no longer exist.
    static func loadAll() -> [Layout] {
        migrateLegacy()
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.desktops, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".previous.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { load($0.deletingPathExtension().lastPathComponent) }
    }

    /// Writes to the layout's own desktop, or to the desktop showing now when it has none.
    static func write(_ layout: Layout, keepPrevious: Bool) throws {
        let desktop = layout.desktop ?? Desktops.current().key
        let url = Paths.layout(for: desktop)
        if keepPrevious, FileManager.default.fileExists(atPath: url.path) {
            let previous = Paths.previousLayout(for: desktop)
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.copyItem(at: url, to: previous)
        }
        try encoder.encode(layout).write(to: url, options: .atomic)
        Engine.adopt(layout)
    }

    private static func migrateLegacy() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.legacyLayout.path), !fm.fileExists(atPath: Paths.layout(for: "main").path) else { return }
        try? fm.moveItem(at: Paths.legacyLayout, to: Paths.layout(for: "main"))
        try? fm.moveItem(at: Paths.legacyPreviousLayout, to: Paths.previousLayout(for: "main"))
        Log.write("Moved layout.json to Desktops/main.json.")
    }
}

/// Pairs saved windows with live ones. Each live window is used at most once.
/// Pass 1: same window ID (only within the boot the layout was saved in).
/// Pass 2: same app and same title.
/// Pass 3 (when `loose`): same app, any remaining window, in on-screen order.
enum Matcher {
    static func match(_ layout: Layout, _ snapshot: Snapshot, loose: Bool) -> [[CGWindowID?]] {
        var result = layout.stages.map { Array<CGWindowID?>(repeating: nil, count: $0.windows.count) }
        var used = Set<CGWindowID>()

        if System.sameBoot(layout.bootTime) {
            for (s, stage) in layout.stages.enumerated() {
                for (w, saved) in stage.windows.enumerated() {
                    guard let raw = saved.windowID, let live = snapshot.windows[CGWindowID(raw)],
                          live.bundleID == saved.bundleID, !used.contains(live.id) else { continue }
                    result[s][w] = live.id
                    used.insert(live.id)
                }
            }
        }

        func pass(_ accepts: (SavedWindow, LiveWindow) -> Bool) {
            for (s, stage) in layout.stages.enumerated() {
                for (w, saved) in stage.windows.enumerated() where result[s][w] == nil {
                    if let id = snapshot.order.first(where: { !used.contains($0) && accepts(saved, snapshot.windows[$0]!) }) {
                        result[s][w] = id
                        used.insert(id)
                    }
                }
            }
        }
        pass { $0.bundleID == $1.bundleID && $0.title == $1.title }
        if loose { pass { $0.bundleID == $1.bundleID } }
        return result
    }

    /// For each live stage, the index in `layout` of the saved stage it is, if any.
    static func savedIndices(_ layout: Layout?, _ snapshot: Snapshot) -> [Int?] {
        snapshot.stages.map { live in live.savedID.flatMap { id in layout?.stages.firstIndex { $0.id == id } } }
    }

    static func labels(_ layout: Layout?, _ snapshot: Snapshot) -> [String?] {
        savedIndices(layout, snapshot).map { index in index.flatMap { layout?.stages[$0].label } }
    }
}

enum Actions {
    /// Captures every stage, carrying labels, colours and IDs over from the previous save.
    @discardableResult
    static func save() throws -> Layout {
        let desktop = Desktops.current().key
        let snapshot = try Snapshot.take()
        let previous = LayoutStore.load(desktop)
        let indices = Matcher.savedIndices(previous, snapshot)
        let stages = snapshot.stages.enumerated().compactMap { index, stage -> SavedStage? in
            let old = indices[index].flatMap { previous?.stages[$0] }
            let ids = stage.windowIDs
            guard !ids.isEmpty else { return nil }
            return SavedStage(
                id: old?.id ?? UUID(),
                label: old?.label,
                color: old?.color,
                current: stage.kind == .current,
                windows: ids.map { id in
                    let w = snapshot.windows[id]!
                    return SavedWindow(bundleID: w.bundleID, appName: w.appName, title: w.title,
                                       frame: SavedRect(w.frame), windowID: w.id)
                }
            )
        }
        // Labelled stages with no open windows here are kept, so their label, colour, shortcut and
        // Dock app survive until you forget them or give the name to another stage.
        let kept = (previous?.stages ?? []).enumerated()
            .filter { $0.element.label != nil && !indices.contains($0.offset) }
            .map { entry -> SavedStage in
                var stage = entry.element
                stage.current = false
                // A labelled stage with no stage of its own has no open windows: any of its
                // window IDs now belong to other stages, and would give it their windows.
                stage.windows = stage.windows.map { var w = $0; w.windowID = nil; return w }
                return stage
            }
        let layout = Layout(savedAt: Date(), bootTime: System.bootTime, stages: stages + kept, desktop: desktop)
        try LayoutStore.write(layout, keepPrevious: true)
        Log.write("Saved \(stages.count) stages, \(snapshot.windows.count) windows.")
        return layout
    }

    /// Saves, then changes the current stage with `change`, then rewrites the layout and Dock apps.
    private static func editCurrent(_ change: (inout SavedStage) -> Void) throws -> SavedStage {
        var layout = try save()
        guard let index = layout.stages.firstIndex(where: \.current) else {
            throw StageError.other("There is no current stage with windows.")
        }
        if layout.stages[index].id == nil { layout.stages[index].id = UUID() }
        change(&layout.stages[index])
        try LayoutStore.write(layout, keepPrevious: false)
        DockApps.sync()
        return layout.stages[index]
    }

    /// Saves, then sets (or clears, when empty) the label of the current stage.
    static func labelCurrent(_ label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Giving the current stage the name of another stage on this desktop moves that stage here:
        // its identity (shortcut, Dock app) and colour come along, and the old entry goes. This is
        // how a window becomes a labelled stage that had no open windows.
        func named(_ stage: SavedStage) -> Bool { !stage.current && stage.label?.caseInsensitiveCompare(trimmed) == .orderedSame }
        if !trimmed.isEmpty, LayoutStore.load()?.stages.contains(where: named) == true {
            var layout = try save()
            guard let here = layout.stages.firstIndex(where: \.current) else {
                throw StageError.other("There is no current stage with windows.")
            }
            if let there = layout.stages.firstIndex(where: named) {
                let previousID = layout.stages[here].id
                let takenID = layout.stages[there].id
                layout.stages[here].id = takenID
                layout.stages[here].color = layout.stages[here].color ?? layout.stages[there].color
                layout.stages[here].label = layout.stages[there].label
                layout.stages.remove(at: there)
                if let previousID, previousID != takenID { DockApps.remove(previousID) }
                try LayoutStore.write(layout, keepPrevious: false)
                DockApps.sync()
                Log.write("Moved the \"\(trimmed)\" label to the current stage.")
                return
            }
        }
        let stage = try editCurrent { $0.label = trimmed.isEmpty ? nil : trimmed }
        if trimmed.isEmpty, let id = stage.id { DockApps.remove(id) }
        Log.write(trimmed.isEmpty ? "Cleared current stage label." : "Labelled current stage \"\(trimmed)\".")
    }

    /// Saves, then sets (or clears, when nil) the colour of the current stage.
    static func colourCurrent(_ hex: String?) throws {
        _ = try editCurrent { $0.color = hex }
        Log.write(hex.map { "Coloured current stage \($0)." } ?? "Cleared current stage colour.")
    }

    /// Labelled stages in shortcut order: desktop by desktop, alphabetical by label within a
    /// desktop, so labelling a stage on one desktop does not renumber another desktop's stages.
    /// The first nine get ⌃⌥1–9.
    static func numbered() -> [SavedStage] {
        let order = Dictionary(uniqueKeysWithValues: Desktops.all().enumerated().map { ($1.key, $0) })
        let layouts = LayoutStore.loadAll().sorted { (order[$0.desktop ?? ""] ?? .max) < (order[$1.desktop ?? ""] ?? .max) }
        return layouts.flatMap { layout in
            layout.stages.filter { $0.label != nil && $0.id != nil }
                .sorted { $0.label!.localizedStandardCompare($1.label!) == .orderedAscending }
        }
    }

    /// Removes a saved stage, with its label, colour and Dock app, from its desktop's layout.
    static func forget(_ id: UUID) throws {
        guard let found = locate(id) else { throw StageError.other("That stage is no longer saved.") }
        var layout = found.layout
        let index = found.index
        let label = layout.stages[index].label ?? "stage"
        layout.stages.remove(at: index)
        try LayoutStore.write(layout, keepPrevious: true)
        DockApps.remove(id)
        Log.write("Forgot the \"\(label)\" stage.")
    }

    /// Deletes a labelled stage on any desktop: its windows join that desktop's current stage,
    /// and its label, colour, shortcut and Dock app are removed. No window is closed.
    static func delete(_ id: UUID) throws {
        guard let found = locate(id) else { throw StageError.other("That stage is no longer saved.") }
        let key = found.layout.desktop ?? Desktops.current().key
        let label = found.layout.stages[found.index].label ?? "stage"
        try Engine.dissolve(savedID: id, on: key)
        try forget(id)
        Settings.update { $0.stageShortcuts?[id.uuidString] = nil }
        // Save this desktop again so its current stage holds the windows it was given.
        if key == Desktops.current().key { _ = try? save() }
        Log.write("Deleted the \"\(label)\" stage; its windows joined the current stage.")
    }

    /// The layout and index of a saved stage, on any desktop.
    static func locate(_ id: UUID) -> (layout: Layout, index: Int)? {
        for layout in LayoutStore.loadAll() {
            if let index = layout.stages.firstIndex(where: { $0.id == id }) { return (layout, index) }
        }
        return nil
    }

    /// Switches to the live stage that matches a saved stage, moving to its desktop first when
    /// it is on another one. Blocks for a second or more, so call it off the main thread.
    static func switchTo(id: UUID) throws {
        guard let (layout, saved) = locate(id) else {
            throw StageError.other("That stage is no longer in the saved layout.")
        }
        let stage = layout.stages[saved]
        let name = stage.label ?? "That stage"
        if let desktop = layout.desktop, desktop != Desktops.current().key {
            try moveToDesktop(desktop, for: stage)
        }
        // After a desktop change the apps take a moment to report their windows.
        var live: Int?
        var snapshot = try Snapshot.take()
        for _ in 0..<6 {
            live = Matcher.savedIndices(layout, snapshot).firstIndex(of: saved)
            if live != nil { break }
            usleep(250_000)
            snapshot = try Snapshot.take()
        }
        guard let live else { throw StageError.other("\(name) has no open windows.") }
        try switchTo(snapshot.stages[live], in: snapshot)
    }

    /// Moves to another desktop. Presses Mission Control's "Switch to Desktop N" shortcut when it
    /// is turned on; otherwise ⌃← or ⌃→ ("Move left/right a space", on by default) once per
    /// desktop between here and there. Failing that, activates an app from the stage, which
    /// macOS follows to a desktop where the app has windows unless it also has windows here.
    private static func moveToDesktop(_ desktop: String, for stage: SavedStage) throws {
        let name = stage.label ?? "That stage"
        let place = Desktops.number(of: desktop).map { "Desktop \($0)" } ?? "another desktop"
        let all = Desktops.all()
        if let from = all.firstIndex(where: { $0.key == Desktops.current().key }),
           let to = all.firstIndex(where: { $0.key == desktop }) {
            let source = CGEventSource(stateID: .hidSystemState)
            func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
                    event?.flags = flags
                    event?.post(tap: .cghidEventTap)
                }
            }
            if let shortcut = Desktops.switchShortcut(toDesktop: all[to].number) {
                press(shortcut.key, shortcut.flags)
            } else {
                let key: CGKeyCode = to > from ? 124 : 123  // right or left arrow
                for _ in 0..<abs(to - from) {
                    press(key, [.maskControl, .maskSecondaryFn, .maskNumericPad])
                    usleep(350_000)
                }
            }
            for _ in 0..<8 {
                if Desktops.current().key == desktop { usleep(400_000); return }
                usleep(250_000)
            }
            Log.write("The desktop shortcut did not reach \(place).")
        }
        let bundles = stage.windows.map(\.bundleID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for bundle in bundles {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
            app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
            for _ in 0..<8 {
                usleep(250_000)
                if Desktops.current().key == desktop { return }
            }
        }
        throw StageError.other("\(name) is on \(place). Switch to that desktop first.")
    }

    /// Makes `stage` current. Bookmarked windows of the stage being left come along.
    static func switchTo(_ stage: LiveStage, in snapshot: Snapshot) throws {
        guard stage.kind != .current, let first = stage.windowIDs.first else { return }
        try Engine.activate(stageWith: first, snapshot: snapshot)
        let names = stage.windowIDs.compactMap { snapshot.windows[$0]?.appName }
        Log.write("Switched to the stage with \(Array(Set(names)).sorted().joined(separator: ", ")).")
    }

    /// Goes back to the stage switched from, or forward again after going back.
    static func step(_ step: Engine.Step) throws {
        Engine.matchFocus()
        guard try Engine.go(step) else {
            throw StageError.other(step == .back ? "There is no earlier stage to go back to on this desktop."
                                                 : "There is no later stage to go forward to on this desktop.")
        }
        Log.write(step == .back ? "Went back to the previous stage." : "Went forward to the next stage.")
    }

    /// Brings bookmarked windows that are in other stages into the current stage.
    static func fetchPinned() throws {
        let snapshot = try Snapshot.take()
        guard let home = frontWindow(snapshot) else { throw StageError.other("There is no current stage to fetch into.") }
        let away = Pins.resolve(snapshot).filter { !snapshot.current.contains($0) }
        guard !away.isEmpty else { throw StageError.other("No bookmarked windows are in other stages on this desktop.") }
        try Engine.move(away, toStageWith: home, snapshot: snapshot)
        Engine.bringForward(home, snapshot: snapshot)
        Log.write("Fetched \(away.count) bookmarked windows.")
    }

    /// The window you are working in: the focused window of the frontmost app when it is in the
    /// current stage, else the current stage's front window by window order.
    static func frontWindow(_ snapshot: Snapshot) -> CGWindowID? {
        let current = Set(snapshot.current)
        return AX.focusedWindow().flatMap { current.contains($0.1) ? $0.1 : nil }
            ?? Snapshot.zOrder().first(where: current.contains)
    }

    /// Moves the front window of the current stage into the stage holding `targetWindow`, and
    /// switches to that stage. `window` picks a window of the current stage other than the front one.
    static func moveFrontWindow(toStageWith targetWindow: CGWindowID, window chosen: CGWindowID? = nil) throws {
        Engine.matchFocus()
        let snapshot = try Snapshot.take()
        guard let front = chosen.flatMap({ snapshot.current.contains($0) ? $0 : nil }) ?? frontWindow(snapshot),
              let name = snapshot.windows[front]?.appName else {
            throw StageError.other("The current stage has no window to move.")
        }
        Log.write("Moving the \(name) window \"\(snapshot.windows[front]?.title ?? "")\".")
        guard let target = snapshot.stages.first(where: { $0.windowIDs.contains(targetWindow) }), target.kind != .current else {
            throw StageError.other("That stage is no longer open.")
        }
        _ = target
        try Engine.move([front], toStageWith: targetWindow, snapshot: snapshot)
        try Engine.activate(stageWith: targetWindow, focus: front, snapshot: snapshot)
        Log.write("Moved the \(name) window to another stage.")
    }

    /// Moves a window of the current stage (the front one when `chosen` is nil) into a new,
    /// unlabelled stage of its own, and switches to it.
    static func moveWindowToNewStage(_ chosen: CGWindowID?) throws {
        Engine.matchFocus()
        let snapshot = try Snapshot.take()
        guard let front = chosen.flatMap({ snapshot.current.contains($0) ? $0 : nil }) ?? frontWindow(snapshot),
              let window = snapshot.windows[front] else {
            throw StageError.other("The current stage has no window to move.")
        }
        guard snapshot.current.count > 1 else {
            throw StageError.other("The \(window.appName) window is already the only window in its stage.")
        }
        try Engine.move([front], toStageWith: nil, snapshot: snapshot)
        // Go with the window: the radial menu holds eight stages, so a new unlabelled stage is
        // often not in it, and the window would seem to vanish.
        try Engine.activate(stageWith: front, focus: front, snapshot: snapshot)
        Log.write("Moved the \(window.appName) window \"\(window.title)\" to a new stage and switched to it.")
    }

    /// Moves a window of the current stage (the front one when `chosen` is nil) into a labelled
    /// stage that has no open windows: the window becomes a stage of its own, and the saved stage
    /// is pointed at it so its label, colour and shortcut follow.
    static func moveWindow(_ chosen: CGWindowID?, toEmptyStage id: UUID) throws {
        guard let found = locate(id), found.layout.desktop == nil || found.layout.desktop == Desktops.current().key else {
            throw StageError.other("That stage is not on this desktop.")
        }
        let snapshot = try Snapshot.take()
        guard let front = chosen.flatMap({ snapshot.current.contains($0) ? $0 : nil }) ?? frontWindow(snapshot),
              let window = snapshot.windows[front] else {
            throw StageError.other("The current stage has no window to move.")
        }
        let label = found.layout.stages[found.index].label ?? "that stage"
        if snapshot.current.count > 1 { try Engine.move([front], toStageWith: nil, snapshot: snapshot) }
        var layout = found.layout
        let saved = SavedWindow(bundleID: window.bundleID, appName: window.appName, title: window.title,
                                frame: SavedRect(window.frame), windowID: window.id)
        for index in layout.stages.indices {
            layout.stages[index].windows.removeAll { $0.windowID == window.id }
        }
        layout.stages[found.index].windows = [saved]
        layout.stages[found.index].current = snapshot.current.count == 1
        try LayoutStore.write(layout, keepPrevious: true)
        Log.write("Moved the \(window.appName) window into the empty \"\(label)\" stage.")
    }

    /// Finds a labelled stage by shortcut number (1-based) or by label, ignoring case.
    static func find(_ query: String) -> SavedStage? {
        let list = numbered()
        if let n = Int(query), n >= 1, n <= list.count { return list[n - 1] }
        return list.first { $0.label!.caseInsensitiveCompare(query) == .orderedSame }
    }

    static func describe() throws -> String {
        let snapshot = try Snapshot.take()
        let labels = Matcher.labels(LayoutStore.load(), snapshot)
        let desktop = Desktops.current()
        var lines = ["Desktop \(desktop.number) of \(max(Desktops.all().count, 1)) (\(desktop.key))"]
        for (index, stage) in snapshot.stages.enumerated() {
            let name = labels[index].map { "\"\($0)\"" } ?? "(no label)"
            lines.append("\(stage.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)")
            for id in stage.windowIDs {
                let w = snapshot.windows[id]!
                lines.append("           \(w.appName) — \(w.title.isEmpty ? "(untitled)" : w.title)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Remembers which window was in front of each stage, so a switch brings that window back to
/// the front rather than whichever window is listed first. The menu-bar app records
/// the front window of the current stage every time it reads the stages.
enum FocusHistory {
    nonisolated(unsafe) private static var lastFront: [CGWindowID: Date] = loadRecent()
    nonisolated(unsafe) private static var lastNoted: CGWindowID?
    private static let lock = NSLock()

    private struct Recent: Codable { var boot: Date?; var windows: [String: Date] }
    private static var path: URL { Paths.directory.appendingPathComponent("recent.json") }

    /// Kept on disk so the order of stages by use survives a restart of StageKeeper. Window IDs
    /// last until the Mac restarts.
    private static func loadRecent() -> [CGWindowID: Date] {
        guard let data = try? Data(contentsOf: path), let recent = try? JSONDecoder().decode(Recent.self, from: data),
              System.sameBoot(recent.boot) else { return [:] }
        return Dictionary(uniqueKeysWithValues: recent.windows.compactMap { key, date in CGWindowID(key).map { ($0, date) } })
    }

    static func note(_ snapshot: Snapshot) {
        let current = Set(snapshot.current)
        guard let front = Snapshot.zOrder().first(where: current.contains) else { return }
        lock.lock(); defer { lock.unlock() }
        lastFront[front] = Date()
        guard front != lastNoted else { return }
        lastNoted = front
        let recent = Recent(boot: System.bootTime, windows: Dictionary(uniqueKeysWithValues: lastFront.map { (String($0.key), $0.value) }))
        if let data = try? JSONEncoder().encode(recent) { try? data.write(to: path, options: .atomic) }
    }

    /// When any of the windows was last in front, for ordering stages by use.
    static func lastUsed(_ ids: [CGWindowID]) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return ids.compactMap { lastFront[$0] }.max()
    }

    /// Stages ordered most recently used first; stages never seen in front keep their order
    /// after them.
    static func byRecentUse<T>(_ items: [T], windows: (T) -> [CGWindowID]) -> [T] {
        let dated = items.enumerated().map { (offset: $0.offset, item: $0.element, used: lastUsed(windows($0.element))) }
        return dated.sorted { a, b in
            switch (a.used, b.used) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.item)
    }

    /// The stage's window that was last in front; failing that, the front one by window order.
    static func frontmost(of ids: [CGWindowID]) -> CGWindowID? {
        lock.lock()
        let remembered = ids.compactMap { id in lastFront[id].map { (id, $0) } }.max { $0.1 < $1.1 }?.0
        lock.unlock()
        if let remembered { return remembered }
        let order = Snapshot.zOrder()
        return ids.min { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }
}

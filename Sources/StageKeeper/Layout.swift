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

/// The one saved configuration. Stages are stored current first, then strip order (top to
/// bottom), then overflow. Restore builds them in reverse so the strip ends in the same order.
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

    /// For each live stage, the index of the named or coloured saved stage it overlaps most
    /// (each saved stage used once).
    static func savedIndices(_ layout: Layout?, _ snapshot: Snapshot) -> [Int?] {
        var result = snapshot.stages.map { _ -> Int? in nil }
        guard let layout else { return result }
        let matched = match(layout, snapshot, loose: false)
        var pairs: [(overlap: Int, live: Int, saved: Int)] = []
        for (l, live) in snapshot.stages.enumerated() {
            let liveSet = Set(live.windowIDs)
            for (s, saved) in layout.stages.enumerated() where saved.isIdentified {
                let overlap = matched[s].compactMap { $0 }.filter(liveSet.contains).count
                if overlap > 0 { pairs.append((overlap, l, s)) }
            }
        }
        var usedSaved = Set<Int>()
        for p in pairs.sorted(by: { $0.overlap > $1.overlap }) where result[p.live] == nil && !usedSaved.contains(p.saved) {
            result[p.live] = p.saved
            usedSaved.insert(p.saved)
        }
        return result
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
        let stages = snapshot.stages.enumerated().map { index, stage in
            let old = indices[index].flatMap { previous?.stages[$0] }
            return SavedStage(
                id: old?.id ?? UUID(),
                label: old?.label,
                color: old?.color,
                current: stage.kind == .current,
                windows: stage.windowIDs.map { id in
                    let w = snapshot.windows[id]!
                    return SavedWindow(bundleID: w.bundleID, appName: w.appName, title: w.title,
                                       frame: SavedRect(w.frame), windowID: w.id)
                }
            )
        }
        let layout = Layout(savedAt: Date(), bootTime: System.bootTime, stages: stages, desktop: desktop)
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
        switchTo(snapshot.stages[live], in: snapshot)
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

    /// Switches to a live stage by focusing one of its windows, which Stage Manager follows.
    /// Checks that the stage became current; the last attempt clicks the strip thumbnail instead,
    /// which is less reliable because Stage Manager often reports the hidden strip off screen.
    ///
    /// Pinned windows in the stage being left come along (see `Pins`) unless `carryPins` is false.
    static func switchTo(_ stage: LiveStage, in snapshot: Snapshot, carryPins: Bool = true) {
        guard stage.kind != .current, let id = FocusHistory.frontmost(of: stage.windowIDs) else { return }
        let pinned = carryPins ? Pins.resolve(snapshot).filter { snapshot.current.contains($0) } : []
        var frames: [CGWindowID: CGRect] = [:]
        if !pinned.isEmpty {
            // Bring the pinned windows to the front, first pin frontmost, so their previews are
            // on top of the thumbnail this stage becomes.
            for pin in pinned {
                if let window = snapshot.windows[pin], let frame = AX.frame(window.element) { frames[pin] = frame }
            }
            for pin in pinned.reversed() {
                if let window = snapshot.windows[pin] { AX.focus(window); usleep(120_000) }
            }
        }
        var snapshot = snapshot
        var switched = false
        for attempt in 1...3 where !switched {
            if attempt < 3, let window = snapshot.windows[id] {
                AX.focus(window)
            } else if let strip = snapshot.stripItem(containing: id) {
                StripClick.click(strip, shift: false)
            }
            // Poll rather than wait a fixed time: most switches finish well inside the limit.
            var after: Snapshot?
            for _ in 0..<8 {
                usleep(80_000)
                after = try? Snapshot.take()
                if after?.current.contains(id) == true { switched = true; break }
            }
            guard let after else { return }
            if !switched {
                Log.write("Stage switch attempt \(attempt) did not take.")
                snapshot = after
            }
        }
        guard switched, !pinned.isEmpty else { return }
        carry(pinned, frames: frames, thenFocus: id)
    }

    /// Brings pinned windows that are in other stages into the current stage: for each stage
    /// holding pinned windows, switches to it (which brings a pinned window to the front),
    /// then switches back, carrying the pinned windows as a StageKeeper switch does. Blocks for a
    /// few seconds, so call it off the main thread.
    static func fetchPinned() throws {
        var snapshot = try Snapshot.take()
        guard let home = frontWindow(snapshot) else { throw StageError.other("There is no current stage to fetch into.") }
        let away = Pins.resolve(snapshot).filter { !snapshot.current.contains($0) && snapshot.stripItem(containing: $0) != nil }
        guard !away.isEmpty else { throw StageError.other("No pinned windows are in other stages on this desktop.") }
        var done = Set<CGWindowID>()
        for pin in away where !done.contains(pin) {
            guard let window = snapshot.windows[pin] else { continue }
            AX.focus(window)
            var there = false
            for _ in 0..<15 {
                usleep(100_000)
                snapshot = try Snapshot.take()
                if snapshot.current.contains(pin) && !snapshot.current.contains(home) { there = true; break }
            }
            guard there, let back = snapshot.stages.first(where: { $0.windowIDs.contains(home) }) else {
                throw StageError.other("Could not go to the \(window.appName) window's stage.")
            }
            done.formUnion(snapshot.current)
            switchTo(back, in: snapshot)
            snapshot = try Snapshot.take()
        }
        let missing = Pins.resolve(snapshot).filter { away.contains($0) && !snapshot.current.contains($0) }
        if !missing.isEmpty { throw StageError.other("Some pinned windows did not come. See the log.") }
    }

    /// Drags pinned windows from the stage just left into the current one, puts each back at its
    /// position and size, and returns focus to `focus`.
    private static func carry(_ pinned: [CGWindowID], frames: [CGWindowID: CGRect], thenFocus focus: CGWindowID) {
        // While Stage Manager animates the switch, the windows left behind still read as current.
        guard var after = try? Snapshot.take() else { return }
        for _ in 0..<18 where pinned.contains(where: after.current.contains) {
            usleep(100_000)
            guard let next = try? Snapshot.take() else { return }
            after = next
        }
        for pin in pinned {
            guard let window = after.windows[pin], after.stripItem(containing: pin) != nil else { continue }
            guard StripClick.dragIntoCurrent(window) else {
                Log.write("The pinned \(window.appName) window stayed behind: its preview was not found.")
                continue
            }
            var arrived = false
            for _ in 0..<10 {
                usleep(100_000)
                guard let next = try? Snapshot.take() else { break }
                after = next
                if next.current.contains(pin) { arrived = true; break }
            }
            if arrived, let frame = frames[pin], let element = after.windows[pin]?.element {
                AX.setFrame(element, frame)
            } else if !arrived {
                Log.write("The pinned \(window.appName) window stayed behind.")
            }
        }
        if let window = (try? Snapshot.take())?.windows[focus] { AX.focus(window) }
    }

    /// The window you are working in: the focused window of the frontmost app when it is in the
    /// current stage, else the current stage's front window by window order. Window order alone
    /// can pick a window that shows on every stage, such as Outlook's reminders.
    static func frontWindow(_ snapshot: Snapshot) -> CGWindowID? {
        let current = Set(snapshot.current)
        let focused = NSWorkspace.shared.frontmostApplication.flatMap { app -> CGWindowID? in
            guard let element = AX.value(AX.application(app.processIdentifier), kAXFocusedWindowAttribute) else { return nil }
            return AX.windowID(element as! AXUIElement)
        }
        return focused.flatMap { current.contains($0) ? $0 : nil } ?? Snapshot.zOrder().first(where: current.contains)
    }

    /// Moves the front window of the current stage into the stage holding `targetWindow`:
    /// switches to that stage, then drags the window's preview out of the strip into it.
    /// Blocks for a couple of seconds, so call it off the main thread.
    static func moveFrontWindow(toStageWith targetWindow: CGWindowID) throws {
        let started = Date()
        let snapshot = try Snapshot.take()
        guard let front = frontWindow(snapshot), let name = snapshot.windows[front]?.appName else {
            throw StageError.other("The current stage has no window to move.")
        }
        Log.write("Moving the \(name) window \"\(snapshot.windows[front]?.title ?? "")\".")
        // A dropped preview lands where it is dropped; the window goes back here afterwards.
        let originalFrame = snapshot.windows[front].flatMap { AX.frame($0.element) }
        guard let target = snapshot.stages.first(where: { $0.windowIDs.contains(targetWindow) }), target.kind != .current else {
            throw StageError.other("That stage is no longer open.")
        }
        switchTo(target, in: snapshot, carryPins: false)
        // While Stage Manager animates the switch, the old stage's windows are still on screen
        // and read as current. Wait for the window to reach the strip.
        var after = try Snapshot.take()
        for _ in 0..<18 where after.current.contains(front) {
            usleep(100_000)
            after = try Snapshot.take()
        }
        guard after.current.contains(targetWindow) else { throw StageError.other("Could not switch to that stage.") }
        if after.current.contains(front) {
            throw StageError.other("The \(name) window shows on every stage, or is already in that stage, so there is nothing to move.")
        }
        guard let window = after.windows[front], after.stripItem(containing: front) != nil else {
            throw StageError.other("The \(name) window is not in the strip, so it cannot be dragged.")
        }
        guard StripClick.dragIntoCurrent(window) else {
            throw StageError.other("Could not find the \(name) window in the strip. See the log for details.")
        }
        for _ in 0..<10 {
            usleep(100_000)
            after = try Snapshot.take()
            if after.current.contains(front) { break }
        }
        guard after.current.contains(front) else { throw StageError.other("Stage Manager did not take the \(name) window.") }
        if let originalFrame, let element = after.windows[front]?.element { AX.setFrame(element, originalFrame) }
        Log.write("Moved the \(name) window to another stage in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
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
/// the front rather than whichever window Stage Manager lists first. The menu-bar app records
/// the front window of the current stage every time it reads the stages.
enum FocusHistory {
    private static var lastFront: [CGWindowID: Date] = [:]
    private static let lock = NSLock()

    static func note(_ snapshot: Snapshot) {
        let current = Set(snapshot.current)
        guard let front = Snapshot.zOrder().first(where: current.contains) else { return }
        lock.lock(); defer { lock.unlock() }
        lastFront[front] = Date()
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

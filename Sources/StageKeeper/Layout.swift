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
}

enum Paths {
    static let directory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StageKeeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let layout = directory.appendingPathComponent("layout.json")
    static let previousLayout = directory.appendingPathComponent("layout.previous.json")
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

    static func load() -> Layout? {
        guard let data = try? Data(contentsOf: Paths.layout) else { return nil }
        return try? decoder.decode(Layout.self, from: data)
    }

    static func write(_ layout: Layout, keepPrevious: Bool) throws {
        if keepPrevious, FileManager.default.fileExists(atPath: Paths.layout.path) {
            try? FileManager.default.removeItem(at: Paths.previousLayout)
            try? FileManager.default.copyItem(at: Paths.layout, to: Paths.previousLayout)
        }
        try encoder.encode(layout).write(to: Paths.layout, options: .atomic)
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
        let snapshot = try Snapshot.take()
        let previous = LayoutStore.load()
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
        let layout = Layout(savedAt: Date(), bootTime: System.bootTime, stages: stages)
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
        DockApps.sync(layout)
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

    /// Labelled stages in shortcut order: alphabetical by label. The first nine get ⌃⌥1–9.
    static func numbered(_ layout: Layout?) -> [SavedStage] {
        (layout?.stages ?? []).filter { $0.label != nil && $0.id != nil }
            .sorted { $0.label!.localizedStandardCompare($1.label!) == .orderedAscending }
    }

    /// Switches to the live stage that matches a saved stage. Blocks for about a second
    /// while it clicks the strip, so call it off the main thread.
    static func switchTo(id: UUID) throws {
        guard let layout = LayoutStore.load(), let saved = layout.stages.firstIndex(where: { $0.id == id }) else {
            throw StageError.other("That stage is no longer in the saved layout.")
        }
        let snapshot = try Snapshot.take()
        let indices = Matcher.savedIndices(layout, snapshot)
        guard let live = indices.firstIndex(of: saved) else {
            let name = layout.stages[saved].label ?? "That stage"
            throw StageError.other("\(name) has no open windows.")
        }
        switchTo(snapshot.stages[live], in: snapshot)
    }

    /// Switches to a live stage by focusing one of its windows, which Stage Manager follows.
    /// Checks that the stage became current; the last attempt clicks the strip thumbnail instead,
    /// which is less reliable because Stage Manager often reports the hidden strip off screen.
    static func switchTo(_ stage: LiveStage, in snapshot: Snapshot) {
        guard stage.kind != .current, let id = FocusHistory.frontmost(of: stage.windowIDs) else { return }
        var snapshot = snapshot
        for attempt in 1...3 {
            if attempt < 3, let window = snapshot.windows[id] {
                AX.focus(window)
            } else if let strip = snapshot.stripItem(containing: id) {
                StripClick.click(strip, shift: false)
            }
            usleep(attempt < 3 ? 600_000 : 500_000)
            guard let after = try? Snapshot.take() else { return }
            if after.current.contains(id) { return }
            Log.write("Stage switch attempt \(attempt) did not take.")
            snapshot = after
        }
    }

    /// Finds a labelled stage by shortcut number (1-based) or by label, ignoring case.
    static func find(_ query: String, in layout: Layout?) -> SavedStage? {
        let list = numbered(layout)
        if let n = Int(query), n >= 1, n <= list.count { return list[n - 1] }
        return list.first { $0.label!.caseInsensitiveCompare(query) == .orderedSame }
    }

    static func describe() throws -> String {
        let snapshot = try Snapshot.take()
        let labels = Matcher.labels(LayoutStore.load(), snapshot)
        var lines: [String] = []
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

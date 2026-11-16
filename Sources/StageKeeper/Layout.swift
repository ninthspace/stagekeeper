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
    var label: String?
    var current: Bool
    var windows: [SavedWindow]
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

    /// For each live stage, the label of the saved stage it overlaps most (each label used once).
    static func labels(_ layout: Layout?, _ snapshot: Snapshot) -> [String?] {
        guard let layout else { return snapshot.stages.map { _ in nil } }
        let matched = match(layout, snapshot, loose: false)
        var pairs: [(overlap: Int, live: Int, saved: Int)] = []
        for (l, live) in snapshot.stages.enumerated() {
            let liveSet = Set(live.windowIDs)
            for (s, saved) in layout.stages.enumerated() where saved.label != nil {
                let overlap = matched[s].compactMap { $0 }.filter(liveSet.contains).count
                if overlap > 0 { pairs.append((overlap, l, s)) }
            }
        }
        var labels = snapshot.stages.map { _ -> String? in nil }
        var usedLive = Set<Int>(), usedSaved = Set<Int>()
        for p in pairs.sorted(by: { $0.overlap > $1.overlap }) where !usedLive.contains(p.live) && !usedSaved.contains(p.saved) {
            labels[p.live] = layout.stages[p.saved].label
            usedLive.insert(p.live)
            usedSaved.insert(p.saved)
        }
        return labels
    }
}

enum Actions {
    /// Captures every stage, carrying labels over from the previous save.
    @discardableResult
    static func save() throws -> Layout {
        let snapshot = try Snapshot.take()
        let labels = Matcher.labels(LayoutStore.load(), snapshot)
        let stages = snapshot.stages.enumerated().map { index, stage in
            SavedStage(
                label: labels[index],
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

    /// Saves, then sets (or clears, when empty) the label of the current stage.
    static func labelCurrent(_ label: String) throws {
        var layout = try save()
        guard let index = layout.stages.firstIndex(where: \.current) else {
            throw StageError.other("There is no current stage with windows to label.")
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        layout.stages[index].label = trimmed.isEmpty ? nil : trimmed
        try LayoutStore.write(layout, keepPrevious: false)
        Log.write(trimmed.isEmpty ? "Cleared current stage label." : "Labelled current stage \"\(trimmed)\".")
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

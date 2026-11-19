import AppKit

/// This desktop's live stages as the radial menu and All stages show them: each with its saved
/// stage, title and windows, most recently used first.
struct StageList {
    struct Window {
        let id: CGWindowID
        let app: String
        let title: String
        let icon: NSImage?
        /// Where the window shows, or for a hidden engine window, where it shows when its stage is current.
        let frame: CGRect
    }

    struct Entry {
        let live: LiveStage
        let saved: SavedStage?
        /// The saved label, else the apps' names.
        let title: String
        let apps: [String]
        /// In stage order, without windows that show on every stage.
        let windows: [Window]
    }

    let snapshot: Snapshot
    let layout: Layout?
    /// For each of `snapshot.stages`, the index of its saved stage in `layout`.
    let indices: [Int?]
    let entries: [Entry]

    var current: Entry? { entries.first { $0.live.kind == .current } }

    static func read() throws -> StageList {
        let snapshot = try Snapshot.take()
        let layout = LayoutStore.load()
        let indices = Matcher.savedIndices(layout, snapshot)
        let hidden = Engine.active ? Engine.hiddenFrames() : [:]
        let everywhere = Everywhere.ids()
        var icons: [pid_t: NSImage] = [:]
        var entries: [Entry] = []
        for (index, live) in snapshot.stages.enumerated() {
            let saved = indices[index].flatMap { layout?.stages[$0] }
            let windows = live.windowIDs.filter { !everywhere.contains($0) }.compactMap { id -> Window? in
                guard let window = snapshot.windows[id] else { return nil }
                if icons[window.pid] == nil { icons[window.pid] = NSRunningApplication(processIdentifier: window.pid)?.icon }
                return Window(id: id, app: window.appName, title: window.title, icon: icons[window.pid], frame: hidden[id] ?? window.frame)
            }
            guard !windows.isEmpty else { continue }
            let apps = windows.map(\.app).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            entries.append(Entry(live: live, saved: saved, title: saved?.label ?? apps.joined(separator: ", "), apps: apps, windows: windows))
        }
        return StageList(snapshot: snapshot, layout: layout, indices: indices,
                         entries: FocusHistory.byRecentUse(entries) { $0.live.windowIDs })
    }
}

import AppKit

/// StageKeeper's own stages, used instead of Stage Manager when Stage Manager is off.
///
/// A stage is a list of windows. Every window belongs to exactly one stage on its desktop; a
/// window StageKeeper has not seen before joins the current stage. Switching moves the current
/// stage's windows off screen, into the bottom-right corner with one point showing (macOS keeps
/// windows on screen otherwise), and moves the new stage's windows back to where they were.
/// Hiding apps would hide every window of an app, and minimising animates and fills the Dock.
///
/// The state is kept on disk so a restart of StageKeeper knows which windows are hidden and
/// where they belong. When StageKeeper quits, every hidden window is put back.
enum Engine {
    static var active: Bool { !Snapshot.stageManagerEnabled }

    struct DesktopState: Codable {
        var stages: [[CGWindowID]] = []
        var current = 0
        /// Where each hidden window was before it was moved off screen, by window ID.
        var hidden: [String: SavedRect] = [:]
    }

    private struct State: Codable {
        var boot: Date?
        var desktops: [String: DesktopState] = [:]
    }

    private static let lock = NSRecursiveLock()
    private static var path: URL { Paths.directory.appendingPathComponent("engine.json") }

    private static func load() -> State {
        guard let data = try? Data(contentsOf: path), let state = try? JSONDecoder().decode(State.self, from: data),
              System.sameBoot(state.boot) else { return State(boot: System.bootTime) }
        return state
    }

    private static func write(_ state: State) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) { try? data.write(to: path, options: .atomic) }
    }

    /// Runs `body` on this desktop's state and writes it back.
    @discardableResult
    private static func edit<T>(_ body: (inout DesktopState) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        var state = load()
        let key = Desktops.current().key
        var desktop = state.desktops[key] ?? seed()
        let result = try body(&desktop)
        state.desktops[key] = desktop
        write(state)
        return result
    }

    /// The first state for a desktop: the stages of the last save, by window ID, so the stages
    /// Stage Manager had carry over.
    private static func seed() -> DesktopState {
        var desktop = DesktopState()
        guard let layout = LayoutStore.load() else { return desktop }
        for stage in layout.stages {
            let ids = stage.windows.compactMap(\.windowID)
            guard !ids.isEmpty else { continue }
            if stage.current { desktop.current = desktop.stages.count }
            desktop.stages.append(ids)
        }
        Log.write("Started StageKeeper's own stages from the last save: \(desktop.stages.count) stages.")
        return desktop
    }

    // MARK: Reading

    /// Brings the state up to date with the windows open now and returns the current stage and
    /// the others. Closed windows leave their stage, empty stages go, and new windows join the
    /// current stage.
    static func stages(_ windows: [CGWindowID: LiveWindow], order: [CGWindowID]) -> (current: [CGWindowID], others: [[CGWindowID]]) {
        edit { desktop in
            let live = Set(windows.keys)
            for i in desktop.stages.indices { desktop.stages[i].removeAll { !live.contains($0) } }
            desktop.hidden = desktop.hidden.filter { live.contains(CGWindowID($0.key) ?? 0) }
            // Empty stages go, except the current one: when its last window closes, the screen
            // stays empty and the next window opened joins it, as on a fresh desktop.
            var kept: [[CGWindowID]] = []
            var current = 0
            for (index, stage) in desktop.stages.enumerated() where !stage.isEmpty || index == desktop.current {
                if index == desktop.current { current = kept.count }
                kept.append(stage)
            }
            if kept.isEmpty { kept = [[]] }
            desktop.stages = kept
            desktop.current = current
            let known = Set(kept.joined())
            for id in order where !known.contains(id) {
                desktop.stages[current].append(id)
                if let window = windows[id] { bringOnScreen(window) }
            }
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let sorted = desktop.stages.map { $0.sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) } }
            return (sorted[current], sorted.enumerated().filter { $0.offset != current }.map(\.element))
        }
    }

    nonisolated(unsafe) private static var seen: Set<CGWindowID> = []

    /// Reads the stages as soon as a window opens, so it joins the current stage (and comes on
    /// screen if it opened in the hiding corner) within a fraction of a second. The window list
    /// is cheap to read; the full read runs only when it shows a window not seen before.
    static func noticeNewWindows() {
        let now = Set(Snapshot.zOrder())
        lock.lock()
        let fresh = !now.subtracting(seen).isEmpty
        seen = now
        lock.unlock()
        if fresh { _ = try? Snapshot.take() }
    }

    /// Switches to the stage of the focused window when you bring a hidden window forward
    /// yourself, with ⌘Tab, the Dock or a window menu.
    static func follow() {
        guard active, let app = NSWorkspace.shared.frontmostApplication,
              let element = AX.value(AX.application(app.processIdentifier), kAXFocusedWindowAttribute),
              let id = AX.windowID(element as! AXUIElement), isHidden(id) else { return }
        Log.write("The focused \(app.localizedName ?? "") window is in a hidden stage; switching to it.")
        try? activate(stageWith: id, focus: id)
    }

    // MARK: Acting

    /// Shows the stage holding `window`, hiding the current one, and brings `focus` (or the
    /// stage's last front window) to the front.
    static func activate(stageWith window: CGWindowID, focus: CGWindowID? = nil) throws {
        let snapshot = try Snapshot.take()
        edit { desktop in
            guard let target = desktop.stages.firstIndex(where: { $0.contains(window) }), target != desktop.current else { return }
            hide(stage: desktop.current, in: &desktop, windows: snapshot.windows)
            desktop.current = target
            show(stage: target, in: &desktop, windows: snapshot.windows)
        }
        bringForward(focus ?? FocusHistory.frontmost(of: (try? Snapshot.take())?.current ?? []) ?? window)
    }

    /// Moves windows into the stage holding `target` (or into a new stage when `target` is nil),
    /// hiding them when that stage is not showing. A stage left empty goes.
    static func move(_ ids: [CGWindowID], toStageWith target: CGWindowID?) throws {
        let snapshot = try Snapshot.take()
        edit { desktop in
            let currentWindows = desktop.stages[desktop.current]
            for i in desktop.stages.indices { desktop.stages[i].removeAll { ids.contains($0) } }
            var destination: Int
            if let target, let index = desktop.stages.firstIndex(where: { $0.contains(target) }) {
                destination = index
                desktop.stages[index].append(contentsOf: ids)
            } else {
                desktop.stages.append(ids)
                destination = desktop.stages.count - 1
            }
            let showing = destination == desktop.current
            for id in ids {
                if showing { unhide(id, in: &desktop, windows: snapshot.windows) } else { hideWindow(id, in: &desktop, windows: snapshot.windows) }
            }
            // Moving every window out of the current stage goes with them.
            if !currentWindows.isEmpty, desktop.stages[desktop.current].isEmpty {
                desktop.stages.remove(at: desktop.current)
                if destination > desktop.current { destination -= 1 }
                desktop.current = destination
                show(stage: destination, in: &desktop, windows: snapshot.windows)
            }
        }
    }

    /// Whether any window is off screen in a hidden stage, on any desktop.
    static var hasHidden: Bool {
        lock.lock(); defer { lock.unlock() }
        return load().desktops.values.contains { !$0.hidden.isEmpty }
    }

    /// Puts every hidden window back where it was, on every desktop StageKeeper can reach.
    /// Called when StageKeeper quits, so no window is left off screen.
    static func revealAll() {
        lock.lock(); defer { lock.unlock() }
        var state = load()
        guard let snapshot = try? Snapshot.take() else { return }
        var count = 0
        for key in state.desktops.keys {
            for (id, frame) in state.desktops[key]!.hidden {
                guard let window = snapshot.windows[CGWindowID(id) ?? 0] else { continue }
                AX.setFrame(window.element, frame.cgRect)
                count += 1
            }
            state.desktops[key]!.hidden = [:]
        }
        write(state)
        if count > 0 { Log.write("Put \(count) hidden windows back on screen.") }
    }

    /// Applies the state to the screen: hides every stage but the current one. Called when
    /// StageKeeper starts, after `revealAll` put everything back when it last quit.
    static func apply() {
        guard let snapshot = try? Snapshot.take() else { return }
        edit { desktop in
            for i in desktop.stages.indices where i != desktop.current { hide(stage: i, in: &desktop, windows: snapshot.windows) }
            show(stage: desktop.current, in: &desktop, windows: snapshot.windows)
        }
    }

    // MARK: Moving windows

    private static func hide(stage index: Int, in desktop: inout DesktopState, windows: [CGWindowID: LiveWindow]) {
        guard desktop.stages.indices.contains(index) else { return }
        let everywhere = Everywhere.ids()
        for id in desktop.stages[index] where !everywhere.contains(id) { hideWindow(id, in: &desktop, windows: windows) }
    }

    private static func show(stage index: Int, in desktop: inout DesktopState, windows: [CGWindowID: LiveWindow]) {
        guard desktop.stages.indices.contains(index) else { return }
        for id in desktop.stages[index] { unhide(id, in: &desktop, windows: windows) }
    }

    private static func hideWindow(_ id: CGWindowID, in desktop: inout DesktopState, windows: [CGWindowID: LiveWindow]) {
        guard desktop.hidden[String(id)] == nil, let window = windows[id], let frame = AX.frame(window.element) else { return }
        desktop.hidden[String(id)] = SavedRect(frame)
        let corner = hidingCorner
        AX.setFrame(window.element, CGRect(origin: corner, size: frame.size))
    }

    private static func unhide(_ id: CGWindowID, in desktop: inout DesktopState, windows: [CGWindowID: LiveWindow]) {
        guard let frame = desktop.hidden.removeValue(forKey: String(id)), let window = windows[id] else { return }
        AX.setFrame(window.element, frame.cgRect)
    }

    /// Moves a new window onto the main screen when it opened mostly off screen. Apps place a new
    /// window by their last one, which may be hidden in the corner.
    private static func bringOnScreen(_ window: LiveWindow) {
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let visible = NSScreen.screens.map { screen -> CGFloat in
            let f = screen.frame
            let ax = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            let overlap = ax.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }.reduce(0, +)
        guard visible < frame.width * frame.height / 2, let main = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = main.visibleFrame
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        let origin = CGPoint(x: area.midX - size.width / 2, y: primaryHeight - area.midY - size.height / 2)
        AX.setFrame(window.element, CGRect(origin: origin, size: size))
        Log.write("The new \(window.appName) window opened off screen; moved it to the middle of the screen.")
    }

    /// The bottom-right corner of all screens, in Accessibility coordinates (origin at the top
    /// left of the main screen), less one point so macOS leaves the window where it is put.
    private static var hidingCorner: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let right = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        let bottom = NSScreen.screens.map { primaryHeight - $0.frame.minY }.max() ?? 0
        return CGPoint(x: right - 1, y: bottom - 1)
    }

    static func bringForward(_ id: CGWindowID) {
        guard let window = (try? Snapshot.take())?.windows[id] else { return }
        AX.focus(window)
    }

    /// Whether a window is in a stage that is not showing.
    static func isHidden(_ id: CGWindowID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return load().desktops[Desktops.current().key]?.hidden[String(id)] != nil
    }
}

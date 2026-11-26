import AppKit

/// StageKeeper's stages. StageKeeper pauses while Stage Manager is on.
///
/// A stage is a list of windows. Every window belongs to exactly one stage on its desktop; a
/// window StageKeeper has not seen before joins the current stage. Switching moves the current
/// stage's windows off screen, into the bottom-right corner of the rightmost screen with one
/// point showing (macOS keeps windows on screen otherwise), and moves the new stage's windows
/// back to where they were. Hiding apps would hide every window of an app, and minimising
/// animates and fills the Dock.
///
/// The state is kept on disk so a restart of StageKeeper knows which windows are hidden and
/// where they belong. When StageKeeper quits, every hidden window it can reach is put back.
///
/// Window moves happen outside the lock: the state is planned under it, then the windows are
/// moved, so the main thread never waits on a slow app.
enum Engine {
    nonisolated(unsafe) private static var activeCache: (value: Bool, at: Date)?

    /// Whether Stage Manager is off, read at most once a second.
    static var active: Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached = activeCache, Date().timeIntervalSince(cached.at) < 1 { return cached.value }
        let value = !Snapshot.stageManagerEnabled
        activeCache = (value, Date())
        return value
    }

    /// One stage: its windows, and the saved stage (label, colour, shortcut) it is. A stage keeps
    /// its saved stage when windows come and go; a new stage has none.
    struct Stage: Codable {
        var windows: [CGWindowID]
        var savedID: UUID?
    }

    struct DesktopState: Codable {
        var stages: [Stage] = []
        var current = 0
        /// Where each hidden window was before it was moved off screen, by window ID.
        var hidden: [String: SavedRect] = [:]

        init() {}

        enum CodingKeys: String, CodingKey { case stages, current, hidden, savedIDs }

        /// Reads both this shape and the earlier one, where `stages` was a list of window-ID
        /// lists and `savedIDs` a parallel list. Missing fields take their defaults.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            current = try container.decodeIfPresent(Int.self, forKey: .current) ?? 0
            hidden = try container.decodeIfPresent([String: SavedRect].self, forKey: .hidden) ?? [:]
            if let records = try? container.decode([Stage].self, forKey: .stages) {
                stages = records
            } else {
                let lists = (try? container.decode([[CGWindowID]].self, forKey: .stages)) ?? []
                let ids = (try? container.decode([UUID?].self, forKey: .savedIDs)) ?? []
                stages = lists.enumerated().map { Stage(windows: $1, savedID: $0 < ids.count ? ids[$0] : nil) }
            }
            if !stages.indices.contains(current) { current = 0 }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stages, forKey: .stages)
            try container.encode(current, forKey: .current)
            try container.encode(hidden, forKey: .hidden)
        }

        func stageIndex(of id: CGWindowID) -> Int? { stages.firstIndex { $0.windows.contains(id) } }
        func isHidden(_ id: CGWindowID) -> Bool { hidden[String(id)] != nil }
    }

    private struct State: Codable {
        var boot: Date?
        var desktops: [String: DesktopState] = [:]

        init(boot: Date?) { self.boot = boot }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            boot = try container.decodeIfPresent(Date.self, forKey: .boot)
            desktops = try container.decodeIfPresent([String: DesktopState].self, forKey: .desktops) ?? [:]
        }
    }

    /// A planned window move, made after the lock is released.
    private typealias Move = (element: AXUIElement, frame: CGRect)

    private static let lock = NSRecursiveLock()
    private static var path: URL { Paths.directory.appendingPathComponent("engine.json") }

    // MARK: State on disk

    /// The state as last read or written, and the file's modification date then. The command-line
    /// tool writes the same file, so a newer file is read again.
    nonisolated(unsafe) private static var cache: State?
    nonisolated(unsafe) private static var cacheDate: Date?
    nonisolated(unsafe) private static var written: Data?

    private static func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    }

    private static func load() -> State {
        let date = modified()
        if let cache, date == cacheDate { return cache }
        var state = State(boot: System.bootTime)
        if let data = try? Data(contentsOf: path) {
            do {
                let decoded = try JSONDecoder().decode(State.self, from: data)
                if System.sameBoot(decoded.boot) { state = decoded }
                written = data
            } catch {
                // Keep the file rather than lose the frames of hidden windows.
                let backup = Paths.directory.appendingPathComponent("engine.unreadable.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: path, to: backup)
                Log.write("Could not read engine.json (\(error)); kept a copy as engine.unreadable.json.")
            }
        }
        cache = state
        cacheDate = date
        return state
    }

    /// Writes the state when it differs from what is on disk.
    private static func write(_ state: State) {
        cache = state
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state), data != written else { return }
        try? data.write(to: path, options: .atomic)
        written = data
        cacheDate = modified()
    }

    /// Runs `body` on this desktop's state and writes it back. A desktop seen for the first time
    /// starts from the last save, matched against `windows` when given.
    @discardableResult
    private static func edit<T>(seedingFrom windows: [CGWindowID: LiveWindow]? = nil, order: [CGWindowID] = [],
                                _ body: (inout DesktopState) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        var state = load()
        let key = Desktops.current().key
        var desktop = state.desktops[key] ?? seed(windows, order: order)
        let result = try body(&desktop)
        state.desktops[key] = desktop
        write(state)
        return result
    }

    private static func read() -> DesktopState? {
        lock.lock(); defer { lock.unlock() }
        return load().desktops[Desktops.current().key]
    }

    /// The first state for a desktop: the stages of the last save. Window IDs are used only within the boot they were saved in, since macOS
    /// reuses them; otherwise windows are matched by app and title.
    private static func seed(_ windows: [CGWindowID: LiveWindow]?, order: [CGWindowID]) -> DesktopState {
        var desktop = DesktopState()
        guard let layout = LayoutStore.load() else { return desktop }
        let groups: [[CGWindowID]]
        if System.sameBoot(layout.bootTime) {
            groups = layout.stages.map { $0.windows.compactMap(\.windowID) }
        } else if let windows {
            let snapshot = Snapshot(windows: windows, order: order, current: order, stages: [])
            groups = Matcher.match(layout, snapshot, loose: false).map { $0.compactMap { $0 } }
        } else {
            groups = []
        }
        for (stage, ids) in zip(layout.stages, groups) where !ids.isEmpty {
            if stage.current { desktop.current = desktop.stages.count }
            desktop.stages.append(Stage(windows: ids, savedID: stage.isIdentified ? stage.id : nil))
        }
        Log.write("Started StageKeeper's own stages from the last save: \(desktop.stages.count) stages.")
        return desktop
    }

    /// Replaces this desktop's stages with the saved ones in `layout`, using `matched` (each saved
    /// stage's windows matched to live ones). Windows not in the save stay together as they were.
    /// The saved stage that was current becomes current, and windows go back to their saved
    /// frames: shown ones now, hidden ones when their stage next shows.
    static func rebuild(_ layout: Layout, matched: [[CGWindowID?]], snapshot: Snapshot) {
        var frames: [CGWindowID: CGRect] = [:]
        edit(seedingFrom: snapshot.windows, order: snapshot.order) { desktop in
            let placed = Set(matched.joined().compactMap { $0 })
            var stages: [Stage] = []
            var current: Int?
            for (s, saved) in layout.stages.enumerated() where s < matched.count {
                let ids = matched[s].compactMap { $0 }
                guard !ids.isEmpty else { continue }
                if saved.current { current = stages.count }
                stages.append(Stage(windows: ids, savedID: saved.isIdentified ? saved.id : nil))
                for (w, id) in matched[s].enumerated() where w < saved.windows.count {
                    if let id { frames[id] = saved.windows[w].frame.cgRect }
                }
            }
            let claimed = Set(stages.compactMap(\.savedID))
            for old in desktop.stages {
                let rest = old.windows.filter { !placed.contains($0) }
                guard !rest.isEmpty else { continue }
                stages.append(Stage(windows: rest, savedID: old.savedID.flatMap { claimed.contains($0) ? nil : $0 }))
            }
            desktop.stages = stages
            desktop.current = min(current ?? 0, max(stages.count - 1, 0))
        }
        reconcile(force: true)
        var shown: Set<CGWindowID> = []
        edit { desktop in
            if desktop.stages.indices.contains(desktop.current) { shown = Set(desktop.stages[desktop.current].windows) }
            for (id, frame) in frames where desktop.isHidden(id) { desktop.hidden[String(id)] = SavedRect(frame) }
        }
        for (id, frame) in frames where shown.contains(id) {
            if let window = snapshot.windows[id] { AX.setFrame(window.element, frame) }
        }
        Log.write("Rebuilt this desktop's stages from the save.")
    }

    // MARK: Reading

    /// Brings the state up to date with the windows open now and returns the current stage and
    /// the others. Closed windows leave their stage, empty stages go, and new windows join the
    /// current stage.
    ///
    /// A window leaves its stage only when the window server no longer has it. Accessibility
    /// can briefly report no windows, or only some, while the Mac wakes or the screen is locked;
    /// dropping those windows would make them new windows on the next read and put every one in
    /// the current stage.
    static func stages(_ windows: [CGWindowID: LiveWindow], order: [CGWindowID]) -> (current: Stage, others: [Stage]) {
        let existing = Set(Snapshot.serverWindows().keys)
        let claimed = hiddenWindows().elsewhere
        var placeOnScreen: [LiveWindow] = []
        let result = edit(seedingFrom: windows, order: order) { desktop -> (Stage, [Stage]) in
            // A window another desktop hid is that desktop's, even if this desktop took it in.
            for i in desktop.stages.indices { desktop.stages[i].windows.removeAll(where: claimed.contains) }
            desktop.hidden = desktop.hidden.filter { !claimed.contains(CGWindowID($0.key) ?? 0) }
            prune(&desktop, existing: existing)
            for id in order where desktop.stageIndex(of: id) == nil {
                guard let window = windows[id] else { continue }
                if let stage = tabGroupStage(of: window, in: desktop, windows: windows) {
                    // A hidden tab group's new tab is in the corner with it, and goes back with it.
                    desktop.stages[stage].windows.append(id)
                    if stage != desktop.current,
                       let sibling = desktop.stages[stage].windows.first(where: { desktop.isHidden($0) && windows[$0]?.pid == window.pid }) {
                        desktop.hidden[String(id)] = desktop.hidden[String(sibling)]
                    }
                    continue
                }
                desktop.stages[desktop.current].windows.append(id)
                if Screens.visibleFraction(of: window.frame) < 0.5 { placeOnScreen.append(window) }
            }
            return view(desktop, windows: windows, order: order)
        }
        placeOnScreen.forEach(bringOnScreen)
        return result
    }

    /// Drops closed windows and their frames, and empty stages other than the current one: when
    /// its last window closes, the screen stays empty and the next window opened joins it.
    private static func prune(_ desktop: inout DesktopState, existing: Set<CGWindowID>) {
        if !existing.isEmpty {
            for i in desktop.stages.indices { desktop.stages[i].windows.removeAll { !existing.contains($0) } }
            desktop.hidden = desktop.hidden.filter { existing.contains(CGWindowID($0.key) ?? 0) }
        }
        var kept: [Stage] = []
        var current = 0
        for (index, stage) in desktop.stages.enumerated() where !stage.windows.isEmpty || index == desktop.current {
            if index == desktop.current { current = kept.count }
            kept.append(stage)
        }
        desktop.stages = kept.isEmpty ? [Stage(windows: [], savedID: nil)] : kept
        desktop.current = current
    }

    /// The stages as callers see them: only windows Accessibility reported, front to back.
    private static func view(_ desktop: DesktopState, windows: [CGWindowID: LiveWindow], order: [CGWindowID]) -> (Stage, [Stage]) {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let stages = desktop.stages.map { stage in
            Stage(windows: stage.windows.filter { windows[$0] != nil }.sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) },
                  savedID: stage.savedID)
        }
        let others = stages.indices.filter { $0 != desktop.current && !stages[$0].windows.isEmpty }.map { stages[$0] }
        return (stages[desktop.current], others)
    }

    /// The stage of another tab of `window`'s tab group (Ghostty, Finder): each tab is a window
    /// of its own, a background tab is new when it comes forward, and it shares its group's
    /// frame. A window on screen is compared with windows on screen; one in the hiding corner
    /// with hidden windows, where every window shares the corner, so the size decides.
    private static func tabGroupStage(of window: LiveWindow, in desktop: DesktopState, windows: [CGWindowID: LiveWindow]) -> Int? {
        let offScreen = Screens.visibleFraction(of: window.frame) < 0.1
        let candidates = desktop.stages.indices.filter { index in
            desktop.stages[index].windows.contains { id in
                guard id != window.id, let other = windows[id], other.pid == window.pid,
                      desktop.isHidden(id) == offScreen else { return false }
                return Screens.sameFrame(other.frame, window.frame)
            }
        }
        if candidates.contains(desktop.current) { return desktop.current }
        return candidates.first
    }

    /// Takes the saved stage IDs from a layout just written for this desktop: each saved stage
    /// whose windows are all in one stage becomes that stage's saved stage. Called after every
    /// layout write, so labelling or colouring a stage, or giving it another stage's name, sticks
    /// to that stage. The first saved stage to claim a stage wins: a save lists the stages open
    /// now before labelled stages with no open windows, whose window IDs may since have moved.
    static func adopt(_ layout: Layout) {
        guard active, System.sameBoot(layout.bootTime),
              (layout.desktop ?? Desktops.current().key) == Desktops.current().key else { return }
        edit { desktop in
            var claimed = Set<Int>()
            for saved in layout.stages {
                guard let id = saved.id else { continue }
                let windows = saved.windows.compactMap(\.windowID)
                guard let first = windows.first, let index = desktop.stageIndex(of: first), !claimed.contains(index),
                      windows.allSatisfy(desktop.stages[index].windows.contains) else { continue }
                claimed.insert(index)
                for i in desktop.stages.indices where desktop.stages[i].savedID == id { desktop.stages[i].savedID = nil }
                desktop.stages[index].savedID = saved.isIdentified ? id : nil
            }
        }
    }

    nonisolated(unsafe) private static var seen: Set<CGWindowID> = []

    /// Reads the stages as soon as a window opens, so it joins the current stage (and comes on
    /// screen if it opened in the hiding corner) within a fraction of a second. Only on-screen
    /// window IDs are read; the full read runs only when one appears that was not seen before.
    static func noticeNewWindows() {
        let now = Snapshot.onScreenAppWindowIDs()
        lock.lock()
        let fresh = !now.subtracting(seen).isEmpty
        seen = now
        lock.unlock()
        if fresh { _ = try? Snapshot.take() }
    }

    // MARK: Following focus

    nonisolated(unsafe) private static var lastFocused: CGWindowID?
    nonisolated(unsafe) private static var lastChange = Date.distantPast

    /// Whether StageKeeper switched or moved in the last 1.5 s. Until the new stage's app comes
    /// forward, the app you left still reports its now hidden window as focused.
    private static var settling: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastChange) < 1.5
    }

    /// Notes that StageKeeper changed the stages, so focus is left to settle.
    private static func changed() {
        lock.lock(); lastChange = Date(); lock.unlock()
    }

    /// Switches to the stage of the focused window when you bring a window of another stage
    /// forward yourself, with ⌘Tab, the Dock, a window menu or Mission Control. Acts only when
    /// the focused window changes, and not while settling.
    static func follow() {
        guard active, let (app, id) = AX.focusedWindow() else { return }
        let settling = settling
        lock.lock()
        let changed = id != lastFocused
        if !settling { lastFocused = id }
        lock.unlock()
        guard changed, !settling else { return }
        if inOtherStage(id) {
            Log.write("The focused \(app.localizedName ?? "") window is in another stage; switching to it.")
            try? activate(stageWith: id, focus: id)
        } else if let owner = owner(ofHidden: id) {
            // Hidden windows sit on the rightmost screen, so bringing one forward from Mission
            // Control or the Dock makes that display's desktop active. Switch the stage on the
            // desktop that hid it, which brings the window back to its own display.
            Log.write("The focused \(app.localizedName ?? "") window is hidden by desktop \(owner.number)'s stages; switching to it there.")
            Desktops.acting(as: owner) { try? activate(stageWith: id, focus: id) }
        }
    }

    /// The desktop, other than the active one, that hid `id`, when that desktop is showing on
    /// its display. A desktop not showing has nowhere to put the window back.
    private static func owner(ofHidden id: CGWindowID) -> Desktop? {
        let key = Desktops.current().key
        let found: String? = {
            lock.lock(); defer { lock.unlock() }
            return load().desktops.first { $0.key != key && $0.value.isHidden(id) }?.key
        }()
        guard let found, let desktop = Desktops.all().first(where: { $0.key == found }),
              Desktops.showing().contains(desktop.spaceID) else { return nil }
        return desktop
    }

    /// Switches to the focused window's stage now if it is not the current one, so an action on
    /// "the current stage" acts on the stage you are looking at. Called before the radial menu
    /// reads the stages and before a window is moved; not while settling.
    static func matchFocus() {
        guard active, !settling, let (_, id) = AX.focusedWindow(), inOtherStage(id) else { return }
        try? activate(stageWith: id, focus: id)
    }

    private static func inOtherStage(_ id: CGWindowID) -> Bool {
        guard let desktop = read(), let index = desktop.stageIndex(of: id) else { return false }
        return index != desktop.current
    }

    // MARK: Keeping the screen in step

    nonisolated(unsafe) private static var lastScreens: [CGRect] = []
    /// Windows the last full read could not act on, with their frame then: Accessibility does
    /// not list them (a tab group's background tabs, some apps' windows on another desktop), so
    /// they look out of step to the cheap check every time. Skipped by the cheap check until
    /// their frame changes, so they do not cause a full read every two seconds.
    nonisolated(unsafe) private static var unreachable: [CGWindowID: CGRect] = [:]

    /// The modification date of the engine state, which changes whenever the stages do.
    static var stateDate: Date? { modified() }

    /// Makes the screen match the state when they differ: hides windows of other stages that
    /// are showing, shows hidden windows of the current stage, brings a window of the current
    /// stage that is lost off screen back to the middle, and re-hides hidden windows when the
    /// screens change. This catches a window that was missed when its stage was switched (an
    /// app that did not answer), the stages of a desktop seen for the first time, and Stage
    /// Manager being turned off while StageKeeper runs. A cheap read of the window server
    /// decides whether the full read is needed.
    ///
    /// Not while settling or while the focused window is in another stage: `follow` is about
    /// to switch to it, and hiding it would undo what you did.
    static func reconcile(force: Bool = false) {
        guard active, force || !settling else { return }
        if !force, let desktop = read(), let (_, id) = AX.focusedWindow(),
           let index = desktop.stageIndex(of: id), index != desktop.current { return }
        let screens = NSScreen.screens.map(\.frame)
        lock.lock()
        let screensChanged = !lastScreens.isEmpty && screens != lastScreens
        lastScreens = screens
        lock.unlock()
        let server = Snapshot.serverWindows()
        if !force, let desktop = read() {
            lock.lock()
            let skipped = unreachable
            lock.unlock()
            let wrong = desktop.stages.indices.contains { index in
                desktop.stages[index].windows.contains { id in
                    guard let frame = server[id]?.frame else { return false }
                    if let then = skipped[id], Screens.sameFrame(then, frame) { return false }
                    let showing = Screens.visibleFraction(of: frame) >= 0.1
                    return index == desktop.current ? desktop.isHidden(id) || !showing : !desktop.isHidden(id) && showing
                }
            }
            guard wrong || (screensChanged && !desktop.hidden.isEmpty) else { return }
        }
        guard let snapshot = try? Snapshot.take() else { return }
        var moves: [Move] = []
        var lost: [LiveWindow] = []
        var missed: [CGWindowID: CGRect] = [:]
        edit { desktop in
            let corner = Screens.hidingCorner
            for (index, stage) in desktop.stages.enumerated() {
                for id in stage.windows {
                    guard let window = snapshot.windows[id] else {
                        if let frame = server[id]?.frame { missed[id] = frame }
                        continue
                    }
                    let showing = Screens.visibleFraction(of: window.frame) >= 0.1
                    if index != desktop.current {
                        if desktop.isHidden(id) {
                            if screensChanged { moves.append((window.element, CGRect(origin: corner, size: window.frame.size))) }
                        } else if showing {
                            planHide(id, in: &desktop, windows: snapshot.windows, moves: &moves)
                        }
                    } else if desktop.isHidden(id) {
                        planShow(id, in: &desktop, windows: snapshot.windows, moves: &moves)
                    } else if !showing {
                        lost.append(window)
                    }
                }
            }
        }
        lock.lock()
        unreachable = missed
        lock.unlock()
        perform(moves)
        lost.forEach(bringOnScreen)
        if !moves.isEmpty || !lost.isEmpty {
            Log.write("Put the screen in step with the stages: moved \(moves.count) windows, brought \(lost.count) back on screen.")
        }
    }

    // MARK: Acting

    /// Shows the stage holding `window`, hiding the current one, and brings `focus` (or the
    /// stage's last front window) to the front. Bookmarked windows of the current stage move
    /// into the stage shown. A stage left with no windows goes. Pass a snapshot taken for the same action to
    /// save reading the windows again.
    static func activate(stageWith window: CGWindowID, focus: CGWindowID? = nil, snapshot given: Snapshot? = nil) throws {
        try activate(stageWith: window, focus: focus, snapshot: given, step: nil)
    }

    /// `step` is set when Back or Forward makes the switch, which records the stage left on the
    /// other list instead of starting a new path.
    private static func activate(stageWith window: CGWindowID, focus: CGWindowID?, snapshot given: Snapshot?, step: Step?) throws {
        changed()
        defer { changed() }
        let snapshot = try given ?? Snapshot.take()
        let bookmarked = Pins.resolve(snapshot)
        let server = bookmarked.isEmpty ? [:] : Snapshot.serverWindows()
        var moves: [Move] = []
        var shown: [CGWindowID] = []
        var carried: [CGWindowID] = []
        edit { desktop in
            guard var target = desktop.stageIndex(of: window) else { return }
            shown = desktop.stages[target].windows
            guard target != desktop.current else { return }
            // Bookmarked windows of the stage being left join the target stage, with their
            // background tabs, and stay where they are on screen.
            let leaving = desktop.current
            carried = desktop.stages[leaving].windows.filter { bookmarked.contains($0) }
            for id in carried {
                guard let pid = snapshot.windows[id]?.pid else { continue }
                carried += desktop.stages[leaving].windows.filter { snapshot.windows[$0] == nil && server[$0]?.pid == pid && !carried.contains($0) }
            }
            if !carried.isEmpty {
                desktop.stages[leaving].windows.removeAll { carried.contains($0) }
                desktop.stages[target].windows += carried
            }
            record(left: desktop.stages[leaving].windows, step: step)
            hide(stage: leaving, in: &desktop, windows: snapshot.windows, moves: &moves)
            if desktop.stages[leaving].windows.isEmpty {
                desktop.stages.remove(at: leaving)
                if target > leaving { target -= 1 }
            }
            desktop.current = target
            show(stage: target, in: &desktop, windows: snapshot.windows, moves: &moves)
        }
        perform(moves)
        if !carried.isEmpty { Log.write("Carried \(carried.count) bookmarked windows into the stage switched to.") }
        let front = focus ?? FocusHistory.frontmost(of: shown.filter { snapshot.windows[$0] != nil }) ?? window
        if let element = snapshot.windows[front] { AX.focus(element) }
    }

    // MARK: Back and forward

    enum Step { case back, forward }

    /// Each desktop's stage switches, as browsers keep pages: `back` holds the stages left, most
    /// recent last, and `forward` the stages Back left. A stage is recorded as its windows, and
    /// found again as the stage holding the first of them still open, so it survives stages
    /// being added, removed or reordered. Kept in memory only.
    private struct History {
        var back: [[CGWindowID]] = []
        var forward: [[CGWindowID]] = []
    }

    nonisolated(unsafe) private static var histories: [String: History] = [:]
    private static let historyLimit = 50

    /// Records the stage being left on this desktop. Called under the lock.
    private static func record(left windows: [CGWindowID], step: Step?) {
        guard !windows.isEmpty else { return }
        let key = Desktops.current().key
        var history = histories[key] ?? History()
        switch step {
        case nil:
            history.back.append(windows)
            history.forward = []
        case .back:
            history.forward.append(windows)
        case .forward:
            history.back.append(windows)
        }
        history.back = Array(history.back.suffix(historyLimit))
        history.forward = Array(history.forward.suffix(historyLimit))
        histories[key] = history
    }

    /// Switches to the stage before (or after) the current one in this desktop's history,
    /// skipping stages that have since closed or are current. False when there is none.
    @discardableResult
    static func go(_ step: Step) throws -> Bool {
        let target: CGWindowID? = {
            lock.lock(); defer { lock.unlock() }
            guard let desktop = read() else { return nil }
            let key = Desktops.current().key
            var history = histories[key] ?? History()
            defer { histories[key] = history }
            while let entry = step == .back ? history.back.popLast() : history.forward.popLast() {
                if let id = entry.first(where: { desktop.stageIndex(of: $0).map { $0 != desktop.current } ?? false }) { return id }
            }
            return nil
        }()
        guard let target else { return false }
        try activate(stageWith: target, focus: nil, snapshot: nil, step: step)
        return true
    }

    /// Moves windows into the stage holding `target` (or into a new stage when `target` is nil),
    /// hiding them when that stage is not showing. A stage left empty goes. Background tabs of a
    /// moved window go with it: Accessibility lists only a tab group's selected tab, so they are
    /// the stage's unlisted windows of the same app.
    static func move(_ ids: [CGWindowID], toStageWith target: CGWindowID?, snapshot given: Snapshot? = nil) throws {
        changed()
        defer { changed() }
        let snapshot = try given ?? Snapshot.take()
        let server = Snapshot.serverWindows()
        var moves: [Move] = []
        edit { desktop in
            var moving = ids
            for id in ids {
                guard let pid = snapshot.windows[id]?.pid, let source = desktop.stageIndex(of: id) else { continue }
                moving += desktop.stages[source].windows.filter { snapshot.windows[$0] == nil && server[$0]?.pid == pid && !moving.contains($0) }
            }
            let currentWindows = desktop.stages[desktop.current].windows
            for i in desktop.stages.indices { desktop.stages[i].windows.removeAll { moving.contains($0) } }
            var destination: Int
            if let target, let index = desktop.stageIndex(of: target) {
                destination = index
                desktop.stages[index].windows += moving
            } else {
                desktop.stages.append(Stage(windows: moving, savedID: nil))
                destination = desktop.stages.count - 1
            }
            let showing = destination == desktop.current
            for id in ids {
                if showing {
                    planShow(id, in: &desktop, windows: snapshot.windows, moves: &moves)
                } else {
                    planHide(id, in: &desktop, windows: snapshot.windows, moves: &moves)
                }
            }
            // Moving every window out of the current stage goes with them.
            if !currentWindows.isEmpty, desktop.stages[desktop.current].windows.isEmpty {
                desktop.stages.remove(at: desktop.current)
                if destination > desktop.current { destination -= 1 }
                desktop.current = destination
                show(stage: destination, in: &desktop, windows: snapshot.windows, moves: &moves)
            }
        }
        perform(moves)
    }

    /// Ends the live stage that is the saved stage `id`, on the desktop `key`: its windows join
    /// that desktop's current stage. On the desktop showing they come on screen now; on another
    /// desktop `reconcile` brings them back when it shows. The current stage itself keeps its
    /// windows and only stops being that saved stage.
    static func dissolve(savedID id: UUID, on key: String) throws {
        changed()
        defer { changed() }
        let here = key == Desktops.current().key
        let snapshot = here ? try Snapshot.take() : nil
        var moves: [Move] = []
        lock.lock()
        var state = load()
        if var desktop = state.desktops[key], let index = desktop.stages.firstIndex(where: { $0.savedID == id }) {
            if index == desktop.current {
                desktop.stages[index].savedID = nil
            } else {
                let windows = desktop.stages.remove(at: index).windows
                if index < desktop.current { desktop.current -= 1 }
                desktop.stages[desktop.current].windows += windows
                if let snapshot {
                    for window in windows { planShow(window, in: &desktop, windows: snapshot.windows, moves: &moves) }
                }
            }
            state.desktops[key] = desktop
            write(state)
        }
        lock.unlock()
        perform(moves)
    }

    /// Whether any window is off screen in a hidden stage, on any desktop.
    static var hasHidden: Bool {
        lock.lock(); defer { lock.unlock() }
        return load().desktops.values.contains { !$0.hidden.isEmpty }
    }

    /// Puts every hidden window StageKeeper can reach back where it was. Called when StageKeeper
    /// quits and when Stage Manager is turned on. Accessibility lists only the windows of
    /// the desktops showing, so windows hidden on another desktop keep their record and are put
    /// back when that desktop shows.
    static func revealAll() {
        let windows = Snapshot.accessibleWindows()
        lock.lock(); defer { lock.unlock() }
        var state = load()
        var count = 0, left = 0
        for key in state.desktops.keys {
            for (id, frame) in state.desktops[key]!.hidden {
                guard let window = windows[CGWindowID(id) ?? 0] else { left += 1; continue }
                AX.setFrame(window.element, frame.cgRect)
                state.desktops[key]!.hidden.removeValue(forKey: id)
                count += 1
            }
        }
        write(state)
        if count > 0 { Log.write("Put \(count) hidden windows back on screen.") }
        if left > 0 { Log.write("\(left) hidden windows on other desktops go back when their desktop shows.") }
    }

    // MARK: Moving windows

    private static func hide(stage index: Int, in desktop: inout DesktopState, windows: [CGWindowID: LiveWindow], moves: inout [Move]) {
        guard desktop.stages.indices.contains(index) else { return }
        for id in desktop.stages[index].windows { planHide(id, in: &desktop, windows: windows, moves: &moves) }
    }

    private static func show(stage index: Int, in desktop: inout DesktopState, windows: [CGWindowID: LiveWindow], moves: inout [Move]) {
        guard desktop.stages.indices.contains(index) else { return }
        for id in desktop.stages[index].windows { planShow(id, in: &desktop, windows: windows, moves: &moves) }
    }

    /// Records where a window is and plans its move to the corner. A window already off screen
    /// has no frame worth keeping: recording it would put the window back off screen later, so
    /// it is brought to the middle of the screen when its stage shows instead.
    private static func planHide(_ id: CGWindowID, in desktop: inout DesktopState, windows: [CGWindowID: LiveWindow], moves: inout [Move]) {
        guard !desktop.isHidden(id), let window = windows[id] else { return }
        if Screens.visibleFraction(of: window.frame) >= 0.1 { desktop.hidden[String(id)] = SavedRect(window.frame) }
        moves.append((window.element, CGRect(origin: Screens.hidingCorner, size: window.frame.size)))
    }

    /// Plans a hidden window's move back. Its record is kept until the window can be moved, so a
    /// window an app did not report this time is moved on a later try.
    private static func planShow(_ id: CGWindowID, in desktop: inout DesktopState, windows: [CGWindowID: LiveWindow], moves: inout [Move]) {
        guard let window = windows[id], let frame = desktop.hidden[String(id)] else { return }
        desktop.hidden.removeValue(forKey: String(id))
        moves.append((window.element, frame.cgRect))
    }

    private static func perform(_ moves: [Move]) {
        for move in moves { AX.setFrame(move.element, move.frame) }
    }

    /// Moves a window onto the main screen, at its size or smaller, in the middle.
    private static func bringOnScreen(_ window: LiveWindow) {
        guard window.frame.width > 0, window.frame.height > 0, let main = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = Screens.toAX(main.visibleFrame)
        let size = CGSize(width: min(window.frame.width, area.width), height: min(window.frame.height, area.height))
        AX.setFrame(window.element, CGRect(origin: CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2), size: size))
        Log.write("The \(window.appName) window was off screen; moved it to the middle of the screen.")
    }

    static func bringForward(_ id: CGWindowID, snapshot: Snapshot? = nil) {
        guard let window = (snapshot ?? (try? Snapshot.take()))?.windows[id] else { return }
        AX.focus(window)
    }

    /// The windows this desktop has hidden, and those other desktops have hidden. A hidden window
    /// sits in the corner of the rightmost screen, so with a desktop per display macOS counts it
    /// as on that display's desktop; it still belongs to the desktop that hid it.
    static func hiddenWindows() -> (here: Set<CGWindowID>, elsewhere: Set<CGWindowID>) {
        lock.lock(); defer { lock.unlock() }
        let key = Desktops.current().key
        var here: Set<CGWindowID> = [], elsewhere: Set<CGWindowID> = []
        for (desktop, state) in load().desktops {
            let ids = state.hidden.keys.compactMap { CGWindowID($0) }
            if desktop == key { here.formUnion(ids) } else { elsewhere.formUnion(ids) }
        }
        return (here, elsewhere)
    }

    /// Where each hidden window on this desktop goes back to, for drawing the stages.
    static func hiddenFrames() -> [CGWindowID: CGRect] {
        let hidden = read()?.hidden ?? [:]
        return Dictionary(uniqueKeysWithValues: hidden.compactMap { key, frame in CGWindowID(key).map { ($0, frame.cgRect) } })
    }
}

/// Screen geometry in Accessibility coordinates: origin at the top left of the main screen,
/// y growing downwards. Cocoa's origin is the bottom left, so converting flips y; the flip is
/// its own inverse.
enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toAX(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }

    /// The share of `frame` (Accessibility coordinates) that lies on a screen.
    static func visibleFraction(of frame: CGRect) -> CGFloat {
        guard frame.width > 0, frame.height > 0 else { return 1 }
        let visible = NSScreen.screens.map { screen -> CGFloat in
            let overlap = toAX(screen.frame).intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }.reduce(0, +)
        return min(visible / (frame.width * frame.height), 1)
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The bottom-right corner of the rightmost screen (the lowest, of screens equally far
    /// right), less one point so macOS leaves a window put there. One real screen's corner,
    /// since the corner of all screens together can lie on none of them.
    static var hidingCorner: CGPoint {
        guard let screen = hidingScreen else { return .zero }
        let frame = toAX(screen.frame)
        return CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)
    }

    /// The screen whose bottom-right corner holds hidden windows.
    static var hidingScreen: NSScreen? {
        NSScreen.screens.max { ($0.frame.maxX, -$0.frame.minY) < ($1.frame.maxX, -$1.frame.minY) }
    }
}

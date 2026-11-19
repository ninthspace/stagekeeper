import AppKit

/// The radial menu: a round panel that opens at the pointer on a four-finger trackpad click.
///
/// The inner ring holds this desktop's stages; clicking one switches to it, and holding ⌥ moves
/// the front window there instead. The outer ring holds actions. Pointing at Tile opens an arc
/// outside the menu with nine positions for the front window. The panel does not activate
/// StageKeeper, so the app you were using stays frontmost and its window stays the target.
final class RadialMenu {
    struct Hooks {
        let perform: (@escaping () throws -> Void) -> Void
        let notify: (String) -> Void
        let labelCurrent: () -> Void
        let refresh: () -> Void
    }

    private let hooks: Hooks
    private var panel: RadialPanel?
    private var outsideClicks: Any?

    private lazy var overview = Overview(perform: hooks.perform)

    init(hooks: Hooks) { self.hooks = hooks }

    func showOverview() {
        close()
        do { try overview.open() } catch { hooks.notify("\(error)") }
    }

    /// Opens the All stages view, or closes it when it is open. A four-finger swipe down.
    func toggleOverview() {
        if overview.isOpen { overview.close() } else { showOverview() }
    }

    func toggle(at point: NSPoint) {
        if overview.isOpen { overview.close(); return }
        if panel != nil { close(animated: true) } else { open(at: point) }
    }

    private var opening = false

    /// Opens the menu once the stages match the focused window, which may switch stages: done
    /// off the main thread, since moving windows waits on their apps.
    func open(at point: NSPoint) {
        guard !opening else { return }
        opening = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            Engine.matchFocus()
            DispatchQueue.main.async {
                self?.opening = false
                self?.present(at: point)
            }
        }
    }

    private func present(at point: NSPoint) {
        guard panel == nil else { return }
        let model: RadialModel
        do { model = try RadialModel.read(at: point) } catch { hooks.notify("\(error)"); return }
        let view = RadialView(model: model, menu: self)
        let size = view.size
        let offset = NSPoint(x: view.centre.x * RadialView.scale, y: view.centre.y * RadialView.scale)
        var origin = NSPoint(x: point.x - offset.x, y: point.y + offset.y - size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let area = screen.visibleFrame
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        }
        let panel = RadialPanel(contentRect: NSRect(origin: origin, size: size))
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        self.panel = panel
        view.pointerMoved(to: view.convert(panel.mouseLocationOutsideOfEventStream, from: nil))
        Log.write("Radial menu opened; modifier keys held: \(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue).")
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close(animated: true)
        }
    }

    /// Closes the menu. A dismissal (Esc, a click outside, the centre) shrinks it away; a
    /// choice hides it at once, because the work that follows holds up the main thread and
    /// would stop the animation part-way.
    func close(animated: Bool = false) {
        guard let panel else { return }
        self.panel = nil
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        panel.ignoresMouseEvents = true
        if animated, let view = panel.contentView as? RadialView {
            view.disappear { panel.orderOut(nil) }
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: Choices

    func switchTo(_ windowID: CGWindowID) {
        close()
        hooks.perform {
            let snapshot = try Snapshot.take()
            guard let stage = snapshot.stages.first(where: { $0.windowIDs.contains(windowID) }) else {
                throw StageError.other("That stage is no longer open.")
            }
            try Actions.switchTo(stage, in: snapshot)
        }
    }

    func show(_ windowID: CGWindowID) {
        close()
        hooks.perform { try Actions.showWindow(windowID) }
    }

    func switchSaved(_ id: UUID) {
        close()
        hooks.perform { try Actions.switchTo(id: id) }
    }

    func move(_ window: CGWindowID?, to windowID: CGWindowID) {
        close()
        hooks.perform { try Actions.moveFrontWindow(toStageWith: windowID, window: window) }
    }

    func moveToNewStage(_ window: CGWindowID?) {
        close()
        hooks.perform { try Actions.moveWindowToNewStage(window) }
    }

    func moveToEmpty(_ window: CGWindowID?, _ id: UUID) {
        close()
        hooks.perform { try Actions.moveWindow(window, toEmptyStage: id) }
    }

    func tile(_ window: CGWindowID?, _ part: CGRect) {
        close()
        hooks.perform { try Actions.tile(window, part) }
    }

    func colour(_ hex: String?) {
        close()
        do { try Actions.colourCurrent(hex); hooks.refresh() } catch { hooks.notify("\(error)") }
    }

    func toggleBookmark(_ chosen: CGWindowID?) {
        close()
        guard let snapshot = try? Snapshot.take(), let front = chosen ?? Actions.frontWindow(snapshot), let window = snapshot.windows[front] else {
            hooks.notify("There is no window to bookmark.")
            return
        }
        if Pins.isPinned(front, snapshot) {
            Pins.unpin(front)
            hooks.notify("Removed the bookmark from the \(window.appName) window.")
        } else {
            Pins.pin(window)
            hooks.notify("Bookmarked the \(window.appName) window. \(Shortcuts.fetch.map { "Press \($0.display)" } ?? "Choose Fetch Bookmarked Windows") to bring bookmarked windows into the stage you are in.")
        }
        hooks.refresh()
    }

    func fetchBookmarks() {
        close()
        hooks.perform { try Actions.fetchPinned() }
    }

    func label() {
        close()
        hooks.labelCurrent()
    }

    func save() {
        close()
        do { try Actions.save(); hooks.notify("Layout saved.") } catch { hooks.notify("\(error)") }
    }
}

/// A borderless panel that can take key events (for Esc and ⌥) without activating the app.
final class RadialPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
}

/// What the menu shows, read once when it opens.
struct RadialModel {
    enum Target { case live(CGWindowID), saved(UUID), empty(UUID), newStage }

    struct Window {
        let id: CGWindowID
        let app: String
        let title: String
        let icon: NSImage?
    }

    struct Stage {
        let title: String
        var label: String?
        /// Position among this desktop's stages in the menu, shown for stages without a label.
        var position = 0
        let number: Int?
        /// The stage's shortcut as shown, such as "⌃⌥1".
        var shortcut: String? = nil
        let colour: String?
        let isCurrent: Bool
        let initial: String
        let place: String?
        let target: Target
        /// The stage's windows, for the arc that opens when the stage is pointed at.
        var windows: [Window] = []
    }

    var stages: [Stage] = []
    /// This desktop's labelled stages with no open windows, offered as places to move a window.
    var empty: [Stage] = []
    /// Where Move can put the window, in arcs of eight across the bottom half of the menu: a new
    /// stage, the other stages by recent use, then the labelled stages with no open windows.
    var moreTargets: [Stage] = []
    static let arcSize = 8, maxArcs = 3
    /// Whether Move offers a new stage: only StageKeeper's own stages can make one.
    var canMakeStages = Backend.current.makesStages
    var others: [Stage] = []
    /// The window the menu acts on: the current stage's window under the pointer when the menu
    /// opened, else the front window.
    var window: CGWindowID?
    var frontApp: String?
    var bookmarked = false
    var currentTitle = "this stage"
    var currentColour: String?
    var otherDesktops = "Other desktops"

    static func read(at point: NSPoint) throws -> RadialModel {
        var model = RadialModel()
        let list = try StageList.read()
        let layout = list.layout, indices = list.indices, snapshot = list.snapshot
        let numbers = Dictionary(uniqueKeysWithValues: Actions.numbered().prefix(9).enumerated().map { ($1.id!, $0 + 1) })
        let shortcuts = Shortcuts.stages()
        var byUse = list.entries.map { entry in
            Stage(title: entry.title, label: entry.saved?.label, number: entry.saved?.id.flatMap { numbers[$0] },
                  shortcut: entry.saved?.id.flatMap { shortcuts[$0]?.display }, colour: entry.saved?.color,
                  isCurrent: entry.live.kind == .current, initial: String(entry.apps.first?.prefix(1) ?? "·"),
                  place: nil, target: .live(entry.live.windowIDs[0]),
                  windows: entry.windows.prefix(9).map { Window(id: $0.id, app: $0.app, title: $0.title, icon: $0.icon) })
        }
        if let current = list.current {
            model.currentTitle = current.title
            model.currentColour = current.saved?.color
        }
        for i in byUse.indices { byUse[i].position = i + 1 }
        model.stages = Array(byUse.prefix(8))
        for (index, saved) in (layout?.stages ?? []).enumerated() where saved.label != nil && saved.id != nil && !indices.contains(index) {
            model.empty.append(Stage(title: saved.label!, label: saved.label, number: numbers[saved.id!], shortcut: shortcuts[saved.id!]?.display, colour: saved.color,
                                     isCurrent: false, initial: "", place: nil, target: .empty(saved.id!)))
        }
        let newStage = model.canMakeStages ? [Stage(title: "New stage", label: nil, number: nil, colour: nil, isCurrent: false, initial: "",
                                                    place: nil, target: .newStage)] : []
        model.moreTargets = Array((newStage + byUse.filter { !$0.isCurrent } + model.empty).prefix(Self.arcSize * Self.maxArcs))

        let desktops = Desktops.all()
        let current = Desktops.current().key
        var otherNumbers: Set<Int> = []
        for other in LayoutStore.loadAll() where other.desktop != current {
            let number = desktops.first { $0.key == other.desktop }?.number
            for stage in other.stages {
                guard let label = stage.label, let id = stage.id else { continue }
                if let number { otherNumbers.insert(number) }
                model.others.append(Stage(title: label, label: label, number: numbers[id], shortcut: shortcuts[id]?.display, colour: stage.color, isCurrent: false,
                                          initial: String(label.prefix(1)), place: number.map { "Desktop \($0)" },
                                          target: .saved(id)))
            }
        }
        model.others = Array(model.others.prefix(8))
        if otherNumbers.count == 1, let only = otherNumbers.first { model.otherDesktops = "Desktop \(only)" }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGPoint(x: point.x, y: primaryHeight - point.y)
        let currentWindows = Set(snapshot.current).subtracting(Everywhere.ids())
        let underPointer = Snapshot.zOrder().first { id in
            currentWindows.contains(id) && (snapshot.windows[id]?.frame.contains(topLeft) ?? false)
        }
        if let id = underPointer ?? Actions.frontWindow(snapshot), let window = snapshot.windows[id] {
            model.window = id
            model.frontApp = window.appName
            model.bookmarked = Pins.isPinned(id, snapshot)
        }
        return model
    }
}

/// Draws the menu and turns pointer positions into choices. Angles are measured clockwise from
/// straight up, in degrees.
final class RadialView: NSView {
    /// Drawn in a 600-point square and shown at `scale` of that size.
    static let scale: CGFloat = 0.75
    /// The view grows to the right, left and downwards for each arc of Move stages; the centre
    /// stays 300 points from the top, where the tile arc and the caption above it need it.
    let design: NSSize
    var size: NSSize { NSSize(width: design.width * Self.scale, height: design.height * Self.scale) }
    let centre: NSPoint
    private static let bandStart: CGFloat = 222, bandDepth: CGFloat = 76, bandStep: CGFloat = 82
    private let rCentre: CGFloat = 50, rInner: CGFloat = 140, rOuter: CGFloat = 216, rArc: CGFloat = 298

    static let tiles: [(name: String, part: CGRect)] = [
        ("Left half", CGRect(x: 0, y: 0, width: 0.5, height: 1)),
        ("Top-left quarter", CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
        ("Bottom-left quarter", CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
        ("Top half", CGRect(x: 0, y: 0, width: 1, height: 0.5)),
        ("Maximise", CGRect(x: 0, y: 0, width: 1, height: 1)),
        ("Bottom half", CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
        ("Top-right quarter", CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
        ("Bottom-right quarter", CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
        ("Right half", CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
    ]

    private enum Mode { case switchStage, move, desktops, colour }
    private enum Hover: Equatable { case none, centre, inner(Int), outer(Int), arc(Int), window(Int), more(Int) }
    /// What opens outside the menu: the tile positions, the stages the Move ring has no room
    /// for, or the windows of the stage at an index of the inner ring.
    private enum Arc: Equatable { case none, tile, more, windows(Int) }
    private enum Item {
        case stage(RadialModel.Stage), colour(String, String?), empty, newStage
        var isEmpty: Bool { if case .empty = self { return true } else { return false } }
    }
    private enum Action: CaseIterable { case tile, bookmark, fetch, desktops, move, colour, label, save }

    private let model: RadialModel
    private weak var radial: RadialMenu?
    private var mode = Mode.switchStage
    private var hover = Hover.none
    private var arc = Arc.none {
        didSet {
            guard arc != oldValue else { return }
            closingArc = oldValue
            arcChanged = CACurrentMediaTime()
            animate()
        }
    }
    private var closingArc = Arc.none
    private var tileOpen: Bool { arc == .tile }
    /// The tile and more-stages arcs open outside the outer ring; window arcs replace it.
    private static func isOuter(_ arc: Arc) -> Bool { arc == .tile || arc == .more }
    private var outerOpen: Bool { Self.isOuter(arc) }
    /// Opens a stage's window arc once the pointer has rested on the stage, so passing over
    /// stages on the way to the outer ring opens nothing.
    private var windowsTimer: Timer?
    private static let windowsDelay = 0.35

    // MARK: Animation

    /// The menu grows from the pointer with a slight overshoot; the tile arc's positions slide
    /// out from under the outer ring one after another, starting from the middle (Maximise),
    /// and a stage's windows slide out from under the inner ring in place of the actions.
    private static let appearTime = 0.26, disappearTime = 0.13
    private static let arcTime = 0.22, arcStagger = 0.03, arcCloseTime = 0.14
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private let opened = CACurrentMediaTime()
    private var arcChanged = 0.0
    private var closing: Double?
    private var onClosed: (() -> Void)?
    private var ticker: Timer?

    private func elapsed(since start: Double) -> Double { CACurrentMediaTime() - start }

    /// Ease out with an overshoot of about 10%.
    private static func overshoot(_ t: Double) -> CGFloat {
        let t = min(max(t, 0), 1), c1 = 1.70158, c3 = c1 + 1
        return CGFloat(1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2))
    }

    private var animating: Bool {
        if reduceMotion { return closing != nil && elapsed(since: closing!) < Self.disappearTime }
        if let closing { return elapsed(since: closing) < Self.disappearTime }
        let arcDuration = max(Self.arcTime + 4 * Self.arcStagger, Self.arcCloseTime)
        return elapsed(since: opened) < Self.appearTime || elapsed(since: arcChanged) < arcDuration
    }

    private func animate() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.needsDisplay = true
            if !self.animating {
                self.ticker?.invalidate()
                self.ticker = nil
                if self.closing != nil { self.onClosed?(); self.onClosed = nil }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func disappear(then done: @escaping () -> Void) {
        closing = CACurrentMediaTime()
        onClosed = done
        animate()
    }

    /// Scale and opacity of the whole menu at this moment.
    private var menuScale: (scale: CGFloat, alpha: CGFloat) {
        if let closing {
            let t = CGFloat(min(elapsed(since: closing) / Self.disappearTime, 1))
            return (reduceMotion ? 1 : 1 - 0.15 * t * t, 1 - t)
        }
        if reduceMotion { return (1, 1) }
        let t = elapsed(since: opened) / Self.appearTime
        return (0.55 + 0.45 * Self.overshoot(t), CGFloat(min(t * 2.5, 1)))
    }

    /// How far position `i` of an arc of `count` has grown out (0 to just over 1), and its
    /// opacity: growing when `opening`, else fading.
    private func arcLevel(_ i: Int, of count: Int, opening: Bool) -> (level: CGFloat, alpha: CGFloat) {
        if reduceMotion { return opening ? (1, 1) : (0, 0) }
        let since = elapsed(since: arcChanged)
        guard opening else {
            // Slides back under, speeding up, and fades over the second half.
            let t = CGFloat(min(since / Self.arcCloseTime, 1))
            return (1 - t * t, min(1, 2 - 2 * t))
        }
        // Tile positions start from the middle; window slots are already ordered outwards from
        // the stage, two to a step.
        if arc == .more {
            let size = RadialModel.arcSize, n = model.moreTargets.count
            let inArc = min(size, n - i / size * size)
            let rank = Double(i / size) + abs(Double(i % size) - Double(inArc - 1) / 2) * 0.5
            let t = (since - rank * Self.arcStagger) / Self.arcTime
            return (Self.easeOut(t), CGFloat(min(max(t * 3, 0), 1)))
        }
        let rank = Self.isOuter(arc) ? abs(Double(i) - Double(count - 1) / 2) : Double((i + 1) / 2)
        let t = (since - rank * Self.arcStagger) / Self.arcTime
        return (Self.easeOut(t), CGFloat(min(max(t * 3, 0), 1)))
    }

    /// Slides out, slowing to a stop, with no overshoot.
    private static func easeOut(_ t: Double) -> CGFloat {
        let t = min(max(t, 0), 1)
        return CGFloat(1 - pow(1 - t, 3))
    }

    /// How far the outer ring's actions are out from under the inner ring: they slide under
    /// while a stage's windows slide out, and back out when the windows go.
    private var actionsLevel: (level: CGFloat, alpha: CGFloat) {
        func isWindows(_ arc: Arc) -> Bool { if case .windows = arc { return true } else { return false } }
        let now = isWindows(arc), before = isWindows(closingArc)
        if now == before { return now ? (0, 0) : (1, 1) }
        return now ? arcLevel(0, of: 1, opening: false) : arcLevel(0, of: 1, opening: true)
    }

    /// The windows shown in place of the outer ring, up to one per slot.
    private func windows(_ arc: Arc) -> [RadialModel.Window] {
        guard case .windows(let i) = arc, i < model.stages.count else { return [] }
        return Array(model.stages[i].windows.prefix(8))
    }

    /// Outer-ring slots for a stage's windows: the slot beside the stage first, then
    /// alternately clockwise and anticlockwise from it.
    private static let windowSlots: [CGFloat] = [0, 1, -1, 2, -2, 3, -3, 4]

    private func angles(_ arc: Arc) -> [CGFloat] {
        switch arc {
        case .none: return []
        case .tile: return (0..<9).map { -80 + CGFloat($0) * 20 }
        case .more:
            let n = model.moreTargets.count, size = RadialModel.arcSize
            return (0..<n).map { k in
                let inArc = min(size, n - k / size * size)
                return 180 + (CGFloat(k % size) - CGFloat(inArc - 1) / 2) * Self.moveStep
            }
        case .windows(let i):
            let centre = CGFloat(i) * 360 / CGFloat(items.count)
            return Self.windowSlots.prefix(windows(arc).count).map { centre + $0 * 45 }
        }
    }

    /// Each Move arc spans the bottom half: eight positions of 22.5 degrees.
    private static let moveStep: CGFloat = 22.5

    /// Inner and outer radius of the Move arc holding position `k`.
    private func band(_ k: Int) -> (CGFloat, CGFloat) {
        let r0 = Self.bandStart + CGFloat(k / RadialModel.arcSize) * Self.bandStep
        return (r0, r0 + Self.bandDepth)
    }

    init(model: RadialModel, menu: RadialMenu) {
        self.model = model
        self.radial = menu
        let arcs = (model.moreTargets.count + RadialModel.arcSize - 1) / RadialModel.arcSize
        let reach = max(300, Self.bandStart + CGFloat(max(arcs - 1, 0)) * Self.bandStep + Self.bandDepth + 4)
        centre = NSPoint(x: reach, y: 300)
        design = NSSize(width: reach * 2, height: 300 + max(340, reach))
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: design.width * Self.scale, height: design.height * Self.scale)))
        setBoundsSize(design)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        animate()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    /// ⌥ is read from the keyboard as it is now, so a stale flag cannot leave the menu in Move.
    private var effectiveMode: Mode { mode == .switchStage && NSEvent.modifierFlags.contains(.option) ? .move : mode }

    private var items: [Item] {
        switch effectiveMode {
        case .switchStage: return pad(model.stages.map { .stage($0) })
        case .move: return pad([])
        case .desktops: return pad(model.others.map { .stage($0) })
        case .colour: return Palette.colours.map { .colour($0.name, $0.hex) } + [.colour("No colour", nil)]
        }
    }

    private func pad(_ list: [Item]) -> [Item] { list + Array(repeating: .empty, count: max(0, 8 - list.count)) }

    private func symbol(_ action: Action) -> String {
        switch action {
        case .tile: return "rectangle.split.2x2"
        case .bookmark: return model.bookmarked ? "bookmark.fill" : "bookmark"
        case .fetch: return "tray.and.arrow.down"
        case .desktops: return "rectangle.on.rectangle"
        case .move: return "arrow.right.square"
        case .colour: return "paintpalette"
        case .label: return "tag"
        case .save: return "square.and.arrow.down"
        }
    }

    private func describe(_ action: Action) -> (String, String) {
        let app = model.frontApp ?? "front"
        switch action {
        case .tile: return ("Tile the \(app) window", "Point outwards to choose a position")
        case .bookmark:
            return model.bookmarked ? ("Remove the bookmark from the \(app) window", "It stops coming with Fetch Bookmarked Windows")
                : ("Bookmark the \(app) window", "Fetch Bookmarked Windows brings it into the stage you are in")
        case .fetch: return ("Fetch bookmarked windows", (Shortcuts.fetch.map { "\($0.display) · " } ?? "") + "brings bookmarked windows into this stage")
        case .desktops:
            return model.others.isEmpty ? ("No labelled stages on other desktops", "Label stages there to list them here")
                : ("\(model.otherDesktops) stages", "Switches desktop, then stage")
        case .move:
            return ("Move the \(app) window to…", "Point at a stage below · or hold ⌥")
        case .colour: return ("Colour \(model.currentTitle)", "Changes its dot and wallpaper")
        case .label: return ("Label \(model.currentTitle)…", "Opens the label dialog")
        case .save: return ("Save layout", "Saves this desktop's stages")
        }
    }

    private func isActive(_ action: Action) -> Bool {
        switch action {
        case .tile: return tileOpen
        case .bookmark: return model.bookmarked
        case .desktops: return mode == .desktops
        case .move: return effectiveMode == .move
        case .colour: return mode == .colour
        default: return false
        }
    }

    // MARK: Geometry

    private func point(_ radius: CGFloat, _ angle: CGFloat) -> NSPoint {
        let t = angle * .pi / 180
        return NSPoint(x: centre.x + radius * sin(t), y: centre.y - radius * cos(t))
    }

    private func sector(_ r0: CGFloat, _ r1: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(r1, a0))
        path.appendArc(withCenter: centre, radius: r1, startAngle: a0 - 90, endAngle: a1 - 90, clockwise: false)
        path.line(to: point(r0, a1))
        path.appendArc(withCenter: centre, radius: r0, startAngle: a1 - 90, endAngle: a0 - 90, clockwise: true)
        path.close()
        return path
    }

    private func hit(_ p: NSPoint) -> Hover {
        let dx = p.x - centre.x, dy = p.y - centre.y
        let r = hypot(dx, dy)
        var a = atan2(dx, -dy) * 180 / .pi
        if a < 0 { a += 360 }
        if case .windows = arc, r >= rInner, r < rOuter {
            for (k, angle) in angles(arc).enumerated() {
                var d = (a - angle).truncatingRemainder(dividingBy: 360)
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                if abs(d) < 22.5 { return .window(k) }
            }
            return .window(-1)  // where an empty slot would be: does nothing
        }
        if arc == .more, r >= rOuter {
            let angles = angles(arc)
            for (k, angle) in angles.enumerated() {
                let (r0, r1) = band(k)
                guard r >= r0 - 6, r < r1 else { continue }
                var d = (a - angle).truncatingRemainder(dividingBy: 360)
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                if abs(d) < Self.moveStep / 2 { return .more(k) }
            }
            if r < band(max(angles.count - 1, 0)).1 && a > 90 && a < 270 { return .more(-1) }
        }
        if tileOpen, r >= rOuter, r <= rArc + 16 {
            for (k, angle) in angles(arc).enumerated() {
                var d = (a - angle).truncatingRemainder(dividingBy: 360)
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                // The end positions also take the space just beyond them.
                let last = k == angles(arc).count - 1
                if (d >= -10 || k == 0 && d >= -20) && (d < 10 || last && d < 20) {
                    return .arc(k)
                }
            }
        }
        if r < rCentre { return .centre }
        if r < rInner {
            let n = CGFloat(items.count)
            return .inner(Int((a + 180 / n).truncatingRemainder(dividingBy: 360) / (360 / n)) % items.count)
        }
        if r < rOuter { return .outer(Int((a + 22.5).truncatingRemainder(dividingBy: 360) / 45) % 8) }
        return .none
    }

    // MARK: Events

    func pointerMoved(to p: NSPoint) {
        let next = hit(p)
        // Each arc stays open while the pointer crosses the rings on its way to a position, so
        // every position can be reached in a straight line. Tile opens its arc when pointed at,
        // and moving into the inner ring or the centre closes it. A stage's windows open after
        // the pointer rests on the stage; once they are showing, they change to another stage's
        // windows, or close at the centre, only after the pointer rests there too, so crossing
        // other stages or the centre on the way to a window leaves them open.
        syncMoveArc()
        if next != hover, effectiveMode != .move {
            windowsTimer?.invalidate()
            windowsTimer = nil
            let showingWindows: Bool = { if case .windows = arc { return true } else { return false } }()
            func after(_ change: @escaping () -> Void) {
                windowsTimer = Timer.scheduledTimer(withTimeInterval: Self.windowsDelay, repeats: false) { [weak self] _ in
                    guard let self, self.hover == next, self.effectiveMode == .switchStage else { return }
                    change()
                    self.needsDisplay = true
                }
            }
            switch next {
            case .outer(0):
                if !showingWindows { arc = .tile }
            case .inner(let i):
                let hasWindows = effectiveMode == .switchStage && i < model.stages.count && !model.stages[i].windows.isEmpty
                if showingWindows {
                    if arc != .windows(i) { after { [weak self] in self?.arc = hasWindows ? .windows(i) : .none } }
                } else {
                    arc = .none
                    if hasWindows { after { [weak self] in self?.arc = .windows(i) } }
                }
            case .centre:
                if showingWindows { after { [weak self] in self?.arc = .none } } else { arc = .none }
            default:
                break
            }
        }
        hover = next
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }

    override func flagsChanged(with event: NSEvent) { syncMoveArc(); needsDisplay = true }

    /// In Move, the stages show in the arcs below the menu, in place of the stages ring.
    private func syncMoveArc() {
        if effectiveMode == .move, !model.moreTargets.isEmpty { if arc != .more { arc = .more } }
        else if arc == .more { arc = .none }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { radial?.close(animated: true) } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let target = hit(convert(event.locationInWindow, from: nil))
        guard let menu = radial else { return }
        switch target {
        case .none:
            menu.close(animated: true)
        case .centre:
            if case .windows = arc { arc = .none; needsDisplay = true }
            else if mode == .switchStage { menu.showOverview() } else { mode = .switchStage; needsDisplay = true }
        case .arc(let i):
            menu.tile(model.window, Self.tiles[i].part)
        case .more(let i):
            guard model.moreTargets.indices.contains(i) else { break }
            switch model.moreTargets[i].target {
            case .live(let id): menu.move(model.window, to: id)
            case .empty(let id): menu.moveToEmpty(model.window, id)
            case .newStage: menu.moveToNewStage(model.window)
            case .saved: break
            }
        case .window(let k):
            let list = windows(arc)
            if list.indices.contains(k) { menu.show(list[k].id) }
        case .inner(let i):
            switch items[i] {
            case .empty: break
            case .newStage: menu.moveToNewStage(model.window)
            case .colour(_, let hex): menu.colour(hex)
            case .stage(let stage):
                switch (effectiveMode, stage.target) {
                case (.move, .live(let id)):
                    if stage.isCurrent { NSSound.beep() } else { menu.move(model.window, to: id) }
                case (_, .empty(let id)):
                    menu.moveToEmpty(model.window, id)
                case (_, .live(let id)):
                    if stage.isCurrent { menu.close() } else { menu.switchTo(id) }
                case (_, .newStage):
                    menu.moveToNewStage(model.window)
                case (_, .saved(let id)):
                    menu.switchSaved(id)
                }
            }
        case .outer(let i):
            switch Action.allCases[i] {
            case .tile: arc = tileOpen ? .none : .tile
            case .bookmark: menu.toggleBookmark(model.window)
            case .fetch: menu.fetchBookmarks()
            case .desktops: if !model.others.isEmpty { mode = mode == .desktops ? .switchStage : .desktops; arc = .none }
            case .move:
                mode = mode == .move ? .switchStage : .move
                arc = .none
                syncMoveArc()
                Log.write("Radial menu: Move chosen (\(mode == .move ? "on" : "off")).")
            case .colour: mode = mode == .colour ? .switchStage : .colour; arc = .none
            case .label: menu.label()
            case .save: menu.save()
            }
            needsDisplay = true
        }
    }

    // MARK: Drawing

    private static let outerFill = NSColor(srgbRed: 0.173, green: 0.173, blue: 0.188, alpha: 1)
    private static let innerFill = NSColor(srgbRed: 0.227, green: 0.227, blue: 0.247, alpha: 1)
    private static let centreFill = NSColor(srgbRed: 0.137, green: 0.137, blue: 0.149, alpha: 1)
    private static let separator = NSColor(white: 0, alpha: 0.4)
    private static let primary = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    private static let secondary = NSColor(srgbRed: 0.72, green: 0.72, blue: 0.74, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let (scale, alpha) = menuScale
        guard alpha > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: centre.x, y: centre.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -centre.x, y: -centre.y)
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }

        drawArc(.tile)

        // The disc, the outer ring and any window slots share one shadow. The disc reaches only
        // to the inner ring; the outer ring's actions slide under the inner ring while a
        // stage's windows slide out in their place, and back again.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(white: 0, alpha: 0.55).cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        Self.outerFill.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - rInner, y: centre.y - rInner, width: rInner * 2, height: rInner * 2)).fill()
        let (actionsLevel, actionsAlpha) = self.actionsLevel
        for (i, action) in Action.allCases.enumerated() where actionsAlpha > 0 {
            let a = CGFloat(i) * 45
            let direction = point(1, a)
            let distance = (1 - actionsLevel) * (rOuter - rInner)
            context.saveGState()
            context.translateBy(x: (centre.x - direction.x) * distance, y: (centre.y - direction.y) * distance)
            context.setAlpha(actionsAlpha)
            let path = sector(rInner, rOuter, a - 22.5, a + 22.5)
            Self.outerFill.setFill(); path.fill()
            let highlight: CGFloat = hover == .outer(i) ? 0.14 : (isActive(action) ? 0.08 : 0)
            if highlight > 0 { NSColor(white: 1, alpha: highlight).setFill(); path.fill() }
            Self.separator.setStroke(); path.lineWidth = 1; path.stroke()
            let dimmed = action == .desktops && model.others.isEmpty
            let colour = dimmed ? Self.secondary.withAlphaComponent(0.5) : (isActive(action) ? .white : Self.secondary)
            drawSymbol(symbol(action), at: point(178, a), size: 19, colour: colour)
            context.restoreGState()
        }
        drawArc(nil)
        context.endTransparencyLayer()
        context.restoreGState()

        // Inner ring.
        let list = items
        let step = 360 / CGFloat(list.count)
        for (i, item) in list.enumerated() {
            let a = CGFloat(i) * step
            let path = sector(rCentre, rInner, a - step / 2, a + step / 2)
            Self.innerFill.setFill(); path.fill()
            let hovered = hover == .inner(i)
            var tint: NSColor?
            switch item {
            case .stage(let stage): tint = stage.colour.map { Palette.color($0) }
            case .colour(_, let hex): tint = hex.map { Palette.color($0) }
            case .empty, .newStage: break
            }
            if let tint {
                if case .stage = item { Self.stageFill(tint, hovered: hovered).setFill() } else { tint.withAlphaComponent(hovered ? 0.42 : 0.2).setFill() }
                path.fill()
            } else if hovered, !item.isEmpty {
                NSColor(white: 1, alpha: 0.14).setFill(); path.fill()
            }
            Self.separator.setStroke(); path.lineWidth = 1; path.stroke()
            if case .stage(let stage) = item, stage.isCurrent, effectiveMode != .desktops {
                let outline = sector(rCentre + 2, rInner - 2, a - step / 2 + 0.8, a + step / 2 - 0.8)
                outline.lineWidth = 2
                Self.primary.setStroke(); outline.stroke()
            }
            // The text's width is the wedge's width a little inside where it is drawn.
            let textRadius = rCentre + (rInner - rCentre) / 2 - 6
            let width = min(80, 2 * textRadius * sin(min(step, 180) / 2 * .pi / 180) - 10)
            drawItem(item, at: point(rCentre + (rInner - rCentre) / 2 + 2, a), width: width)
        }

        // Centre.
        let centreRect = NSRect(x: centre.x - rCentre, y: centre.y - rCentre, width: rCentre * 2, height: rCentre * 2)
        Self.centreFill.setFill()
        NSBezierPath(ovalIn: centreRect).fill()
        if hover == .centre { NSColor(white: 1, alpha: 0.12).setFill(); NSBezierPath(ovalIn: centreRect).fill() }
        drawSymbol(mode == .switchStage ? "square.grid.2x2" : "chevron.left", at: centre, size: 20, colour: Self.primary)

        drawCaption()
    }

    /// Draws the tile arc (`only` .tile, under the outer ring) or the window slots (`only`
    /// nil, over the outer ring and under the inner ring), opening or closing.
    private func drawArc(_ only: Arc?) {
        for (shown, opening) in [(closingArc, false), (arc, true)] where shown != .none && (opening || closingArc != arc) {
            if Self.isOuter(shown) == (only == .tile) { drawArc(shown, opening: opening) }
        }
    }

    private func drawArc(_ shown: Arc, opening: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let list = windows(shown)
        let positions = angles(shown)
        for (i, a) in positions.enumerated() {
            let (level, alpha) = arcLevel(i, of: positions.count, opening: opening)
            guard alpha > 0 else { continue }
            // Each position keeps its final shape and slides out from under the ring inside it,
            // which is drawn over it.
            let tile = Self.isOuter(shown)
            let (r0, r1) = shown == .more ? band(i) : (rOuter + 6, rArc)
            let distance = (1 - level) * (tile ? r1 - rOuter : rOuter - rInner)
            let direction = point(1, a)
            context.saveGState()
            context.translateBy(x: (centre.x - direction.x) * distance, y: (centre.y - direction.y) * distance)
            context.setAlpha(alpha)
            let half = shown == .more ? Self.moveStep / 2 : 10
            let path = tile ? sector(r0, r1, a - half, a + half) : sector(rInner, rOuter, a - 22.5, a + 22.5)
            Self.outerFill.setFill(); path.fill()
            if shown == .more, i < model.moreTargets.count, let hex = model.moreTargets[i].colour {
                Self.stageFill(Palette.color(hex), hovered: hover == .more(i)).setFill(); path.fill()
            }
            let hovered = opening && (shown == .tile ? hover == .arc(i) : shown == .more ? hover == .more(i) : hover == .window(i))
            if hovered { NSColor(white: 1, alpha: 0.16).setFill(); path.fill() }
            Self.separator.setStroke(); path.lineWidth = 1; path.stroke()
            if shown == .tile {
                drawTile(Self.tiles[i].part, at: point(262, a))
            } else if shown == .more {
                if i < model.moreTargets.count { drawMore(model.moreTargets[i], at: point((r0 + r1) / 2, a), width: 2 * r0 * sin(Self.moveStep / 2 * .pi / 180) - 12) }
            } else if i < list.count {
                drawWindow(list[i], at: a)
            }
            context.restoreGState()
        }
    }

    /// A window's app icon, with the start of its title under it.
    private func drawWindow(_ window: RadialModel.Window, at a: CGFloat) {
        let p = point((rInner + rOuter) / 2 + 2, a)
        window.icon?.draw(in: NSRect(x: p.x - 14, y: p.y - 22, width: 28, height: 28), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: window.title.isEmpty ? window.app : window.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Self.secondary, .paragraphStyle: style])
        text.draw(with: NSRect(x: p.x - 45, y: p.y + 8, width: 90, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A stage in a Move arc, drawn as in the stages ring.
    private func drawMore(_ stage: RadialModel.Stage, at p: NSPoint, width: CGFloat) {
        if case .newStage = stage.target { drawItem(.newStage, at: p, width: width); return }
        var shown = stage
        if shown.label == nil { shown.label = "\(stage.position) · \(stage.title)" }
        drawItem(.stage(shown), at: p, width: width)
    }

    private func drawTile(_ part: CGRect, at p: NSPoint) {
        let outline = NSRect(x: p.x - 14, y: p.y - 10, width: 28, height: 20)
        Self.primary.setStroke()
        let frame = NSBezierPath(roundedRect: outline, xRadius: 3, yRadius: 3)
        frame.lineWidth = 1.5
        frame.stroke()
        let inner = outline.insetBy(dx: 2, dy: 2)
        let fill = NSRect(x: inner.minX + part.minX * inner.width, y: inner.minY + part.minY * inner.height,
                          width: part.width * inner.width, height: part.height * inner.height)
        Self.primary.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// The label as it fits on one line in `width`: in full, then in a smaller size, then
    /// with every word after the first shortened to its initial ("World S."), then as
    /// initials ("WS"), then cut short with an ellipsis. The caption names the stage in full.
    static func fit(_ label: String, width: CGFloat) -> (text: String, size: CGFloat) {
        func fits(_ text: String, _ size: CGFloat) -> Bool {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).size().width <= width
        }
        let words = label.split(separator: " ").map(String.init)
        var candidates = [label]
        if words.count > 1 {
            candidates.append(words[0] + " " + words.dropFirst().map { "\($0.prefix(1))." }.joined(separator: " "))
            candidates.append(words.map { String($0.prefix(1)) }.joined().uppercased())
        }
        for text in candidates {
            for size: CGFloat in [14, 12] where fits(text, size) { return (text, size) }
        }
        var cut = label
        while cut.count > 1, !fits(cut + "…", 12) { cut.removeLast() }
        return (cut.trimmingCharacters(in: .whitespaces) + "…", 12)
    }

    private func drawItem(_ item: Item, at p: NSPoint, width: CGFloat) {
        switch item {
        case .empty:
            break
        case .newStage:
            drawSymbol("plus", at: NSPoint(x: p.x, y: p.y - 8), size: 16, colour: Self.primary)
            draw("New stage", centredAt: NSPoint(x: p.x, y: p.y + 12), font: .systemFont(ofSize: 12, weight: .semibold), colour: Self.primary)
        case .colour(_, let hex):
            let rect = NSRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)
            if let hex {
                Palette.color(hex).setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                Self.secondary.setStroke()
                let circle = NSBezierPath(ovalIn: rect); circle.lineWidth = 1.5; circle.stroke()
                let slash = NSBezierPath(); slash.move(to: NSPoint(x: rect.minX + 5, y: rect.maxY - 5)); slash.line(to: NSPoint(x: rect.maxX - 5, y: rect.minY + 5))
                slash.lineWidth = 1.5; slash.stroke()
            }
            if hex == model.currentColour { ring(rect) }
        case .stage(let stage):
            if let label = stage.label {
                // The label, on the stage's colour, which fills the tile.
                let top = p.y - 9
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let fitted = Self.fit(label, width: width)
                let text = NSAttributedString(string: fitted.text, attributes: [
                    .font: NSFont.systemFont(ofSize: fitted.size, weight: .semibold), .paragraphStyle: style,
                    .foregroundColor: {
                        if let hex = stage.colour { return Self.contrast(on: Self.stageFill(Palette.color(hex), hovered: false)) }
                        if case .empty = stage.target { return Self.secondary } else { return Self.primary }
                    }()])
                let box = NSRect(x: p.x - width / 2, y: top + (14 - fitted.size) / 2, width: width, height: 20)
                text.draw(with: box, options: [.usesLineFragmentOrigin])
            } else {
                let rect = NSRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30)
                if let hex = stage.colour {
                    Palette.color(hex).setFill()
                    NSBezierPath(ovalIn: rect).fill()
                } else {
                    let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                    circle.lineWidth = 1.5
                    circle.setLineDash([3, 2.5], count: 2, phase: 0)
                    Self.secondary.setStroke(); circle.stroke()
                }
                let colour = stage.colour.map { Self.contrast(on: Palette.color($0)) } ?? Self.primary
                draw(String(stage.position), centredAt: p, font: .systemFont(ofSize: 16, weight: .semibold), colour: colour)
            }
        }
    }

    private func ring(_ rect: NSRect) {
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -4, dy: -4))
        ring.lineWidth = 2
        Self.primary.setStroke()
        ring.stroke()
    }

    /// A coloured stage's tile: its colour, darkened towards the ring so white text reads on most
    /// colours, and lighter while pointed at.
    private static func stageFill(_ colour: NSColor, hovered: Bool) -> NSColor {
        colour.blended(withFraction: hovered ? 0.2 : 0.4, of: innerFill) ?? colour
    }

    private static func contrast(on colour: NSColor) -> NSColor {
        guard let c = colour.usingColorSpace(.sRGB) else { return .white }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        return (l + 0.05) / 0.05 > 1.05 / (l + 0.05) ? NSColor(white: 0.07, alpha: 1) : .white
    }

    private func drawSymbol(_ name: String, at p: NSPoint, size: CGFloat, colour: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let s = image.size
        image.draw(in: NSRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func draw(_ text: String, centredAt p: NSPoint, font: NSFont, colour: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
        let s = string.size()
        string.draw(at: NSPoint(x: p.x - s.width / 2, y: p.y - s.height / 2))
    }

    private func caption() -> (mode: String, title: String, detail: String) {
        let app = model.frontApp ?? "front"
        let modeName: String
        var title: String, detail: String
        switch effectiveMode {
        case .switchStage: modeName = "Switch stage"; title = "Point at a stage"; detail = "Click to switch · hold ⌥ to move the \(app) window"
        case .move: modeName = "Move window"; title = "Move the \(app) window"; detail = "Point at a stage below"
        case .desktops: modeName = model.otherDesktops; title = model.otherDesktops; detail = "Point at a stage to switch desktop and stage"
        case .colour: modeName = "Colour stage"; title = "Colour for \(model.currentTitle)"; detail = "Changes its dot and wallpaper"
        }
        switch hover {
        case .centre where arc != .none && !outerOpen:
            title = "Back to the actions"
            detail = "Rest here or click"
        case .centre:
            title = mode == .switchStage ? "All stages" : "Back"
            detail = mode == .switchStage ? "See every stage and pick one · Esc or a click outside closes the menu" : "Back to the stages"
        case .outer(let i):
            (title, detail) = describe(Action.allCases[i])
        case .arc(let i):
            title = Self.tiles[i].name
            detail = "Tile the \(app) window"
        case .more(let i):
            if model.moreTargets.indices.contains(i) {
                let stage = model.moreTargets[i]
                title = "Move the \(app) window to \(stage.title)"
                if case .newStage = stage.target { title = "Move the \(app) window to a new stage"; detail = "It becomes a stage of its own" }
                else if case .empty = stage.target { detail = "No open windows · the window becomes this stage" } else { detail = "Keeps its size and position" }
            }
        case .window(let k):
            let list = windows(arc)
            if list.indices.contains(k), case .windows(let i) = arc {
                let stage = model.stages[i]
                title = list[k].title.isEmpty ? list[k].app : list[k].title
                detail = "\(list[k].app) · " + (stage.isCurrent ? "click to bring it to the front" : "click to switch to \(stage.label ?? "its stage") and show it")
            }
        case .inner(let i):
            switch items[i] {
            case .empty where effectiveMode == .move: title = "Move the \(app) window"; detail = "Point at a stage below"
            case .empty: title = "Empty"; detail = "Up to 8 stages per desktop"
            case .newStage: title = "Move the \(app) window to a new stage"; detail = "It becomes a stage of its own"
            case .colour(let name, let hex): title = name; detail = hex == model.currentColour ? "Current colour" : "Colour \(model.currentTitle)"
            case .stage(let stage):
                let key = stage.shortcut
                switch effectiveMode {
                case .move:
                    title = "Move the \(app) window to \(stage.title)"
                    if case .empty = stage.target {
                        detail = "No open windows · the window becomes this stage"
                    } else {
                        detail = stage.isCurrent ? "It is already in this stage" : "Keeps its size and position"
                    }
                case .desktops:
                    title = stage.title
                    detail = [stage.place, key].compactMap { $0 }.joined(separator: " · ")
                default:
                    title = stage.label ?? "\(stage.position) · \(stage.title)"
                    detail = stage.isCurrent ? "Current stage" : "Switch" + (key.map { " · \($0)" } ?? "")
                    if !stage.windows.isEmpty { detail += " · rest here to see its windows" }
                }
            }
        case .none:
            if tileOpen { title = "Tile the \(app) window"; detail = "Point at a position in the arc" }
            if arc == .more { title = "Move the \(app) window"; detail = "Point at a stage below" }
        }
        return (modeName.uppercased(), title, detail)
    }

    private func drawCaption() {
        let (mode, title, detail) = caption()
        let lines: [(String, NSFont, NSColor)] = [
            (mode, .systemFont(ofSize: 13, weight: .semibold), Self.secondary),
            (title, .systemFont(ofSize: 17, weight: .semibold), Self.primary),
            (detail, .systemFont(ofSize: 15), Self.secondary),
        ]
        let strings = lines.map { NSAttributedString(string: $0.0, attributes: [.font: $0.1, .foregroundColor: $0.2]) }
        let width = min(560, (strings.map { $0.size().width }.max() ?? 0) + 32)
        let height = strings.reduce(CGFloat(16)) { $0 + $1.size().height + 2 }
        // The more-stages arc fills the space below the menu, so the caption goes above it then.
        let above = arc == .more || closingArc == .more && animating
        let top = above ? max(0, centre.y - rOuter - 8 - height) : centre.y + rOuter + 14
        let box = NSRect(x: centre.x - width / 2, y: top, width: width, height: height)
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        var y = box.minY + 8
        for string in strings {
            let s = string.size()
            let clipped = NSRect(x: max(box.minX + 12, centre.x - s.width / 2), y: y, width: min(s.width, box.width - 24), height: s.height)
            string.draw(with: clipped, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += s.height + 2
        }
    }
}

extension Actions {
    /// Shows one window: switches to its stage the way StageKeeper always does, then brings
    /// the window to the front. Picking a window in Mission Control takes it out of its stage
    /// instead, so this is the way to reach a window hidden behind others.
    static func showWindow(_ id: CGWindowID) throws {
        let snapshot = try Snapshot.take()
        guard let window = snapshot.windows[id] else { throw StageError.other("That window is no longer open.") }
        if let stage = snapshot.stages.first(where: { $0.windowIDs.contains(id) }), stage.kind != .current {
            try switchTo(stage, in: snapshot)
            usleep(150_000)
        }
        AX.focus(window)
        Log.write("Showed the \(window.appName) window \"\(window.title)\".")
    }

    /// Puts a window of the current stage (the front one when `chosen` is nil) in a part of its screen. `part` is a fraction of the screen's usable
    /// area (without the menu bar and Dock), measured from its top-left corner. A window over the
    /// strip's area makes Stage Manager slide the strip away until the pointer reaches the edge.
    static func tile(_ chosen: CGWindowID?, _ part: CGRect) throws {
        let snapshot = try Snapshot.take()
        guard let front = chosen ?? frontWindow(snapshot), let window = snapshot.windows[front], let frame = AX.frame(window.element) else {
            throw StageError.other("There is no window to tile.")
        }
        // Accessibility uses top-left coordinates from the top of the main screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func topLeft(_ rect: NSRect) -> CGRect { CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height) }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { topLeft($0.frame).contains(middle) }) ?? NSScreen.main else {
            throw StageError.other("Could not find the window's screen.")
        }
        let area = topLeft(screen.visibleFrame)
        let target = CGRect(x: (area.minX + part.minX * area.width).rounded(), y: (area.minY + part.minY * area.height).rounded(),
                            width: (part.width * area.width).rounded(), height: (part.height * area.height).rounded())
        AX.setFrame(window.element, target)
    }
}

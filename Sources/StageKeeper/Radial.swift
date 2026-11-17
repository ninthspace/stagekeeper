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

    init(hooks: Hooks) { self.hooks = hooks }

    func toggle(at point: NSPoint) {
        if panel != nil { close() } else { open(at: point) }
    }

    func open(at point: NSPoint) {
        let model: RadialModel
        do { model = try RadialModel.read(at: point) } catch { hooks.notify("\(error)"); return }
        let size = RadialView.size
        let offset = NSPoint(x: RadialView.centre.x * RadialView.scale, y: RadialView.centre.y * RadialView.scale)
        var origin = NSPoint(x: point.x - offset.x, y: point.y + offset.y - size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let area = screen.visibleFrame
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        }
        let panel = RadialPanel(contentRect: NSRect(origin: origin, size: size))
        let view = RadialView(model: model, menu: self)
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        self.panel = panel
        view.pointerMoved(to: view.convert(panel.mouseLocationOutsideOfEventStream, from: nil))
        Log.write("Radial menu opened; modifier keys held: \(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue).")
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
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

    func switchSaved(_ id: UUID) {
        close()
        hooks.perform { try Actions.switchTo(id: id) }
    }

    func move(_ window: CGWindowID?, to windowID: CGWindowID) {
        close()
        hooks.perform { try Actions.moveFrontWindow(toStageWith: windowID, window: window) }
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
            hooks.notify("Bookmarked the \(window.appName) window. Press ⌃⌥0 to bring bookmarked windows into the stage you are in.")
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
    enum Target { case live(CGWindowID), saved(UUID) }

    struct Stage {
        let title: String
        var label: String?
        /// Position among this desktop's stages in the menu, shown for stages without a label.
        var position = 0
        let number: Int?
        let colour: String?
        let isCurrent: Bool
        let initial: String
        let place: String?
        let target: Target
    }

    var stages: [Stage] = []
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
        let snapshot = try Snapshot.take()
        let layout = LayoutStore.load()
        let indices = Matcher.savedIndices(layout, snapshot)
        let numbers = Dictionary(uniqueKeysWithValues: Actions.numbered().prefix(9).enumerated().map { ($1.id!, $0 + 1) })
        var labelled: [Stage] = []
        var unlabelled: [Stage] = []
        // Overflow stages are ones the strip has no room for; switching to them works the same way.
        for (index, stage) in snapshot.stages.enumerated() {
            guard let first = stage.windowIDs.first else { continue }
            let saved = indices[index].flatMap { layout?.stages[$0] }
            let apps = stage.windowIDs.compactMap { snapshot.windows[$0]?.appName }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let title = saved?.label ?? apps.joined(separator: ", ")
            let entry = Stage(title: title, label: saved?.label, number: saved?.id.flatMap { numbers[$0] }, colour: saved?.color,
                              isCurrent: stage.kind == .current, initial: String(apps.first?.prefix(1) ?? "·"),
                              place: nil, target: .live(first))
            if stage.kind == .current {
                model.currentTitle = title
                model.currentColour = saved?.color
            }
            if saved?.label != nil { labelled.append(entry) } else { unlabelled.append(entry) }
        }
        labelled.sort { ($0.number ?? 99) < ($1.number ?? 99) }
        model.stages = Array((labelled + unlabelled).prefix(8))
        for i in model.stages.indices { model.stages[i].position = i + 1 }

        let desktops = Desktops.all()
        let current = Desktops.current().key
        var otherNumbers: Set<Int> = []
        for other in LayoutStore.loadAll() where other.desktop != current {
            let number = desktops.first { $0.key == other.desktop }?.number
            for stage in other.stages {
                guard let label = stage.label, let id = stage.id else { continue }
                if let number { otherNumbers.insert(number) }
                model.others.append(Stage(title: label, label: label, number: numbers[id], colour: stage.color, isCurrent: false,
                                          initial: String(label.prefix(1)), place: number.map { "Desktop \($0)" },
                                          target: .saved(id)))
            }
        }
        model.others = Array(model.others.prefix(8))
        if otherNumbers.count == 1, let only = otherNumbers.first { model.otherDesktops = "Desktop \(only)" }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGPoint(x: point.x, y: primaryHeight - point.y)
        let currentWindows = Set(snapshot.current)
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
    static let design = NSSize(width: 600, height: 640)
    static let scale: CGFloat = 0.75
    static let size = NSSize(width: design.width * scale, height: design.height * scale)
    static let centre = NSPoint(x: 300, y: 300)
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
    private enum Hover: Equatable { case none, centre, inner(Int), outer(Int), arc(Int) }
    private enum Item {
        case stage(RadialModel.Stage), colour(String, String?), empty
        var isEmpty: Bool { if case .empty = self { return true } else { return false } }
    }
    private enum Action: CaseIterable { case tile, bookmark, fetch, desktops, move, colour, label, save }

    private let model: RadialModel
    private weak var radial: RadialMenu?
    private var mode = Mode.switchStage
    private var hover = Hover.none
    private var tileOpen = false

    init(model: RadialModel, menu: RadialMenu) {
        self.model = model
        self.radial = menu
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setBoundsSize(Self.design)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
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
        case .switchStage, .move: return pad(model.stages.map { .stage($0) })
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
            return model.bookmarked ? ("Remove the bookmark from the \(app) window", "It stops coming with ⌃⌥0")
                : ("Bookmark the \(app) window", "Fetch Bookmarked Windows (⌃⌥0) brings it into the stage you are in")
        case .fetch: return ("Fetch bookmarked windows", "⌃⌥0 · brings bookmarked windows into this stage")
        case .desktops:
            return model.others.isEmpty ? ("No labelled stages on other desktops", "Label stages there to list them here")
                : ("\(model.otherDesktops) stages", "Switches desktop, then stage")
        case .move: return ("Move the \(app) window to…", "Or hold ⌥ while pointing at a stage")
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
        return NSPoint(x: Self.centre.x + radius * sin(t), y: Self.centre.y - radius * cos(t))
    }

    private func sector(_ r0: CGFloat, _ r1: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(r1, a0))
        path.appendArc(withCenter: Self.centre, radius: r1, startAngle: a0 - 90, endAngle: a1 - 90, clockwise: false)
        path.line(to: point(r0, a1))
        path.appendArc(withCenter: Self.centre, radius: r0, startAngle: a1 - 90, endAngle: a0 - 90, clockwise: true)
        path.close()
        return path
    }

    private func hit(_ p: NSPoint) -> Hover {
        let dx = p.x - Self.centre.x, dy = p.y - Self.centre.y
        let r = hypot(dx, dy)
        var a = atan2(dx, -dy) * 180 / .pi
        if a < 0 { a += 360 }
        if tileOpen, r >= rOuter, r <= rArc + 16 {
            let relative = a > 180 ? a - 360 : a
            if relative >= -90, relative <= 90 { return .arc(min(8, max(0, Int((relative + 90) / 20)))) }
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
        switch next {
        case .outer(0): tileOpen = true
        case .outer, .inner, .centre: tileOpen = false
        default: break
        }
        hover = next
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }

    override func flagsChanged(with event: NSEvent) { needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { radial?.close() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let target = hit(convert(event.locationInWindow, from: nil))
        guard let menu = radial else { return }
        switch target {
        case .none:
            menu.close()
        case .centre:
            if mode == .switchStage { menu.close() } else { mode = .switchStage; needsDisplay = true }
        case .arc(let i):
            menu.tile(model.window, Self.tiles[i].part)
        case .inner(let i):
            switch items[i] {
            case .empty: break
            case .colour(_, let hex): menu.colour(hex)
            case .stage(let stage):
                switch (effectiveMode, stage.target) {
                case (.move, .live(let id)):
                    if stage.isCurrent { NSSound.beep() } else { menu.move(model.window, to: id) }
                case (_, .live(let id)):
                    if stage.isCurrent { menu.close() } else { menu.switchTo(id) }
                case (_, .saved(let id)):
                    menu.switchSaved(id)
                }
            }
        case .outer(let i):
            switch Action.allCases[i] {
            case .tile: tileOpen.toggle()
            case .bookmark: menu.toggleBookmark(model.window)
            case .fetch: menu.fetchBookmarks()
            case .desktops: if !model.others.isEmpty { mode = mode == .desktops ? .switchStage : .desktops }
            case .move:
                mode = mode == .move ? .switchStage : .move
                Log.write("Radial menu: Move chosen (\(mode == .move ? "on" : "off")).")
            case .colour: mode = mode == .colour ? .switchStage : .colour
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
        // Disc with shadow.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        Self.outerFill.setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.centre.x - rOuter, y: Self.centre.y - rOuter, width: rOuter * 2, height: rOuter * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        if tileOpen { drawArc() }

        // Outer ring.
        for (i, action) in Action.allCases.enumerated() {
            let a = CGFloat(i) * 45
            let path = sector(rInner, rOuter, a - 22.5, a + 22.5)
            Self.outerFill.setFill(); path.fill()
            let highlight: CGFloat = hover == .outer(i) ? 0.14 : (isActive(action) ? 0.08 : 0)
            if highlight > 0 { NSColor(white: 1, alpha: highlight).setFill(); path.fill() }
            Self.separator.setStroke(); path.lineWidth = 1; path.stroke()
            let dimmed = action == .desktops && model.others.isEmpty
            let colour = dimmed ? Self.secondary.withAlphaComponent(0.5) : (isActive(action) ? .white : Self.secondary)
            drawSymbol(symbol(action), at: point(178, a), size: 19, colour: colour)
        }

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
            case .empty: break
            }
            if let tint {
                tint.withAlphaComponent(hovered ? 0.42 : 0.2).setFill(); path.fill()
            } else if hovered, !item.isEmpty {
                NSColor(white: 1, alpha: 0.14).setFill(); path.fill()
            }
            Self.separator.setStroke(); path.lineWidth = 1; path.stroke()
            if case .stage(let stage) = item, stage.isCurrent, effectiveMode != .desktops {
                let outline = sector(rCentre + 2, rInner - 2, a - step / 2 + 0.8, a + step / 2 - 0.8)
                outline.lineWidth = 2
                Self.primary.setStroke(); outline.stroke()
            }
            drawItem(item, at: point(rCentre + (rInner - rCentre) / 2 + 2, a))
        }

        // Centre.
        let centreRect = NSRect(x: Self.centre.x - rCentre, y: Self.centre.y - rCentre, width: rCentre * 2, height: rCentre * 2)
        Self.centreFill.setFill()
        NSBezierPath(ovalIn: centreRect).fill()
        if hover == .centre { NSColor(white: 1, alpha: 0.12).setFill(); NSBezierPath(ovalIn: centreRect).fill() }
        drawSymbol(mode == .switchStage ? "xmark" : "chevron.left", at: Self.centre, size: 20, colour: Self.primary)

        drawCaption()
    }

    private func drawArc() {
        for (i, tile) in Self.tiles.enumerated() {
            let a = -80 + CGFloat(i) * 20
            let path = sector(rOuter + 6, rArc, a - 10, a + 10)
            Self.outerFill.setFill(); path.fill()
            if hover == .arc(i) { NSColor(white: 1, alpha: 0.16).setFill(); path.fill() }
            Self.separator.setStroke(); path.lineWidth = 1; path.stroke()
            drawTile(tile.part, at: point(262, a))
        }
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

    private func drawItem(_ item: Item, at p: NSPoint) {
        switch item {
        case .empty:
            break
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
                // The label, with the stage's colour as a dot above it.
                var top = p.y - 20
                if let hex = stage.colour {
                    Palette.color(hex).setFill()
                    NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 26, width: 12, height: 12)).fill()
                    top = p.y - 10
                }
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.lineBreakMode = .byWordWrapping
                let text = NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Self.primary, .paragraphStyle: style])
                let box = NSRect(x: p.x - 40, y: top, width: 80, height: stage.colour == nil ? 40 : 36)
                text.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
        case .move: modeName = "Move window"; title = "Move the \(app) window"; detail = "Point at the stage to move it to"
        case .desktops: modeName = model.otherDesktops; title = model.otherDesktops; detail = "Point at a stage to switch desktop and stage"
        case .colour: modeName = "Colour stage"; title = "Colour for \(model.currentTitle)"; detail = "Changes its dot and wallpaper"
        }
        switch hover {
        case .centre:
            title = mode == .switchStage ? "Close" : "Back"
            detail = mode == .switchStage ? "Esc or a click outside also closes the menu" : "Back to the stages"
        case .outer(let i):
            (title, detail) = describe(Action.allCases[i])
        case .arc(let i):
            title = Self.tiles[i].name
            detail = "Tile the \(app) window"
        case .inner(let i):
            switch items[i] {
            case .empty: title = "Empty"; detail = "Up to 8 stages per desktop"
            case .colour(let name, let hex): title = name; detail = hex == model.currentColour ? "Current colour" : "Colour \(model.currentTitle)"
            case .stage(let stage):
                let key = stage.number.map { "⌃⌥\($0)" }
                switch effectiveMode {
                case .move:
                    title = "Move the \(app) window to \(stage.title)"
                    detail = stage.isCurrent ? "It is already in this stage" : "Keeps its size and position"
                case .desktops:
                    title = stage.title
                    detail = [stage.place, key].compactMap { $0 }.joined(separator: " · ")
                default:
                    title = stage.label ?? "\(stage.position) · \(stage.title)"
                    detail = stage.isCurrent ? "Current stage" : "Switch" + (key.map { " · \($0)" } ?? "")
                }
            }
        case .none:
            if tileOpen { title = "Tile the \(app) window"; detail = "Point at a position in the arc" }
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
        let box = NSRect(x: Self.centre.x - width / 2, y: Self.centre.y + rOuter + 14, width: width, height: height)
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        var y = box.minY + 8
        for string in strings {
            let s = string.size()
            let clipped = NSRect(x: max(box.minX + 12, Self.centre.x - s.width / 2), y: y, width: min(s.width, box.width - 24), height: s.height)
            string.draw(with: clipped, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += s.height + 2
        }
    }
}

extension Actions {
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

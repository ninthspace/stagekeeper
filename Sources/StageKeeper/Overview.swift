import AppKit

/// A full-screen view of every stage on this desktop, each drawn as a small screen with its
/// windows as boxes at their real position and size, with the app's icon and the window's
/// title. Click a stage to switch to it; Esc or a click outside the stages closes it.
/// Opened from the centre of the radial menu.
final class Overview {
    struct Window {
        let frame: CGRect
        let title: String
        let app: String
        let icon: NSImage?
    }

    struct Stage {
        let title: String
        let colour: String?
        let shortcut: String?
        let isCurrent: Bool
        /// Back to front.
        let windows: [Window]
        let live: LiveStage
    }

    private let perform: (@escaping () throws -> Void) -> Void
    private var panel: NSPanel?
    private var keys: Any?

    init(perform: @escaping (@escaping () throws -> Void) -> Void) { self.perform = perform }

    var isOpen: Bool { panel != nil }

    func open() throws {
        let (stages, snapshot) = try Self.read()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = OverviewPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        let view = OverviewView(stages: stages) { [weak self] chosen in
            self?.close()
            guard let chosen, !chosen.isCurrent else { return }
            self?.perform { try Actions.switchTo(chosen.live, in: snapshot) }
        }
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        self.panel = panel
        Log.write("Stage overview opened: \(stages.count) stages.")
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// The stages, most recently used first, as in the radial menu.
    private static func read() throws -> ([Stage], Snapshot) {
        let list = try StageList.read()
        let shortcuts = Shortcuts.stages()
        let rank = Dictionary(Snapshot.zOrder().enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let stages = list.entries.map { entry in
            let windows = entry.windows.sorted { (rank[$0.id] ?? .max) > (rank[$1.id] ?? .max) }
                .map { Window(frame: $0.frame, title: $0.title, app: $0.app, icon: $0.icon) }
            return Stage(title: entry.title, colour: entry.saved?.color, shortcut: entry.saved?.id.flatMap { shortcuts[$0]?.display },
                         isCurrent: entry.live.kind == .current, windows: windows, live: entry.live)
        }
        return (stages, list.snapshot)
    }
}

private final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class OverviewView: NSView {
    private let stages: [Overview.Stage]
    private let choose: (Overview.Stage?) -> Void
    private var hover: Int?
    private var tiles: [CGRect] = []
    private var tracking: NSTrackingArea?

    init(stages: [Overview.Stage], choose: @escaping (Overview.Stage?) -> Void) {
        self.stages = stages
        self.choose = choose
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// One tile per stage, in a grid that fits the screen, each with the main screen's shape.
    private func layOutTiles() {
        let count = max(stages.count, 1)
        let screen = NSScreen.screens.first?.frame.size ?? bounds.size
        let aspect = screen.width / max(screen.height, 1)
        let margin: CGFloat = 60, gap: CGFloat = 36, caption: CGFloat = 30
        let area = bounds.insetBy(dx: margin, dy: margin)
        var best: (columns: Int, width: CGFloat) = (1, 0)
        for columns in 1...count {
            let rows = Int(ceil(Double(count) / Double(columns)))
            let width = min((area.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
                            ((area.height - gap * CGFloat(rows - 1)) / CGFloat(rows) - caption) * aspect)
            if width > best.width { best = (columns, width) }
        }
        let width = best.width, height = width / aspect
        let rows = Int(ceil(Double(count) / Double(best.columns)))
        let gridHeight = CGFloat(rows) * (height + caption) + CGFloat(rows - 1) * gap
        tiles = stages.indices.map { i in
            let row = i / best.columns, column = i % best.columns
            let inRow = row == rows - 1 ? count - row * best.columns : best.columns
            let rowWidth = CGFloat(inRow) * width + CGFloat(inRow - 1) * gap
            let x = bounds.midX - rowWidth / 2 + CGFloat(column) * (width + gap)
            let y = bounds.midY - gridHeight / 2 + CGFloat(row) * (height + caption + gap) + caption
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        layOutTiles()
        NSColor(white: 0, alpha: 0.6).setFill()
        bounds.fill()
        let screen = NSScreen.screens.first?.frame.size ?? bounds.size
        for (i, stage) in stages.enumerated() {
            let tile = tiles[i]
            let scale = tile.width / screen.width
            let shape = NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8)
            (stage.colour.map { Palette.color($0).blended(withFraction: 0.75, of: NSColor(white: 0.12, alpha: 1)) } ?? NSColor(white: 0.16, alpha: 1))?.setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            for window in stage.windows {
                let box = CGRect(x: tile.minX + window.frame.minX * scale, y: tile.minY + window.frame.minY * scale,
                                 width: window.frame.width * scale, height: window.frame.height * scale)
                drawWindow(window, in: box)
            }
            NSGraphicsContext.restoreGraphicsState()
            if stage.isCurrent || hover == i {
                let outline = NSBezierPath(roundedRect: tile.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
                outline.lineWidth = stage.isCurrent ? 3 : 2
                (hover == i ? NSColor.white : NSColor(white: 1, alpha: 0.7)).setStroke()
                outline.stroke()
            }
            drawCaption(stage, above: tile)
        }
    }

    private func drawWindow(_ window: Overview.Window, in box: CGRect) {
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSColor(white: 0.93, alpha: 1).setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
        let bar = CGRect(x: box.minX, y: box.minY, width: box.width, height: min(18, box.height))
        NSColor(white: 0.82, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
        let side = min(36, box.width * 0.4, box.height * 0.4)
        if let icon = window.icon, side >= 10 {
            icon.draw(in: CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let title = window.title.isEmpty ? window.app : window.title
        if box.width > 40, bar.height >= 12 {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = .center
            NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.15, alpha: 1), .paragraphStyle: style])
                .draw(with: bar.insetBy(dx: 6, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawCaption(_ stage: Overview.Stage, above tile: CGRect) {
        var x = tile.minX
        if let hex = stage.colour {
            Palette.color(hex).setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: tile.minY - 20, width: 11, height: 11)).fill()
            x += 17
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = stage.title + (stage.shortcut.map { "   \($0)" } ?? "")
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style])
            .draw(with: CGRect(x: x, y: tile.minY - 24, width: tile.maxX - x, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func tile(at point: NSPoint) -> Int? {
        tiles.firstIndex { $0.insetBy(dx: -6, dy: -30).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let next = tile(at: convert(event.locationInWindow, from: nil))
        if next != hover { hover = next; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        choose(tile(at: convert(event.locationInWindow, from: nil)).map { stages[$0] })
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { choose(nil) } else { super.keyDown(with: event) }
    }
}

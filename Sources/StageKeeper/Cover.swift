import AppKit

/// Covers the corner where hidden windows sit. macOS keeps part of every window on screen, so
/// each hidden window leaves a strip one point wide and as tall as its title bar in the corner of
/// the rightmost screen, with its shadow around it. The cover is a small window of StageKeeper's
/// own over that corner, above other windows, painted with what the screen's wallpaper shows
/// there. Clicks pass through it, and it stays out of Mission Control, so the hidden windows
/// still show there.
@MainActor
final class CornerCover {
    static let shared = CornerCover()

    /// Wide enough for the shadows left of the strips, tall enough for the tallest title bar
    /// and the shadow above it.
    static let size = NSSize(width: 72, height: 150)

    private var panel: NSPanel?
    private let view = CoverView()
    private var signature: String?

    /// Shows the cover while any desktop has hidden windows, and hides it otherwise. Cheap when
    /// nothing changed, so it can run on every tick.
    func update() {
        guard Engine.active, Engine.hasHidden, let screen = Screens.hidingScreen else {
            panel?.orderOut(nil)
            return
        }
        let size = Self.size
        let frame = NSRect(x: screen.frame.maxX - size.width, y: screen.frame.minY, width: size.width, height: size.height)
        let workspace = NSWorkspace.shared
        let url = workspace.desktopImageURL(for: screen)
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let next = "\(frame)|\(screen.frame)|\(url?.path ?? "")|\(options.map { "\($0.key.rawValue)=\($0.value)" }.sorted())"
        if next != signature {
            signature = next
            view.paint(screen: screen.frame.size, scale: screen.backingScaleFactor, cover: frame.size, url: url, options: options)
        }
        let panel = self.panel ?? makePanel()
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = view
        self.panel = panel
        return panel
    }
}

/// Draws the part of the wallpaper under the cover: the image placed on the screen as the
/// wallpaper options place it, over the wallpaper's fill colour.
private final class CoverView: NSView {
    private var image: CGImage?
    private var fill: NSColor = .black
    /// Where the image lies, in the cover's coordinates.
    private var placed: CGRect = .zero

    func paint(screen: CGSize, scale: CGFloat, cover: CGSize, url: URL?, options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        fill = (options[.fillColor] as? NSColor) ?? .black
        image = url.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        if let image {
            let pixels = CGSize(width: image.width, height: image.height)
            let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
            let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
            let fit = min(screen.width / pixels.width, screen.height / pixels.height)
            let fillScale = max(screen.width / pixels.width, screen.height / pixels.height)
            var size: CGSize
            switch scaling {
            case .scaleAxesIndependently: size = screen
            case .scaleProportionallyDown: size = pixels.applying(.init(scaleX: min(1 / scale, fit), y: min(1 / scale, fit)))
            case .scaleNone: size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
            default: let s = clipping ? fillScale : fit; size = CGSize(width: pixels.width * s, height: pixels.height * s)
            }
            // Centred on the screen; the cover sits in the screen's bottom-right corner.
            let onScreen = CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
            placed = onScreen.offsetBy(dx: -(screen.width - cover.width), dy: 0)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: placed)
    }
}

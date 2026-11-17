import AppKit

/// The colours offered in the menu. Any "#RRGGBB" value also works from the command line.
enum Palette {
    static let colours: [(name: String, hex: String)] = [
        ("Red", "#C8383E"),
        ("Orange", "#D9661F"),
        ("Yellow", "#D9A21F"),
        ("Green", "#3E8E4F"),
        ("Teal", "#16867A"),
        ("Blue", "#1F6FC8"),
        ("Indigo", "#3E4FB8"),
        ("Purple", "#7A47B0"),
        ("Pink", "#B83E86"),
        ("Graphite", "#5A5D66"),
    ]

    /// Accepts a palette name or "#RRGGBB"; returns the normalised hex, or nil if neither.
    static func resolve(_ value: String) -> String? {
        if let named = colours.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
            return named.hex
        }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, UInt32(hex, radix: 16) != nil else { return nil }
        return "#" + hex.uppercased()
    }

    static func name(_ hex: String) -> String {
        colours.first { $0.hex == hex }?.name ?? hex
    }

    static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// A filled circle for the menu bar and menu items.
    static func dot(_ hex: String, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color(hex).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// Sets every screen's wallpaper to the current stage's colour, and puts the user's own
/// wallpaper back on stages without a colour and when the app quits.
enum Wallpaper {
    private static var lastApplied: String??

    static func apply(_ hex: String?) {
        if lastApplied == .some(hex) { return }
        lastApplied = .some(hex)
        var state = AgentState.load()
        let workspace = NSWorkspace.shared
        for screen in NSScreen.screens {
            let key = screenKey(screen)
            let current = workspace.desktopImageURL(for: screen)
            let currentIsOurs = current.map(isOurs) ?? false
            if let hex {
                if let current, !currentIsOurs { state.originalWallpapers = (state.originalWallpapers ?? [:]).merging([key: current.absoluteString]) { $1 } }
                guard let url = image(for: hex), url != current else { continue }
                let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                    .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                    .allowClipping: true,
                    .fillColor: Palette.color(hex),
                ]
                do { try workspace.setDesktopImageURL(url, for: screen, options: options) }
                catch { Log.write("Could not set wallpaper: \(error)") }
            } else if currentIsOurs, let saved = state.originalWallpapers?[key], let url = URL(string: saved) {
                do { try workspace.setDesktopImageURL(url, for: screen, options: [:]) }
                catch { Log.write("Could not restore wallpaper \(saved): \(error)") }
            }
        }
        state.write()
    }

    private static func screenKey(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    private static func isOurs(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(Paths.wallpapers.standardizedFileURL.path)
    }

    /// A small solid PNG per colour; macOS stretches it to fill the screen.
    private static func image(for hex: String) -> URL? {
        let url = Paths.wallpapers.appendingPathComponent(String(hex.dropFirst()) + ".png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        Palette.color(hex).setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }
}

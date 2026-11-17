import AppKit

/// One small app per labelled stage in ~/Applications/StageKeeper Stages. Each app opens
/// stagekeeper://switch/<stage id>, which the menu-bar app handles. The app is found by the
/// stage ID in its Info.plist, so renaming a stage renames the app in place.
enum DockApps {
    private static let idKey = "StageKeeperStageID"
    private static let colourKey = "StageKeeperColor"

    static func sync(_ layout: Layout) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.dockApps, withIntermediateDirectories: true)
        let existing = installed()
        for stage in layout.stages {
            guard let id = stage.id, let label = stage.label else { continue }
            let target = Paths.dockApps.appendingPathComponent(fileName(label) + ".app")
            var app = existing[id]
            if let current = app, current.standardizedFileURL != target.standardizedFileURL {
                if fm.fileExists(atPath: target.path) {
                    Log.write("Cannot rename \(current.lastPathComponent): \(target.lastPathComponent) already exists.")
                } else {
                    do { try fm.moveItem(at: current, to: target); app = target }
                    catch { Log.write("Could not rename \(current.lastPathComponent): \(error)") }
                }
            }
            write(app ?? target, id: id, label: label, colour: stage.color)
        }
    }

    /// Deletes the app for a stage whose label was removed.
    static func remove(_ id: UUID) {
        guard let url = installed()[id] else { return }
        try? FileManager.default.removeItem(at: url)
        Log.write("Removed \(url.lastPathComponent).")
    }

    private static func installed() -> [UUID: URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Paths.dockApps, includingPropertiesForKeys: nil)) ?? []
        var result: [UUID: URL] = [:]
        for url in urls where url.pathExtension == "app" {
            let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            if let raw = plist?[idKey] as? String, let id = UUID(uuidString: raw) { result[id] = url }
        }
        return result
    }

    /// Finder and the Dock show "/" as ":", and ":" is not allowed in a file name.
    private static func fileName(_ label: String) -> String {
        label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private static func write(_ app: URL, id: UUID, label: String, colour: String?) {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let plistURL = contents.appendingPathComponent("Info.plist")
        let old = NSDictionary(contentsOf: plistURL)
        let fresh = old == nil
        try? fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let script = macOS.appendingPathComponent("switch")
        let body = "#!/bin/sh\nexec /usr/bin/open -g \"stagekeeper://switch/\(id.uuidString)\"\n"
        if (try? String(contentsOf: script, encoding: .utf8)) != body {
            try? body.write(to: script, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        let plist: [String: Any] = [
            "CFBundleIdentifier": "local.stagekeeper.stage.\(id.uuidString.lowercased())",
            "CFBundleName": label,
            "CFBundleDisplayName": label,
            "CFBundleExecutable": "switch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
            idKey: id.uuidString,
            colourKey: colour ?? "",
        ]
        if (old as? [String: AnyHashable]) != (plist as? [String: AnyHashable]) {
            (plist as NSDictionary).write(to: plistURL, atomically: true)
        }
        if fresh || old?[colourKey] as? String != (colour ?? "") || old?["CFBundleName"] as? String != label {
            NSWorkspace.shared.setIcon(icon(label: label, colour: colour), forFile: app.path, options: [])
        }
    }

    /// A rounded square in the stage colour (grey without one) with the label's first letters.
    private static func icon(label: String, colour: String?) -> NSImage {
        let size: CGFloat = 512
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let tile = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
            (colour.map(Palette.color) ?? NSColor.systemGray).setFill()
            path.fill()
            let initials = label.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
            let text = initials.isEmpty ? "?" : initials
            let font = NSFont.systemFont(ofSize: size * (text.count > 1 ? 0.3 : 0.38), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let measured = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: tile.midX - measured.width / 2, y: tile.midY - measured.height / 2),
                      withAttributes: attributes)
            return true
        }
    }
}

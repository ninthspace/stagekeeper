import AppKit

/// A window that comes with you when StageKeeper switches stage (⌃⌥1–9, Dock apps, the menu).
///
/// Stage Manager has no such setting. Before switching, StageKeeper brings the pinned windows to
/// the front of the stage you are leaving, so their previews are on top of that stage's strip
/// thumbnail, then switches and drags them into the new stage. Switches you make yourself, by
/// clicking the strip or with ⌘Tab, do not carry pinned windows: reacting to those means reading
/// the strip while it animates and grabbing previews buried under others, which moved the wrong
/// windows.
struct Pin: Codable, Equatable {
    var bundleID: String
    var appName: String
    var title: String
    /// Only meaningful during the boot it was recorded in.
    var windowID: UInt32
    var bootTime: Date
    var desktop: String

    init(window: LiveWindow, desktop: String) {
        bundleID = window.bundleID
        appName = window.appName
        title = window.title
        windowID = window.id
        bootTime = System.bootTime
        self.desktop = desktop
    }
}

enum Pins {
    static func load() -> [Pin] { AgentState.load().pins ?? [] }

    private static func save(_ pins: [Pin]) {
        var state = AgentState.load()
        state.pins = pins
        state.write()
    }

    /// Pinned windows on the desktop showing now, as live window IDs. A pin from an earlier boot
    /// is matched by app and title and updated to this boot's window ID. A pin whose window has
    /// closed is dropped.
    static func resolve(_ snapshot: Snapshot) -> [CGWindowID] {
        let desktop = Desktops.current().key
        var pins = load()
        guard !pins.isEmpty else { return [] }
        var ids: [CGWindowID] = []
        var changed = false
        pins = pins.compactMap { pin in
            guard pin.desktop == desktop else { return pin }
            if System.sameBoot(pin.bootTime), let live = snapshot.windows[pin.windowID], live.bundleID == pin.bundleID {
                ids.append(live.id)
                if live.title != pin.title { changed = true; return Pin(window: live, desktop: desktop) }
                return pin
            }
            if let live = snapshot.windows.values.first(where: { $0.bundleID == pin.bundleID && $0.title == pin.title && !ids.contains($0.id) }) {
                ids.append(live.id)
                changed = true
                return Pin(window: live, desktop: desktop)
            }
            if System.sameBoot(pin.bootTime) {
                changed = true
                Log.write("Unpinned the closed \(pin.appName) window \"\(pin.title)\".")
                return nil
            }
            return pin
        }
        if changed { save(pins) }
        return ids
    }

    static func isPinned(_ id: CGWindowID, _ snapshot: Snapshot) -> Bool {
        resolve(snapshot).contains(id)
    }

    static func pin(_ window: LiveWindow) {
        var pins = load().filter { !($0.windowID == window.id && System.sameBoot($0.bootTime)) }
        pins.append(Pin(window: window, desktop: Desktops.current().key))
        save(pins)
        Log.write("Pinned the \(window.appName) window \"\(window.title)\".")
    }

    static func unpin(_ id: CGWindowID) {
        let pins = load()
        save(pins.filter { !($0.windowID == id && System.sameBoot($0.bootTime)) })
        if let pin = pins.first(where: { $0.windowID == id }) { Log.write("Unpinned the \(pin.appName) window \"\(pin.title)\".") }
    }

    static func unpin(at index: Int) {
        var pins = load()
        guard pins.indices.contains(index) else { return }
        let pin = pins.remove(at: index)
        save(pins)
        Log.write("Unpinned the \(pin.appName) window \"\(pin.title)\".")
    }
}

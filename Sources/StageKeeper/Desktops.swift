import AppKit

/// The desktops (Spaces) macOS manages, read through private SkyLight calls that have been
/// stable for many releases. Stage Manager keeps separate stages on each desktop, and
/// StageKeeper can only see the stages of the desktop that is showing, so it keeps one
/// layout per desktop.
///
/// A desktop is identified by the UUID macOS stores for it, which stays the same across
/// restarts. The first desktop on the main display has an empty UUID; it is called "main".
struct Desktop: Equatable {
    let key: String
    /// 1-based position among the display's desktops, as Mission Control shows them.
    let number: Int
    let spaceID: Int
}

enum Desktops {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> Int
    private typealias ManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private static let connection: Int32? = symbol("SLSMainConnectionID", MainConnection.self)?()

    /// Every ordinary desktop on every display (full-screen app spaces are left out).
    static func all() -> [Desktop] {
        guard let connection, let copy = symbol("SLSCopyManagedDisplaySpaces", ManagedDisplaySpaces.self),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result: [Desktop] = []
        for display in displays {
            let spaces = (display["Spaces"] as? [[String: Any]]) ?? []
            var number = 0
            for space in spaces where (space["type"] as? NSNumber)?.intValue == 0 {
                number += 1
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.intValue else { continue }
                let uuid = (space["uuid"] as? String) ?? ""
                result.append(Desktop(key: uuid.isEmpty ? "main" : uuid, number: number, spaceID: id))
            }
        }
        return result
    }

    /// The desktop showing now, or "main" when the private calls are unavailable.
    static func current() -> Desktop {
        let fallback = Desktop(key: "main", number: 1, spaceID: 0)
        guard let connection, let active = symbol("SLSGetActiveSpace", ActiveSpace.self) else { return fallback }
        let id = active(connection)
        return all().first { $0.spaceID == id } ?? fallback
    }

    /// The key and modifiers of Mission Control's "Switch to Desktop N" shortcut, when it is
    /// turned on (System Settings › Keyboard › Keyboard Shortcuts › Mission Control).
    /// macOS stores Desktop 1–16 as symbolic hot keys 118–133.
    static func switchShortcut(toDesktop number: Int) -> (key: CGKeyCode, flags: CGEventFlags)? {
        guard (1...16).contains(number),
              let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotKeys[String(117 + number)] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
              parameters.count == 3, parameters[1].intValue != 65535 else { return nil }
        return (CGKeyCode(parameters[1].intValue), CGEventFlags(rawValue: parameters[2].uint64Value))
    }

    static func number(of key: String) -> Int? {
        all().first { $0.key == key }?.number
    }
}

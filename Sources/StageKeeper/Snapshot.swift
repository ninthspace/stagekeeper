import AppKit

struct LiveWindow {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    let element: AXUIElement
}

/// One thumbnail in the Stage Manager strip: a stage that is not the current one.
struct StripItem {
    let button: AXUIElement
    let windowIDs: [CGWindowID]
}

struct LiveStage {
    enum Kind: String { case current, strip, overflow }
    let kind: Kind
    let windowIDs: [CGWindowID]
}

enum StageError: Error, CustomStringConvertible {
    case notTrusted
    case stageManagerOff
    case windowManagerMissing
    case noLayout(String)
    case other(String)

    var description: String {
        switch self {
        case .notTrusted: return "This process does not have Accessibility permission in System Settings › Privacy & Security › Device Control and Data Access (called Accessibility before macOS 27)."
        case .stageManagerOff: return "Stage Manager is turned off."
        case .windowManagerMissing: return "The Stage Manager process (WindowManager) is not running."
        case .noLayout(let path): return "No saved layout at \(path). Run `stagekeeper save` first."
        case .other(let message): return message
        }
    }
}

/// The state of every stage at one moment.
///
/// Stages come in three kinds: the current stage (on screen, not in the strip), the stages
/// shown in the strip, and overflow windows that are in neither because the strip shows a
/// limited number of stages. Overflow windows are grouped one stage per app, because their
/// real grouping cannot be read.
struct Snapshot {
    let windows: [CGWindowID: LiveWindow]
    let order: [CGWindowID]
    let strip: [StripItem]
    let current: [CGWindowID]
    let stages: [LiveStage]

    static var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    static func take() throws -> Snapshot {
        guard AX.isTrusted(prompt: false) else { throw StageError.notTrusted }
        guard stageManagerEnabled else { throw StageError.stageManagerOff }

        let strip = try readStrip()
        let (windows, order) = readWindows()
        let onScreen = onScreenWindowIDs()

        let inStrip = Set(strip.flatMap(\.windowIDs))
        let current = order.filter { !inStrip.contains($0) && onScreen.contains($0) }
        let currentSet = Set(current)

        var stages: [LiveStage] = []
        if !current.isEmpty { stages.append(LiveStage(kind: .current, windowIDs: current)) }
        for item in strip {
            let ids = item.windowIDs.filter { windows[$0] != nil }
            if !ids.isEmpty { stages.append(LiveStage(kind: .strip, windowIDs: ids)) }
        }
        var overflowByApp: [String: [CGWindowID]] = [:]
        var appOrder: [String] = []
        for id in order where !inStrip.contains(id) && !currentSet.contains(id) {
            let bundle = windows[id]!.bundleID
            if overflowByApp[bundle] == nil { appOrder.append(bundle) }
            overflowByApp[bundle, default: []].append(id)
        }
        for bundle in appOrder {
            stages.append(LiveStage(kind: .overflow, windowIDs: overflowByApp[bundle]!))
        }

        return Snapshot(windows: windows, order: order, strip: strip, current: current, stages: stages)
    }

    func stripItem(containing id: CGWindowID) -> StripItem? {
        strip.first { $0.windowIDs.contains(id) }
    }

    static func readStrip() throws -> [StripItem] {
        guard let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else {
            throw StageError.windowManagerMissing
        }
        var items: [StripItem] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 8 else { return }
            if AX.string(element, kAXRoleAttribute) == kAXButtonRole,
               let ids = AX.value(element, "AXWindowsIDs") as? [NSNumber] {
                items.append(StripItem(button: element, windowIDs: ids.map { CGWindowID($0.uint32Value) }))
                return
            }
            for child in AX.children(element) { walk(child, depth: depth + 1) }
        }
        walk(AX.application(wm.processIdentifier), depth: 0)
        return items
    }

    private static func readWindows() -> ([CGWindowID: LiveWindow], [CGWindowID]) {
        var windows: [CGWindowID: LiveWindow] = [:]
        var order: [CGWindowID] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier else { continue }
            let axApp = AX.application(app.processIdentifier)
            for element in AX.elements(axApp, kAXWindowsAttribute) {
                guard AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      AX.bool(element, kAXMinimizedAttribute) != true,
                      let id = AX.windowID(element), windows[id] == nil else { continue }
                windows[id] = LiveWindow(
                    id: id,
                    pid: app.processIdentifier,
                    bundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    title: AX.string(element, kAXTitleAttribute) ?? "",
                    frame: AX.frame(element) ?? .zero,
                    element: element
                )
                order.append(id)
            }
        }
        return (windows, order)
    }

    /// Normal-level windows front to back, including windows Stage Manager has moved off screen.
    static func zOrder() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }
}

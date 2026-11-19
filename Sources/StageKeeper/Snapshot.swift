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
    /// With StageKeeper's own stages, the saved stage this stage is.
    var savedID: UUID? = nil
}

enum StageError: Error, CustomStringConvertible {
    case notTrusted
    case windowManagerMissing
    case noLayout(String)
    case other(String)

    var description: String {
        switch self {
        case .notTrusted: return "This process does not have Accessibility permission in System Settings › Privacy & Security › Device Control and Data Access (called Accessibility before macOS 27)."
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
        if Engine.active {
            // Only the active desktop's windows: with a desktop per display, Accessibility also
            // lists the other display's windows, which belong to that desktop's stages.
            var (windows, order) = readWindows()
            let here = Desktops.onActiveSpace(order)
            windows = windows.filter { here.contains($0.key) }
            order = order.filter(here.contains)
            let (current, others) = Engine.stages(windows, order: order)
            var stages: [LiveStage] = []
            if !current.windows.isEmpty { stages.append(LiveStage(kind: .current, windowIDs: current.windows, savedID: current.savedID)) }
            stages += others.map { LiveStage(kind: .strip, windowIDs: $0.windows, savedID: $0.savedID) }
            return Snapshot(windows: windows, order: order, strip: [], current: current.windows, stages: stages)
        }

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

    /// Apps that did not answer Accessibility: how many reads in a row they missed, and when to
    /// ask them again. An app that never answers (Solo, for one) costs the full one-second
    /// timeout on every read, which made every StageKeeper action and the radial menu a second
    /// slower. An app that is only busy (Word opening a document) misses one read, so an app is
    /// skipped only after two misses in a row, first for 30 seconds, doubling up to 5 minutes,
    /// and never while it is the frontmost app; one answer clears its record.
    private struct Unresponsive { var misses = 0; var skips = 0; var until = Date.distantPast }
    nonisolated(unsafe) private static var unresponsive: [pid_t: Unresponsive] = [:]
    private static let unresponsiveLock = NSLock()

    private static func readWindows() -> ([CGWindowID: LiveWindow], [CGWindowID]) {
        var windows: [CGWindowID: LiveWindow] = [:]
        var order: [CGWindowID] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier
            unresponsiveLock.lock()
            let record = unresponsive[pid]
            unresponsiveLock.unlock()
            if let record, record.until > Date(), !app.isActive { continue }
            let axApp = AX.application(pid)
            let asked = Date()
            let elements = AX.elements(axApp, kAXWindowsAttribute)
            let missed = elements.isEmpty && Date().timeIntervalSince(asked) > 0.5
            unresponsiveLock.lock()
            if missed {
                var next = record ?? Unresponsive()
                next.misses += 1
                if next.misses >= 2, !app.isActive {
                    let seconds = min(30 * pow(2, Double(next.skips)), 300)
                    next.skips += 1
                    next.misses = 0
                    next.until = Date().addingTimeInterval(seconds)
                    Log.write("\(app.localizedName ?? bundleID) did not answer Accessibility twice; skipping it for \(Int(seconds)) s.")
                }
                unresponsive[pid] = next
            } else if record != nil {
                unresponsive[pid] = nil
            }
            unresponsiveLock.unlock()
            if missed { continue }
            for element in elements {
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

    /// How long each part of reading the stages takes, for finding what makes StageKeeper slow.
    static func timings() -> String {
        func time(_ body: () -> Void) -> String {
            let start = Date(); body(); return String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
        }
        var lines = ["strip: " + time { _ = try? readStrip() }]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            var count = 0
            let spent = time {
                let axApp = AX.application(app.processIdentifier)
                for element in AX.elements(axApp, kAXWindowsAttribute) {
                    count += 1
                    _ = AX.string(element, kAXSubroleAttribute); _ = AX.bool(element, kAXMinimizedAttribute)
                    _ = AX.windowID(element); _ = AX.string(element, kAXTitleAttribute); _ = AX.frame(element)
                }
            }
            lines.append("\(app.localizedName ?? "?"): \(spent), \(count) windows")
        }
        lines.append("on-screen list: " + time { _ = onScreenWindowIDs() })
        lines.append("whole snapshot: " + time { _ = try? take() })
        return lines.joined(separator: "\n")
    }

    /// Normal-level windows front to back, including windows Stage Manager has moved off screen.
    struct ServerWindow {
        let pid: pid_t
        /// In Accessibility coordinates.
        let frame: CGRect
    }

    /// Every ordinary window the window server has, on every desktop, with its app and frame.
    static func serverWindows() -> [CGWindowID: ServerWindow] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [CGWindowID: ServerWindow] = [:]
        for entry in info where (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            result[id] = ServerWindow(pid: pid, frame: frame)
        }
        return result
    }

    /// The IDs of ordinary windows on screen now.
    static func onScreenAppWindowIDs() -> Set<CGWindowID> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
    }

    /// Every window Accessibility lists, on whichever desktops are showing.
    static func accessibleWindows() -> [CGWindowID: LiveWindow] { readWindows().0 }

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

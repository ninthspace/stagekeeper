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

struct LiveStage {
    enum Kind: String { case current, other }
    let kind: Kind
    let windowIDs: [CGWindowID]
    /// The saved stage (label, colour, shortcut) this stage is.
    var savedID: UUID? = nil
}

enum StageError: Error, CustomStringConvertible {
    case notTrusted
    case stageManagerOn
    case noLayout(String)
    case other(String)

    var description: String {
        switch self {
        case .notTrusted: return "This process does not have Accessibility permission in System Settings › Privacy & Security › Device Control and Data Access (called Accessibility before macOS 27)."
        case .stageManagerOn: return "Stage Manager is on. StageKeeper keeps its own stages: turn Stage Manager off in System Settings › Desktop & Dock."
        case .noLayout(let path): return "No saved layout at \(path). Run `stagekeeper save` first."
        case .other(let message): return message
        }
    }
}

/// The state of every stage at one moment: the current stage, whose windows are on screen,
/// and the others, whose windows are hidden.
struct Snapshot {
    let windows: [CGWindowID: LiveWindow]
    let order: [CGWindowID]
    let current: [CGWindowID]
    let stages: [LiveStage]

    static var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    static func take() throws -> Snapshot {
        guard AX.isTrusted(prompt: false) else { throw StageError.notTrusted }
        guard Engine.active else { throw StageError.stageManagerOn }
        // Only the active desktop's windows: with a desktop per display, Accessibility also
        // lists the other display's windows, which belong to that desktop's stages. Hidden
        // windows go by the desktop that hid them, not the display their corner is on.
        var (windows, order) = readWindows()
        let hidden = Engine.hiddenWindows()
        let here = Desktops.onActiveSpace(order).subtracting(hidden.elsewhere).union(hidden.here)
        windows = windows.filter { here.contains($0.key) }
        order = order.filter(here.contains)
        let (current, others) = Engine.stages(windows, order: order)
        var stages: [LiveStage] = []
        if !current.windows.isEmpty { stages.append(LiveStage(kind: .current, windowIDs: current.windows, savedID: current.savedID)) }
        stages += others.map { LiveStage(kind: .other, windowIDs: $0.windows, savedID: $0.savedID) }
        return Snapshot(windows: windows, order: order, current: current.windows, stages: stages)
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
        var lines: [String] = []
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

    /// Normal-level windows front to back, including hidden ones.
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

    /// Normal windows front to back. Only the on-screen list is in stacking order; the full list
    /// mixes in off-screen windows out of order, so those follow the on-screen ones.
    static func zOrder() -> [CGWindowID] {
        func ids(_ options: CGWindowListOption) -> [CGWindowID] {
            let info = CGWindowListCopyWindowInfo(options.union(.excludeDesktopElements), kCGNullWindowID) as? [[String: Any]] ?? []
            return info.compactMap { entry in
                guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
                return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            }
        }
        let onScreen = ids(.optionOnScreenOnly)
        let seen = Set(onScreen)
        return onScreen + ids(.optionAll).filter { !seen.contains($0) }
    }

    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }
}

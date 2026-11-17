import AppKit
import ApplicationServices

/// Private but long-stable call that maps an accessibility window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        value(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        (value(element, name) as? NSNumber)?.boolValue
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (value(element, name) as? [AXUIElement]) ?? []
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute)
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func setFrame(_ element: AXUIElement, _ frame: CGRect) {
        var point = frame.origin
        var size = frame.size
        if let p = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        }
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// Makes one window the frontmost window of the frontmost app. Stage Manager then switches
    /// to the stage that holds the window, with no need to click the strip.
    static func focus(_ window: LiveWindow) {
        perform(window.element, kAXRaiseAction)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: window.pid)?.activate(from: NSRunningApplication.current, options: [])
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        return app
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}

/// Stage Manager on macOS 27 reports AXPress / AXAddToStage on strip thumbnails as successful
/// but ignores them, so stages are switched and merged with real mouse clicks instead:
/// a click switches to the stage, a shift-click adds it to the current stage.
enum StripClick {
    static func click(_ item: StripItem, shift: Bool) {
        guard let key = item.windowIDs.first, let initial = AX.frame(item.button), initial.width > 0 else {
            AX.perform(item.button, shift ? "AXAddToStage" : kAXPressAction)
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location ?? .zero
        let flags: CGEventFlags = shift ? .maskShift : []

        func post(_ type: CGEventType, _ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }

        // While the strip is hidden, Stage Manager reports every thumbnail off screen (x < 0),
        // and it may replace the thumbnail elements when the strip slides out. So hold the
        // pointer at the left edge, nudging it, and read the strip again until the thumbnail
        // holding this stage's window is on screen and has stopped moving.
        let edgeY = max(initial.midY, 1)
        var previous: CGRect?
        var frame: CGRect?
        var seen: [String] = []
        let deadline = Date().addingTimeInterval(2.5)
        var step = 0
        while Date() < deadline {
            post(.mouseMoved, CGPoint(x: step % 2 == 0 ? 0 : 2, y: edgeY))
            step += 1
            usleep(90_000)
            let current = (try? Snapshot.readStrip())?.first { $0.windowIDs.contains(key) }.flatMap { AX.frame($0.button) }
            if seen.count < 30 { seen.append(current.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "none") }
            guard let current, current.width > 0, current.minX >= 0 else { previous = nil; continue }
            if current == previous { frame = current; break }
            previous = current
        }
        guard let frame else {
            Log.write("Strip thumbnail did not come on screen; not clicking. Positions seen: \(seen.joined(separator: " "))")
            post(.mouseMoved, original)
            return
        }
        let target = CGPoint(x: frame.midX, y: frame.midY)
        // Move along the strip rather than jumping, so the pointer never leaves it.
        post(.mouseMoved, CGPoint(x: min(frame.minX + 8, target.x), y: target.y))
        usleep(80_000)
        post(.mouseMoved, target)
        usleep(120_000)
        post(.leftMouseDown, target)
        usleep(60_000)
        post(.leftMouseUp, target)
        usleep(100_000)
        if let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }
}

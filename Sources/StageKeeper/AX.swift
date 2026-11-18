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

/// Clicks and drags on the Stage Manager strip.
///
/// Stage Manager on macOS 27 reports AXPress / AXAddToStage on strip thumbnails as successful
/// but ignores them, so the strip is worked with real mouse events. That needs the strip on
/// screen: while any window covers its area Stage Manager slides it off the left edge (both
/// Accessibility and the window list then report it about 255 points off screen), and simulated
/// pointer moves to the edge do not bring it back. So each action first moves the current
/// stage's windows out of the strip's area, waits for the strip to come back, acts, and then
/// puts the windows back.
enum StripClick {
    /// A click switches to the stage; a shift-click adds it to the current stage.
    static func click(_ item: StripItem, shift: Bool) {
        guard let key = item.windowIDs.first else { return }
        withStripVisible { strip in
            guard let frame = strip.first(where: { $0.windowIDs.contains(key) }).flatMap({ AX.frame($0.button) }) else {
                Log.write("Strip thumbnail not found on screen; not clicking.")
                return
            }
            Mouse.click(CGPoint(x: frame.midX, y: frame.midY), shift: shift)
        }
    }

    /// Drags one window's preview out of its strip thumbnail into the middle of the screen,
    /// which adds just that window to the current stage. Returns false when the preview
    /// could not be found.
    @discardableResult
    static func dragIntoCurrent(_ window: LiveWindow) -> Bool {
        var dragged = false
        withStripVisible { strip in
            guard let item = strip.first(where: { $0.windowIDs.contains(window.id) }),
                  let thumbnail = AX.frame(item.button),
                  let preview = Previews.find(window, in: item, thumbnail: thumbnail,
                                              windows: (try? Snapshot.take())?.windows ?? [:]) else {
                Log.write("Window preview not found in the strip; not dragging.")
                return
            }
            let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            Mouse.drag(from: preview.grab, to: CGPoint(x: screen.midX, y: screen.midY))
            dragged = true
        }
        return dragged
    }

    /// Drags a window of the current stage by its title bar into an empty part of the strip,
    /// below the last thumbnail, which makes it a stage of its own. Returns false when the strip
    /// has no empty space to drop on.
    static func dragOutToStrip(_ window: LiveWindow) -> Bool {
        var dragged = false
        withStripVisible { strip in
            let frames = strip.compactMap { AX.frame($0.button) }
            let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let widest = frames.map(\.width).max() ?? 160
            let lowest = frames.map(\.maxY).max() ?? screen.midY
            let drop = CGPoint(x: 16 + widest / 2, y: min(lowest + 90, screen.maxY - 80))
            guard drop.y > lowest + 20, let frame = AX.frame(window.element) else {
                Log.write("No empty space in the strip to drop on.")
                return
            }
            Log.write("Dragging the \(window.appName) window out: thumbnails \(frames.map { "\(Int($0.minY))–\(Int($0.maxY))" }), drop at \(Int(drop.x)),\(Int(drop.y)).")
            let grab = CGPoint(x: frame.midX, y: frame.minY + 12)
            Mouse.post(.mouseMoved, grab)
            usleep(80_000)
            Mouse.post(.leftMouseDown, grab)
            usleep(200_000)
            for step in 1...20 {
                let t = Double(step) / 20
                Mouse.post(.leftMouseDragged, CGPoint(x: grab.x + (drop.x - grab.x) * t, y: grab.y + (drop.y - grab.y) * t))
                usleep(25_000)
            }
            usleep(600_000)
            Mouse.post(.leftMouseUp, drop)
            usleep(300_000)
            dragged = true
        }
        return dragged
    }

    /// Clears the strip's area, runs `body` with the strip's thumbnails once they are on screen,
    /// then moves the windows back.
    static func withStripVisible(_ body: ([StripItem]) -> Void) {
        let original = Mouse.location
        var moved: [(AXUIElement, CGRect)] = []
        if let strip = try? Snapshot.readStrip(), !onScreen(strip), let snapshot = settledSnapshot() {
            // The strip's width when shown: thumbnails start 16 points from the edge.
            let widest = strip.compactMap { AX.frame($0.button)?.width }.max() ?? 230
            let clearance = 16 + widest + 24
            for id in snapshot.current {
                guard let window = snapshot.windows[id], let frame = AX.frame(window.element), frame.minX < clearance else { continue }
                moved.append((window.element, frame))
                var cleared = frame
                cleared.origin.x = clearance
                if frame.maxX > clearance + 300 { cleared.size.width = frame.maxX - clearance }
                AX.setFrame(window.element, cleared)
            }
            let names = snapshot.current.compactMap { snapshot.windows[$0]?.appName }
            Log.write("Uncovering the strip; the current stage reads as: \(names.joined(separator: ", ")).")
        }
        if let strip = waitForStrip() {
            body(strip)
        } else {
            Log.write("The strip did not come on screen.")
        }
        // Give Stage Manager time to take the click or drop before windows move again.
        usleep(200_000)
        for (element, frame) in moved { AX.setFrame(element, frame) }
        Mouse.move(original)
    }

    /// The stages once the current stage has read the same three times in a row (up to two
    /// seconds). Just after a switch, windows of the stage being left, or of other stages, still
    /// read as current; moving one of those makes Stage Manager bring its stage forward.
    private static func settledSnapshot() -> Snapshot? {
        guard var latest = try? Snapshot.take() else { return nil }
        var steady = 0
        for _ in 0..<14 where steady < 2 {
            usleep(150_000)
            guard let next = try? Snapshot.take() else { return nil }
            steady = Set(next.current) == Set(latest.current) && Set(next.strip.flatMap(\.windowIDs)) == Set(latest.strip.flatMap(\.windowIDs)) ? steady + 1 : 0
            latest = next
        }
        return latest
    }

        private static func onScreen(_ strip: [StripItem]) -> Bool {
        strip.allSatisfy { (AX.frame($0.button)?.minX ?? -1) >= 0 }
    }

    /// The strip once every thumbnail is on screen and neither the thumbnails nor the previews
    /// inside them have moved over three reads, or nil after 2.5 seconds. After a stage switch
    /// Stage Manager re-sorts the strip with an animation; reading positions during it picks
    /// the wrong thumbnail.
    private static func waitForStrip() -> [StripItem]? {
        var previous: [CGRect] = []
        var steady = 0
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            guard let strip = try? Snapshot.readStrip() else { return nil }
            let frames = strip.compactMap { AX.frame($0.button) } + Previews.all()
            if onScreen(strip), frames == previous {
                steady += 1
                if steady >= 2 { return strip }
            } else {
                steady = 0
            }
            previous = frames
            usleep(100_000)
        }
        return nil
    }
}

/// The window previews Stage Manager draws inside strip thumbnails. Each preview is a window
/// owned by WindowManager; the window list gives its position but not which window it shows.
/// The window list gives a thumbnail's previews in the same order as the thumbnail's
/// AXWindowsIDs, so a window's preview is the one at its position in that list. Previews are
/// drawn in perspective, so their shapes are not the windows' shapes, but a wider window still
/// has a wider preview: that is used as a check, and a preview that fails it is not used.
enum Previews {
    /// Every preview and icon WindowManager draws in the strip, in window-list order.
    static func all() -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerName as String] as? String) == "WindowManager",
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let b = entry[kCGWindowBounds as String] as? [String: Double] else { return nil }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
    }

    /// The window's preview and a point on it to grab. Previews in a thumbnail overlap, and the
    /// window list gives them front to back, so the grab point is a part of the preview that no
    /// preview or icon in front of it covers. Previews are drawn in perspective, so the corners of
    /// their bounding boxes are empty, and grabbing there takes the whole stage; only the middle
    /// half of the preview is used. Returns nil when that part is covered.
    static func find(_ window: LiveWindow, in item: StripItem, thumbnail: CGRect,
                     windows: [CGWindowID: LiveWindow]) -> (rect: CGRect, grab: CGPoint)? {
        let area = thumbnail.insetBy(dx: -24, dy: -24)
        // Everything WindowManager draws on this thumbnail, front to back.
        let drawn = all().filter { area.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        // App icons drawn on the thumbnails are 66 × 82.
        func isIcon(_ r: CGRect) -> Bool { abs(r.width - 66) < 4 && abs(r.height - 82) < 4 }
        let previews = drawn.filter { !isIcon($0) }
        guard let index = item.windowIDs.firstIndex(of: window.id) else { return nil }
        guard previews.count == item.windowIDs.count else {
            Log.write("The thumbnail shows \(previews.count) previews for \(item.windowIDs.count) windows; not dragging.")
            return nil
        }
        let chosen = previews[index]
        func aspect(_ r: CGRect) -> CGFloat { r.width / max(r.height, 1) }
        if let frame = AX.frame(window.element) {
            for (other, id) in item.windowIDs.enumerated() where id != window.id {
                guard let otherFrame = windows[id].flatMap({ AX.frame($0.element) }) else { continue }
                let windowDifference = aspect(frame) - aspect(otherFrame)
                guard abs(windowDifference) > 0.15 else { continue }
                if (windowDifference > 0) != (aspect(chosen) > aspect(previews[other])) {
                    Log.write("The preview at the window's position does not match its shape; not dragging.")
                    return nil
                }
            }
        }
        // Sample the preview and keep the points nothing in front covers.
        let inFront = Array(drawn.prefix { $0 != chosen })
        let inner = chosen.insetBy(dx: chosen.width * 0.25, dy: chosen.height * 0.25)
        var open: [CGPoint] = []
        for i in 0...10 {
            for j in 0...10 {
                let point = CGPoint(x: inner.minX + inner.width * CGFloat(i) / 10, y: inner.minY + inner.height * CGFloat(j) / 10)
                if !inFront.contains(where: { $0.contains(point) }) { open.append(point) }
            }
        }
        guard !open.isEmpty else {
            Log.write("The window's preview is covered by the previews in front of it; not dragging.")
            return nil
        }
        // The open point nearest the middle of the open part, so the grab is not on an edge.
        let middle = CGPoint(x: open.map(\.x).reduce(0, +) / CGFloat(open.count), y: open.map(\.y).reduce(0, +) / CGFloat(open.count))
        let grab = open.min { hypot($0.x - middle.x, $0.y - middle.y) < hypot($1.x - middle.x, $1.y - middle.y) }!
        return (chosen, grab)
    }
}

/// Simulated pointer events.
enum Mouse {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func post(_ type: CGEventType, _ point: CGPoint, flags: CGEventFlags = []) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func move(_ point: CGPoint) { post(.mouseMoved, point) }

    static func click(_ point: CGPoint, shift: Bool) {
        let flags: CGEventFlags = shift ? .maskShift : []
        post(.mouseMoved, point, flags: flags)
        usleep(150_000)
        post(.leftMouseDown, point, flags: flags)
        usleep(60_000)
        post(.leftMouseUp, point, flags: flags)
        usleep(100_000)
    }

    static func drag(from start: CGPoint, to end: CGPoint) {
        post(.mouseMoved, start)
        usleep(80_000)
        post(.leftMouseDown, start)
        usleep(150_000)
        for step in 1...12 {
            let t = Double(step) / 12
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            usleep(15_000)
        }
        usleep(150_000)
        post(.leftMouseUp, end)
        usleep(100_000)
    }
}

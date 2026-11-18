import AppKit

/// Counts the fingers on the trackpad, through the private MultitouchSupport framework (the one
/// BetterTouchTool and MiddleClick use). macOS has no public way to tell how many fingers are
/// down when the trackpad is clicked.
enum Trackpad {
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// Fingers on the trackpad touched most recently. Written on the framework's thread and
    /// read in the event tap; a stale read only means one click is treated as ordinary.
    nonisolated(unsafe) static var fingers: Int32 = 0
    nonisolated(unsafe) private static var devices: CFArray?

    /// Called on the main thread after a four-finger tap: four fingers down and up within
    /// `tapTime` without moving and without pressing the trackpad. macOS sends no event for a
    /// tap of more than two fingers, so it is recognised here from the raw finger data.
    nonisolated(unsafe) static var onTap: (() -> Void)?
    /// Set by the event tap when the trackpad is pressed, so a four-finger click is not also
    /// taken as a tap.
    nonisolated(unsafe) static var pressedDuringTouch = false
    private static let tapTime = 0.3
    private static let tapMovement: Float = 0.04  // fraction of the trackpad's width or height

    nonisolated(unsafe) private static var touchStart = 0.0
    nonisolated(unsafe) private static var mostFingers = 0
    nonisolated(unsafe) private static var startCentre: (Float, Float)?
    nonisolated(unsafe) private static var moved = false

    /// Bytes per finger in the framework's touch array, and where the fields used here sit:
    /// the touch state (4 = making contact, 5 = touching) and the position as a fraction of the
    /// trackpad's size.
    private static let stride = 96, stateOffset = 20, xOffset = 32, yOffset = 36

    private static func track(_ data: UnsafeMutableRawPointer?, _ count: Int, _ time: Double) {
        var touching = 0
        var sumX: Float = 0, sumY: Float = 0
        if let data {
            for i in 0..<count {
                let state = data.load(fromByteOffset: i * stride + stateOffset, as: Int32.self)
                guard state == 4 || state == 5 else { continue }
                touching += 1
                sumX += data.load(fromByteOffset: i * stride + xOffset, as: Float.self)
                sumY += data.load(fromByteOffset: i * stride + yOffset, as: Float.self)
            }
        }
        if touching > 0 {
            let centre = (sumX / Float(touching), sumY / Float(touching))
            if mostFingers == 0 {
                touchStart = time
                moved = false
                pressedDuringTouch = false
            }
            if touching > mostFingers {
                mostFingers = touching
                startCentre = centre
            } else if touching == mostFingers, let start = startCentre,
                      abs(centre.0 - start.0) > tapMovement || abs(centre.1 - start.1) > tapMovement {
                moved = true
            }
            return
        }
        if mostFingers == 4, !moved, !pressedDuringTouch, time - touchStart < tapTime {
            DispatchQueue.main.async { onTap?() }
        }
        mostFingers = 0
        startCentre = nil
    }

    /// Starts listening to every trackpad, first stopping any devices from an earlier start.
    /// The devices stop sending touches after the Mac sleeps or the screen locks, so this is
    /// called again on wake and unlock. Returns false when the framework is unavailable.
    @discardableResult
    static func start() -> Bool {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createPointer = dlsym(framework, "MTDeviceCreateList"),
              let registerPointer = dlsym(framework, "MTRegisterContactFrameCallback"),
              let startPointer = dlsym(framework, "MTDeviceStart"),
              let stopPointer = dlsym(framework, "MTDeviceStop") else { return false }
        let create = unsafeBitCast(createPointer, to: CreateList.self)
        let register = unsafeBitCast(registerPointer, to: Register.self)
        let startDevice = unsafeBitCast(startPointer, to: Start.self)
        let stopDevice = unsafeBitCast(stopPointer, to: Stop.self)
        if let old = devices {
            for index in 0..<CFArrayGetCount(old) {
                stopDevice(UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(old, index)))
            }
            devices = nil
        }
        fingers = 0
        mostFingers = 0
        startCentre = nil
        guard let list = create()?.takeRetainedValue() else { return false }
        devices = list
        let callback: Callback = { _, data, count, time, _ in
            Trackpad.fingers = count
            Trackpad.track(data, Int(count), time)
            return 0
        }
        for index in 0..<CFArrayGetCount(list) {
            let device = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, index))
            register(device, callback)
            startDevice(device, 0)
        }
        return CFArrayGetCount(list) > 0
    }
}

/// Turns a trackpad click made with four fingers into a call to `handler`, with the pointer's
/// position in Cocoa screen coordinates. The click itself, and the drag and release that follow
/// it, are taken out of the event stream so the app under the pointer never sees them.
enum FourFingerClick {
    nonisolated(unsafe) static var handler: ((NSPoint) -> Void)?
    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var swallowing = false

    @discardableResult
    static func install() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap = FourFingerClick.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            case .leftMouseDown where Trackpad.fingers >= 4:
                FourFingerClick.swallowing = true
                Trackpad.pressedDuringTouch = true
                let location = event.location
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                DispatchQueue.main.async { FourFingerClick.handler?(NSPoint(x: location.x, y: primaryHeight - location.y)) }
                return nil
            case .leftMouseDragged where FourFingerClick.swallowing:
                return nil
            case .leftMouseUp where FourFingerClick.swallowing:
                FourFingerClick.swallowing = false
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }, userInfo: nil) else { return false }
        tap = port
        // macOS can turn the tap off without telling it (for example while the screen is
        // locked), so check it every few seconds.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            if let tap = FourFingerClick.tap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.write("The four-finger click watch was off; turned it back on.")
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
}

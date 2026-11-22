import AppKit
import Carbon

/// Global shortcuts through the Carbon hot-key API, which needs no extra permission. Each
/// labelled stage has one (see `Shortcuts`), and Fetch Bookmarked Windows has one that is
/// registered only while a window is bookmarked, so unused keys stay free for other apps. The
/// radial menu has one too, for opening it where a trackpad gesture cannot reach StageKeeper,
/// such as over Screen Sharing.
enum Hotkeys {
    enum Target: Hashable { case stage(UUID), fetch, radial }

    static var handler: ((Target) -> Void)?
    private static var refs: [EventHotKeyRef] = []
    private static var targets: [UInt32: Target] = [:]
    private static var registered: [Target: Shortcut]?
    private static var installed = false
    /// Set while the Settings window records a shortcut, so pressing one records it.
    private static var suspended = false

    static func register(_ wanted: [Target: Shortcut]) {
        installHandler()
        let wanted = suspended ? [:] : wanted
        guard wanted != registered else { return }
        let before = registered ?? [:]
        registered = wanted
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        targets = [:]
        var next: UInt32 = 1
        for (target, shortcut) in wanted.sorted(by: { $0.value.display < $1.value.display }) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x53544B50), id: next)
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                targets[next] = target
            } else if before[target] != shortcut {
                Log.write("\(shortcut.display) is taken by another app.")
            }
            next += 1
        }
    }

    /// Turns every shortcut off (while recording) or lets the next `register` turn them back on.
    static func suspend(_ on: Bool) {
        suspended = on
        if on { register([:]) } else { registered = nil }
    }

    private static func installHandler() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            if let target = Hotkeys.targets[key.id] { Hotkeys.handler?(target) }
            return noErr
        }, 1, &spec, nil, nil)
        installed = true
    }
}

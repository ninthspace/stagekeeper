import AppKit
import Carbon

/// Global ⌃⌥1–9 shortcuts through the Carbon hot-key API, which needs no extra permission.
/// Only as many keys are registered as there are labelled stages, so unused ones stay free
/// for other apps. ⌃⌥0 (Fetch Pinned Windows) is registered only while a window is pinned;
/// the handler receives 0 for it.
enum Hotkeys {
    static var handler: ((Int) -> Void)?
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false
    private static var registered = -1
    private static let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                   kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    static let modifiers: NSEvent.ModifierFlags = [.control, .option]

    private static var fetchRef: EventHotKeyRef?

    static func register(count: Int, fetch: Bool = false) {
        installHandler()
        if fetch != (fetchRef != nil) {
            if let fetchRef { UnregisterEventHotKey(fetchRef); self.fetchRef = nil }
            if fetch {
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(UInt32(kVK_ANSI_0), UInt32(controlKey | optionKey),
                                                 EventHotKeyID(signature: OSType(0x53544B50), id: 0), GetApplicationEventTarget(), 0, &ref)
                if status == noErr { fetchRef = ref } else { Log.write("⌃⌥0 is taken by another app.") }
            }
        }
        let wanted = min(count, keyCodes.count)
        guard wanted != registered else { return }
        registered = wanted
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        for (index, code) in keyCodes.prefix(wanted).enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x53544B50), id: UInt32(index + 1))
            let status = RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { Log.write("⌃⌥\(index + 1) is taken by another app.") }
        }
    }

    private static func installHandler() {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var key = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
                Hotkeys.handler?(Int(key.id))
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
    }
}

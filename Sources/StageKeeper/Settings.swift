import AppKit
import Carbon
import SwiftUI

/// A keyboard shortcut: a key and the modifier keys held with it.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, holding only ⌃ ⌥ ⇧ ⌘.
    var modifiers: UInt

    /// Stored for a stage or for Fetch that should have no shortcut.
    static let none = Shortcut(keyCode: 0xFFFF, modifiers: 0)
    var isNone: Bool { keyCode == 0xFFFF }

    static let defaultModifiers: NSEvent.ModifierFlags = [.control, .option]
    private static let digitCodes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                     kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    static func digit(_ n: Int) -> Shortcut { Shortcut(keyCode: UInt32(digitCodes[n]), modifiers: defaultModifiers.rawValue) }
    /// The radial menu's default: ⌃⌥R. (⌃⌥Space is the input-source switch.)
    static let radial = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: defaultModifiers.rawValue)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var value = 0
        if flags.contains(.control) { value |= controlKey }
        if flags.contains(.option) { value |= optionKey }
        if flags.contains(.shift) { value |= shiftKey }
        if flags.contains(.command) { value |= cmdKey }
        return UInt32(value)
    }

    var display: String {
        guard !isNone else { return "None" }
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (Self.names[Int(keyCode)]?.display ?? "Key \(keyCode)")
    }

    /// The key equivalent for a menu item, or nil for a key a menu cannot show.
    var menuKey: String? { isNone ? nil : Self.names[Int(keyCode)]?.menu }

    /// Function keys and keys without a modifier-free meaning may be used without ⌃, ⌥ or ⌘.
    var isFunctionKey: Bool { (Self.names[Int(keyCode)]?.display.hasPrefix("F") ?? false) && (Self.names[Int(keyCode)]?.display.count ?? 0) > 1 }

    /// What each key is called on screen and in a menu's key equivalent, by key code (ANSI layout).
    private static let names: [Int: (display: String, menu: String)] = {
        var names: [Int: (String, String)] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_E, "e"), (kVK_ANSI_F, "f"),
            (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"), (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"),
            (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"), (kVK_ANSI_P, "p"), (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"),
            (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"), (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"),
            (kVK_ANSI_Y, "y"), (kVK_ANSI_Z, "z"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Grave, "`"),
        ]
        for (code, key) in letters { names[code] = (key.uppercased(), key) }
        for (n, code) in digitCodes.enumerated() { names[code] = (String(n), String(n)) }
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (n, code) in functions.enumerated() {
            names[code] = ("F\(n + 1)", String(Character(UnicodeScalar(NSF1FunctionKey + n)!)))
        }
        func key(_ value: Int) -> String { String(Character(UnicodeScalar(value)!)) }
        names[kVK_Space] = ("Space", " ")
        names[kVK_Return] = ("↩", "\r")
        names[kVK_Tab] = ("⇥", "\t")
        names[kVK_Delete] = ("⌫", key(NSBackspaceCharacter))
        names[kVK_ForwardDelete] = ("⌦", key(NSDeleteFunctionKey))
        names[kVK_LeftArrow] = ("←", key(NSLeftArrowFunctionKey))
        names[kVK_RightArrow] = ("→", key(NSRightArrowFunctionKey))
        names[kVK_UpArrow] = ("↑", key(NSUpArrowFunctionKey))
        names[kVK_DownArrow] = ("↓", key(NSDownArrowFunctionKey))
        names[kVK_Home] = ("↖", key(NSHomeFunctionKey))
        names[kVK_End] = ("↘", key(NSEndFunctionKey))
        names[kVK_PageUp] = ("⇞", key(NSPageUpFunctionKey))
        names[kVK_PageDown] = ("⇟", key(NSPageDownFunctionKey))
        return names
    }()
}

/// What the Settings window changes, kept in `settings.json` beside the layouts. Anything not
/// set keeps its default.
struct Settings: Codable {
    struct PaletteColour: Codable, Hashable {
        var name: String
        var hex: String
    }

    /// The colours offered in the menus and the radial menu.
    var palette: [PaletteColour]?
    /// Fetch Bookmarked Windows; `Shortcut.none` turns it off.
    var fetchShortcut: Shortcut?
    /// Opens the radial menu at the pointer; `Shortcut.none` turns it off.
    var radialShortcut: Shortcut?
    /// Shortcuts chosen for labelled stages, by stage ID. A stage not listed gets the next free
    /// ⌃⌥1–9; `Shortcut.none` gives it none.
    var stageShortcuts: [String: Shortcut]?

    nonisolated(unsafe) private static var cached: Settings?

    static var current: Settings {
        if let cached { return cached }
        let loaded = (try? Data(contentsOf: Paths.settings)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        cached = loaded
        return loaded
    }

    static func update(_ change: (inout Settings) -> Void) {
        var settings = current
        change(&settings)
        cached = settings
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings).write(to: Paths.settings, options: .atomic)
    }
}

extension Paths {
    static var settings: URL { directory.appendingPathComponent("settings.json") }
}

/// Which shortcut each labelled stage, Fetch Bookmarked Windows and the radial menu has.
enum Shortcuts {
    static var radial: Shortcut? {
        let chosen = Settings.current.radialShortcut ?? .radial
        return chosen.isNone ? nil : chosen
    }

    static var fetch: Shortcut? {
        let chosen = Settings.current.fetchShortcut ?? .digit(0)
        return chosen.isNone ? nil : chosen
    }

    /// A stage's shortcut is the one chosen in Settings; otherwise the labelled stages without
    /// one take ⌃⌥1–9 in `Actions.numbered()` order, skipping any already chosen.
    static func stages() -> [UUID: Shortcut] {
        let chosen = Settings.current.stageShortcuts ?? [:]
        var taken = Set(chosen.values.filter { !$0.isNone })
        if let fetch { taken.insert(fetch) }
        if let radial { taken.insert(radial) }
        var result: [UUID: Shortcut] = [:]
        var digit = 1
        for stage in Actions.numbered() {
            guard let id = stage.id else { continue }
            if let shortcut = chosen[id.uuidString] {
                if !shortcut.isNone { result[id] = shortcut }
                continue
            }
            while digit <= 9, taken.contains(.digit(digit)) { digit += 1 }
            guard digit <= 9 else { continue }
            result[id] = .digit(digit)
            digit += 1
        }
        return result
    }

    static func isAutomatic(_ id: UUID) -> Bool { Settings.current.stageShortcuts?[id.uuidString] == nil }

    /// The shortcuts to register now: every stage's, the radial menu's, and Fetch's while a
    /// window is bookmarked.
    static func wanted(fetchActive: Bool) -> [Hotkeys.Target: Shortcut] {
        var wanted: [Hotkeys.Target: Shortcut] = [:]
        for (id, shortcut) in stages() { wanted[.stage(id)] = shortcut }
        if fetchActive, let fetch { wanted[.fetch] = fetch }
        if let radial { wanted[.radial] = radial }
        return wanted
    }

    /// What already uses a shortcut, other than `except`, or nil when it is free.
    static func user(of shortcut: Shortcut, except: Hotkeys.Target) -> String? {
        if except != .fetch, shortcut == fetch { return "Fetch Bookmarked Windows" }
        if except != .radial, shortcut == radial { return "the radial menu" }
        let labels = Dictionary(uniqueKeysWithValues: Actions.numbered().compactMap { s in s.id.map { ($0, s.label ?? "a stage") } })
        for (id, other) in stages() where other == shortcut && except != .stage(id) { return labels[id] ?? "another stage" }
        return nil
    }
}

extension NSMenuItem {
    func show(_ shortcut: Shortcut?) {
        guard let shortcut, let key = shortcut.menuKey else { return }
        keyEquivalent = key
        keyEquivalentModifierMask = shortcut.flags
    }
}

extension Actions {
    /// Renames a labelled stage on whichever desktop it is on. Its Dock app is renamed in place,
    /// and a shortcut chosen in Settings stays with it. Refuses an empty label or one that
    /// another stage already has.
    static func setLabel(of id: UUID, _ label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StageError.other("A label cannot be empty.") }
        guard let found = locate(id) else { throw StageError.other("That stage is no longer saved.") }
        let clash = LayoutStore.loadAll().flatMap(\.stages).contains {
            $0.id != id && $0.label?.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !clash else { throw StageError.other("Another stage is already called \"\(trimmed)\".") }
        var layout = found.layout
        let old = layout.stages[found.index].label ?? ""
        guard old != trimmed else { return }
        layout.stages[found.index].label = trimmed
        try LayoutStore.write(layout, keepPrevious: false)
        DockApps.sync()
        Log.write("Renamed the \"\(old)\" stage \"\(trimmed)\".")
    }

    /// Sets (or clears, when nil) a saved stage's colour on whichever desktop it is on.
    static func setColour(of id: UUID, _ hex: String?) throws {
        guard let found = locate(id) else { throw StageError.other("That stage is no longer saved.") }
        var layout = found.layout
        layout.stages[found.index].color = hex
        try LayoutStore.write(layout, keepPrevious: false)
        DockApps.sync()
    }
}

// MARK: Window

/// The Settings window: each labelled stage's colour and shortcut, the palette, and the
/// Fetch Bookmarked Windows shortcut. `changed` is called after each change so the menu bar
/// can register the shortcuts and redraw.
enum SettingsWindow {
    nonisolated(unsafe) private static var window: NSWindow?

    static func show(changed: @escaping () -> Void) {
        installEditMenu()
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(changed: changed))
            let window = NSWindow(contentViewController: host)
            window.title = "StageKeeper Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A menu-bar app has no main menu, and without one ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z and ⌘W do
    /// nothing in its windows. The menu shows only while the Settings window is in front.
    private static func installEditMenu() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()
        let app = NSMenu(title: "StageKeeper")
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for submenu in [app, edit] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}

private struct SettingsView: View {
    let changed: () -> Void

    var body: some View {
        TabView {
            StagesPane(changed: changed).tabItem { Text("Stages") }
            PalettePane(changed: changed).tabItem { Text("Palette") }
            ShortcutsPane(changed: changed).tabItem { Text("Shortcuts") }
        }
        .padding()
        .frame(width: 620, height: 460)
    }
}

private func colour(_ hex: String) -> Color { Color(nsColor: Palette.color(hex)) }

private func hex(_ colour: Color) -> String {
    let c = NSColor(colour).usingColorSpace(.sRGB) ?? .gray
    return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                  Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
}

/// Runs the last change after the user pauses, so dragging in a colour picker does not rewrite
/// the layout and every Dock app on each step.
private final class Debounce {
    private var pending: DispatchWorkItem?
    func run(after seconds: Double = 0.4, _ body: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: body)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}

// MARK: Stages

private struct StagesPane: View {
    let changed: () -> Void

    struct Row: Identifiable {
        let id: UUID
        var label: String
        /// The label as saved, put back when an edit is refused.
        var saved: String
        let desktop: String
        var colour: String?
    }

    @State private var rows: [Row] = []
    @State private var shortcuts: [UUID: Shortcut] = [:]
    @State private var message: String?
    @FocusState private var focused: UUID?
    @State private var deleting: Row?
    private let debounce = Debounce()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labelled stages on every desktop. Click a label to rename it. A stage set to Automatic takes the next free ⌃⌥1–9. Deleting a stage moves its windows into the current stage.")
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No labelled stages yet. Label a stage from the menu bar first.").padding(.top, 20)
            }
            List {
                ForEach($rows) { $row in
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(Palette.colours, id: \.hex) { entry in
                                Button(entry.name) { setColour(&row, entry.hex) }
                            }
                            Divider()
                            Button("No colour") { setColour(&row, nil) }
                        } label: {
                            Image(systemName: "paintpalette")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose a palette colour")
                        ColorPicker("", selection: Binding(
                            get: { row.colour.map(colour) ?? .gray },
                            set: { setColour(&row, hex($0)) }), supportsOpacity: false)
                            .labelsHidden()
                            .help("Choose any colour")
                        TextField("Label", text: $row.label)
                            .textFieldStyle(.plain)
                            .focused($focused, equals: row.id)
                            .onSubmit { rename(&row) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("Click to rename; Return saves")
                        Text(row.desktop).foregroundStyle(.secondary)
                        ShortcutRecorder(shortcut: shortcuts[row.id], target: .stage(row.id), changed: reload, message: $message)
                        Menu {
                            Button("Automatic") { Settings.update { $0.stageShortcuts?[row.id.uuidString] = nil }; reload() }
                            Button("No Shortcut") { Settings.update { $0.stageShortcuts = ($0.stageShortcuts ?? [:]).merging([row.id.uuidString: .none]) { $1 } }; reload() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(Shortcuts.isAutomatic(row.id) ? "Automatic" : "Chosen in Settings")
                        Button { deleting = row } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this stage")
                    }
                }
            }
            if let message { Text(message).foregroundStyle(.red) }
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete \(deleting?.label ?? "")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let row = deleting { delete(row) } }
        } message: {
            Text("Its windows join the current stage on \(deleting?.desktop ?? "its desktop"); none are closed. Its label, colour, shortcut and Dock app are removed.")
        }
        // Leaving a label field saves it, as Return does.
        .onChange(of: focused) { previous, _ in
            guard let previous, let index = rows.firstIndex(where: { $0.id == previous }) else { return }
            rename(&rows[index])
        }
    }

    private func rename(_ row: inout Row) {
        guard row.label != row.saved else { return }
        do {
            try Actions.setLabel(of: row.id, row.label)
            row.label = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
            row.saved = row.label
            message = nil
            reload()  // renaming can change the automatic shortcuts' order
        } catch {
            message = "\(error)"
            row.label = row.saved
        }
    }

    private func load() {
        let desktops = Desktops.all()
        var rows: [Row] = []
        for layout in LayoutStore.loadAll() {
            let number = desktops.first { $0.key == layout.desktop }?.number
            for stage in layout.stages {
                guard let id = stage.id, let label = stage.label else { continue }
                rows.append(Row(id: id, label: label, saved: label, desktop: number.map { "Desktop \($0)" } ?? "Removed desktop", colour: stage.color))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: Actions.numbered().enumerated().compactMap { i, s in s.id.map { ($0, i) } })
        self.rows = rows.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        shortcuts = Shortcuts.stages()
    }

    private func reload() {
        shortcuts = Shortcuts.stages()
        changed()
    }

    /// Off the main thread: moving windows waits on their apps.
    private func delete(_ row: Row) {
        deleting = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String? = { do { try Actions.delete(row.id); return nil } catch { return "\(error)" } }()
            DispatchQueue.main.async {
                message = failure
                load()
                changed()
            }
        }
    }

    private func setColour(_ row: inout Row, _ hex: String?) {
        row.colour = hex
        let id = row.id
        debounce.run {
            do { try Actions.setColour(of: id, hex); changed() } catch { message = "\(error)" }
        }
    }
}

// MARK: Palette

private struct PalettePane: View {
    let changed: () -> Void
    /// Rows keep their own identity, so editing a name does not rebuild the row mid-typing.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var hex: String
    }

    @State private var colours: [Entry] = Palette.colours.map { Entry(name: $0.name, hex: $0.hex) }
    private let debounce = Debounce()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The colours offered in the menu bar's Colour Current Stage, the radial menu and the Stages tab. Changing one here does not recolour stages that already use it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
            List {
                ForEach($colours) { $entry in
                    HStack {
                        ColorPicker("", selection: Binding(get: { colour(entry.hex) }, set: { entry.hex = hex($0) }), supportsOpacity: false)
                            .labelsHidden()
                        TextField("Name", text: $entry.name)
                        Text(entry.hex).monospaced().foregroundStyle(.secondary)
                        Button {
                            colours.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(colours.count <= 1)
                    }
                    .id(entry.id)
                }
            }
            .onChange(of: colours.count) { before, after in
                guard after > before, let last = colours.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            }
            HStack {
                Button("Add Colour") { colours.append(Entry(name: "New colour", hex: "#808080")) }
                Spacer()
                Button("Restore Defaults") { colours = Palette.defaults.map { Entry(name: $0.name, hex: $0.hex) } }
            }
        }
        .onChange(of: colours) { _, value in
            debounce.run {
                Settings.update { $0.palette = value.map { .init(name: $0.name, hex: $0.hex) } }
                changed()
            }
        }
    }
}

// MARK: Shortcuts

private struct ShortcutsPane: View {
    let changed: () -> Void
    @State private var fetch = Shortcuts.fetch
    @State private var radial = Shortcuts.radial
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Fetch Bookmarked Windows").frame(maxWidth: .infinity, alignment: .leading)
                ShortcutRecorder(shortcut: fetch, target: .fetch, changed: { fetch = Shortcuts.fetch; changed() }, message: $message)
                Menu {
                    Button("Default (⌃⌥0)") { Settings.update { $0.fetchShortcut = nil }; fetch = Shortcuts.fetch; changed() }
                    Button("No Shortcut") { Settings.update { $0.fetchShortcut = Shortcut.none }; fetch = Shortcuts.fetch; changed() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text("It is registered only while a window is bookmarked, so other apps can use it otherwise.")
                .foregroundStyle(.secondary)
            HStack {
                Text("Radial Menu").frame(maxWidth: .infinity, alignment: .leading)
                ShortcutRecorder(shortcut: radial, target: .radial, changed: { radial = Shortcuts.radial; changed() }, message: $message)
                Menu {
                    Button("Default (⌃⌥R)") { Settings.update { $0.radialShortcut = nil }; radial = Shortcuts.radial; changed() }
                    Button("No Shortcut") { Settings.update { $0.radialShortcut = Shortcut.none }; radial = Shortcuts.radial; changed() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text("Opens the radial menu at the pointer, as a four-finger click or tap does. Use it where the trackpad gestures cannot reach StageKeeper, such as over Screen Sharing.")
                .foregroundStyle(.secondary)
            Text("Stage shortcuts are on the Stages tab.")
                .foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(.red) }
            Spacer()
        }
    }
}

// MARK: Recorder

/// A button that shows a shortcut and, when clicked, records the next key pressed with ⌃, ⌥
/// or ⌘ (or a function key on its own). Esc cancels. StageKeeper's own shortcuts are turned
/// off while recording, so pressing one records it instead of running it.
private struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let target: Hotkeys.Target
    let changed: () -> Void
    @Binding var message: String?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type a shortcut…" : (shortcut?.display ?? "None")) {
            recording ? stop() : start()
        }
        .frame(minWidth: 110)
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        recording = true
        Hotkeys.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue)
            guard !flags.subtracting(.shift).isEmpty || candidate.isFunctionKey else {
                message = "Hold ⌃, ⌥ or ⌘ with the key, or use a function key."
                NSSound.beep()
                return nil
            }
            if let user = Shortcuts.user(of: candidate, except: target) {
                message = "\(candidate.display) is already used by \(user)."
                NSSound.beep()
                return nil
            }
            switch target {
            case .fetch: Settings.update { $0.fetchShortcut = candidate }
            case .radial: Settings.update { $0.radialShortcut = candidate }
            case .stage(let id): Settings.update { $0.stageShortcuts = ($0.stageShortcuts ?? [:]).merging([id.uuidString: candidate]) { $1 } }
            }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        Hotkeys.suspend(false)
        changed()
    }
}

import AppKit

let usage = """
StageKeeper — window stages for macOS, with Stage Manager off.

Usage:
  stagekeeper save              Save every stage on this desktop (labels are kept).
  stagekeeper restore [--wait N] Open saved apps and rebuild the stages (waits up to N s, default 90, for windows).
  stagekeeper list              Show this desktop's stages and their labels.
  stagekeeper label "<name>"    Label the current stage ("" removes the label).
  stagekeeper colour <colour>   Colour the current stage: a name (\(Palette.colours.map(\.name).joined(separator: ", "))),
                                #RRGGBB, or none.
  stagekeeper switch <label|n>  Switch to a labelled stage by label or shortcut number (asks the menu-bar app).
  stagekeeper agent             Run the menu-bar item.
  stagekeeper reveal            Put back every window StageKeeper hid.
  stagekeeper update [--check]  Install the newest version from the checkout StageKeeper was built from
                                (--check only says whether there is one).
  stagekeeper version           Show the installed version and the checkout it came from.

Layouts:     \(Paths.desktops.path) (one file per desktop)
Log:         \(Paths.log.path)
"""

func runCLI(_ body: () throws -> Void) -> Never {
    do {
        try body()
        exit(0)
    } catch {
        FileHandle.standardError.write("stagekeeper: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
// Launched from Finder or `open` (no arguments, or a -psn argument): run as the menu-bar agent.
args.removeAll { $0.hasPrefix("-psn") }
let command = args.first ?? "agent"

switch command {
case "save":
    runCLI { try Actions.save() }
case "restore":
    var restorer = Restorer()
    if let i = args.firstIndex(of: "--wait"), i + 1 < args.count, let n = Double(args[i + 1]) { restorer.waitSeconds = n }
    runCLI { _ = try restorer.run() }
case "list":
    runCLI { print(try Actions.describe()) }
case "timings":
    runCLI { print(Snapshot.timings()) }
case "label":
    guard args.count >= 2 else { print(usage); exit(2) }
    runCLI { try Actions.labelCurrent(args.dropFirst().joined(separator: " ")) }
case "colour", "color":
    guard args.count == 2 else { print(usage); exit(2) }
    runCLI {
        if args[1].lowercased() == "none" { return try Actions.colourCurrent(nil) }
        guard let hex = Palette.resolve(args[1]) else { throw StageError.other("Unknown colour \(args[1]).") }
        try Actions.colourCurrent(hex)
    }
case "switch":
    guard args.count >= 2 else { print(usage); exit(2) }
    runCLI {
        let query = args.dropFirst().joined(separator: " ")
        guard let stage = Actions.find(query), let id = stage.id else {
            throw StageError.other("No labelled stage \"\(query)\".")
        }
        // The menu-bar app does the switch, so only it needs Accessibility permission.
        NSWorkspace.shared.open(URL(string: "stagekeeper://switch/\(id.uuidString)")!)
    }
case "reveal":
    runCLI { Engine.revealAll() }
case "update":
    runCLI {
        switch try Updater.check() {
        case .upToDate(let version):
            print("StageKeeper \(version) is up to date.")
        case .available(let target, let summary):
            print("Update available: \(Updater.installed()?.version ?? "?") → \(summary)")
            if args.contains("--check") { return }
            try Updater.installInForeground(target: target)
        }
    }
case "version", "--version":
    if let installed = Updater.installed() {
        print("StageKeeper \(installed.version) (\(installed.commit.prefix(7))), built from \(installed.source.path)")
    } else {
        print("StageKeeper (no build information; reinstall with scripts/install.sh)")
    }
case "agent":
    Log.echo = false
    let app = NSApplication.shared
    let controller = MenuBarController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
case "help", "-h", "--help":
    print(usage)
default:
    print(usage)
    exit(2)
}

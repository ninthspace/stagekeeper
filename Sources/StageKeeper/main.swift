import AppKit

let usage = """
StageKeeper — save and restore Stage Manager stages.

Usage:
  stagekeeper save              Save every stage (labels are kept).
  stagekeeper restore [--wait N] Open saved apps and rebuild the stages (waits up to N s, default 90, for windows).
  stagekeeper list              Show the current stages and their labels.
  stagekeeper label "<name>"    Label the current stage ("" removes the label).
  stagekeeper colour <colour>   Colour the current stage: a name (\(Palette.colours.map(\.name).joined(separator: ", "))),
                                #RRGGBB, or none.
  stagekeeper switch <label|n>  Switch to a labelled stage by label or shortcut number (asks the menu-bar app).
  stagekeeper agent             Run the menu-bar item; restores once per boot.

Layout file: \(Paths.layout.path)
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
        guard let stage = Actions.find(query, in: LayoutStore.load()), let id = stage.id else {
            throw StageError.other("No labelled stage \"\(query)\".")
        }
        // The menu-bar app does the switch, so only it needs Accessibility permission.
        NSWorkspace.shared.open(URL(string: "stagekeeper://switch/\(id.uuidString)")!)
    }
case "agent":
    Log.echo = false
    let app = NSApplication.shared
    let controller = MenuBarController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
case "skip-restore":
    // Used by install.sh so the first agent launch does not rearrange the current session.
    var state = AgentState.load()
    state.lastRestoredBoot = System.bootTime
    state.write()
case "help", "-h", "--help":
    print(usage)
default:
    print(usage)
    exit(2)
}

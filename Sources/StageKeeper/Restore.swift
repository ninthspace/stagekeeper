import AppKit

struct RestoreReport {
    var stages = 0
    var missingWindows: [String] = []

    var summary: String {
        var parts = ["Rebuilt \(stages) stages from the save."]
        if !missingWindows.isEmpty { parts.append("Windows not found: \(missingWindows.joined(separator: "; ")).") }
        return parts.joined(separator: " ")
    }
}

/// Rebuilds this desktop's stages from its last save: opens saved apps that are not running,
/// waits for their windows, matches them to the saved ones by app and title, and sets the stages.
struct Restorer {
    var waitSeconds: Double = 90

    func run() throws -> RestoreReport {
        guard var layout = LayoutStore.load() else { throw StageError.noLayout(Paths.layout.path) }
        _ = try Snapshot.take()
        launchMissingApps(layout)
        let snapshot = waitForWindows(layout)
        let matched = Matcher.match(layout, snapshot, loose: true)
        Engine.rebuild(layout, matched: matched, snapshot: snapshot)

        var report = RestoreReport()
        for (s, stage) in layout.stages.enumerated() {
            for (w, id) in matched[s].enumerated() {
                if let id, let live = snapshot.windows[id] {
                    // Point the save at this boot's windows so labels follow them.
                    layout.stages[s].windows[w].windowID = id
                    layout.stages[s].windows[w].title = live.title
                } else if id == nil {
                    report.missingWindows.append("\(stage.windows[w].appName) “\(stage.windows[w].title)”")
                }
            }
            if matched[s].contains(where: { $0 != nil }) { report.stages += 1 }
        }
        layout.bootTime = System.bootTime
        try LayoutStore.write(layout, keepPrevious: false)
        Log.write(report.summary)
        return report
    }

    private func launchMissingApps(_ layout: Layout) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var seen = Set<String>()
        for window in layout.stages.flatMap(\.windows) where !running.contains(window.bundleID) && seen.insert(window.bundleID).inserted {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: window.bundleID) else {
                Log.write("Cannot find app \(window.bundleID).")
                continue
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { Log.write("Could not open \(window.appName): \(error.localizedDescription)") }
            }
            Log.write("Opening \(window.appName).")
        }
    }

    /// Waits until every saved window has a live match, or (after at least 15 s) the window
    /// count has not changed for five seconds, or the timeout passes.
    private func waitForWindows(_ layout: Layout) -> Snapshot {
        let start = Date()
        let deadline = start.addingTimeInterval(waitSeconds)
        let needed = layout.stages.reduce(0) { $0 + $1.windows.count }
        var lastCount = -1
        var steadySince = Date()
        while true {
            if let snapshot = try? Snapshot.take() {
                let found = Matcher.match(layout, snapshot, loose: true).joined().compactMap { $0 }.count
                if found == needed { return snapshot }
                if snapshot.windows.count != lastCount {
                    lastCount = snapshot.windows.count
                    steadySince = Date()
                } else if Date().timeIntervalSince(steadySince) > 5, Date().timeIntervalSince(start) > 15 {
                    return snapshot
                }
                if Date() > deadline { return snapshot }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

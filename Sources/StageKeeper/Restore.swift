import AppKit

struct RestoreReport {
    var exact = 0
    var total = 0
    var missingWindows: [String] = []
    var notes: [String] = []

    var summary: String {
        var parts = ["Restored \(exact) of \(total) stages exactly."]
        if !missingWindows.isEmpty { parts.append("Windows not found: \(missingWindows.joined(separator: "; ")).") }
        parts.append(contentsOf: notes)
        return parts.joined(separator: " ")
    }
}

/// Rebuilds the saved stages with two Stage Manager actions on strip thumbnails:
/// click (switch to that stage) and shift-click (merge that stage into the current one).
/// Stage Manager cannot split a stage, so a strip item holding windows from more than one
/// saved stage is merged whole; the report notes it.
struct Restorer {
    var waitSeconds: Double = 90

    func run() throws -> RestoreReport {
        guard var layout = LayoutStore.load() else { throw StageError.noLayout(Paths.layout.path) }
        _ = try Snapshot.take()

        launchMissingApps(layout)
        let snapshot = waitForWindows(layout)
        let matched = Matcher.match(layout, snapshot, loose: true)

        var report = RestoreReport()
        for (s, stage) in layout.stages.enumerated() {
            for (w, id) in matched[s].enumerated() where id == nil {
                let saved = stage.windows[w]
                report.missingWindows.append("\(saved.appName) “\(saved.title)”")
            }
        }

        let targets = matched.map { $0.compactMap { $0 } }
        for s in layout.stages.indices.reversed() where !targets[s].isEmpty {
            build(targets[s], frames: zip(matched[s], layout.stages[s].windows).compactMap { id, saved in
                id.map { ($0, saved.frame.cgRect) }
            })
        }

        let final = try Snapshot.take()
        for target in targets where !target.isEmpty {
            report.total += 1
            let wanted = Set(target)
            if final.stages.contains(where: { Set($0.windowIDs) == wanted }) {
                report.exact += 1
            } else if let holder = final.stages.first(where: { !wanted.isDisjoint(with: $0.windowIDs) }) {
                let extras = holder.windowIDs.filter { !wanted.contains($0) }.compactMap { final.windows[$0]?.appName }
                if !extras.isEmpty {
                    let names = target.compactMap { final.windows[$0]?.appName }.joined(separator: ", ")
                    report.notes.append("The \(names) stage also holds \(extras.joined(separator: ", ")); Stage Manager cannot split a stage, so drag that window to the strip by hand.")
                }
            }
        }

        // Point the saved layout at this boot's window IDs so labels follow the windows.
        for (s, ids) in matched.enumerated() {
            for (w, id) in ids.enumerated() {
                if let id, let live = final.windows[id] {
                    layout.stages[s].windows[w].windowID = id
                    layout.stages[s].windows[w].title = live.title
                }
            }
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

    private func build(_ target: [CGWindowID], frames: [(CGWindowID, CGRect)]) {
        guard let first = target.first, let snapshot = try? Snapshot.take() else { return }
        if !snapshot.current.contains(first) {
            bringForward(first, snapshot)
            settle { $0.current.contains(first) }
        }

        for id in target.dropFirst() {
            guard let snapshot = try? Snapshot.take(), !snapshot.current.contains(id) else { continue }
            if let item = snapshot.stripItem(containing: id) {
                StripClick.click(item, shift: true)
                settle { $0.current.contains(id) }
            } else {
                // The window is beyond the strip: switch to it, then pull the stage being built back in.
                let building = Set(snapshot.current)
                bringForward(id, snapshot)
                settle { $0.current.contains(id) }
                if let after = try? Snapshot.take(),
                   let item = after.strip.first(where: { !building.isDisjoint(with: $0.windowIDs) }) {
                    StripClick.click(item, shift: true)
                    settle { $0.current.contains(first) }
                }
            }
        }

        guard let snapshot = try? Snapshot.take() else { return }
        for (id, frame) in frames {
            if let window = snapshot.windows[id], window.frame != frame { AX.setFrame(window.element, frame) }
        }
    }

    private func bringForward(_ id: CGWindowID, _ snapshot: Snapshot) {
        if let window = snapshot.windows[id] {
            AX.focus(window)
        } else if let item = snapshot.stripItem(containing: id) {
            StripClick.click(item, shift: false)
        }
    }

    /// Waits for Stage Manager's animation to finish and the condition to hold (up to 3 s).
    private func settle(_ condition: (Snapshot) -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        Thread.sleep(forTimeInterval: 0.4)
        while Date() < deadline {
            if let s = try? Snapshot.take(), condition(s) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
}

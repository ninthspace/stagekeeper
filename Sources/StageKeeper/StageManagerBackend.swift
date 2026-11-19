import AppKit

/// Stages kept by Stage Manager: StageKeeper reads them from the strip and changes them by
/// focusing windows and dragging previews.
struct StageManagerBackend: StageBackend {
    var makesStages: Bool { false }

    /// For each live stage, the index of the named or coloured saved stage it overlaps most
    /// (each saved stage used once). Bookmarked windows count for little: they move between
    /// stages, so a stage you fetch one into would otherwise take the name of the stage it came
    /// from. They still count, so a stage made mostly of bookmarked windows keeps its name.
    func savedIndices(_ layout: Layout, _ snapshot: Snapshot) -> [Int?] {
        var result = snapshot.stages.map { _ -> Int? in nil }
        let matched = Matcher.match(layout, snapshot, loose: false)
        let bookmarked = Set(Pins.load().filter { System.sameBoot($0.bootTime) }.map(\.windowID))
        let everywhere = Everywhere.ids()
        var pairs: [(overlap: Int, share: Double, live: Int, saved: Int)] = []
        for (l, live) in snapshot.stages.enumerated() {
            let liveSet = Set(live.windowIDs)
            for (s, saved) in layout.stages.enumerated() where saved.isIdentified {
                let shared = matched[s].compactMap { $0 }.filter { liveSet.contains($0) && !everywhere.contains($0) }
                let overlap = shared.filter { !bookmarked.contains($0) }.count * 100 + shared.filter(bookmarked.contains).count
                // On equal overlap, the saved stage with more of its windows here wins. A window
                // that shows on every stage, such as an Outlook reminder, otherwise ties a stage
                // with the one it was saved in.
                let counted = matched[s].enumerated().filter { _, id in id.map { !everywhere.contains($0) } ?? true }.count
                let share = Double(shared.count) / Double(max(counted, 1))
                if overlap > 0 { pairs.append((overlap, share, l, s)) }
            }
        }
        var usedSaved = Set<Int>()
        // On equal overlap and share, the live stage with more windows wins: a window moved
        // out to a new stage leaves the label with the stage it came from.
        let sizes = snapshot.stages.map(\.windowIDs.count)
        let ranked = pairs.sorted {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.share != $1.share { return $0.share > $1.share }
            return sizes[$0.live] > sizes[$1.live]
        }
        for p in ranked where result[p.live] == nil && !usedSaved.contains(p.saved) {
            result[p.live] = p.saved
            usedSaved.insert(p.saved)
        }
        return result
    }

    /// Checks that the stage became current; the last attempt clicks the strip thumbnail instead,
    /// which is less reliable because Stage Manager often reports the hidden strip off screen.
    ///
    /// With `carryPins`, pinned windows in the stage being left come along (see `Pins`). Only
    /// Fetch Pinned Windows (⌃⌥0) does that: an ordinary switch leaves pinned windows where they
    /// are, because a drag that takes a whole stage instead of one window merges two stages.
    func switchTo(_ stage: LiveStage, in snapshot: Snapshot, carryPins: Bool) throws {
        guard stage.kind != .current, let id = FocusHistory.frontmost(of: stage.windowIDs) else { return }
        let pinned = carryPins ? Pins.resolve(snapshot).filter { snapshot.current.contains($0) } : []
        var frames: [CGWindowID: CGRect] = [:]
        if !pinned.isEmpty {
            // Bring the pinned windows to the front, first pin frontmost, so their previews are
            // on top of the thumbnail this stage becomes.
            for pin in pinned {
                if let window = snapshot.windows[pin], let frame = AX.frame(window.element) { frames[pin] = frame }
            }
            for pin in pinned.reversed() {
                if let window = snapshot.windows[pin] { AX.focus(window); usleep(120_000) }
            }
        }
        var snapshot = snapshot
        var switched = false
        for attempt in 1...3 where !switched {
            if attempt < 3, let window = snapshot.windows[id] {
                AX.focus(window)
            } else if let strip = snapshot.stripItem(containing: id) {
                StripClick.click(strip, shift: false)
            }
            // Poll rather than wait a fixed time: most switches finish well inside the limit.
            var after: Snapshot?
            for _ in 0..<8 {
                usleep(80_000)
                after = try? Snapshot.take()
                if after?.current.contains(id) == true { switched = true; break }
            }
            guard let after else { return }
            if !switched {
                Log.write("Stage switch attempt \(attempt) did not take.")
                snapshot = after
            }
        }
        if switched, !carryPins {
            let names = stage.windowIDs.compactMap { snapshot.windows[$0]?.appName }
            Log.write("Switched to the stage with \(Array(Set(names)).sorted().joined(separator: ", ")).")
        }
        guard switched, carryPins else { return }
        if !pinned.isEmpty { carry(pinned, frames: frames, thenFocus: id) }
    }

    func fetchPinned(into home: CGWindowID, snapshot: Snapshot) throws {
        var snapshot = snapshot
        let away = Pins.resolve(snapshot).filter { !snapshot.current.contains($0) && snapshot.stripItem(containing: $0) != nil }
        guard !away.isEmpty else { throw StageError.other("No bookmarked windows are in other stages on this desktop.") }
        let groups = stageGroups(snapshot, leaving: Set(Pins.resolve(snapshot)))
        var done = Set<CGWindowID>()
        for pin in away where !done.contains(pin) {
            guard let window = snapshot.windows[pin] else { continue }
            AX.focus(window)
            var there = false
            for _ in 0..<15 {
                usleep(100_000)
                snapshot = try Snapshot.take()
                if snapshot.current.contains(pin) && !snapshot.current.contains(home) { there = true; break }
            }
            guard there, let back = snapshot.stages.first(where: { $0.windowIDs.contains(home) }) else {
                throw StageError.other("Could not go to the \(window.appName) window's stage.")
            }
            done.formUnion(snapshot.current)
            try switchTo(back, in: snapshot, carryPins: true)
            snapshot = try Snapshot.take()
        }
        try checkForMerges(groups, after: "fetching bookmarked windows")
        snapshot = try Snapshot.take()
        let missing = Pins.resolve(snapshot).filter { away.contains($0) && !snapshot.current.contains($0) }
        if !missing.isEmpty { throw StageError.other("Some bookmarked windows did not come. See the log.") }
    }

    /// Drags pinned windows from the stage just left into the current one, puts each back at its
    /// position and size, and returns focus to `focus`.
    private func carry(_ pinned: [CGWindowID], frames: [CGWindowID: CGRect], thenFocus focus: CGWindowID) {
        // While Stage Manager animates the switch, the windows left behind still read as current.
        guard var after = try? Snapshot.take() else { return }
        for _ in 0..<18 where pinned.contains(where: after.current.contains) {
            usleep(100_000)
            guard let next = try? Snapshot.take() else { return }
            after = next
        }
        for pin in pinned {
            guard let window = after.windows[pin] else {
                Log.write("A bookmarked window was not found after the switch.")
                continue
            }
            if after.current.contains(pin) { continue }
            guard after.stripItem(containing: pin) != nil else {
                Log.write("The bookmarked \(window.appName) window is not in the strip, so it cannot be dragged.")
                continue
            }
            guard StripClick.dragIntoCurrent(window) else {
                Log.write("The bookmarked \(window.appName) window stayed behind: its preview was not found.")
                continue
            }
            var arrived = false
            for _ in 0..<10 {
                usleep(100_000)
                guard let next = try? Snapshot.take() else { break }
                after = next
                if next.current.contains(pin) { arrived = true; break }
            }
            if arrived, let frame = frames[pin], let element = after.windows[pin]?.element {
                AX.setFrame(element, frame)
            } else if !arrived {
                Log.write("The bookmarked \(window.appName) window stayed behind.")
            }
        }
        if let window = (try? Snapshot.take())?.windows[focus] { AX.focus(window) }
    }

    func move(_ front: CGWindowID, toStageWith targetWindow: CGWindowID, target: LiveStage, snapshot: Snapshot) throws {
        let started = Date()
        guard let name = snapshot.windows[front]?.appName else { return }
        // A dropped preview lands where it is dropped; the window goes back here afterwards.
        let originalFrame = snapshot.windows[front].flatMap { AX.frame($0.element) }
        try switchTo(target, in: snapshot, carryPins: false)
        // While Stage Manager animates the switch, the old stage's windows are still on screen
        // and read as current. Wait for the window to reach the strip.
        var after = try Snapshot.take()
        for _ in 0..<18 where after.current.contains(front) {
            usleep(100_000)
            after = try Snapshot.take()
        }
        guard after.current.contains(targetWindow) else { throw StageError.other("Could not switch to that stage.") }
        if after.current.contains(front) {
            throw StageError.other("The \(name) window shows on every stage, or is already in that stage, so there is nothing to move.")
        }
        guard let window = after.windows[front], after.stripItem(containing: front) != nil else {
            throw StageError.other("The \(name) window is not in the strip, so it cannot be dragged.")
        }
        let groups = stageGroups(snapshot, leaving: [front])
        guard StripClick.dragIntoCurrent(window) else {
            throw StageError.other("Could not find the \(name) window in the strip. See the log for details.")
        }
        for _ in 0..<10 {
            usleep(100_000)
            after = try Snapshot.take()
            if after.current.contains(front) { break }
        }
        guard after.current.contains(front) else { throw StageError.other("Stage Manager did not take the \(name) window.") }
        if let originalFrame, let element = after.windows[front]?.element { AX.setFrame(element, originalFrame) }
        try checkForMerges(groups, after: "moving the \(name) window")
        Log.write("Moved the \(name) window to another stage in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
    }

    /// The windows of each stage in the strip and the current stage, leaving out `leaving` (the
    /// windows that are meant to move).
    private func stageGroups(_ snapshot: Snapshot, leaving: Set<CGWindowID>) -> [Set<CGWindowID>] {
        snapshot.stages.filter { $0.kind != .overflow }
            .map { Set($0.windowIDs).subtracting(leaving) }
            .filter { !$0.isEmpty }
    }

    /// Throws when two of the stages in `groups` are now one stage, which happens when a drag
    /// takes a whole stage instead of one window. Waits for the stages to read the same three
    /// times in a row first: while Stage Manager animates, windows of other stages briefly read
    /// as current.
    private func checkForMerges(_ groups: [Set<CGWindowID>], after action: String) throws {
        guard var latest = try? Snapshot.take() else { return }
        func shape(_ snapshot: Snapshot) -> [Set<CGWindowID>] { snapshot.stages.map { Set($0.windowIDs) } }
        var steady = 0
        for _ in 0..<20 where steady < 2 {
            usleep(150_000)
            guard let next = try? Snapshot.take() else { return }
            steady = shape(next) == shape(latest) ? steady + 1 : 0
            latest = next
        }
        for stage in latest.stages where stage.kind != .overflow {
            let ids = Set(stage.windowIDs)
            let joined = groups.filter { !$0.isDisjoint(with: ids) }
            guard joined.count > 1 else { continue }
            let names = joined.map { group in
                group.compactMap { latest.windows[$0] }.map { "\($0.appName) \"\($0.title)\"" }.sorted().joined(separator: ", ")
            }
            Log.write("After \(action), these stages are now one: \(names.map { "[\($0)]" }.joined(separator: " + ")).")
            throw StageError.other("Two stages merged while \(action). See the log.")
        }
    }

}

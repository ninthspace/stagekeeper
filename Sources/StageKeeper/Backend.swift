import AppKit

/// What StageKeeper does with stages, done either through Stage Manager or through
/// StageKeeper's own stages (`Engine`) when Stage Manager is off.
protocol StageBackend {
    /// Whether StageKeeper can split a window off into a new stage of its own.
    var makesStages: Bool { get }
    /// For each live stage, the index in `layout` of the saved stage it is, if any.
    func savedIndices(_ layout: Layout, _ snapshot: Snapshot) -> [Int?]
    /// Makes `stage` current; with `carryPins`, bookmarked windows of the stage being left come along.
    func switchTo(_ stage: LiveStage, in snapshot: Snapshot, carryPins: Bool) throws
    /// Brings bookmarked windows in other stages into the stage holding `home`.
    func fetchPinned(into home: CGWindowID, snapshot: Snapshot) throws
    /// Moves `front`, a window of the current stage, into `target`, the stage holding
    /// `targetWindow`, and makes that stage current.
    func move(_ front: CGWindowID, toStageWith targetWindow: CGWindowID, target: LiveStage, snapshot: Snapshot) throws
}

enum Backend {
    static var current: StageBackend { Engine.active ? EngineBackend() : StageManagerBackend() }
}

/// StageKeeper's own stages, kept by `Engine`.
struct EngineBackend: StageBackend {
    var makesStages: Bool { true }

    /// Each engine stage records which saved stage it is.
    func savedIndices(_ layout: Layout, _ snapshot: Snapshot) -> [Int?] {
        snapshot.stages.map { live in live.savedID.flatMap { id in layout.stages.firstIndex { $0.id == id } } }
    }

    func switchTo(_ stage: LiveStage, in snapshot: Snapshot, carryPins: Bool) throws {
        guard stage.kind != .current, let first = stage.windowIDs.first else { return }
        if carryPins {
            let pinned = Pins.resolve(snapshot).filter { snapshot.current.contains($0) }
            if !pinned.isEmpty { try Engine.move(pinned, toStageWith: first, snapshot: snapshot) }
        }
        try Engine.activate(stageWith: first, snapshot: snapshot)
        let names = stage.windowIDs.compactMap { snapshot.windows[$0]?.appName }
        Log.write("Switched to the stage with \(Array(Set(names)).sorted().joined(separator: ", ")).")
    }

    func fetchPinned(into home: CGWindowID, snapshot: Snapshot) throws {
        let away = Pins.resolve(snapshot).filter { !snapshot.current.contains($0) }
        guard !away.isEmpty else { throw StageError.other("No bookmarked windows are in other stages on this desktop.") }
        try Engine.move(away, toStageWith: home, snapshot: snapshot)
        Engine.bringForward(home, snapshot: snapshot)
        Log.write("Fetched \(away.count) bookmarked windows.")
    }

    func move(_ front: CGWindowID, toStageWith targetWindow: CGWindowID, target: LiveStage, snapshot: Snapshot) throws {
        try Engine.move([front], toStageWith: targetWindow, snapshot: snapshot)
        try Engine.activate(stageWith: targetWindow, focus: front, snapshot: snapshot)
        Log.write("Moved the \(snapshot.windows[front]?.appName ?? "") window to another stage.")
    }
}

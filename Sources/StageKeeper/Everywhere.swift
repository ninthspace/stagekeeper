import AppKit

/// Windows that show on every stage, such as Outlook's reminders. Stage Manager keeps them on
/// screen whichever stage is showing, so they read as part of the current stage. Saving one
/// with a stage, or matching labels by it, gives that stage's label to whatever stage is showing.
///
/// A window counts as showing everywhere once it has been seen in the current stage alongside
/// three sets of windows that have nothing in common: three different stages. Only stage reads
/// that match the previous read count, so a read taken while Stage Manager animates a switch
/// (when windows of two stages show at once) is not used. Window IDs last until a restart, so
/// the list is kept with the boot it belongs to.
enum Everywhere {
    nonisolated(unsafe) private static var lastCurrent: Set<CGWindowID> = []
    nonisolated(unsafe) private static var companions: [CGWindowID: [Set<CGWindowID>]] = [:]
    private static let lock = NSLock()
    private static let stagesNeeded = 3

    static func ids() -> Set<CGWindowID> {
        let state = AgentState.load()
        guard System.sameBoot(state.everywhereBoot) else { return [] }
        return Set(state.everywhere ?? [])
    }

    /// Called with each stage read the menu-bar app makes for its title.
    static func note(_ snapshot: Snapshot) {
        let current = Set(snapshot.current)
        lock.lock(); defer { lock.unlock() }
        defer { lastCurrent = current }
        guard current == lastCurrent, current.count >= 2 else { return }
        var known = ids()
        var found: [CGWindowID] = []
        for window in current where !known.contains(window) {
            let others = current.subtracting([window]).subtracting(known)
            guard !others.isEmpty else { continue }
            var seen = companions[window] ?? []
            if let same = seen.firstIndex(where: { !$0.isDisjoint(with: others) }) {
                seen[same].formUnion(others)
            } else {
                seen.append(others)
            }
            companions[window] = seen
            if seen.count >= stagesNeeded { found.append(window) }
        }
        guard !found.isEmpty else { return }
        known.formUnion(found)
        var state = AgentState.load()
        state.everywhere = Array(known)
        state.everywhereBoot = System.bootTime
        state.write()
        for id in found {
            let window = snapshot.windows[id]
            Log.write("The \(window?.appName ?? "") window \"\(window?.title ?? "")\" shows on every stage; it is left out of saves and label matching.")
        }
    }
}

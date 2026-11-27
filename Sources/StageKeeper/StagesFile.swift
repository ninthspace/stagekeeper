import Foundation

/// The content of `stages.json`: the labelled stages in shortcut order, with the one showing marked,
/// for other tools (the Stream Deck plugin) to read. The menu-bar app writes it.
struct StagesFile: Codable, Equatable {
    struct Stage: Codable, Equatable {
        var id: UUID
        var label: String
        /// Hex colour such as "#0090FF", or nil.
        var colour: String?
        /// 1-based shortcut order.
        var number: Int
        var current: Bool

        enum CodingKeys: String, CodingKey { case id, label, colour, number, current }

        // `colour` is written as null rather than left out, so readers see every key.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(colour, forKey: .colour)
            try c.encode(number, forKey: .number)
            try c.encode(current, forKey: .current)
        }
    }

    static let fileName = "stages.json"

    var version: Int
    var updatedAt: Date
    var agentPid: Int32
    var stageManagerOn: Bool
    var stages: [Stage]

    /// Builds the file from the labelled stages in shortcut order (`Actions.numbered()`). `current` comes
    /// only from `currentID`, the stage the live snapshot shows, never from `SavedStage.current`, which
    /// is stale between saves. With Stage Manager on, no stage is current.
    static func encode(numbered: [SavedStage], currentID: UUID?, stageManagerOn: Bool, agentPid: Int32,
                       now: Date) -> StagesFile {
        let stages = numbered.enumerated().compactMap { index, saved -> Stage? in
            guard let id = saved.id, let label = saved.label else { return nil }
            return Stage(id: id, label: label, colour: saved.color, number: index + 1,
                         current: !stageManagerOn && id == currentID)
        }
        return StagesFile(version: 1, updatedAt: now, agentPid: agentPid, stageManagerOn: stageManagerOn,
                          stages: stages)
    }

    /// Writes `stages.json` into `directory` by writing a temporary file and renaming it into place.
    /// Returns false, leaving the file untouched, when the file on disk already holds the same content
    /// apart from `updatedAt`, or when the write fails.
    @discardableResult
    static func write(_ file: StagesFile, to directory: URL) -> Bool {
        let url = directory.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url), var existing = try? decoder.decode(StagesFile.self, from: data) {
            existing.updatedAt = file.updatedAt
            if existing == file { return false }
        }
        guard let data = try? encoder.encode(file) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return isoFormatter.date(from: text) ?? Date(timeIntervalSince1970: 0)
        }
        return decoder
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

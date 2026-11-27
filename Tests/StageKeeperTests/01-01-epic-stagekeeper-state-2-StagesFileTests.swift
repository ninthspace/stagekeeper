import Foundation
import Testing
@testable import stagekeeper

/// Acceptance tests for epic 01-01 Story 2, "Write stages.json".
/// Every test reads `stages.json` back from a temporary directory; nothing touches the real
/// Application Support folder or anything in main.swift.
@Suite struct StagesFileStory2Tests {
    // MARK: - Fixtures

    private static let t0 = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18
    private static let pid: Int32 = 4242

    private func stage(_ label: String, colour: String?, current: Bool = false, id: UUID = UUID()) -> SavedStage {
        SavedStage(id: id, label: label, color: colour, current: current, windows: [])
    }

    /// Labels deliberately not in any sorted order, so a writer that re-sorts fails.
    private func fixture() -> [SavedStage] {
        [
            stage("Zulu", colour: "#0090FF", current: true),
            stage("alpha", colour: nil),
            stage("Stage 10", colour: "#FF5500"),
            stage("Stage 9", colour: "#00AA44"),
        ]
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("01-01-epic-stagekeeper-state-2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileURL(_ directory: URL) -> URL { directory.appendingPathComponent("stages.json") }

    /// Writes `file` to a fresh directory and returns the decoded `stages.json`.
    private func writtenJSON(_ file: StagesFile) throws -> [String: Any] {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(StagesFile.write(file, to: dir))
        return try readJSON(dir)
    }

    private func readJSON(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL(directory))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func stages(_ json: [String: Any]) throws -> [[String: Any]] {
        try #require(json["stages"] as? [[String: Any]])
    }

    /// A JSON boolean (not a number that bridges to Bool).
    private func jsonBool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// A JSON number (not a boolean).
    private func jsonNumber(_ value: Any?) -> NSNumber? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }

    private func currentFlags(_ json: [String: Any]) throws -> [Bool?] {
        try stages(json).map { jsonBool($0["current"]) }
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func inode(_ url: URL) throws -> Int {
        try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue)
    }

    // MARK: - encode

    @Test func encodeGivesTopLevelFieldsAndStagesInOrderNumbered() throws {
        let numbered = fixture()
        let file = StagesFile.encode(numbered: numbered, currentID: nil, stageManagerOn: false,
                                     agentPid: Self.pid, now: Self.t0)
        let json = try writtenJSON(file)

        #expect(jsonNumber(json["version"])?.intValue == 1)
        #expect(json["updatedAt"] != nil)
        #expect(!(json["updatedAt"] is NSNull))
        #expect(jsonNumber(json["agentPid"])?.int32Value == Self.pid)
        #expect(jsonBool(json["stageManagerOn"]) == false)

        let out = try stages(json)
        try #require(out.count == numbered.count)
        #expect(out.map { $0["label"] as? String } == ["Zulu", "alpha", "Stage 10", "Stage 9"])
        #expect(out.map { jsonNumber($0["number"])?.intValue } == [1, 2, 3, 4])
        #expect(out.map { uuid($0["id"]) } == numbered.map(\.id))
        #expect(out.map { $0["colour"] as? String } == ["#0090FF", nil, "#FF5500", "#00AA44"])
        // A stage with no colour carries `colour: null`.
        #expect(out[1].keys.contains("colour"))
        #expect(out[1]["colour"] is NSNull)
    }

    @Test func updatedAtFollowsNow() throws {
        let numbered = fixture()
        let a = try writtenJSON(StagesFile.encode(numbered: numbered, currentID: nil, stageManagerOn: false,
                                                  agentPid: Self.pid, now: Self.t0))
        let b = try writtenJSON(StagesFile.encode(numbered: numbered, currentID: nil, stageManagerOn: false,
                                                  agentPid: Self.pid, now: Self.t0.addingTimeInterval(3600)))
        let ua = try #require(a["updatedAt"])
        let ub = try #require(b["updatedAt"])
        #expect(!(ua as AnyObject).isEqual(ub))
    }

    @Test func encodeOfNoStagesGivesEmptyStages() throws {
        let json = try writtenJSON(StagesFile.encode(numbered: [], currentID: nil, stageManagerOn: false,
                                                     agentPid: Self.pid, now: Self.t0))
        #expect(try stages(json).isEmpty)
        #expect(jsonNumber(json["version"])?.intValue == 1)
    }

    // MARK: - current

    @Test func onlyTheCurrentIDStageIsCurrentRegardlessOfSavedCurrent() throws {
        let numbered = fixture()
        // "Zulu" (index 0) has SavedStage.current true; "Stage 10" (index 2) is false but is currentID.
        #expect(numbered[0].current == true)
        #expect(numbered[2].current == false)
        let json = try writtenJSON(StagesFile.encode(numbered: numbered, currentID: numbered[2].id,
                                                     stageManagerOn: false, agentPid: Self.pid, now: Self.t0))
        #expect(try currentFlags(json) == [false, false, true, false])
        let current = try stages(json).filter { jsonBool($0["current"]) == true }
        try #require(current.count == 1)
        #expect(uuid(current[0]["id"]) == numbered[2].id)
    }

    @Test func nilCurrentIDMarksNoStageCurrent() throws {
        let numbered = fixture() // "Zulu" has SavedStage.current true
        let json = try writtenJSON(StagesFile.encode(numbered: numbered, currentID: nil, stageManagerOn: false,
                                                     agentPid: Self.pid, now: Self.t0))
        #expect(try currentFlags(json) == [false, false, false, false])
    }

    @Test func stageManagerOnMarksNoStageCurrent() throws {
        let numbered = fixture()
        let json = try writtenJSON(StagesFile.encode(numbered: numbered, currentID: numbered[1].id,
                                                     stageManagerOn: true, agentPid: Self.pid, now: Self.t0))
        #expect(jsonBool(json["stageManagerOn"]) == true)
        #expect(try currentFlags(json) == [false, false, false, false])
        #expect(try stages(json).count == numbered.count)
    }

    /// Stages distinct by `id` but sharing label and colour are all kept, and `current` follows the id.
    @Test func stagesSharingLabelAndColourAreKeptByID() throws {
        let first = stage("Work", colour: "#0090FF", current: true)
        let second = stage("Work", colour: "#0090FF")
        let json = try writtenJSON(StagesFile.encode(numbered: [first, second], currentID: second.id,
                                                     stageManagerOn: false, agentPid: Self.pid, now: Self.t0))
        let out = try stages(json)
        try #require(out.count == 2)
        #expect(out.map { uuid($0["id"]) } == [first.id, second.id])
        #expect(out.map { jsonNumber($0["number"])?.intValue } == [1, 2])
        #expect(out.map { jsonBool($0["current"]) } == [false, true])
    }

    // MARK: - write

    @Test func writeReplacesFileByRenameLeavingNoTemporaryFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let numbered = fixture()
        let url = fileURL(dir)

        let first = StagesFile.encode(numbered: numbered, currentID: numbered[0].id, stageManagerOn: false,
                                      agentPid: Self.pid, now: Self.t0)
        #expect(StagesFile.write(first, to: dir))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["stages.json"])
        let firstInode = try inode(url)

        let second = StagesFile.encode(numbered: numbered, currentID: numbered[3].id, stageManagerOn: false,
                                       agentPid: Self.pid, now: Self.t0.addingTimeInterval(3))
        #expect(StagesFile.write(second, to: dir))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["stages.json"])
        // A rename puts a new file in place; writing into the existing file keeps its inode.
        #expect(try inode(url) != firstInode)
        #expect(try currentFlags(readJSON(dir)) == [false, false, false, true])
    }

    @Test func unchangedApartFromUpdatedAtIsNotRewrittenButChangedCurrentIs() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let numbered = fixture()
        let url = fileURL(dir)

        #expect(StagesFile.write(StagesFile.encode(numbered: numbered, currentID: numbered[0].id,
                                                   stageManagerOn: false, agentPid: Self.pid, now: Self.t0),
                                 to: dir))
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        let bytesBefore = try Data(contentsOf: url)
        let inodeBefore = try inode(url)

        // Same content, later time: not rewritten.
        let same = StagesFile.encode(numbered: numbered, currentID: numbered[0].id, stageManagerOn: false,
                                     agentPid: Self.pid, now: Self.t0.addingTimeInterval(3))
        #expect(StagesFile.write(same, to: dir) == false)
        #expect(try modificationDate(url) == past)
        #expect(try Data(contentsOf: url) == bytesBefore)
        #expect(try inode(url) == inodeBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["stages.json"])

        // A changed `current`: rewritten.
        let changed = StagesFile.encode(numbered: numbered, currentID: numbered[1].id, stageManagerOn: false,
                                        agentPid: Self.pid, now: Self.t0.addingTimeInterval(6))
        #expect(StagesFile.write(changed, to: dir))
        #expect(try modificationDate(url) != past)
        #expect(try currentFlags(readJSON(dir)) == [false, true, false, false])
    }

    /// The comparison is with the file on disk, not with the last thing written.
    @Test func unchangedIsJudgedAgainstTheFileOnDisk() throws {
        let dir = try makeDirectory()
        let other = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: other)
        }
        let numbered = fixture()
        let url = fileURL(dir)

        let a = StagesFile.encode(numbered: numbered, currentID: numbered[0].id, stageManagerOn: false,
                                  agentPid: Self.pid, now: Self.t0)
        let b = StagesFile.encode(numbered: numbered, currentID: numbered[2].id, stageManagerOn: false,
                                  agentPid: Self.pid, now: Self.t0.addingTimeInterval(3))
        #expect(StagesFile.write(a, to: other))
        #expect(StagesFile.write(b, to: dir))

        // Put content A back on disk in `dir` behind the writer's back.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: fileURL(other), to: url)
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)

        // A again, later: equal to the disk apart from updatedAt, so not rewritten.
        let aAgain = StagesFile.encode(numbered: numbered, currentID: numbered[0].id, stageManagerOn: false,
                                       agentPid: Self.pid, now: Self.t0.addingTimeInterval(6))
        #expect(StagesFile.write(aAgain, to: dir) == false)
        #expect(try modificationDate(url) == past)

        // B again: differs from the disk (A), so rewritten even though B was the last write here.
        let bAgain = StagesFile.encode(numbered: numbered, currentID: numbered[2].id, stageManagerOn: false,
                                       agentPid: Self.pid, now: Self.t0.addingTimeInterval(9))
        #expect(StagesFile.write(bAgain, to: dir))
        #expect(try currentFlags(readJSON(dir)) == [false, false, true, false])
    }
}

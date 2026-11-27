// Independent tests: 01-01-epic-stagekeeper-state Story 3, "stagekeeper list --json".
//
// Boundary:
//   ListJSON.render(stateFile: URL, isAgent: (Int32) -> Bool) -> (output: String, status: Int32)
//     reads `stages.json` at `stateFile`; `isAgent` is the outbound seam and is faked here.
//   AgentCheck.isAgent(pid: Int32, ownPid: Int32) -> Bool, the real check.
//
// Seam chosen for AgentCheck: these tests also call
//   AgentCheck.isAgent(pid: Int32, ownPid: Int32, executable: String) -> Bool
// where `executable` is the path of the StageKeeper app's executable. `isAgent(pid:ownPid:)` is the
// same check with `executable` set to the calling process's own executable (the CLI and the agent are
// the same `stagekeeper` binary).
//
// No `stagekeeper` subcommand waits without side effects (`agent` starts the menu-bar item; the others
// exit at once or act on windows), so the tests never launch the StageKeeper binary. For the
// 3-argument form, "the StageKeeper app's executable" is the executable of a process the test
// controls (/bin/sleep), and "another executable" is a path that process does not run (/bin/cat).
// Nothing here touches ~/Library/Application Support/StageKeeper.

import Foundation
import Testing

@testable import stagekeeper

@Suite("stagekeeper list --json (01-01-epic-stagekeeper-state-3)")
struct ListJSONTests_01_01_epic_stagekeeper_state_3 {
    // MARK: - Fixtures

    static let agentPid: Int32 = 51807

    static let ids = [
        "6F1C2A3B-0001-4000-8000-000000000001",
        "6F1C2A3B-0002-4000-8000-000000000002",
        "6F1C2A3B-0003-4000-8000-000000000003",
        "6F1C2A3B-0004-4000-8000-000000000004",
    ]

    /// A `stages.json` as Story 2's `StagesFile.write` produces it: pretty-printed, sorted keys,
    /// `colour` written as null, `updatedAt` in ISO 8601 with fractional seconds.
    static func stagesJSON(agentPid: Int32 = agentPid, stageManagerOn: Bool = false) -> String {
        """
        {
          "agentPid" : \(agentPid),
          "stageManagerOn" : \(stageManagerOn),
          "stages" : [
            {
              "colour" : "#0090FF",
              "current" : false,
              "id" : "\(ids[0])",
              "label" : "Zulu",
              "number" : 1
            },
            {
              "colour" : null,
              "current" : true,
              "id" : "\(ids[1])",
              "label" : "alpha",
              "number" : 2
            },
            {
              "colour" : "#FF5500",
              "current" : false,
              "id" : "\(ids[2])",
              "label" : "Stage 10",
              "number" : 3
            },
            {
              "colour" : "#00AA44",
              "current" : false,
              "id" : "\(ids[3])",
              "label" : "Stage 9",
              "number" : 4
            }
          ],
          "updatedAt" : "2026-11-26T10:15:00.250Z",
          "version" : 1
        }
        """
    }

    static let noFileOutput: [String: Any] = [
        "version": 1, "stages": [Any](), "stageManagerOn": false, "agentRunning": false,
    ]

    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("01-01-epic-stagekeeper-state-3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeStateFile(_ text: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("stages.json")
        try Data(text.utf8).write(to: url)
        return url
    }

    static func parse(_ output: String) throws -> [String: Any] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        return try #require(object as? [String: Any], "output is not a JSON object: \(output)")
    }

    static func content(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        NSDictionary(dictionary: a).isEqual(to: b)
    }

    /// A JSON boolean (not a number that bridges to Bool).
    static func jsonBool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func stageIDs(_ object: [String: Any]) -> [String] {
        (object["stages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    // MARK: - The fixture

    @Test("the fixture's stage ids are unique")
    func fixtureIdsAreUnique() throws {
        let ids = Self.stageIDs(try Self.content(Self.stagesJSON()))
        #expect(ids.count == 4)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - A file with stages

    @Test("a file with stages prints its content plus agentRunning, and exits 0")
    func fileWithStages() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = Self.stagesJSON()
        let stateFile = try Self.writeStateFile(text, in: dir)

        var asked: [Int32] = []
        let result = ListJSON.render(stateFile: stateFile, isAgent: { pid in
            asked.append(pid)
            return pid == Self.agentPid
        })

        #expect(result.status == 0)
        var output = try Self.parse(result.output)
        #expect(Self.jsonBool(output["agentRunning"]) == true, "output: \(result.output)")
        #expect(asked.contains(Self.agentPid))
        output.removeValue(forKey: "agentRunning")
        #expect(Self.same(output, try Self.content(text)), "output apart from agentRunning: \(result.output)")
        // Floor: every stage in the file is in the output, in the file's order.
        #expect(Self.stageIDs(output) == Self.ids)
    }

    @Test("the content is passed through with stageManagerOn true")
    func fileWithStageManagerOn() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = Self.stagesJSON(stageManagerOn: true)
        let stateFile = try Self.writeStateFile(text, in: dir)

        let result = ListJSON.render(stateFile: stateFile, isAgent: { $0 == Self.agentPid })

        #expect(result.status == 0)
        var output = try Self.parse(result.output)
        #expect(Self.jsonBool(output["stageManagerOn"]) == true)
        #expect(Self.jsonBool(output["agentRunning"]) == true)
        output.removeValue(forKey: "agentRunning")
        #expect(Self.same(output, try Self.content(text)), "output apart from agentRunning: \(result.output)")
    }

    @Test("agentRunning is false when the check says agentPid is not the agent")
    func agentNotRunning() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = Self.stagesJSON()
        let stateFile = try Self.writeStateFile(text, in: dir)

        let result = ListJSON.render(stateFile: stateFile, isAgent: { _ in false })

        #expect(result.status == 0)
        var output = try Self.parse(result.output)
        #expect(Self.jsonBool(output["agentRunning"]) == false, "output: \(result.output)")
        output.removeValue(forKey: "agentRunning")
        #expect(Self.same(output, try Self.content(text)), "output apart from agentRunning: \(result.output)")
    }

    @Test("agentRunning is worked out from the file's agentPid")
    func agentRunningFromAgentPid() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateFile = try Self.writeStateFile(Self.stagesJSON(agentPid: 62219), in: dir)

        // The check says only 51807 is the agent; this file's agent is 62219.
        let result = ListJSON.render(stateFile: stateFile, isAgent: { $0 == Self.agentPid })

        #expect(result.status == 0)
        let output = try Self.parse(result.output)
        #expect(Self.jsonBool(output["agentRunning"]) == false, "output: \(result.output)")
        #expect((output["agentPid"] as? NSNumber)?.int32Value == 62219)
    }

    // MARK: - No file

    @Test("with no file the output is the empty output and the exit status is 0")
    func noFile() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateFile = dir.appendingPathComponent("stages.json")

        // A check that says every pid is the agent: with no file there is no agent pid to check.
        let result = ListJSON.render(stateFile: stateFile, isAgent: { _ in true })

        #expect(result.status == 0)
        let output = try Self.parse(result.output)
        #expect(Self.same(output, Self.noFileOutput), "output: \(result.output)")
        #expect(Self.jsonBool(output["agentRunning"]) == false)
        #expect(Self.jsonBool(output["stageManagerOn"]) == false)
    }

    @Test("with no directory either the output is the empty output and the exit status is 0")
    func noDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("01-01-epic-stagekeeper-state-3-missing-\(UUID().uuidString)", isDirectory: true)
        let stateFile = dir.appendingPathComponent("stages.json")

        let result = ListJSON.render(stateFile: stateFile, isAgent: { _ in true })

        #expect(result.status == 0)
        let output = try Self.parse(result.output)
        #expect(Self.same(output, Self.noFileOutput), "output: \(result.output)")
    }

    // MARK: - A file that does not parse

    @Test(
        "a file that does not parse prints the no-file output plus error, and exits 0",
        arguments: [
            "not json at all",
            "",
            "{\n  \"agentPid\" : 51807,\n  \"stageManagerOn\" : false,\n  \"stages\" : [\n    {\n      \"colour\" : \"#00",  // truncated
        ])
    func unparseable(_ text: String) throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateFile = try Self.writeStateFile(text, in: dir)

        let result = ListJSON.render(stateFile: stateFile, isAgent: { _ in true })

        #expect(result.status == 0)
        var output = try Self.parse(result.output)
        let error = output["error"] as? String
        #expect(error != nil, "no error string in: \(result.output)")
        #expect(error?.isEmpty == false, "empty error in: \(result.output)")
        output.removeValue(forKey: "error")
        #expect(Self.same(output, Self.noFileOutput), "output apart from error: \(result.output)")
    }

    // MARK: - AgentCheck (real processes)

    /// The executable a live controlled process runs, standing in for the StageKeeper executable.
    static let liveExecutable = "/bin/sleep"
    /// An executable the controlled process does not run.
    static let otherExecutable = "/bin/cat"

    static func spawnSleep() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: liveExecutable)
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    static func finish(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    @Test("isAgent is true for a live process running the StageKeeper executable")
    func liveAgent() throws {
        let agent = try Self.spawnSleep()
        defer { Self.finish(agent) }
        #expect(agent.isRunning)

        #expect(AgentCheck.isAgent(pid: agent.processIdentifier, ownPid: getpid(), executable: Self.liveExecutable))
    }

    @Test("isAgent(pid:ownPid:) is true for a live process running the calling process's own executable")
    func liveAgentTwoArgumentForm() {
        // This test process runs its own executable; any pid other than ownPid passes the ownPid test.
        let otherOwnPid: Int32 = getpid() == 1 ? 2 : 1
        #expect(AgentCheck.isAgent(pid: getpid(), ownPid: otherOwnPid))
    }

    @Test("isAgent is false for a dead pid")
    func deadPid() throws {
        let agent = try Self.spawnSleep()
        let pid = agent.processIdentifier
        Self.finish(agent)
        #expect(kill(pid, 0) == -1, "pid \(pid) is still alive")

        #expect(!AgentCheck.isAgent(pid: pid, ownPid: getpid(), executable: Self.liveExecutable))
        #expect(!AgentCheck.isAgent(pid: pid, ownPid: getpid()))
    }

    @Test("isAgent is false for ownPid, even when that process runs the StageKeeper executable")
    func ownPid() throws {
        let agent = try Self.spawnSleep()
        defer { Self.finish(agent) }
        // Control: the same process with another ownPid is the agent.
        #expect(AgentCheck.isAgent(pid: agent.processIdentifier, ownPid: getpid(), executable: Self.liveExecutable))

        #expect(!AgentCheck.isAgent(pid: agent.processIdentifier, ownPid: agent.processIdentifier,
                                    executable: Self.liveExecutable))
        // The 2-argument form: this process runs its own executable, and is ownPid.
        #expect(!AgentCheck.isAgent(pid: getpid(), ownPid: getpid()))
    }

    @Test("isAgent is false for a live process running another executable")
    func liveOtherExecutable() throws {
        let other = try Self.spawnSleep()
        defer { Self.finish(other) }
        // Control: the pid is alive and not ownPid, so a check that only tests liveness says true here.
        #expect(kill(other.processIdentifier, 0) == 0)
        #expect(other.processIdentifier != getpid())

        #expect(!AgentCheck.isAgent(pid: other.processIdentifier, ownPid: getpid(), executable: Self.otherExecutable))
        // The 2-argument form: /bin/sleep is not this process's executable.
        #expect(!AgentCheck.isAgent(pid: other.processIdentifier, ownPid: getpid()))
    }
}

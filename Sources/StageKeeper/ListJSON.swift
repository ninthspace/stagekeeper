import Darwin
import Foundation

/// `stagekeeper list --json`: prints `stages.json`, which the menu-bar app writes, with `agentRunning` added.
enum ListJSON {
    static let noFile = #"{"agentRunning":false,"stageManagerOn":false,"stages":[],"version":1}"#

    /// The output and exit status. A missing file prints no stages; a file that does not parse prints the
    /// same with an `error`. `agentRunning` is whether the file's `agentPid` is the running agent.
    static func render(stateFile: URL, isAgent: (Int32) -> Bool) -> (output: String, status: Int32) {
        guard let data = try? Data(contentsOf: stateFile) else { return (noFile, 0) }
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (json(["version": 1, "stages": [], "stageManagerOn": false, "agentRunning": false,
                          "error": "stages.json does not parse"]), 0)
        }
        let agentPid = (object["agentPid"] as? NSNumber)?.int32Value
        object["agentRunning"] = agentPid.map(isAgent) ?? false
        return (json(object), 0)
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return noFile }
        return text
    }
}

/// Whether a pid is the running StageKeeper agent. The agent and the CLI are the same binary, so a check by
/// process name would match the CLI itself; this compares the process's executable and excludes `ownPid`.
enum AgentCheck {
    static func isAgent(pid: Int32, ownPid: Int32, executable: String) -> Bool {
        guard pid > 0, pid != ownPid, kill(pid, 0) == 0 || errno == EPERM,
              let path = executablePath(of: pid)
        else { return false }
        return resolved(path) == resolved(executable)
    }

    /// The same check against this process's own executable, which the agent shares.
    static func isAgent(pid: Int32, ownPid: Int32) -> Bool {
        guard let own = executablePath(of: getpid()) else { return false }
        return isAgent(pid: pid, ownPid: ownPid, executable: own)
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

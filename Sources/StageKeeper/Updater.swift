import Foundation

/// Updates StageKeeper from the git checkout it was built from. install.sh records the checkout,
/// commit and version in the app's Info.plist. An update is the newest `v*` tag when the repository
/// has release tags, and otherwise the tip of origin's default branch. Installing fast-forwards the
/// checkout and runs install.sh, so the new build is signed on this Mac like the old one and keeps
/// its Accessibility permission.
enum Updater {
    struct Installed {
        var version: String
        var commit: String
        var source: URL
    }

    enum Status {
        case upToDate(String)
        /// `target` is a tag or a remote branch; `summary` describes it for the menu.
        case available(target: String, summary: String)
    }

    enum Failure: Error, CustomStringConvertible {
        case notRecorded
        case git(String)
        case dirty(String)

        var description: String {
            switch self {
            case .notRecorded: "This copy of StageKeeper does not know which checkout it was built from. Reinstall it once with scripts/install.sh."
            case .git(let message): message
            case .dirty(let path): "The checkout at \(path) has uncommitted changes. Commit or stash them, or run scripts/install.sh yourself."
            }
        }
    }

    static let log = Paths.directory.appendingPathComponent("update.log")

    /// The Info.plist of the installed app. Bundle.main can't be used: the CLI runs through a link
    /// in ~/.local/bin.
    static func installed() -> Installed? {
        // argv[0] is only "stagekeeper" when run from PATH, so ask for the executable's real path.
        guard let path = Bundle.main.executablePath else { return nil }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let source = info["StageKeeperSourcePath"] as? String,
              let commit = info["StageKeeperCommit"] as? String else { return nil }
        let version = info["CFBundleShortVersionString"] as? String ?? commit
        return Installed(version: version, commit: commit, source: URL(fileURLWithPath: source))
    }

    /// Fetches origin and compares it with the installed commit. Blocks: call it off the main thread.
    static func check() throws -> Status {
        guard let installed = installed() else { throw Failure.notRecorded }
        let dir = installed.source
        // The repository is public, so fetch over HTTPS: a menu-bar app may have no SSH agent to
        // use. A private one falls back to origin's own URL.
        do {
            try git(dir, "-c", "url.https://github.com/.insteadOf=git@github.com:", "fetch", "--quiet", "--tags", "origin")
        } catch {
            do { try git(dir, "fetch", "--quiet", "--tags", "origin") } catch {
                throw Failure.git("Could not fetch from origin: \(error)")
            }
        }
        if let tag = try git(dir, "tag", "--list", "v*", "--sort=-v:refname").split(separator: "\n").first.map(String.init) {
            // Up to date when the installed commit already contains the newest tag.
            if (try? git(dir, "merge-base", "--is-ancestor", tag, installed.commit)) != nil {
                return .upToDate(installed.version)
            }
            return .available(target: tag, summary: tag)
        }
        let branch = (try? git(dir, "rev-parse", "--abbrev-ref", "origin/HEAD")) ?? "origin/main"
        let behind = Int(try git(dir, "rev-list", "--count", "\(installed.commit)..\(branch)")) ?? 0
        if behind == 0 { return .upToDate(installed.version) }
        // Worded as Claude Monitor words it: the remote's short commit and how many commits it adds.
        let latest = try git(dir, "rev-parse", "--short", branch)
        return .available(target: branch, summary: "\(latest) (\(behind == 1 ? "1 new commit" : "\(behind) new commits"))")
    }

    /// The shell commands that fast-forward the checkout to `target` and reinstall.
    static func script(target: String) throws -> String {
        guard let installed = installed() else { throw Failure.notRecorded }
        let dir = installed.source.path
        if !(try git(installed.source, "status", "--porcelain", "--untracked-files=no")).isEmpty {
            throw Failure.dirty(dir)
        }
        let branch = try git(installed.source, "rev-parse", "--abbrev-ref", "HEAD")
        let main = ((try? git(installed.source, "rev-parse", "--abbrev-ref", "origin/HEAD")) ?? "origin/main")
            .replacingOccurrences(of: "origin/", with: "")
        guard branch == main else {
            throw Failure.git("The checkout at \(dir) is on \(branch), not \(main). Switch back to \(main) to update.")
        }
        return "cd \(quote(dir)) && git merge --ff-only \(quote(target)) && ./scripts/install.sh"
    }

    /// From the CLI: becomes the install, in this terminal. Replacing the process matters, because
    /// install.sh stops every process called stagekeeper, this one included.
    static func installInForeground(target: String) throws -> Never {
        let command = try script(target: target)
        print("Installing \(target)…")
        fflush(stdout)
        let words: [String] = ["/bin/zsh", "-lc", command]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        execv("/bin/zsh", argv)
        throw Failure.git("Could not start the install: \(String(cString: strerror(errno)))")
    }

    static let status = Paths.directory.appendingPathComponent("update.status")
    private static let jobLabel = "local.stagekeeper.update"

    /// From the menu-bar app: runs the install as its own launchd job, so it outlives the app,
    /// which install.sh quits. Its LaunchAgent opens the new build. A failure before that leaves
    /// the exit status in `status` for `installFailure()` to find.
    static func installInBackground(target: String) throws {
        let command = try script(target: target)
        try? FileManager.default.removeItem(at: status)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let job: [String: Any] = [
            "Label": jobLabel,
            // A login shell finds the same swift as the Terminal does.
            "ProgramArguments": ["/bin/zsh", "-lc", "{ \(command); } > \(quote(log.path)) 2>&1; echo $? > \(quote(status.path))"],
            "RunAtLoad": true,
            "EnvironmentVariables": ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
        ]
        // Not `launchctl submit`: it keeps the job alive, so it would run the install again.
        let plist = Paths.directory.appendingPathComponent("\(jobLabel).plist")
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
        let domain = "gui/\(getuid())"
        _ = try? launchctl("bootout", "\(domain)/\(jobLabel)")
        guard try launchctl("bootstrap", domain, plist.path) == 0 else {
            throw Failure.git("launchctl could not start the install.")
        }
        Log.write("Updating StageKeeper to \(target); output in \(log.path).")
    }

    /// The install's exit status once it has failed. A successful install restarts the app first.
    static func installFailure() -> Int32? {
        guard let text = try? String(contentsOf: status, encoding: .utf8),
              let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), code != 0 else { return nil }
        return code
    }

    private static func launchctl(_ args: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @discardableResult
    private static func git(_ dir: URL, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        // Never wait for a password or a host-key prompt nobody can answer.
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=2"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        // A fetch can stall after connecting (a sleeping network, an agent waiting for a touch).
        // git's output is small, so the pipes don't fill before it exits.
        if done.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            throw Failure.git("git \(args.first ?? "") took longer than 45 seconds, so it was stopped.")
        }
        let output = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure.git(errors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "git \(args.joined(separator: " ")) failed" : errors.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

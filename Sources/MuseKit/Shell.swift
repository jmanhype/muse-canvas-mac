import Foundation

/// Thin process helpers. Everything shells out deliberately: `cp`, `lsof`,
/// `xattr` are the same battle-tested tools the upstream scripts use, and
/// parity beats cleverness for a supervisor whose job is boring reliability.
public enum Shell {

    public struct Result: Sendable, Equatable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public var success: Bool { exitCode == 0 }
    }

    @discardableResult
    public static func run(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil
    ) async -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            task.environment = env
        }
        do {
            try task.run()
        } catch {
            return Result(exitCode: 127, stdout: "", stderr: "\(error)")
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Result(
            exitCode: task.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// `lsof -nP -iTCP:<port> -sTCP:LISTEN -t` — port squatter pids.
    public static func portListeners(_ port: Int) async -> [Int] {
        let r = await run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        guard r.success else { return [] }
        return r.stdout.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Process start time (`ps -p PID -o lstart=`) for the pid-reuse guard (M7).
    public static func processStartTime(pid: Int) async -> String? {
        processStartTimeSync(pid: pid)
    }

    /// Blocking variant for spawn paths (one call per unit start).
    public static func processStartTimeSync(pid: Int) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "lstart="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Full command line (`ps -ww -p PID -o command=`).
    public static func processCommand(pid: Int) async -> String? {
        let r = await run("/bin/ps", ["-ww", "-p", String(pid), "-o", "command="])
        guard r.success else { return nil }
        let trimmed = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Alive for supervision purposes: signalable AND not a zombie. A
    /// SIGKILLed child of a long-running parent (the --watch watcher) stays
    /// a zombie until reaped, and `kill(pid, 0)` still succeeds on zombies —
    /// which would make a dead service look alive forever. Hence the stat
    /// check (and the reap in killTree).
    public static func pidAlive(_ pid: Int) -> Bool {
        guard kill(pid_t(pid), 0) == 0 else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "stat="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return true }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let stat = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !stat.hasPrefix("Z")
    }

    /// kill_tree parity (M9): TERM the process group, wait up to ~3s, KILL.
    /// The supervisor spawns units as process-group leaders (see Spawner),
    /// so `-pid` reaches browser children too.
    public static func killTree(pid: Int) async {
        let p = pid_t(pid)
        _ = kill(-p, SIGTERM)
        _ = kill(p, SIGTERM)
        for _ in 0..<6 {
            if !pidAlive(pid) { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        _ = kill(-p, SIGKILL)
        _ = kill(p, SIGKILL)
        // Reap if it's our child (ECHILD is harmless for non-children).
        var status: Int32 = 0
        _ = waitpid(p, &status, WNOHANG)
    }
}

extension Array where Element == Int {
    /// First port in the list with a listener, if any (watcher self-exit check).
    public func asyncFirstListener() async -> Int? {
        for port in self {
            if !(await Shell.portListeners(port)).isEmpty { return port }
        }
        return nil
    }
}

/// Canonical locations. Mac defaults follow the upstream mac package
/// (`~/MuseCanvas` program, `~/Library/Application Support/MuseCanvas/data`
/// data) so a `muse` install and an upstream-script install are the same
/// thing, interchangeable.
public enum Paths {
    public static var home: String { NSHomeDirectory() }

    public static var defaultInstallRoot: String { home + "/MuseCanvas" }

    public static var defaultDataDirectory: String {
        home + "/Library/Application Support/MuseCanvas/data"
    }

    public static var desktopLaunchers: [URL] {
        let dir = URL(fileURLWithPath: home + "/Desktop")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix("MuseCanvas") && $0.pathExtension == "command" }
    }
}

/// M3 — single-install detection. Upstream's wizard scans the default root
/// plus desktop launchers (each embeds `# MuseCanvas install root:`). Same
/// discovery, plus the wizard's refusals: running from an installed tree and
/// multiple installs are both hard errors, never a guess.
public enum InstallSet {
    public struct Found: Sendable, Equatable {
        public let root: String
        public let source: String   // "default-location" | "desktop-launcher"
    }

    public static func detect(defaultRoot: String = Paths.defaultInstallRoot) -> [Found] {
        var found: [Found] = []
        var seen = Set<String>()
        let fm = FileManager.default
        if fm.fileExists(atPath: defaultRoot + "/scripts/manage.sh") {
            found.append(Found(root: defaultRoot, source: "default-location"))
            seen.insert(defaultRoot)
        }
        for launcher in Paths.desktopLaunchers {
            guard let text = try? String(contentsOf: launcher, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.hasPrefix("# MuseCanvas install root: ") else { continue }
                let root = String(line.dropFirst("# MuseCanvas install root: ".count))
                    .trimmingCharacters(in: .whitespaces)
                if !root.isEmpty, !seen.contains(root),
                   fm.fileExists(atPath: root + "/scripts/manage.sh") {
                    seen.insert(root)
                    found.append(Found(root: root, source: "desktop-launcher"))
                }
                break
            }
        }
        return found
    }
}

/// M4/M14 — browser discovery. Upstream's mac wizard checks exactly two
/// paths (`/Applications/Google Chrome.app`, `/Applications/Microsoft
/// Edge.app`) — the same "installed but not found" bug class that Windows
/// 0.21.3 fixed by searching registered locations and other volumes. Here
/// is that fix, on mac: default locations, per-user Applications, and a
/// Spotlight query by bundle id (which finds installs anywhere on disk).
public enum BrowserFinder {
    public struct Hit: Sendable, Equatable {
        public let name: String      // "Google Chrome" | "Microsoft Edge"
        public let path: String
        public let how: String       // how it was found, surfaced as evidence
    }

    public static let knownLocations: [(name: String, path: String)] = [
        ("Google Chrome", "/Applications/Google Chrome.app"),
        ("Google Chrome", Paths.home + "/Applications/Google Chrome.app"),
        ("Microsoft Edge", "/Applications/Microsoft Edge.app"),
        ("Microsoft Edge", Paths.home + "/Applications/Microsoft Edge.app"),
    ]

    /// Bundle ids for the Spotlight fallback (finds non-default installs).
    static let bundleIds = ["com.google.Chrome", "com.microsoft.edgemac"]

    public static func find() async -> [Hit] {
        var hits: [Hit] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for (name, path) in knownLocations where fm.fileExists(atPath: path) {
            guard seen.insert(path).inserted else { continue }
            hits.append(Hit(name: name, path: path, how: "default location"))
        }
        if hits.isEmpty {
            // Spotlight by bundle id — the "outside the default folders" fix.
            for (bundle, name) in zip(bundleIds, ["Google Chrome", "Microsoft Edge"]) {
                let r = await Shell.run("/usr/bin/mdfind", [
                    "kMDItemCFBundleIdentifier == '\(bundle)'"
                ])
                for line in r.stdout.split(separator: "\n").map(String.init) {
                    let p = line.trimmingCharacters(in: .whitespaces)
                    guard p.hasSuffix(".app"), fm.fileExists(atPath: p),
                          seen.insert(p).inserted else { continue }
                    hits.append(Hit(name: name, path: p, how: "Spotlight"))
                    break   // one hit per browser is enough
                }
            }
        }
        return hits
    }
}

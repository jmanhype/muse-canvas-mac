import Foundation

/// Spawns a unit as its own process-group leader with stdout/stderr
/// redirected into the unit's log files — the POSIX equivalent of
/// upstream's `( cd "$wd" && exec nohup "$exe" … ) &` under `set -m`.
/// Group leadership is what later lets `kill(-pid, SIGTERM)` reach the
/// browsers the pool spawns (M9 kill_tree parity).
/// Re-exec helper for `muse start --watch`: launches a detached child in
/// its own process group so it survives the calling terminal/session.
public enum Daemonize {
    @discardableResult
    public static func spawnDetached(
        executable: String, arguments: [String], logPath: String
    ) throws -> pid_t {
        try Spawner.spawn(
            executable: executable, arguments: arguments,
            workingDirectory: "/tmp",
            environment: [:],
            stdoutPath: logPath, stderrPath: logPath).pid
    }
}

enum Spawner {

    struct Spawned: Sendable {
        let pid: pid_t
        let startedTicks: String   // `ps -o lstart=` for the pid-reuse guard (M7)
    }

    enum SpawnError: Error, CustomStringConvertible {
        case posixSpawn(Int32, String)
        case exitedImmediately(Int32)

        var description: String {
            switch self {
            case .posixSpawn(let code, let message):
                return "posix_spawn failed (\(code)): \(message)"
            case .exitedImmediately(let code):
                return "process exited immediately (code \(code))"
            }
        }
    }

    static func spawn(
        executable: String, arguments: [String], workingDirectory: String,
        environment: [String: String], stdoutPath: String, stderrPath: String
    ) throws -> Spawned {
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        // New process group with the child as leader (pgid = child pid).
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)
        defer { posix_spawnattr_destroy(&attrs) }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, stdoutPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_addopen(&fileActions, 2, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        // Upstream spawns with `( cd "$wd" && exec … )`; the spawn-side
        // chdir action is the equivalent.
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Build argv / envp the C way.
        let argv: [String?] = [executable] + arguments + [nil]
        let fullEnv = Foundation.ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let envp: [String?] = fullEnv.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" } + [nil]

        let pid: pid_t = try withCArray(argv) { cArgv in
            try withCArray(envp) { cEnv in
                var child: pid_t = -1
                let rc = posix_spawn(&child, executable, &fileActions, &attrs, cArgv, cEnv)
                guard rc == 0 else {
                    throw SpawnError.posixSpawn(rc, String(cString: strerror(rc)))
                }
                return child
            }
        }

        // Parity with upstream's `sleep 0.3; kill -0` early-exit detection.
        Thread.sleep(forTimeInterval: 0.3)
        if !Shell.pidAlive(Int(pid)) {
            throw SpawnError.exitedImmediately(-1)
        }
        // Synchronous `ps` for the start-time: this runs once per spawn,
        // off any hot path — simplicity wins over async ceremony here.
        let started = Shell.processStartTimeSync(pid: Int(pid)) ?? Date().description
        return Spawned(pid: pid, startedTicks: started)
    }
}

/// Bridge [String?] (nil-terminated argv/envp) into C arrays for the
/// duration of `body`.
private func withCArray<R>(
    _ strings: [String?],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> R
) rethrows -> R {
    var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { $0.flatMap { strdup($0) } }
    cStrings.append(nil)
    defer { cStrings.compactMap { $0 }.forEach { free($0) } }
    return try cStrings.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress)
    }
}

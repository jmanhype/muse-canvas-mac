import Foundation
import MuseCore

/// The engine side of M7/M8/M9: spawns units in upstream's order with
/// upstream's environment, drives one `UnitMachine` per unit through real
/// health probes, and keeps `processes.json` byte-compatible so
/// `manage.sh stop/status` interoperate with a `muse`-started stack.
public final class Supervisor: @unchecked Sendable {

    public struct Instance: Sendable {
        public let installRoot: String
        public let dataDirectory: String
        public let config: InstallConfig

        public init(installRoot: String, dataDirectory: String, config: InstallConfig) {
            self.installRoot = installRoot
            self.dataDirectory = dataDirectory
            self.config = config
        }

        public var configPath: String { dataDirectory + "/install.json" }
        public var processesPath: String { dataDirectory + "/processes.json" }
        public var logsDirectory: String { dataDirectory + "/logs" }
        public var workspace: String { dataDirectory + "/agent-workspace" }

        /// Loads an existing instance from an install root (instance.json +
        /// install.json), creating/migrating the config exactly like
        /// manage.sh's config block (M6): create-once secrets, additive
        /// migration afterwards.
        public static func load(installRoot: String) throws -> Instance {
            let instanceURL = URL(fileURLWithPath: installRoot + "/instance.json")
            guard let data = try? Data(contentsOf: instanceURL),
                  let record = try? JSONDecoder().decode(InstanceRecord.self, from: data) else {
                throw MuseError.notInstalled(installRoot)
            }
            return try load(installRoot: installRoot, record: record)
        }

        public static func load(installRoot: String, record: InstanceRecord) throws -> Instance {
            let dataDir = record.dataDirectory
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            let configPath = dataDir + "/install.json"
            let fm = FileManager.default
            let decoder = JSONDecoder()
            if fm.fileExists(atPath: configPath), let raw = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
               var config = try? decoder.decode(InstallConfig.self, from: raw) {
                // Migrate in place: stamp version/dataDir; ports fill via
                // per-key defaults; secrets NEVER rewritten.
                config.version = record.version
                config.dataDir = dataDir
                try encodeAtomic(config, to: configPath)
                return Instance(installRoot: installRoot, dataDirectory: dataDir, config: config)
            }
            // First start: create with fresh, distinct secrets (M6).
            let secret = { () -> String in
                var bytes = [UInt8](repeating: 0, count: 32)
                _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
                return bytes.map { String(format: "%02x", $0) }.joined()
            }
            let config = InstallConfig(
                version: record.version, dataDir: dataDir,
                poolKey: secret(), serviceKey: secret())
            try encodeAtomic(config, to: configPath)
            return Instance(installRoot: installRoot, dataDirectory: dataDir, config: config)
        }

        static func encodeAtomic(_ config: InstallConfig, to path: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(config)
            let tmp = URL(fileURLWithPath: path + ".tmp")
            let final = URL(fileURLWithPath: path)
            try data.write(to: tmp)
            // replaceItemAt handles the destination-exists case (moveItem
            // does not — caught by EngineTests.instanceLoadCreatesSecretsOnce).
            _ = try FileManager.default.replaceItemAt(final, withItemAt: tmp,
                                                      backupItemName: nil)
        }
    }

    public enum MuseError: Error, CustomStringConvertible {
        case notInstalled(String)
        case partiallyRunning(alive: [String], dead: [String])
        case portsOccupied([(port: Int, pids: [Int])])
        case bootFailed(unit: String, reason: String, logHint: String)

        public var description: String {
            switch self {
            case .notInstalled(let root):
                return "No MuseCanvas installation at \(root). Run `muse install` first."
            case .partiallyRunning(let alive, let dead):
                return "Partially running (alive: \(alive.joined(separator: ", ")); not running: \(dead.joined(separator: ", "))). Run `muse stop`, then `muse start`."
            case .portsOccupied(let conflicts):
                let detail = conflicts.map { "port \($0.port) held by pid(s) \($0.pids.map(String.init).joined(separator: ","))" }.joined(separator: "; ")
                return "Ports occupied; nothing was stopped to make room. \(detail)"
            case .bootFailed(let unit, let reason, let logHint):
                return "\(unit) failed to start: \(reason). Logs: \(logHint)"
            }
        }
    }

    let instance: Instance
    let units: [UnitSpec]
    let machine = UnitMachine(policy: .standard)
    private var phases: [String: UnitMachine.Phase]
    private var records: [ProcessRecord]

    public init(instance: Instance, units: [UnitSpec] = UnitTable.all) {
        self.instance = instance
        self.units = units
        var initial: [String: UnitMachine.Phase] = [:]
        for u in units { initial[u.id] = .stopped }
        self.phases = initial
        self.records = []
    }

    // MARK: - processes.json parity (M7)

    /// Records as-is on disk, for the detached watcher's liveness check.
    public func readRecordsForDaemon() -> [ProcessRecord] { readRecords() }

    func readRecords() -> [ProcessRecord] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: instance.processesPath)),
              let decoded = try? JSONDecoder().decode([ProcessRecord].self, from: data) else { return [] }
        return decoded
    }

    func writeRecords(_ records: [ProcessRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        let tmp = URL(fileURLWithPath: instance.processesPath + ".tmp")
        let final = URL(fileURLWithPath: instance.processesPath)
        // replaceItemAt handles destination-exists; a silent no-op here once
        // left stale pids after an aborted boot (caught during dogfood).
        if (try? data.write(to: tmp)) != nil {
            _ = try? FileManager.default.replaceItemAt(final, withItemAt: tmp, backupItemName: nil)
        }
    }

    /// A record counts as running iff pid alive AND start time matches AND
    /// the command line contains the executable — the pid-reuse guard,
    /// verbatim from manage.sh's `record_running`.
    public static func recordIsRunning(_ record: ProcessRecord) async -> Bool {
        guard Shell.pidAlive(record.pid) else { return false }
        guard let started = await Shell.processStartTime(pid: record.pid),
              started == record.startedTicks else { return false }
        let command = await Shell.processCommand(pid: record.pid) ?? ""
        return command.contains(record.executable)
    }

    // MARK: - Status (one-shot reconcile + probe; no watcher needed)

    public struct UnitStatus: Codable, Sendable {
        public let id: String
        public let title: String
        public let port: Int
        public let phase: String
        public let detail: String
        public let pid: Int?
    }

    public struct Snapshot: Codable, Sendable {
        public let stack: String
        public let stackDetail: String
        public let units: [UnitStatus]
        public let canvasURL: String
        public let dashboardURL: String?
        public let generatedAtUnix: Double
    }

    /// Reconcile recorded truth against the machine, then probe live units
    /// once so `.degraded` is visible without a watcher.
    public func snapshot(now: Date = Date(), dashboardURL: String? = nil) async -> Snapshot {
        records = readRecords()
        var byId = [String: ProcessRecord]()
        for r in records { byId[r.name] = r }

        var statuses: [UnitStatus] = []
        var phaseMap: [String: UnitMachine.Phase] = [:]
        for unit in units {
            var phase: UnitMachine.Phase = .stopped
            var detail = ""
            var pid: Int? = nil
            if let record = byId[unit.id] {
                pid = record.pid
                if await Supervisor.recordIsRunning(record) {
                    switch await probe(unit) {
                    case .ready(let streak):
                        phase = .ready(streak: streak)
                        detail = "healthy"
                    case .failing(let reason):
                        phase = .degraded(consecutiveFailures: 1, lastReason: reason)
                        detail = "running but health probe failing: \(reason)"
                    }
                } else {
                    phase = .failed(reason: .exitedUnexpectedly(code: nil))
                    detail = "recorded pid \(record.pid) is not running (crashed or stopped elsewhere)"
                    pid = nil
                }
            }
            phaseMap[unit.id] = phase
            statuses.append(UnitStatus(id: unit.id, title: unit.title, port: unit.port,
                                       phase: Self.phaseName(phase), detail: detail.isEmpty ? "stopped" : detail, pid: pid))
        }
        let stack = StackPhase.derive(units: phaseMap)
        return Snapshot(
            stack: Self.stackName(stack), stackDetail: Self.stackDetail(stack),
            units: statuses, canvasURL: instance.config.webURL,
            dashboardURL: dashboardURL,
            generatedAtUnix: now.timeIntervalSince1970)
    }

    // MARK: - Preflight (M10 — including 19400, which upstream forgets)

    @discardableResult
    public func preflight() async throws -> [Int] {
        // Partial-run guard (M7): 0 or all-5 alive is fine; in-between is a
        // hard error with named units.
        records = readRecords()
        var alive: [String] = [], dead: [String] = []
        for r in records {
            if await Supervisor.recordIsRunning(r) { alive.append(r.name) } else { dead.append(r.name) }
        }
        let expected = Set(units.map(\.id))
        if !alive.isEmpty && Set(alive) != expected {
            throw MuseError.partiallyRunning(alive: alive, dead: expected.subtracting(alive).sorted())
        }
        var conflicts: [(Int, [Int])] = []
        for port in instance.config.allPorts {
            let listeners = await Shell.portListeners(port)
            // A listener that is our own recorded unit is fine (idempotent start).
            if listeners.isEmpty { continue }
            let ours = Set(listeners).intersection(records.map(\.pid))
            if ours.count == listeners.count { continue }
            conflicts.append((port, listeners))
        }
        if !conflicts.isEmpty {
            throw MuseError.portsOccupied(conflicts.map { (port: $0.0, pids: $0.1) })
        }
        return instance.config.allPorts
    }

    // MARK: - Boot (M8: upstream order, per-unit gates, all-or-nothing)

    public struct BootEvent: Sendable {
        public let unit: String
        public let text: String
    }
    public var onEvent: (@Sendable (BootEvent) -> Void)?

    public func start() async throws {
        try await preflight()

        // Upstream parity: starting an all-running stack is a no-op success,
        // never a re-spawn. (Found during dogfood: without this, a second
        // `muse start` double-spawned, failed on the busy port, and its
        // abort path clobbered the healthy stack's records.)
        records = readRecords()
        let expectedIds = Set(units.map(\.id))
        var aliveNow: [String] = []
        for r in records where await Supervisor.recordIsRunning(r) {
            aliveNow.append(r.name)
        }
        if aliveNow.count == expectedIds.count {
            for u in units { phases[u.id] = .ready(streak: 1) }
            return
        }

        let fm = FileManager.default
        for dir in [instance.logsDirectory, instance.workspace,
                    instance.dataDirectory + "/agent",
                    instance.dataDirectory + "/pool",
                    instance.dataDirectory + "/license",
                    instance.dataDirectory + "/merges"] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let env = EnvironmentContract.build(
            installRoot: instance.installRoot, dataDir: instance.dataDirectory,
            configPath: instance.configPath, config: instance.config,
            home: Paths.home,
            claudeConfigDir: Foundation.ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"])

        var started: [(id: String, pid: Int)] = []
        var newRecords: [ProcessRecord] = []
        // Records as they were at boot entry: an aborted boot restores THIS,
        // not [] — an abort must never orphan a previously healthy stack.
        let recordsAtBoot = records

        func abortBoot(_ unit: String, _ reason: String) async -> MuseError {
            for s in started { await Shell.killTree(pid: s.pid) }
            writeRecords(recordsAtBoot)
            return MuseError.bootFailed(unit: unit, reason: reason,
                                        logHint: instance.logsDirectory)
        }

        for unit in units {   // boot order comes from the table (M12)
            let t0 = machine.step(.stopped, on: .startRequested)
            phases[unit.id] = t0.to
            onEvent?(BootEvent(unit: unit.id, text: "spawning \(unit.executable)"))
            let exe = instance.installRoot + "/" + unit.executable
            // Upstream passes absolute script paths to node while running in
            // the workspace dir; relative path args are install-rooted the
            // same way (caught live during dogfood: agent's `agent/agent.cjs`
            // resolved against the CWD and died with MODULE_NOT_FOUND).
            let args = unit.arguments.map { arg in
                let substituted = arg
                    .replacingOccurrences(of: "{poolPort}", with: String(instance.config.ports.pool))
                    .replacingOccurrences(of: "{poolStateDir}", with: instance.dataDirectory + "/pool")
                if arg.contains("/"), !arg.hasPrefix("-"), !arg.hasPrefix("/"),
                   !arg.hasPrefix("{") {
                    return instance.installRoot + "/" + substituted
                }
                return substituted
            }
            let wd = unit.workingDirectory.isEmpty
                ? instance.installRoot
                : instance.dataDirectory + "/" + unit.workingDirectory
            do {
                try fm.createDirectory(atPath: wd, withIntermediateDirectories: true)
                let spawned = try Spawner.spawn(
                    executable: exe, arguments: args, workingDirectory: wd,
                    environment: env,
                    stdoutPath: instance.logsDirectory + "/\(unit.id).out.log",
                    stderrPath: instance.logsDirectory + "/\(unit.id).err.log")
                started.append((unit.id, Int(spawned.pid)))
                newRecords.append(ProcessRecord(
                    name: unit.id, pid: Int(spawned.pid), executable: exe,
                    startedTicks: spawned.startedTicks))
                writeRecords(newRecords)   // incremental, like upstream
                phases[unit.id] = machine.step(t0.to, on: .processSpawned).to
            } catch {
                throw await abortBoot(unit.id, "\(error)")
            }
        }

        // Health gates in boot order; a unit that never turns ready aborts
        // the whole stack (upstream abort_start semantics), but the reason
        // is per-unit and real (M8's upgrade over a single log line).
        for unit in units {
            onEvent?(BootEvent(unit: unit.id, text: "waiting for health on :\(unit.port)\(unit.healthPath)"))
            let outcome = await waitForHealth(unit, budgetSeconds: unit.startTimeoutSeconds)
            switch outcome {
            case .ready(let streak):
                phases[unit.id] = .ready(streak: streak)
                onEvent?(BootEvent(unit: unit.id, text: "ready"))
            case .failed(let reason):
                throw await abortBoot(unit.id, reason)
            }
        }
        writeRecords(newRecords)
    }

    // MARK: - Stop (M9)

    @discardableResult
    public func stop() async -> [String] {
        records = readRecords()
        var stopped: [String] = []
        for record in records {
            phases[record.name] = .stopping
            if await Supervisor.recordIsRunning(record) {
                await Shell.killTree(pid: record.pid)
                stopped.append(record.name)
            }
            phases[record.name] = .stopped
        }
        // Orphan reconciliation: if a record was lost (an aborted boot in a
        // buggier past, a manually edited processes.json), services of THIS
        // install can still be found by port and command line. Upstream
        // cannot recover these; we refuse to lose track of them.
        for unit in units {
            let listeners = await Shell.portListeners(unit.port)
            for pid in listeners {
                let command = await Shell.processCommand(pid: pid) ?? ""
                guard command.contains(instance.installRoot) else { continue }
                await Shell.killTree(pid: pid)
                stopped.append(unit.id + "(port-recovered)")
            }
        }
        writeRecords([])
        return stopped
    }

    // MARK: - Probing

    public enum ProbeOutcome: Sendable {
        case ready(streak: Int)
        case failing(String)
    }

    /// Outcome of a full startup health gate (probe loop with deadline).
    public enum GateOutcome: Sendable {
        case ready(streak: Int)
        case failed(String)
    }

    /// One health probe, honoring the unit's dialect (M12): path, optional
    /// service-key header, optional JSON ready predicate, 2s timeout,
    /// proxy bypassed (URLSession equivalent of `curl --noproxy '*'`).
    public func probe(_ unit: UnitSpec) async -> ProbeOutcome {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(unit.port)\(unit.healthPath)")!)
        request.timeoutInterval = 2
        if unit.healthRequiresServiceKey {
            request.setValue(instance.config.serviceKey,
                             forHTTPHeaderField: "x-canvas-service-key")
        }
        let session = URLSession(configuration: .ephemeralNoProxy)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failing("non-HTTP response")
            }
            guard http.statusCode == 200 else {
                return .failing("HTTP \(http.statusCode)")
            }
            if let ready = unit.healthJSONReady {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let value = json[ready.key] else {
                    return .failing("health body missing `\(ready.key)`")
                }
                // Upstream (`j && j.ffmpeg ? "yes" : "no"`) is a *truthy*
                // check — merge reports the ffmpeg PATH, not a boolean.
                if !isTruthy(value) {
                    return .failing("health body `\(ready.key)` is \(value) — expected truthy")
                }
            }
            return .ready(streak: 1)
        } catch {
            return .failing(error.localizedDescription)
        }
    }

    func waitForHealth(_ unit: UnitSpec, budgetSeconds: Int) async -> GateOutcome {
        let deadline = Date().addingTimeInterval(TimeInterval(budgetSeconds))
        var lastReason = "no probe attempt"
        while Date() < deadline {
            switch await probe(unit) {
            case .ready(let streak): return .ready(streak: streak)
            case .failing(let reason): lastReason = reason
            }
            if !Shell.pidAlive(currentPid(for: unit)) {
                return .failed("process exited while waiting for health (last probe: \(lastReason))")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .failed("health gate timed out after \(budgetSeconds)s (last probe: \(lastReason))")
    }

    func currentPid(for unit: UnitSpec) -> Int {
        records.first { $0.name == unit.id }?.pid ?? -1
    }

    // MARK: - Display names (single source for CLI / JSON / dashboard)

    static func phaseName(_ phase: UnitMachine.Phase) -> String {
        switch phase {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .ready: return "ready"
        case .degraded: return "degraded"
        case .stopping: return "stopping"
        case .failed(let reason):
            switch reason {
            case .spawnFailed: return "failed:spawn"
            case .startTimeout: return "failed:start-timeout"
            case .exitedUnexpectedly: return "failed:exited"
            case .healthCollapsed: return "failed:health"
            case .portConflict: return "failed:port-conflict"
            }
        }
    }

    static func stackName(_ stack: StackPhase) -> String {
        switch stack {
        case .cold: return "cold"
        case .booting: return "booting"
        case .running: return "running"
        case .degraded: return "degraded"
        case .failed: return "failed"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        }
    }

    static func stackDetail(_ stack: StackPhase) -> String {
        switch stack {
        case .cold: return "not started"
        case .booting(let ready, let pending):
            return "booting (ready: \(ready.joined(separator: ", ")); pending: \(pending.joined(separator: ", ")))"
        case .running: return "all services healthy"
        case .degraded(let units):
            return "running, but retrying: \(units.joined(separator: ", "))"
        case .failed(let units):
            return "failed units: \(units.joined(separator: ", "))"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        }
    }
}

public /// JavaScript-style truthiness for JSON health values (parity with the
/// upstream wait_health check).
func isTruthy(_ value: Any) -> Bool {
    switch value {
    case let b as Bool: return b
    case let n as NSNumber: return n.boolValue
    case let s as String: return !s.isEmpty && s.lowercased() != "false" && s.lowercased() != "no"
    case is NSNull: return false
    default: return true
    }
}

public extension URLSessionConfiguration {
    /// `curl --noproxy '*'` parity: force direct connections so a system
    /// proxy can't sit between the supervisor and its own services.
    static var ephemeralNoProxy: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }
}

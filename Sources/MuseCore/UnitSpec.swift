/// The declarative service table (machine M12).
///
/// `manage.sh` knows five services that all mean something different by
/// "ready": different health paths, different auth, different retry budgets,
/// one positional script. This table says the same thing as data. The
/// supervisor derives its behavior from it; the tests pin each row; the
/// dashboard renders it. Adding a service or changing a health dialect is a
/// one-line diff, not an archaeology dig.
public struct UnitSpec: Codable, Equatable, Sendable, Identifiable {

    /// Unit id — also the record name written to `processes.json`
    /// (upstream parity: "license", "agent", "merge", "pool", "web").
    public let id: String

    /// Human title for UI surfaces.
    public let title: String

    /// Executable path relative to the install root.
    public let executable: String

    /// Arguments, relative paths resolved against the install root.
    public let arguments: [String]

    /// Working directory relative to the install root ("" = install root).
    public let workingDirectory: String

    /// Port this unit listens on (for health probing).
    public let port: Int

    /// Health path to GET.
    public let healthPath: String

    /// Whether the health request must carry `x-canvas-service-key`.
    public let healthRequiresServiceKey: Bool

    /// For JSON health bodies: the key whose value must be *truthy* for
    /// "ready" (merge reports `{"ffmpeg": "<path>"}` — upstream checks
    /// `j && j.ffmpeg`, a truthiness test, not a boolean). nil = any 200.
    public let healthJSONReady: (key: String, value: String)?

    /// Startup budget in seconds before `.failed(.startTimeout)`.
    public let startTimeoutSeconds: Int

    /// Boot order position (upstream: license → agent → merge → pool → web).
    public let bootOrder: Int

    public init(
        id: String, title: String, executable: String, arguments: [String] = [],
        workingDirectory: String = "", port: Int, healthPath: String,
        healthRequiresServiceKey: Bool = false,
        healthJSONReady: (key: String, value: String)? = nil,
        startTimeoutSeconds: Int = 60, bootOrder: Int
    ) {
        self.id = id
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.port = port
        self.healthPath = healthPath
        self.healthRequiresServiceKey = healthRequiresServiceKey
        self.healthJSONReady = healthJSONReady
        self.startTimeoutSeconds = startTimeoutSeconds
        self.bootOrder = bootOrder
    }
}

extension UnitSpec {
    /// (key, value) tuples don't synthesize Equatable/ Codable; the derived
    /// conformance below keeps the public API tuple-friendly while satisfying
    /// the compiler. Encode as nested object, decode both shapes.

    public static func == (lhs: UnitSpec, rhs: UnitSpec) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
            && lhs.executable == rhs.executable && lhs.arguments == rhs.arguments
            && lhs.workingDirectory == rhs.workingDirectory && lhs.port == rhs.port
            && lhs.healthPath == rhs.healthPath
            && lhs.healthRequiresServiceKey == rhs.healthRequiresServiceKey
            && lhs.healthJSONReady?.key == rhs.healthJSONReady?.key
            && lhs.healthJSONReady?.value == rhs.healthJSONReady?.value
            && lhs.startTimeoutSeconds == rhs.startTimeoutSeconds
            && lhs.bootOrder == rhs.bootOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, executable, arguments, workingDirectory, port
        case healthPath, healthRequiresServiceKey, healthJSONReadyKey
        case healthJSONReadyValue, startTimeoutSeconds, bootOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        port = try c.decode(Int.self, forKey: .port)
        healthPath = try c.decode(String.self, forKey: .healthPath)
        healthRequiresServiceKey = try c.decodeIfPresent(Bool.self, forKey: .healthRequiresServiceKey) ?? false
        healthJSONReady = try c.decodeIfPresent(String.self, forKey: .healthJSONReadyKey).map {
            (key: $0, value: try c.decode(String.self, forKey: .healthJSONReadyValue))
        }
        startTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .startTimeoutSeconds) ?? 60
        bootOrder = try c.decode(Int.self, forKey: .bootOrder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(executable, forKey: .executable)
        try c.encode(arguments, forKey: .arguments)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encode(port, forKey: .port)
        try c.encode(healthPath, forKey: .healthPath)
        try c.encode(healthRequiresServiceKey, forKey: .healthRequiresServiceKey)
        try c.encodeIfPresent(healthJSONReady?.key, forKey: .healthJSONReadyKey)
        try c.encodeIfPresent(healthJSONReady?.value, forKey: .healthJSONReadyValue)
        try c.encode(startTimeoutSeconds, forKey: .startTimeoutSeconds)
        try c.encode(bootOrder, forKey: .bootOrder)
    }
}

/// The five units, exactly as `manage.sh` starts them — same ids, same boot
/// order, same health dialects, same budgets. This constant is the parity
/// contract with upstream; tests pin it row by row.
public enum UnitTable {
    public static let all: [UnitSpec] = [
        UnitSpec(
            id: "license", title: "License & update",
            executable: "node/node", arguments: ["services/entry.cjs", "license"],
            workingDirectory: "", port: 17373, healthPath: "/health",
            healthRequiresServiceKey: true,
            startTimeoutSeconds: 60, bootOrder: 0
        ),
        UnitSpec(
            id: "agent", title: "Canvas agent (Codex/Claude)",
            executable: "node/node", arguments: ["agent/agent.cjs"],
            workingDirectory: "agent-workspace", port: 17371,
            healthPath: "/health", startTimeoutSeconds: 60, bootOrder: 1
        ),
        UnitSpec(
            id: "merge", title: "Merge & export",
            executable: "node/node", arguments: ["services/entry.cjs", "merge"],
            workingDirectory: "", port: 17372, healthPath: "/health",
            healthRequiresServiceKey: true,
            healthJSONReady: (key: "ffmpeg", value: "truthy"),
            startTimeoutSeconds: 45, bootOrder: 2
        ),
        UnitSpec(
            id: "pool", title: "Generation pool",
            executable: "pool/MusePool",
            arguments: ["--host", "127.0.0.1", "--port", "{poolPort}", "--state-dir", "{poolStateDir}"],
            workingDirectory: "", port: 18610, healthPath: "/healthz",
            startTimeoutSeconds: 120, bootOrder: 3
        ),
        UnitSpec(
            id: "web", title: "Canvas web",
            executable: "node/node", arguments: ["services/entry.cjs", "web"],
            workingDirectory: "", port: 3000, healthPath: "/health",
            startTimeoutSeconds: 60, bootOrder: 4
        ),
    ].sorted { $0.bootOrder < $1.bootOrder }

    public static func unit(named id: String) -> UnitSpec? {
        all.first { $0.id == id }
    }
}

/// The environment contract (M8): every variable `manage.sh` exports before
/// spawning, built as data so the supervisor's env is diffable against the
/// upstream script's (a test does exactly that comparison by construction —
/// the builder is the single source of truth for both spawn and docs).
public enum EnvironmentContract {
    /// Placeholders substituted by the supervisor at spawn time.
    /// `claudeConfigDir` mirrors upstream's conditional: when the caller has
    /// `CLAUDE_CONFIG_DIR` set, projects live under it; otherwise
    /// `~/.claude/projects`.
    public static func build(
        installRoot: String, dataDir: String, configPath: String,
        config: InstallConfig, home: String,
        claudeConfigDir: String? = nil
    ) -> [String: String] {
        let p = config.ports
        // Upstream: CLAUDE_PROJECT_DIR = workspace path with every
        // non-alphanumeric character replaced by '-' (sed-style).
        let workspace = dataDir + "/agent-workspace"
        let projectDir = workspace.map { ch in
            (ch.isLetter || ch.isNumber) ? String(ch) : "-"
        }.joined()
        let claudeProjects = (claudeConfigDir ?? (home + "/.claude")) + "/projects"
        return [
            "CANVAS_APP_DIR": installRoot,
            "CANVAS_STATE_DIR": dataDir,
            "CANVAS_INSTALL_CONFIG": configPath,
            "CANVAS_AGENT_CONFIG_DIR": dataDir + "/agent",
            "CANVAS_SERVICE_KEY": config.serviceKey,
            "MUSE2API_KEY": config.poolKey,
            "MUSE2API_HOME": dataDir + "/pool",
            "MUSE2API_PROFILE_ROOT": dataDir + "/browser-profiles/pool",
            "MUSE2API_HOME_DIR": dataDir,
            "MUSE2API_CDP_PORT": String(p.cdp),
            "MUSE2API_PUBLIC_BASE": "http://localhost:\(p.pool)",
            "MUSE2API_WHISPER_MODEL": installRoot + "/models/faster-whisper-small",
            "MERGE_PORT": String(p.export),
            "MC_LICENSE_DIR": dataDir + "/license",
            "MC_DOUBAO_PROFILE": dataDir + "/provider-profiles/doubao",
            "MC_DOUBAO_CDP_PORT": String(p.doubaoCdp),
            "MC_LICENSE_CLIENT_PORT": String(p.license),
            "MC_POOL_ACCOUNTS": dataDir + "/pool/data/accounts.json",
            "MERGE_OUTPUT_DIR": dataDir + "/merges",
            "MERGE_FFMPEG_PATH": installRoot + "/tools/ffmpeg",
            "MERGE_FFPROBE_PATH": installRoot + "/tools/ffprobe",
            "CLAUDE_PROJECTS_DIR": claudeProjects,
            "CLAUDE_PROJECT_DIR": projectDir,
            "PORT": String(p.agent),
        ]
    }
}

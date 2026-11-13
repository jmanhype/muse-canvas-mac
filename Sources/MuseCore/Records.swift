import Foundation

/// On-disk records, byte-compatible with the upstream payload's formats so
/// `manage.sh stop/status` keeps working on a `muse`-started stack and vice
/// versa. Compatibility is parity, not kindness: two supervisors for one
/// install must agree on truth (M7), and the cheapest agreement is a shared
/// file format.

/// `<installRoot>/instance.json` — pins the install to its data directory
/// (machine M2). Written by the installer; read by everything else.
public struct InstanceRecord: Codable, Equatable, Sendable {
    public var product: String
    public var version: String
    public var installDir: String
    public var dataDirectory: String
    public var forUser: String

    public init(product: String = "MuseCanvas", version: String,
                installDir: String, dataDirectory: String, forUser: String) {
        self.product = product
        self.version = version
        self.installDir = installDir
        self.dataDirectory = dataDirectory
        self.forUser = forUser
    }
}

/// `<dataDir>/install.json` — ports + per-instance secrets (machine M6).
/// Secrets are generated exactly once at creation and never rewritten by
/// migration; upstream DEPLOY requires pool key and service key to stay
/// distinct per instance.
public struct InstallConfig: Codable, Equatable, Sendable {
    public struct Ports: Codable, Equatable, Sendable {
        public var web: Int = 3000
        public var agent: Int = 17371
        public var export: Int = 17372
        public var pool: Int = 18610
        public var cdp: Int = 19210
        public var license: Int = 17373
        public var doubaoCdp: Int = 19400
        public init() {}

        private enum CodingKeys: String, CodingKey {
            case web, agent, export, pool, cdp, license, doubaoCdp
        }

        /// Per-key defaults: mirrors upstream's additive migration, where an
        /// older `install.json` simply lacks newer port slots and they are
        /// filled in one by one, existing values left alone.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            web = try c.decodeIfPresent(Int.self, forKey: .web) ?? web
            agent = try c.decodeIfPresent(Int.self, forKey: .agent) ?? agent
            export = try c.decodeIfPresent(Int.self, forKey: .export) ?? export
            pool = try c.decodeIfPresent(Int.self, forKey: .pool) ?? pool
            cdp = try c.decodeIfPresent(Int.self, forKey: .cdp) ?? cdp
            license = try c.decodeIfPresent(Int.self, forKey: .license) ?? license
            doubaoCdp = try c.decodeIfPresent(Int.self, forKey: .doubaoCdp) ?? doubaoCdp
        }
    }

    public var version: String
    public var dataDir: String
    public var poolKey: String
    public var serviceKey: String
    public var ports: Ports

    public init(version: String, dataDir: String, poolKey: String,
                serviceKey: String, ports: Ports = Ports()) {
        self.version = version
        self.dataDir = dataDir
        self.poolKey = poolKey
        self.serviceKey = serviceKey
        self.ports = ports
    }

    public enum CodingKeys: String, CodingKey {
        case version, dataDir, poolKey, serviceKey, ports
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        dataDir = try c.decode(String.self, forKey: .dataDir)
        poolKey = try c.decode(String.self, forKey: .poolKey)
        serviceKey = try c.decode(String.self, forKey: .serviceKey)
        // Migration (M6): older configs lack newer port slots. Additive,
        // idempotent, and never inventive about secrets.
        ports = try c.decodeIfPresent(Ports.self, forKey: .ports) ?? Ports()
    }

    /// All ports this instance could occupy, including `doubaoCdp` — which
    /// upstream's start preflight forgets to check (M10). One list, checked
    /// everywhere, is the fix.
    public var allPorts: [Int] {
        [ports.web, ports.agent, ports.export, ports.pool, ports.cdp,
         ports.license, ports.doubaoCdp]
    }

    /// HTTP base URLs for the supervised surfaces.
    public var webURL: String { "http://localhost:\(ports.web)" }
    public var poolURL: String { "http://localhost:\(ports.pool)" }
}

/// `<dataDir>/processes.json` — upstream's liveness ledger (M7): an array of
/// records; a record is "running" iff pid alive AND start time matches AND
/// the command line contains the executable (pid-reuse guard).
public struct ProcessRecord: Codable, Equatable, Sendable {
    public var name: String
    public var pid: Int
    public var executable: String
    public var startedTicks: String

    public init(name: String, pid: Int, executable: String, startedTicks: String) {
        self.name = name
        self.pid = pid
        self.executable = executable
        self.startedTicks = startedTicks
    }

    private enum CodingKeys: String, CodingKey {
        case name, pid, executable, startedTicks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pid = try c.decode(Int.self, forKey: .pid)
        executable = try c.decode(String.self, forKey: .executable)
        startedTicks = try c.decodeIfPresent(String.self, forKey: .startedTicks) ?? ""
    }
}

/// The upstream package's own `manifest.json` (decoded subset) — source of
/// the expected zip name, size and SHA-256 for download verification.
public struct PayloadManifest: Codable, Equatable, Sendable {
    public struct Package: Codable, Equatable, Sendable {
        public var file: String?
        public var sizeBytes: Int?
        public var sha256: String?
        public var url: String?
    }
    public struct Ports: Codable, Equatable, Sendable {
        public var web: Int?
        public var agent: Int?
        public var export: Int?
        public var pool: Int?
        public var cdp: Int?
        public var license: Int?
    }
    public var version: String?
    public var platform: String?
    public var package: Package?
    public var ports: Ports?
}

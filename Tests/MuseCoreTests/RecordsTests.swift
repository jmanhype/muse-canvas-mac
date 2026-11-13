import Foundation
import Testing
@testable import MuseCore

/// Parity with the upstream payload's on-disk formats (M6, M7, M12) and the
/// environment contract (M8). These tests quote the upstream scripts; if
/// upstream changes its contract, these rows are what must be reviewed.
struct RecordsTests {

    // MARK: instance.json parity

    @Test func instanceRecordMatchesUpstreamShape() throws {
        let json = """
        {"product":"MuseCanvas","version":"0.21.2","installDir":"/Users/x/MuseCanvas","dataDirectory":"/Users/x/Library/Application Support/MuseCanvas/data","forUser":"x"}
        """
        let record = try JSONDecoder().decode(InstanceRecord.self, from: Data(json.utf8))
        #expect(record.version == "0.21.2")
        #expect(record.forUser == "x")
        #expect(record.dataDirectory.contains("Application Support"))
        // And it re-encodes losslessly for manage.sh to read.
        let encoded = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(InstanceRecord.self, from: encoded)
        #expect(back == record)
    }

    // MARK: install.json migration (M6): additive, never inventive

    @Test func configMigrationAddsMissingPortsButKeepsSecrets() throws {
        // An 0.21.0-era config: no license/doubaoCdp ports.
        let legacy = """
        {"version":"0.21.0","dataDir":"/data","poolKey":"pk-1","serviceKey":"sk-1","ports":{"web":3000,"agent":17371,"export":17372,"pool":18610,"cdp":19210}}
        """
        let config = try JSONDecoder().decode(InstallConfig.self, from: Data(legacy.utf8))
        #expect(config.ports.license == 17373)     // defaulted, not invented
        #expect(config.ports.doubaoCdp == 19400)
        #expect(config.poolKey == "pk-1")          // secrets survive migration
        #expect(config.serviceKey == "sk-1")
        #expect(config.ports.web == 3000)          // user customization survives
    }

    @Test func configWithoutPortsBlockGetsDefaults() throws {
        let ancient = """
        {"version":"0.19.0","dataDir":"/data","poolKey":"pk","serviceKey":"sk"}
        """
        let config = try JSONDecoder().decode(InstallConfig.self, from: Data(ancient.utf8))
        #expect(config.ports == InstallConfig.Ports())
    }

    @Test func allPortsIncludesDoubaoCdp() {
        // Upstream start preflight forgets 19400; the doctor must not (M10).
        let config = InstallConfig(version: "t", dataDir: "/d", poolKey: "p", serviceKey: "s")
        #expect(config.allPorts.contains(19400))
        #expect(config.allPorts.count == 7)
    }

    // MARK: processes.json parity (M7)

    @Test func processRecordDecodesUpstreamShape() throws {
        let json = """
        [{"name":"license","pid":123,"executable":"/Users/x/MuseCanvas/node/node","startedTicks":"Thu Nov 13 10:00:00 2026"}]
        """
        let records = try JSONDecoder().decode([ProcessRecord].self, from: Data(json.utf8))
        #expect(records.count == 1)
        #expect(records[0].name == "license")
        #expect(records[0].pid == 123)
        // Tolerate a record missing startedTicks (older writers).
        let tolerant = """
        [{"name":"web","pid":9,"executable":"/n"}]
        """
        let decoded = try JSONDecoder().decode([ProcessRecord].self, from: Data(tolerant.utf8))
        #expect(decoded[0].startedTicks == "")
    }

    // MARK: UnitTable — the parity contract with manage.sh (M12)

    @Test func bootOrderMatchesManageDotSh() {
        // manage.sh spawns: license, agent, merge, pool, web.
        #expect(UnitTable.all.map(\.id) == ["license", "agent", "merge", "pool", "web"])
    }

    @Test func healthDialectsMatchWaitHealthCalls() {
        // wait_health $P_WEB /health           — no key
        // wait_health $P_AGENT /health          — no key
        // wait_health $P_POOL /healthz          — no key, 240 tries
        // wait_health $P_LICENSE /health $KEY   — keyed
        // merge /health JSON must say ffmpeg yes
        let byPort = Dictionary(uniqueKeysWithValues: UnitTable.all.map { ($0.port, $0) })
        #expect(byPort[3000]?.healthPath == "/health" && byPort[3000]?.healthRequiresServiceKey == false)
        #expect(byPort[17371]?.healthPath == "/health" && byPort[17371]?.healthRequiresServiceKey == false)
        #expect(byPort[18610]?.healthPath == "/healthz")
        #expect(byPort[18610]!.startTimeoutSeconds >= 120)  // upstream budget: 240 × 0.5 s
        #expect(byPort[17373]?.healthRequiresServiceKey == true)
        #expect(byPort[17372]?.healthJSONReady?.key == "ffmpeg")
        #expect(byPort[17372]?.healthJSONReady?.value == "truthy")
        #expect(byPort[17372]?.healthRequiresServiceKey == true)
    }

    @Test func executablesMatchInstallRequiredList() {
        // install.sh REQUIRED: node/node pool/MusePool agent/agent.cjs
        // services/entry.cjs services/{web,merge,license}.jsc web/index.html tools/ffmpeg
        let exes = Set(UnitTable.all.map(\.executable))
        #expect(exes.contains("node/node"))
        #expect(exes.contains("pool/MusePool"))
        let agent = UnitTable.unit(named: "agent")
        #expect(agent?.arguments.first == "agent/agent.cjs")
        let merge = UnitTable.unit(named: "merge")
        #expect(merge?.arguments == ["services/entry.cjs", "merge"])
    }

    // MARK: Environment contract (M8) — same 24 keys manage.sh exports

    @Test func environmentContractKeysMatchManageDotSh() {
        let config = InstallConfig(version: "0.21.2", dataDir: "/data", poolKey: "pk", serviceKey: "sk")
        let env = EnvironmentContract.build(
            installRoot: "/apps/MuseCanvas", dataDir: "/data",
            configPath: "/data/install.json", config: config, home: "/Users/x")
        let expectedKeys: Set<String> = [
            "CANVAS_APP_DIR", "CANVAS_STATE_DIR", "CANVAS_INSTALL_CONFIG",
            "CANVAS_AGENT_CONFIG_DIR", "CANVAS_SERVICE_KEY", "MUSE2API_KEY",
            "MUSE2API_HOME", "MUSE2API_PROFILE_ROOT", "MUSE2API_HOME_DIR",
            "MUSE2API_CDP_PORT", "MUSE2API_PUBLIC_BASE", "MUSE2API_WHISPER_MODEL",
            "MERGE_PORT", "MC_LICENSE_DIR", "MC_DOUBAO_PROFILE",
            "MC_DOUBAO_CDP_PORT", "MC_LICENSE_CLIENT_PORT", "MC_POOL_ACCOUNTS",
            "MERGE_OUTPUT_DIR", "MERGE_FFMPEG_PATH", "MERGE_FFPROBE_PATH",
            "CLAUDE_PROJECTS_DIR", "CLAUDE_PROJECT_DIR", "PORT",
        ]
        #expect(Set(env.keys) == expectedKeys)
        #expect(env["MUSE2API_PUBLIC_BASE"] == "http://localhost:18610")
        #expect(env["MERGE_FFMPEG_PATH"] == "/apps/MuseCanvas/tools/ffmpeg")
    }

    @Test func claudeProjectDirSedParity() {
        // manage.sh: CLAUDE_PROJECT_DIR="$(printf '%s' "$WORKSPACE" | sed 's/[^a-zA-Z0-9]/-/g')"
        let config = InstallConfig(version: "t", dataDir: "/Users/x/Library/Application Support/MuseCanvas/data", poolKey: "p", serviceKey: "s")
        let env = EnvironmentContract.build(
            installRoot: "/i", dataDir: config.dataDir, configPath: "/c",
            config: config, home: "/Users/x")
        #expect(env["CLAUDE_PROJECT_DIR"]
                == "-Users-x-Library-Application-Support-MuseCanvas-data-agent-workspace")
        // With CLAUDE_CONFIG_DIR set, projects live under it.
        let env2 = EnvironmentContract.build(
            installRoot: "/i", dataDir: config.dataDir, configPath: "/c",
            config: config, home: "/Users/x", claudeConfigDir: "/Users/x/.custom-claude")
        #expect(env2["CLAUDE_PROJECTS_DIR"] == "/Users/x/.custom-claude/projects")
    }
}

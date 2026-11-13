import Foundation
import Testing
@testable import MuseCore
@testable import MuseKit

/// Engine-level tests: the installer's refusal table (M1–M3), the spawner's
/// process-group semantics (M8/M9), and record reconciliation (M7) against
/// real processes on a real (test) filesystem.
struct EngineTests {

    func makeTempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-tests-\(UUID().uuidString)-\(name)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A minimal fake payload: every required file, plus a manifest line
    /// for each so quick verification works.
    func makeFakePayload(root: URL) -> URL {
        let fm = FileManager.default
        for rel in Installer.requiredFiles {
            let target = root.appendingPathComponent(rel)
            try? fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            fm.createFile(atPath: target.path, contents: Data("stub-\(rel)".utf8))
        }
        let manifest = Installer.requiredFiles.map { rel in
            let digest = SHA256Stub.hex(of: rel)
            return "\(digest)  \(rel)"
        }.joined(separator: "\n") + "\n"
        fm.createFile(atPath: root.appendingPathComponent("MANIFEST.sha256").path,
                      contents: Data(manifest.utf8))
        fm.createFile(atPath: root.appendingPathComponent("scripts/manage.sh").path,
                      contents: Data("#!/bin/bash\ntrue\n".utf8))
        return root
    }

    // MARK: Installer plan (M1–M3)

    @Test func freshInstallPlanIsNewAndClean() {
        let payload = makeFakePayload(root: makeTempDir("payload"))
        let dest = makeTempDir("dest").path + "/MuseCanvas"
        let installer = Installer(source: payload.path, destination: dest)
        let plan = installer.plan()
        #expect(plan.mode == "NEW")
        #expect(plan.refusals.isEmpty)
        #expect(plan.dataDirResolution == "derived")
    }

    @Test func incompleteSourceIsRefusedWithNothingChanged() {
        let dest = makeTempDir("dest2").path + "/MuseCanvas"
        let installer = Installer(source: makeTempDir("empty-payload").path, destination: dest)
        let plan = installer.plan()
        #expect(plan.refusals.contains { $0.contains("incomplete") })
        // And install() refuses before touching the destination.
        #expect(FileManager.default.fileExists(atPath: dest) == false)
    }

    @Test func foreignDestinationIsRefused() throws {
        let payload = makeFakePayload(root: makeTempDir("payload3"))
        let foreign = makeTempDir("foreign")
        try "hello".write(to: foreign.appendingPathComponent("unrelated.txt"),
                          atomically: true, encoding: .utf8)
        let installer = Installer(source: payload.path, destination: foreign.path)
        let plan = installer.plan()
        #expect(plan.refusals.contains { $0.contains("not a MuseCanvas installation") })
    }

    @Test func protectedDestinationsAreRefused() {
        let payload = makeFakePayload(root: makeTempDir("payload4"))
        for protected in ["/Applications", "/usr", "/System"] {
            let installer = Installer(source: payload.path, destination: protected)
            #expect(installer.plan().refusals.contains { $0.contains("Refusing to install into") })
        }
    }

    @Test func upgradeInheritsRecordedDataDir() throws {
        let payload = makeFakePayload(root: makeTempDir("payload5"))
        let dest = makeTempDir("dest5").path + "/MuseCanvas"
        let fm = FileManager.default
        // An existing install with a pinned data dir.
        try fm.createDirectory(atPath: dest + "/scripts", withIntermediateDirectories: true)
        fm.createFile(atPath: dest + "/scripts/manage.sh", contents: Data())
        let record = InstanceRecord(version: "0.21.1", installDir: dest,
                                    dataDirectory: "/tmp/legacy-data", forUser: "x")
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: dest + "/instance.json"))
        let installer = Installer(source: payload.path, destination: dest)
        let plan = installer.plan()
        #expect(plan.mode == "UPGRADE")
        #expect(plan.dataDirectory == "/tmp/legacy-data")
        #expect(plan.dataDirResolution == "inherited")
        #expect(plan.willStopRunningServices)
    }

    @Test func missingRecordedDataDirIsRefused() throws {
        let payload = makeFakePayload(root: makeTempDir("payload6"))
        let dest = makeTempDir("dest6").path + "/MuseCanvas"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dest + "/scripts", withIntermediateDirectories: true)
        fm.createFile(atPath: dest + "/scripts/manage.sh", contents: Data())
        let record = InstanceRecord(version: "0.21.1", installDir: dest,
                                    dataDirectory: "/definitely/not/here/\(UUID().uuidString)",
                                    forUser: "x")
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: dest + "/instance.json"))
        let plan = Installer(source: payload.path, destination: dest).plan()
        // The wizard's hard refusal: never silently derive a fresh data dir.
        #expect(plan.refusals.contains { $0.contains("no longer exists") })
    }

    @Test func tamperedRequiredFileFailsIntegrityCheck() {
        let payload = makeFakePayload(root: makeTempDir("payload7"))
        // Tamper after the manifest was written.
        try? Data("tampered".utf8).write(to: payload.appendingPathComponent("tools/ffmpeg"))
        let installer = Installer(source: payload.path, destination: makeTempDir("dest7").path + "/M")
        let problems = installer.verifyRequiredAgainstManifest()
        #expect(problems.contains("tools/ffmpeg"))
    }

    // MARK: Spawner + kill tree (M8/M9) — real processes

    @Test func spawnedProcessGetsOwnGroupAndDiesWithTree() async throws {
        let log = makeTempDir("logs")
        let spawned = try Spawner.spawn(
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: "/tmp",
            environment: ["MUSE_TEST_MARKER": "1"],
            stdoutPath: log.appendingPathComponent("out.log").path,
            stderrPath: log.appendingPathComponent("err.log").path)
        #expect(spawned.pid > 0)
        #expect(Shell.pidAlive(Int(spawned.pid)))

        // Group leader: pgid == pid (this is what makes kill(-pid) work).
        let pgid = getpgid(spawned.pid)
        #expect(pgid == spawned.pid)

        await Shell.killTree(pid: Int(spawned.pid))
        #expect(!Shell.pidAlive(Int(spawned.pid)))
    }

    // MARK: processes.json round-trip (M7)

    @Test func processRecordsRoundTripThroughDisk() throws {
        let dir = makeTempDir("data")
        let path = dir.appendingPathComponent("processes.json").path
        let records = [
            ProcessRecord(name: "web", pid: 42, executable: "/x/node", startedTicks: "s"),
        ]
        let encoded = try JSONEncoder().encode(records)
        try encoded.write(to: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode([ProcessRecord].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(decoded == records)
    }

    // MARK: Config migration through Instance.load (M6)

    @Test func instanceLoadCreatesSecretsOnceAndKeepsThem() throws {
        let root = makeTempDir("install-root")
        let data = makeTempDir("data-dir")
        let record = InstanceRecord(version: "0.21.2", installDir: root.path,
                                    dataDirectory: data.path, forUser: "t")
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: root.path + "/instance.json"))

        let first = try Supervisor.Instance.load(installRoot: root.path)
        #expect(!first.config.poolKey.isEmpty)
        #expect(!first.config.serviceKey.isEmpty)
        #expect(first.config.poolKey != first.config.serviceKey)   // distinct, always

        // Second load must NOT regenerate (secrets are create-once).
        let second = try Supervisor.Instance.load(installRoot: root.path)
        #expect(second.config.poolKey == first.config.poolKey)
        #expect(second.config.serviceKey == first.config.serviceKey)
    }
}

import CryptoKit
enum SHA256Stub {
    static func hex(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

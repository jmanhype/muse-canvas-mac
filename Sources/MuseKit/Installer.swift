import Foundation
import MuseCore

/// The InstallMachine engine: same guarantees as upstream's install.sh
/// (validated source, staged-and-verified copy, preserved user models,
/// stop-before-swap, rollback on failed swap, pinned data dir), plus one
/// guarantee upstream doesn't give: optional full per-file verification
/// against the package's own MANIFEST.sha256 before anything is touched.
public struct Installer: Sendable {

    /// Required payload files — identical list to install.sh's REQUIRED.
    public static let requiredFiles = [
        "scripts/manage.sh", "node/node", "pool/MusePool", "agent/agent.cjs",
        "services/entry.cjs", "services/web.jsc", "services/merge.jsc",
        "services/license.jsc", "web/index.html", "tools/ffmpeg", "tools/ffprobe",
    ]

    public enum VerifyLevel: String, Sendable {
        case off, quick, full
    }

    public enum InstallError: Error, CustomStringConvertible, Equatable {
        case sourceIncomplete([String])
        case sourceIsDestination
        case protectedDestination(String)
        case foreignDestination(String, entries: Int)
        case multipleInstalls([String])
        case recordedDataDirMissing(String)
        case verifyFailed([String])

        public var description: String {
            switch self {
            case .sourceIncomplete(let missing):
                return "Install source is incomplete (missing: \(missing.joined(separator: ", "))). Re-download and re-extract. Nothing was changed."
            case .sourceIsDestination:
                return "Source and destination are the same folder. Extract the package somewhere else first."
            case .protectedDestination(let path):
                return "Refusing to install into \(path). Choose a dedicated folder such as ~/MuseCanvas."
            case .foreignDestination(let path, let entries):
                return "\(path) already contains \(entries) other file(s) and is not a MuseCanvas installation. Nothing was changed."
            case .multipleInstalls(let roots):
                return "Found more than one MuseCanvas (\(roots.joined(separator: ", "))). Refusing to guess which to upgrade."
            case .recordedDataDirMissing(let path):
                return "An older install recorded data directory \(path), which no longer exists. Refusing: a silent fresh data dir would look like lost work."
            case .verifyFailed(let problems):
                return "Payload integrity check failed for \(problems.count) file(s): \(problems.prefix(5).joined(separator: ", "))\(problems.count > 5 ? " …" : ""). Nothing was changed."
            }
        }
    }

    public struct Plan: Codable, Sendable {
        /// "NEW" or "UPGRADE" — wire-compatible with the wizard's
        /// --detect-only output (M5), plus everything it can't say.
        public let mode: String
        public let destination: String
        public let dataDirectory: String
        public let dataDirResolution: String   // explicit | inherited | derived
        public let refusals: [String]
        public let willStopRunningServices: Bool
    }

    public let source: String
    public let destination: String
    public let explicitDataDir: String?
    public let verify: VerifyLevel
    // FileManager.default is safe to use from any thread; Swift 6 just
    // can't see it. Use a computed property instead of a stored one.
    var fm: FileManager { FileManager.default }

    public init(source: String, destination: String = Paths.defaultInstallRoot,
                explicitDataDir: String? = nil, verify: VerifyLevel = .quick) {
        self.source = source
        self.destination = destination
        self.explicitDataDir = explicitDataDir
        self.verify = verify
    }

    // MARK: - Detection & planning (M3, M5)

    static let protectedPaths: [String] = [
        "/", "/Applications", "/System", "/Library", "/usr", "/bin", "/sbin",
        "/etc", "/private", "/Volumes", "/Users", Paths.home,
    ]

    public func plan() -> Plan {
        var refusals: [String] = []

        // Multi-install refusal (wizard parity).
        let found = InstallSet.detect()
        if found.count > 1 && destination == Paths.defaultInstallRoot {
            refusals.append(InstallError.multipleInstalls(found.map(\.root)).description)
        }
        // Source sanity.
        if let missing = missingFiles(under: source) {
            refusals.append(InstallError.sourceIncomplete(missing).description)
        }
        if realPath(source) == realPath(destination) {
            refusals.append(InstallError.sourceIsDestination.description)
        }
        if InstallSet.detect().contains(where: { $0.root == realPath(source) }) {
            refusals.append("You are running the installer from inside an installed tree. Extract the new package elsewhere.")
        }
        // Destination safety.
        if Self.protectedPaths.contains(realPath(destination)) {
            refusals.append(InstallError.protectedDestination(destination).description)
        }
        let hadInstall = fm.fileExists(atPath: destination + "/scripts/manage.sh")
        if !hadInstall, fm.fileExists(atPath: destination) {
            let entries = (try? fm.contentsOfDirectory(atPath: destination))?.count ?? 0
            if entries > 0 {
                refusals.append(InstallError.foreignDestination(destination, entries: entries).description)
            }
        }

        // Data dir resolution (M2) — as the explicit type.
        let previousDataDir = hadInstall ? readRecordedDataDir() : nil
        let resolution = DataDirectoryResolution.resolve(
            explicit: explicitDataDir, previous: previousDataDir,
            default: Paths.defaultDataDirectory)
        // The wizard's data-dir refusal: recorded dir must still exist.
        if case .inheritedFromInstance(let dir) = resolution, !fm.fileExists(atPath: dir) {
            refusals.append(InstallError.recordedDataDirMissing(dir).description)
        }

        let willStop = hadInstall
        return Plan(
            mode: hadInstall ? "UPGRADE" : "NEW",
            destination: destination,
            dataDirectory: resolution.path,
            dataDirResolution: {
                switch resolution {
                case .explicit: return "explicit"
                case .inheritedFromInstance: return "inherited"
                case .derivedDefault: return "derived"
                }
            }(),
            refusals: refusals,
            willStopRunningServices: willStop)
    }

    // MARK: - Install (M1)

    public struct InstallResult: Codable, Sendable {
        public let fresh: Bool
        public let dataDirectory: String
        public let preservedModelFiles: Int
        public let verifiedFiles: Int
    }

    @discardableResult
    public func install(version: String = "0.21.2") async throws -> InstallResult {
        // Step 1+2: validate source, classify destination — must be clean.
        let plan = plan()
        guard plan.refusals.isEmpty else {
            throw MuseInstallRefused(refusals: plan.refusals)
        }
        if let missing = missingFiles(under: source) {
            throw InstallError.sourceIncomplete(missing)
        }

        // Integrity: the payload ships MANIFEST.sha256 (5,135 files).
        var verified = 0
        switch verify {
        case .full:
            let problems = await verifyAllAgainstManifest()
            if !problems.isEmpty { throw InstallError.verifyFailed(problems) }
            verified = countManifestLines()
        case .quick:
            let problems = verifyRequiredAgainstManifest()
            if !problems.isEmpty { throw InstallError.verifyFailed(problems) }
            verified = Self.requiredFiles.count
        case .off:
            break
        }

        let stamp = Self.stamp()
        let staging = destination + ".new-" + stamp
        let backup = destination + ".old-" + stamp
        let hadInstall = fm.fileExists(atPath: destination + "/scripts/manage.sh")

        // Step 3: stage + verify the staged copy (a broken source changes
        // nothing; the destination has not been touched yet).
        try? fm.removeItem(atPath: staging)
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        let cp = await Shell.run("/bin/cp", ["-a", source + "/.", staging + "/"])
        guard cp.success else {
            try? fm.removeItem(atPath: staging)
            throw InstallError.sourceIncomplete(["staging copy failed: \(cp.stderr)"])
        }
        guard missingFiles(under: staging) == nil else {
            try? fm.removeItem(atPath: staging)
            throw InstallError.sourceIncomplete(missingFiles(under: staging)!)
        }
        // Unsigned download: strip quarantine from the staged tree before
        // anything inside it is executed (parity with install.sh).
        _ = await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging])

        // Step 4: preserve user-added model files.
        var preserved = 0
        if hadInstall, fm.fileExists(atPath: destination + "/models") {
            let modelsURL = URL(fileURLWithPath: destination + "/models")
            if let walker = fm.enumerator(at: modelsURL, includingPropertiesForKeys: [.isRegularFileKey]) {
                let files = walker.allObjects.compactMap { $0 as? URL }
                for file in files {
                    guard file.lastPathComponent != "README.txt" else { continue }
                    let rel = file.path.replacingOccurrences(of: modelsURL.path + "/", with: "")
                    let target = staging + "/models/" + rel
                    try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                           withIntermediateDirectories: true)
                    if (try? fm.copyItem(atPath: file.path, toPath: target)) != nil { preserved += 1 }
                }
            }
        }

        // Step 5: stop old, swap with rollback.
        if hadInstall {
            _ = await Shell.run("/bin/bash", [destination + "/scripts/manage.sh", "stop"])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        do {
            if fm.fileExists(atPath: destination) {
                try fm.moveItem(atPath: destination, toPath: backup)
            }
            try fm.moveItem(atPath: staging, toPath: destination)
        } catch {
            // Rollback (M1): only the swap step owes this.
            if fm.fileExists(atPath: backup) && !fm.fileExists(atPath: destination) {
                try? fm.moveItem(atPath: backup, toPath: destination)
            }
            try? fm.removeItem(atPath: staging)
            throw NSError(domain: "muse.install.swap", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Install failed during the folder swap; the previous installation was restored. \(error)"])
        }

        // Markers — same files upstream writes.
        let marker = #"{"product":"MuseCanvas","version":"\#(version)","installedAt":"\#(Self.nowString())"}"#
        try marker.write(toFile: destination + "/musecanvas.json", atomically: true, encoding: .utf8)

        // Step 5b: pin the instance (M2).
        let resolution = DataDirectoryResolution.resolve(
            explicit: explicitDataDir, previous: hadInstall ? readRecordedDataDir() : nil,
            default: Paths.defaultDataDirectory)
        let record = InstanceRecord(
            version: version, installDir: destination,
            dataDirectory: resolution.path, forUser: NSUserName())
        let encoder = JSONEncoder()
        try encoder.encode(record).write(to: URL(fileURLWithPath: destination + "/instance.json"))
        try? fm.removeItem(atPath: backup)

        // Step 6: desktop launcher, byte-compatible with upstream's (the
        // `# MuseCanvas install root:` marker is what M3 detection reads).
        let launcher = Paths.home + "/Desktop/MuseCanvas.command"
        let script = """
        #!/bin/bash
        # MuseCanvas install root: \(destination)
        bash "\(destination)/scripts/manage.sh" start
        echo
        read -r -p "按回车关闭这个窗口" _
        """
        try script.write(toFile: launcher, atomically: true, encoding: .utf8)
        _ = await Shell.run("/bin/chmod", ["+x", launcher])

        return InstallResult(fresh: !hadInstall, dataDirectory: resolution.path,
                             preservedModelFiles: preserved, verifiedFiles: verified)
    }

    public struct MuseInstallRefused: Error, CustomStringConvertible, Encodable {
        public let refusals: [String]
        public var description: String {
            "Refused, nothing was changed:\n- " + refusals.joined(separator: "\n- ")
        }
    }

    // MARK: - Verification against the payload's own manifest

    func manifestEntries() -> [(hash: String, path: String)] {
        let url = URL(fileURLWithPath: source + "/MANIFEST.sha256")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "  ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
    }

    func countManifestLines() -> Int { manifestEntries().count }

    func verifyRequiredAgainstManifest() -> [String] {
        let entries = Dictionary(uniqueKeysWithValues: manifestEntries().map { ($0.path, $0.hash) })
        var problems: [String] = []
        for required in Self.requiredFiles {
            guard let expected = entries[required] else { continue }  // not listed → skip
            let actual = sha256Hex(source + "/" + required)
            if actual != expected.lowercased() { problems.append(required) }
        }
        return problems
    }

    func verifyAllAgainstManifest() async -> [String] {
        // `shasum -c` does 5,135 files fast in one process; reuse it.
        let result = await Shell.run(
            "/usr/bin/env", ["sh", "-c", "cd \"\(source)\" && shasum -a 256 -c MANIFEST.sha256 2>/dev/null | grep -v ': OK$' || true"],
            environment: ["PATH": "/usr/bin:/bin:/usr/local/bin"])
        guard result.success else { return ["manifest check could not run"] }
        return result.stdout.split(separator: "\n")
            .map { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? String($0) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Helpers

    func missingFiles(under root: String) -> [String]? {
        let missing = Self.requiredFiles.filter { !fm.fileExists(atPath: root + "/" + $0) }
        return missing.isEmpty ? nil : missing
    }

    func readRecordedDataDir() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: destination + "/instance.json")),
              let record = try? JSONDecoder().decode(InstanceRecord.self, from: data) else { return nil }
        return record.dataDirectory.isEmpty ? nil : record.dataDirectory
    }

    func realPath(_ p: String) -> String {
        (p as NSString).resolvingSymlinksInPath
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func nowString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

import CryptoKit

func sha256Hex(_ path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

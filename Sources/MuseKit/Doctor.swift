import Foundation
import MuseCore

/// The doctor engine (M4, M10, M17): every check upstream's wizard and
/// DEPLOY acceptance steps perform, as data, with the tri-state verdict and
/// an explicit userActionRequired flag for everything an agent must not do
/// (log into accounts, complete captchas, spend quota).
///
/// The doctor never contacts external services: no license server, no
/// muse.ai, no pool traffic. It inspects the local machine and probes
/// loopback only.
public struct Doctor: Sendable {

    public let installRoot: String?

    public init(installRoot: String?) {
        self.installRoot = installRoot
    }

    public func run(now: Date = Date()) async -> DoctorReport {
        var checks: [DoctorCheck] = []
        checks.append(await checkArchitecture())
        checks.append(await checkBrowser())
        checks.append(await checkDisk())
        if let root = installRoot {
            checks.append(await checkPayload(root: root))
            checks.append(await checkIntegrity(root: root))
            checks.append(await checkInstance(root: root))
            checks.append(await checkConfigSecrets(root: root))
            checks.append(await checkSingleInstall())
            checks.append(await checkServices(root: root))
            checks.append(await checkCanvasReachable(root: root))
            checks.append(checkPoolLogin())
            checks.append(checkAgentAuth())
        } else {
            checks.append(DoctorCheck(
                id: "install", title: "MuseCanvas installation",
                verdict: .untested, evidence: "no install root given",
                remedy: "Run `muse install --source <extracted package>`"))
        }
        return DoctorReport(generatedAtUnix: Int(now.timeIntervalSince1970), checks: checks)
    }

    // MARK: Individual checks

    func checkArchitecture() async -> DoctorCheck {
        #if arch(arm64)
        return DoctorCheck(id: "arch", title: "Apple Silicon (arm64)",
                           verdict: .passed, evidence: "running on arm64")
        #else
        return DoctorCheck(id: "arch", title: "Apple Silicon (arm64)",
                           verdict: .failed, evidence: "this build is not arm64",
                           remedy: "The upstream Mac test build supports Apple Silicon only (macOS 13.5+).")
        #endif
    }

    func checkBrowser() async -> DoctorCheck {
        let hits = await BrowserFinder.find()
        if hits.isEmpty {
            return DoctorCheck(
                id: "browser", title: "Chrome or Edge found",
                verdict: .failed,
                evidence: "no Chrome/Edge in default locations or Spotlight",
                remedy: "Install Google Chrome or Microsoft Edge, then re-run `muse doctor`.")
        }
        let detail = hits.map { "\($0.name) at \($0.path) (\($0.how))" }.joined(separator: "; ")
        return DoctorCheck(id: "browser", title: "Chrome or Edge found",
                           verdict: .passed, evidence: detail)
    }

    func checkDisk() async -> DoctorCheck {
        let target = installRoot ?? Paths.defaultInstallRoot
        let dir = (target as NSString).deletingLastPathComponent
        let values = try? URL(fileURLWithPath: dir)
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let free = values?.volumeAvailableCapacity else {
            return DoctorCheck(id: "disk", title: "Free disk (≥ 4 GB)",
                               verdict: .untested, evidence: "could not query \(dir)",
                               remedy: "Check free space manually.")
        }
        let gb = Double(free) / 1_000_000_000
        return DoctorCheck(
            id: "disk", title: "Free disk (≥ 4 GB)",
            verdict: gb >= 4 ? .passed : .failed,
            evidence: String(format: "%.1f GB free on %@", gb, dir),
            remedy: gb >= 4 ? nil : "Free at least 4 GB (the payload extracts to ~2 GB plus media).")
    }

    func checkPayload(root: String) async -> DoctorCheck {
        let missing = Installer.requiredFiles.filter {
            !FileManager.default.fileExists(atPath: root + "/" + $0)
        }
        if missing.isEmpty {
            return DoctorCheck(id: "payload", title: "Payload required files",
                               verdict: .passed,
                               evidence: "\(Installer.requiredFiles.count) required files present")
        }
        return DoctorCheck(id: "payload", title: "Payload required files",
                           verdict: .failed, evidence: "missing: \(missing.joined(separator: ", "))",
                           remedy: "Re-extract the release zip (verify its SHA-256 first) and reinstall.")
    }

    func checkIntegrity(root: String) async -> DoctorCheck {
        let manifest = root + "/MANIFEST.sha256"
        guard FileManager.default.fileExists(atPath: manifest) else {
            return DoctorCheck(id: "integrity", title: "Payload integrity (MANIFEST.sha256)",
                               verdict: .untested,
                               evidence: "no MANIFEST.sha256 inside the install tree",
                               remedy: "If the zip's SHA-256 matched the release notes, the package was verified at download time.")
        }
        // Spot-check the required files (full check is `muse install --verify full`).
        // The managed English overlay (web/index.html) is a *declared*
        // deviation: expected while on, and excluded from "problems".
        let installer = Installer(source: root, destination: root)
        let problems = installer.verifyRequiredAgainstManifest().filter {
            !EnglishOverlay.isDeclaredDeviation(file: $0, installRoot: root)
        }
        let overlayOn = EnglishOverlay.status(installRoot: root) == .on
        let overlayNote = overlayOn
            ? "; declared deviation: web/index.html + new web/muse-english.js (English overlay on — `muse english off` restores)"
            : ""
        if problems.isEmpty {
            return DoctorCheck(id: "integrity", title: "Payload integrity (MANIFEST.sha256)",
                               verdict: .passed,
                               evidence: "spot-check of \(Installer.requiredFiles.count) required files matches the package manifest\(overlayNote)")
        }
        return DoctorCheck(id: "integrity", title: "Payload integrity (MANIFEST.sha256)",
                           verdict: .failed,
                           evidence: "hash mismatch: \(problems.joined(separator: ", "))",
                           remedy: "Payload modified or damaged. Re-download the zip, verify SHA-256, reinstall. (The English overlay only ever injects into web/index.html plus a new muse-english.js; that one file is excluded while declared.)")
    }

    func checkInstance(root: String) async -> DoctorCheck {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/instance.json")),
              let record = try? JSONDecoder().decode(InstanceRecord.self, from: data) else {
            return DoctorCheck(id: "instance", title: "Instance pin (instance.json)",
                               verdict: .failed,
                               evidence: "missing or unreadable at \(root)/instance.json",
                               remedy: "Reinstall; the installer pins install dir + data dir here.")
        }
        let dataOK = FileManager.default.fileExists(atPath: record.dataDirectory)
        return DoctorCheck(
            id: "instance", title: "Instance pin (instance.json)",
            verdict: dataOK ? .passed : .failed,
            evidence: "v\(record.version), data at \(record.dataDirectory)\(dataOK ? "" : " (directory missing!)")",
            remedy: dataOK ? nil : "The pinned data directory is gone. Restore it from backup before doing anything else — a reinstall without it looks like lost work.")
    }

    func checkConfigSecrets(root: String) async -> DoctorCheck {
        do {
            let instance = try Supervisor.Instance.load(installRoot: root)
            let c = instance.config
            let distinct = c.poolKey != c.serviceKey && !c.poolKey.isEmpty && !c.serviceKey.isEmpty
            // Never print keys (DEPLOY: diagnostics show fingerprints, not secrets).
            let fingerprint = { (s: String) in s.count >= 8 ? String(s.prefix(4)) + "…" + String(s.suffix(4)) + " (\(s.count) chars)" : "too short" }
            return DoctorCheck(
                id: "secrets", title: "Per-instance keys present and distinct",
                verdict: distinct ? .passed : .failed,
                evidence: "poolKey \(fingerprint(c.poolKey)), serviceKey \(fingerprint(c.serviceKey))",
                remedy: distinct ? nil : "Keys must exist and stay distinct per instance; never align credentials across instances.")
        } catch {
            return DoctorCheck(id: "secrets", title: "Per-instance keys present and distinct",
                               verdict: .failed, evidence: "\(error)",
                               remedy: "Check \(root)/instance.json and the data directory.")
        }
    }

    func checkSingleInstall() async -> DoctorCheck {
        let found = InstallSet.detect()
        switch found.count {
        case 0:
            return DoctorCheck(id: "installs", title: "Exactly one installation",
                               verdict: .untested, evidence: "none found",
                               remedy: "Run `muse install` first.")
        case 1:
            return DoctorCheck(id: "installs", title: "Exactly one installation",
                               verdict: .passed,
                               evidence: "\(found[0].root) (via \(found[0].source))")
        default:
            return DoctorCheck(id: "installs", title: "Exactly one installation",
                               verdict: .failed,
                               evidence: found.map(\.root).joined(separator: "; "),
                               remedy: "Two installs share one port set; only one can run. Decide which to keep before upgrading.")
        }
    }

    func checkServices(root: String) async -> DoctorCheck {
        guard let instance = try? Supervisor.Instance.load(installRoot: root) else {
            return DoctorCheck(id: "services", title: "Five services",
                               verdict: .untested, evidence: "cannot load instance",
                               remedy: "Reinstall.")
        }
        let supervisor = Supervisor(instance: instance)
        let snap = await supervisor.snapshot()
        let failed = snap.units.filter { $0.phase.hasPrefix("failed") }
        let degraded = snap.units.filter { $0.phase == "degraded" }
        let running = snap.units.filter { $0.phase == "ready" }
        let evidence = snap.units.map { "\($0.id)=\($0.phase)" }.joined(separator: " ")
        if !failed.isEmpty {
            return DoctorCheck(id: "services", title: "Five services",
                               verdict: .failed,
                               evidence: evidence,
                               remedy: "Failed: \(failed.map(\.id).joined(separator: ", ")). See logs at \(instance.logsDirectory). `muse stop && muse start` resets a partial state.")
        }
        if running.count == snap.units.count {
            return DoctorCheck(id: "services", title: "Five services",
                               verdict: .passed, evidence: evidence)
        }
        if !degraded.isEmpty || !running.isEmpty {
            return DoctorCheck(id: "services", title: "Five services",
                               verdict: .failed, evidence: evidence,
                               remedy: "Partial/degraded stack. `muse stop`, then `muse start`.")
        }
        return DoctorCheck(id: "services", title: "Five services",
                           verdict: .untested, evidence: "not running (\(evidence))",
                           remedy: "Run `muse start`.")
    }

    func checkCanvasReachable(root: String) async -> DoctorCheck {
        guard let instance = try? Supervisor.Instance.load(installRoot: root) else {
            return DoctorCheck(id: "canvas", title: "Canvas page reachable",
                               verdict: .untested, evidence: "cannot load instance", remedy: "Reinstall.")
        }
        let supervisor = Supervisor(instance: instance)
        guard let web = UnitTable.unit(named: "web") else { return .init(id: "canvas", title: "Canvas page reachable", verdict: .untested, evidence: "no web unit", remedy: nil) }
        // Snapshot says whether the stack is up.
        let snap = await supervisor.snapshot()
        let webUp = snap.units.first { $0.id == "web" }?.phase == "ready"
        guard webUp else {
            return DoctorCheck(id: "canvas", title: "Canvas page reachable",
                               verdict: .untested, evidence: "web service not running",
                               remedy: "Start the stack (`muse start`), then open \(instance.config.webURL).")
        }
        // Real evidence: fetch the page like a browser would (200 + html).
        var request = URLRequest(url: URL(string: instance.config.webURL + "/")!)
        request.timeoutInterval = 3
        let session = URLSession(configuration: .ephemeralNoProxy)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let isHTML = String(data: data.prefix(512), encoding: .utf8)?.contains("<") ?? false
            if code == 200 && isHTML {
                return DoctorCheck(id: "canvas", title: "Canvas page reachable",
                                   verdict: .passed,
                                   evidence: "GET \(instance.config.webURL)/ → 200, HTML body (\(data.count) bytes)")
            }
            return DoctorCheck(id: "canvas", title: "Canvas page reachable",
                               verdict: .failed, evidence: "GET / → HTTP \(code), body looks like: \(String(data: data.prefix(120), encoding: .utf8) ?? "binary")")
        } catch {
            return DoctorCheck(id: "canvas", title: "Canvas page reachable",
                               verdict: .failed, evidence: "\(error.localizedDescription)")
        }
    }

    /// Account login is the user's and only the user's (upstream rule,
    /// enforced here by schema rather than prose).
    func checkPoolLogin() -> DoctorCheck {
        DoctorCheck(
            id: "pool-login", title: "Generation pool login (Muse accounts)",
            verdict: .untested,
            evidence: "requires the user's own Muse account; agents must not attempt it",
            remedy: "Open the pool page from the canvas and sign in yourself. Connected ≠ usable: verify quota is queryable.",
            userActionRequired: true)
    }

    func checkAgentAuth() -> DoctorCheck {
        DoctorCheck(
            id: "agent-auth", title: "Agent auth (Codex / Claude / API key)",
            verdict: .untested,
            evidence: "requires the user's own Codex/Claude account or API key; agents must not attempt it",
            remedy: "Sign in via the model page in the canvas with your own account. Never regenerate MCP tokens to fix 'invalid token'.",
            userActionRequired: true)
    }
}

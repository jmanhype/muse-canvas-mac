import Foundation
import MuseCore
import MuseKit

/// `muse` — the Mac supervisor for MuseCanvas.
///
/// Exit-code contract (inherited from the upstream wizard, M5):
///   0 done · 1 failed · 2 cancelled by user · 3 refused, nothing changed.
/// Every command that reports state also speaks `--json`.

let arguments = Array(CommandLine.arguments.dropFirst())
let jsonEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
}()

func printJSON<T: Encodable>(_ value: T) {
    print(String(data: (try? jsonEncoder.encode(value)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
}

func resolveInstall() -> String {
    if let i = arguments.firstIndex(of: "--install-root"), i + 1 < arguments.count {
        return arguments[i + 1]
    }
    return Paths.defaultInstallRoot
}

func fail(_ message: String, code: Int32 = 1, json: (any Encodable)? = nil) -> Never {
    if arguments.contains("--json"), let json {
        printJSON(json)
    } else {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
    exit(code)
}

struct SimpleError: Encodable { let error: String }

let command = arguments.first ?? "help"
let flags = Set(arguments.dropFirst().filter { $0.hasPrefix("--") })

switch command {

// MARK: version

case "version":
    print("muse-canvas-mac \(MuseVersion.current)")

// MARK: install

case "install":
    var source: String?
    var destination = Paths.defaultInstallRoot
    var dataDir: String?
    var verify = Installer.VerifyLevel.quick
    var dryRun = false
    var i = 1
    while i < arguments.count {
        switch arguments[i] {
        case "--source": source = arguments[i + 1]; i += 1
        case "--destination": destination = arguments[i + 1]; i += 1
        case "--data-directory": dataDir = arguments[i + 1]; i += 1
        case "--verify":
            let v = arguments[i + 1].lowercased(); i += 1
            verify = Installer.VerifyLevel(rawValue: v) ?? .quick
        case "--dry-run", "--detect-only": dryRun = true
        default: break
        }
        i += 1
    }
    guard let source else {
        fail("usage: muse install --source <extracted-package> [--destination <dir>] [--data-directory <dir>] [--verify off|quick|full] [--dry-run]", code: 2)
    }
    let installer = Installer(source: source, destination: destination,
                              explicitDataDir: dataDir, verify: verify)
    let plan = installer.plan()
    if dryRun {
        // M5 parity: machine-readable NEW/UPGRADE decision + every refusal.
        printJSON(plan)
        exit(plan.refusals.isEmpty ? 0 : 3)
    }
    guard plan.refusals.isEmpty else {
        fail(refusalRender(plan.refusals), code: 3, json: plan)
    }
    if !flags.contains("--yes") {
        if isatty(1) != 0 {
            print("will \(plan.mode == "NEW" ? "install to" : "upgrade") \(plan.destination)")
            print("data directory: \(plan.dataDirectory) (\(plan.dataDirResolution))")
            if plan.willStopRunningServices {
                print("the running MuseCanvas will be stopped first; in-flight generation may be interrupted")
            }
            print("proceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("cancelled; nothing was changed")
                exit(2)
            }
        }
    }
    do {
        let result = try await installer.install()
        if flags.contains("--json") {
            printJSON(result)
        } else {
            print("Installed \(result.fresh ? "(new)" : "(upgraded)") → \(plan.destination)")
            print("data: \(result.dataDirectory) (never touched by install or upgrade)")
            if result.preservedModelFiles > 0 { print("preserved \(result.preservedModelFiles) user-added model file(s)") }
            if result.verifiedFiles > 0 { print("verified \(result.verifiedFiles) file(s) against MANIFEST.sha256") }
        }
    } catch let refused as Installer.MuseInstallRefused {
        fail(refusalRender(refused.refusals), code: 3, json: refused)
    } catch {
        fail("\(error)", code: 1, json: SimpleError(error: "\(error)"))
    }

// MARK: start

case "start":
    let root = resolveInstall()
    let instance: Supervisor.Instance
    do {
        instance = try Supervisor.Instance.load(installRoot: root)
    } catch {
        fail("\(error)", code: 1, json: SimpleError(error: "\(error)"))
    }
    let supervisor = Supervisor(instance: instance)
    supervisor.onEvent = { event in
        if !flags.contains("--json") && !flags.contains("--quiet") {
            print("  \(event.unit): \(event.text)")
        }
    }
    do {
        try await supervisor.start()
        let canvas = instance.config.webURL
        if flags.contains("--json") {
            let snap = await supervisor.snapshot()
            printJSON(snap)
        } else {
            print("MuseCanvas is ready: \(canvas)")
        }
        if flags.contains("--watch") {
            // The watcher runs detached in its own process group: it survives
            // the terminal (or agent session) that started it, serves the
            // dashboard, and exits by itself once the stack is stopped.
            let logPath = instance.logsDirectory + "/watcher.log"
            do {
                // Absolute path: the daemon chdirs to /tmp before exec, and
                // a relative argv[0] would resolve against that.
                let selfPath = URL(fileURLWithPath: CommandLine.arguments[0])
                    .standardizedFileURL.path
                _ = try Daemonize.spawnDetached(
                    executable: selfPath,
                    arguments: ["_watch-daemon", "--install-root", root],
                    logPath: logPath)
                if !flags.contains("--json") {
                    print("watcher detached (logs: \(logPath)) — dashboard: http://127.0.0.1:\(StatusServer.defaultPort)")
                }
            } catch {
                if !flags.contains("--json") {
                    print("note: could not detach watcher (\(error)); continuing without it")
                }
            }
        }
        if !flags.contains("--no-browser") && !flags.contains("--json") {
            _ = await Shell.run("/usr/bin/open", [canvas])
        }
    } catch {
        fail("\(error)", code: 1, json: SimpleError(error: "\(error)"))
    }

// MARK: stop

case "stop":
    let root = resolveInstall()
    do {
        let instance = try Supervisor.Instance.load(installRoot: root)
        let supervisor = Supervisor(instance: instance)
        let stopped = await supervisor.stop()
        if flags.contains("--json") {
            printJSON(["stopped": stopped])
        } else {
            print(stopped.isEmpty
                  ? "Nothing was running. Data retained."
                  : "Stopped \(stopped.joined(separator: ", ")). Data retained.")
        }
        // Port release verification — DEPLOY acceptance step 7.
        let busy = await checkPortsFree(instance.config.allPorts)
        if !busy.isEmpty, !flags.contains("--json") {
            print("warning: still listening: \(busy.map { "port \($0.port) (pid \($0.pid))" }.joined(separator: ", "))")
        }
    } catch {
        fail("\(error)", code: 1, json: SimpleError(error: "\(error)"))
    }

// MARK: status

case "status":
    let root = resolveInstall()
    do {
        let instance = try Supervisor.Instance.load(installRoot: root)
        let supervisor = Supervisor(instance: instance)
        let snap = await supervisor.snapshot()
        if flags.contains("--json") {
            printJSON(snap)
        } else {
            print("stack: \(snap.stack) — \(snap.stackDetail)")
            for u in snap.units {
                print("  \(u.id.padding(toLength: 8, withPad: " ", startingAt: 0)) :\(u.port)  \(u.phase.padding(toLength: 12, withPad: " ", startingAt: 0)) \(u.pid.map { "pid \($0)  " } ?? "")\(u.detail)")
            }
            print("canvas: \(snap.canvasURL)")
        }
        exit(snap.stack == "running" ? 0 : snap.stack == "degraded" ? 0 : 1)
    } catch {
        fail("\(error)", code: 1, json: SimpleError(error: "\(error)"))
    }

// MARK: doctor

case "doctor":
    let root = resolveInstall()
    let fm = FileManager.default
    let report = await Doctor(installRoot: fm.fileExists(atPath: root + "/instance.json") ? root : nil).run()
    if flags.contains("--json") {
        printJSON(report)
    } else {
        let (p, f, u) = report.summary
        print("doctor: \(p) passed · \(f) failed · \(u) untested — overall: \(report.overall.rawValue)")
        for c in report.checks {
            let mark = c.verdict == .passed ? "✔" : c.verdict == .failed ? "✘" : "?"
            print("  [\(mark)] \(c.title)")
            print("        \(c.evidence)")
            if let remedy = c.remedy { print("        → \(remedy)") }
        }
        print("tri-state honesty: failed beats untested beats passed; \"untested\" is a result, not a gap to hide.")
    }
    exit(report.overall == .passed ? 0 : report.overall == .untested ? 2 : 1)

// MARK: open

case "open":
    let root = resolveInstall()
    do {
        let instance = try Supervisor.Instance.load(installRoot: root)
        _ = await Shell.run("/usr/bin/open", [instance.config.webURL])
        print("opened \(instance.config.webURL)")
    } catch {
        fail("\(error)", code: 1)
    }

// MARK: autostart (M18 — same plist label as upstream, both tools interoperate)

case "autostart":
    let op = arguments.dropFirst().first ?? "status"
    let plist = Paths.home + "/Library/LaunchAgents/xyz.fylmlgsb.musecanvas.plist"
    let fm = FileManager.default
    switch op {
    case "enable":
        try? fm.createDirectory(atPath: (plist as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let manage = (arguments.firstIndex(of: "--install-root").map { arguments[$0 + 1] } ?? Paths.defaultInstallRoot)
            + "/scripts/manage.sh"
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>xyz.fylmlgsb.musecanvas</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/bash</string>
            <string>\(manage)</string>
            <string>start</string>
            <string>--no-browser</string>
          </array>
          <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        try plistXML.write(toFile: plist, atomically: true, encoding: .utf8)
        _ = await Shell.run("/bin/launchctl", ["unload", plist])
        _ = await Shell.run("/bin/launchctl", ["load", plist])
        print("Auto-start at login enabled (LaunchAgent: xyz.fylmlgsb.musecanvas).")
    case "disable":
        _ = await Shell.run("/bin/launchctl", ["unload", plist])
        try? fm.removeItem(atPath: plist)
        print("Auto-start at login disabled.")
    default:
        print("Auto-start at login: \(fm.fileExists(atPath: plist) ? "enabled" : "disabled (default)")")
    }

// MARK: english (managed UI translation overlay)

case "english":
    let root = resolveInstall()
    let op = arguments.dropFirst().first ?? "status"
    do {
        let instance = try Supervisor.Instance.load(installRoot: root)
        switch op {
        case "on":
            _ = try EnglishOverlay.apply(installRoot: root, dataDirectory: instance.dataDirectory)
            print("English overlay ON — reload the canvas (⌘R). Turn off with `muse english off`; re-apply after payload upgrades.")
        case "off":
            _ = try EnglishOverlay.remove(installRoot: root, dataDirectory: instance.dataDirectory)
            print("English overlay OFF — web/index.html restored to pristine bytes, muse-english.js removed. Reload the canvas.")
        default:
            let state = EnglishOverlay.status(installRoot: root)
            print("English overlay: \(state.rawValue)")
            print("  modifies only web/config.js (pristine copy stashed in the data dir);")
            print("  `muse doctor` treats it as a declared deviation, never as tampering.")
        }
    } catch {
        fail("\(error)", code: 1, json: SimpleError(error: "\(error)"))
    }

// MARK: uninstall (guarded)

case "uninstall":
    let root = resolveInstall()
    let fm = FileManager.default
    guard fm.fileExists(atPath: root + "/instance.json") else {
        fail("No installation at \(root).", code: 1)
    }
    let purgeData = flags.contains("--purge-data")
    if let instance = try? Supervisor.Instance.load(installRoot: root) {
        let supervisor = Supervisor(instance: instance)
        _ = await supervisor.stop()
    } else {
        _ = await Shell.run("/bin/bash", [root + "/scripts/manage.sh", "stop"])
    }
    if !flags.contains("--yes"), isatty(0) != 0 {
        print("Delete the program folder \(root)? [y/N] ", terminator: "")
        guard readLine()?.lowercased() == "y" else { print("cancelled"); exit(2) }
    }
    try? fm.removeItem(atPath: root)
    try? fm.removeItem(atPath: Paths.home + "/Desktop/MuseCanvas.command")
    print("Program folder removed. Data retained.")
    if purgeData {
        let dataDir = Paths.defaultDataDirectory
        print("Deleting data at \(dataDir) — this cannot be undone. [type DELETE] ", terminator: "")
        guard readLine() == "DELETE" else { print("data kept"); exit(0) }
        try? fm.removeItem(atPath: dataDir)
        print("Data deleted.")
    } else {
        print("Your data (settings, workspace, merged videos) is kept at \(Paths.defaultDataDirectory); delete it yourself when you're sure.")
    }

// MARK: _watch-daemon (internal: detached dashboard/watcher process)

case "_watch-daemon":
    let root = resolveInstall()
    do {
        let instance = try Supervisor.Instance.load(installRoot: root)
        let supervisor = Supervisor(instance: instance)
        let server = StatusServer(supervisor: supervisor)
        try server.start()
        // Self-terminate once the stack is gone (no records, no listeners).
        Task.detached {
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let records = supervisor.readRecordsForDaemon()
                if records.isEmpty {
                    let anyPort = await instance.config.allPorts.asyncFirstListener()
                    if anyPort == nil { exit(0) }
                }
            }
        }
        dispatchMain()
    } catch {
        fail("watch-daemon: \(error)", code: 1)
    }

// MARK: help / default

default:
    print("""
    muse — Mac supervisor for MuseCanvas (ports, formats and env contract
    are upstream-compatible; see docs/STATE-MACHINES.md)

    usage:
      muse install --source <extracted-package> [--destination <dir>]
                   [--data-directory <dir>] [--verify off|quick|full]
                   [--dry-run] [--yes]
      muse start [--watch] [--no-browser]     boot the five services
      muse stop                                stop them (data kept)
      muse status [--json]                     per-unit phases + evidence
      muse doctor [--json]                     passed / failed / untested
      muse open                                open the canvas in a browser
      muse autostart enable|disable|status     login LaunchAgent (opt-in)\n      muse english on|off|status                fill the canvas UI's English gaps
      muse uninstall [--purge-data]            guarded; data kept by default
      muse version

    common flags: --install-root <dir> (default ~/MuseCanvas), --json

    exit codes: 0 done · 1 failed · 2 cancelled · 3 refused (nothing changed)
    """ +
    (command == "help" ? "" : "\nunknown command: \(command)"))
    exit(command == "help" ? 0 : 2)
}

// MARK: helpers

func refusalRender(_ refusals: [String]) -> String {
    "Refused — nothing was changed:\n" + refusals.map { "  - \($0)" }.joined(separator: "\n")
}

func checkPortsFree(_ ports: [Int]) async -> [(port: Int, pid: Int)] {
    var busy: [(Int, Int)] = []
    for port in ports {
        if let pid = await Shell.portListeners(port).first {
            busy.append((port, pid))
        }
    }
    return busy.map { (port: $0.0, pid: $0.1) }
}

enum MuseVersion {
    static let current = "0.1.0"
}

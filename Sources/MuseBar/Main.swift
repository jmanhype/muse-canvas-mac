import AppKit
import SwiftUI
import MuseCore
import MuseKit

/// MuseBar — the ambient face of the supervisor: one menu bar item that
/// always tells the truth about the stack, derived from the same snapshot
/// the CLI and dashboard serve. It never launches at login by itself and
/// never touches accounts.
@main
struct MuseBarApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var model = BarModel()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        Task { await model.refresh() }   // first reading immediately, then poll
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.model.refresh() }
            self.updateTitle()
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch model.phaseKey {
        case "running": symbol = "checkmark.circle.fill"
        case "degraded": symbol = "exclamationmark.triangle.fill"
        case "failed": symbol = "xmark.octagon.fill"
        case "booting", "stopping": symbol = "arrow.triangle.2.circlepath"
        default: symbol = "moon.zzz"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.phaseKey)
        button.toolTip = "MuseCanvas: \(model.phaseKey)"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let phaseItem = NSMenuItem(
            title: "MuseCanvas — \(model.phaseKey)",
            action: nil, keyEquivalent: "")
        phaseItem.isEnabled = false
        menu.addItem(phaseItem)
        menu.addItem(.separator())

        for unit in model.units {
            let mark: String
            switch Supervisor.phaseKeyPrefix(unit.phase) {
            case "ready": mark = "●"
            case "degraded": mark = "◐"
            case "failed": mark = "✕"
            case "starting", "stopping": mark = "◌"
            default: mark = "○"
            }
            let item = NSMenuItem(title: "\(mark)  \(unit.title)  ·\(unit.phase)",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(withTitle: "Open canvas", action: #selector(openCanvas), keyEquivalent: "c")
        menu.addItem(withTitle: "Open dashboard…", action: #selector(openDashboard), keyEquivalent: "d")
        menu.addItem(withTitle: "Start", action: #selector(start), keyEquivalent: "s")
        menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "x")
        menu.addItem(withTitle: "Run doctor", action: #selector(runDoctor), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal data folder", action: #selector(revealData), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal logs", action: #selector(revealLogs), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MuseBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    // MARK: actions — same binaries the CLI uses, nothing bespoke

    @objc private func openCanvas() { shell("/usr/bin/open", [model.canvasURL]) }
    @objc private func openDashboard() { shell("/usr/bin/open", ["http://127.0.0.1:17370"]) }
    @objc private func start() { runMuse(["start", "--no-browser"]) }
    @objc private func stop() { runMuse(["stop"]) }
    @objc private func runDoctor() { runMuse(["doctor"]) }
    @objc private func revealData() {
        if let dir = model.dataDirectory {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            shell("/usr/bin/open", ["-R", dir])
        }
    }
    @objc private func revealLogs() {
        if let dir = model.logsDirectory {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            shell("/usr/bin/open", ["-R", dir])
        }
    }

    private func runMuse(_ args: [String]) {
        let selfPath = CommandLine.arguments[0]
        shell(selfPath, args)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { await self.model.refresh() }
            self.updateTitle()
            self.rebuildMenu()
        }
    }

    private func shell(_ executable: String, _ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}

/// Reads the live watcher if present (status.json), else reconciles from
/// disk directly — the menu bar works whether or not `muse start --watch`
/// is running.
@MainActor
final class BarModel {
    var phaseKey = "cold"
    var detail = ""
    var units: [Supervisor.UnitStatus] = []
    var canvasURL = "http://localhost:3000"
    var dataDirectory: String?
    var logsDirectory: String?

    func refresh() async {
        let root = Paths.defaultInstallRoot
        guard let instance = try? Supervisor.Instance.load(installRoot: root) else {
            phaseKey = "not installed"
            units = []
            return
        }
        dataDirectory = instance.dataDirectory
        logsDirectory = instance.logsDirectory
        canvasURL = instance.config.webURL

        // Prefer the watcher's live view; fall back to on-disk truth.
        if let snapshot = await fetchWatcherSnapshot(port: StatusServer.defaultPort) {
            apply(snapshot)
            return
        }
        let supervisor = Supervisor(instance: instance)
        apply(await supervisor.snapshot())
    }

    private func apply(_ snap: Supervisor.Snapshot) {
        phaseKey = snap.stack.components(separatedBy: ":").first ?? snap.stack
        detail = snap.stackDetail
        units = snap.units
    }

    private nonisolated func fetchWatcherSnapshot(port: Int) async -> Supervisor.Snapshot? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status.json")!)
        request.timeoutInterval = 2
        let session = URLSession(configuration: .ephemeralNoProxy)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Supervisor.Snapshot.self, from: data)
    }
}

extension Supervisor {
    static func phaseKeyPrefix(_ phase: String) -> String {
        String(phase.split(separator: ":").first ?? Substring(phase))
    }
}

import Foundation
import MuseCore
import Network

/// Loopback status server: the one place humans (dashboard), agents
/// (`status.json` / `doctor.json`), and the menu bar app all read the same
/// truth. Binds 127.0.0.1 only; never includes secrets; actions shell out
/// to the `muse` binary itself so server and CLI cannot drift apart.
public final class StatusServer: @unchecked Sendable {

    public static let defaultPort = 17370

    public let supervisor: Supervisor
    public let port: Int
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "muse.status-server")

    public var dashboardURL: String { "http://127.0.0.1:\(port)" }

    public init(supervisor: Supervisor, port: Int = StatusServer.defaultPort) {
        self.supervisor = supervisor
        self.port = port
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only — same rule as every MuseCanvas service.
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? DispatchQueue(label: "muse.status-conn"))
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write("status-server: \(error)\n".data(using: .utf8)!)
            }
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
    }

    // MARK: - HTTP plumbing (GET/POST is all a status page needs)

    private func handle(_ connection: NWConnection) {
        receiveRequest(connection, buffer: Data()) { request in
            guard let request else {
                connection.cancel()
                return
            }
            let parts = request.split(separator: "\r\n", maxSplits: 1)
            let requestLine = parts.first.map(String.init) ?? ""
            let tokens = requestLine.split(separator: " ")
            guard tokens.count >= 2 else {
                self.respond(connection, status: "400 Bad Request", body: Data("bad request".utf8), contentType: "text/plain")
                return
            }
            let method = String(tokens[0]), path = String(tokens[1])
            Task { await self.route(connection, method: method, path: path) }
        }
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data,
                                done: @escaping (String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let head = String(data: buffer, encoding: .utf8), head.contains("\r\n\r\n") {
                done(head)
            } else if complete || error != nil {
                done(nil)
            } else if buffer.count > 1_048_576 {
                done(nil)
            } else {
                self.receiveRequest(connection, buffer: buffer, done: done)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data, contentType: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let payload = head.data(using: .utf8)! + body
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routes

    private func route(_ connection: NWConnection, method: String, path rawPath: String) async {
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        func json(_ object: some Encodable) -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            return (try? encoder.encode(object)).map { Data($0) } ?? Data("{}".utf8)
        }
        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(connection, status: "200 OK", body: Self.dashboardHTML, contentType: "text/html; charset=utf-8")
        case ("GET", "/status.json"):
            let snapshot = await supervisor.snapshot(dashboardURL: dashboardURL)
            respond(connection, status: "200 OK", body: json(snapshot), contentType: "application/json")
        case ("GET", "/doctor.json"):
            let report = await Doctor(installRoot: supervisor.instance.installRoot).run()
            respond(connection, status: "200 OK", body: json(report), contentType: "application/json")
        case ("GET", "/healthz"):
            respond(connection, status: "200 OK", body: Data("ok".utf8), contentType: "text/plain")
        case ("POST", "/action/start"):
            let out = await self.runMuse(["start", "--no-browser"])
            respond(connection, status: "200 OK", body: json(out), contentType: "application/json")
        case ("POST", "/action/stop"):
            let out = await self.runMuse(["stop"])
            respond(connection, status: "200 OK", body: json(out), contentType: "application/json")
        case ("POST", "/action/doctor"):
            _ = await Doctor(installRoot: supervisor.instance.installRoot).run()
            respond(connection, status: "200 OK", body: json(["ok": true]), contentType: "application/json")
        case ("POST", "/action/open-canvas"):
            await self.open(urlString: supervisor.instance.config.webURL)
            respond(connection, status: "200 OK", body: json(["ok": true]), contentType: "application/json")
        case ("POST", "/action/open-dashboard"):
            await self.open(urlString: dashboardURL)
            respond(connection, status: "200 OK", body: json(["ok": true]), contentType: "application/json")
        case ("POST", "/action/reveal-data"):
            await self.reveal(supervisor.instance.dataDirectory)
            respond(connection, status: "200 OK", body: json(["ok": true]), contentType: "application/json")
        case ("POST", "/action/reveal-logs"):
            await self.reveal(supervisor.instance.logsDirectory)
            respond(connection, status: "200 OK", body: json(["ok": true]), contentType: "application/json")
        default:
            respond(connection, status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain")
        }
    }

    struct ActionOutcome: Encodable {
        let ok: Bool
        let exitCode: Int32
        let output: String
    }

    /// Actions run this very binary in a fresh process — one code path for
    /// humans, agents and buttons.
    func runMuse(_ arguments: [String]) async -> ActionOutcome {
        let selfPath = CommandLine.arguments[0]
        let result = await Shell.run(selfPath, arguments)
        return ActionOutcome(ok: result.success, exitCode: result.exitCode,
                             output: (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func open(urlString: String) async {
        _ = await Shell.run("/usr/bin/open", [urlString])
    }

    func reveal(_ path: String) async {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = await Shell.run("/usr/bin/open", ["-R", path])
    }

    // MARK: - Dashboard asset

    static let dashboardHTML: Data = {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "status", withExtension: "html")
            ?? bundle.url(forResource: "status", withExtension: "html", subdirectory: "web")
            ?? bundle.url(forResource: "status", withExtension: "html", subdirectory: "Resources/web")
        guard let url, let data = try? Data(contentsOf: url) else {
            return Data(#"<!doctype html><title>MuseCanvas</title><p>dashboard asset missing"#.utf8)
        }
        return data
    }()
}

import Foundation
import MuseCore

/// Managed English overlay for the canvas UI (upstream's en-US locale is
/// partial: homepage cards, the Agent panel, and category labels fall back
/// to Chinese).
///
/// Mechanism — chosen against how the payload actually behaves:
/// - The web service **generates `/config.js` at request time** (it injects
///   the pool URL and keys), so the on-disk config.js is a template and
///   editing it does nothing. Verified live during dogfood.
/// - `/index.html` is served verbatim from disk, and arbitrary files under
///   `web/` are served statically.
///
/// Therefore the overlay is exactly two files, both managed:
/// 1. `web/muse-english.js` — NEW file (not integrity-tracked) with the
///    runtime translation layer.
/// 2. `web/index.html` — one script tag + marker comment injected before
///   `</body>`. The pristine file is stashed; `remove()` restores it
///   byte-perfect. The doctor treats this single file as a *declared*
///   deviation while the overlay is on; any other mismatch still fails.
///
/// `apply()` is idempotent; upstream upgrades replace `web/` (removing the
/// overlay) — re-run `muse english on`.
public enum EnglishOverlay {

    static let marker = "<!-- muse-canvas-mac:english-overlay -->"
    static let injection = "<script src=\"/muse-english.js\"></script>"

    public enum State: String, Codable, Sendable {
        case on, off
    }

    static var overlayScript: String {
        guard let url = Bundle.module.url(forResource: "english-overlay", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* overlay asset missing */"
        }
        return source
    }

    static func indexHTMLPath(_ installRoot: String) -> String {
        installRoot + "/web/index.html"
    }

    static func overlayJSPath(_ installRoot: String) -> String {
        installRoot + "/web/muse-english.js"
    }

    static func pristinePath(_ dataDirectory: String) -> String {
        dataDirectory + "/english-overlay/index.html.pristine"
    }

    // MARK: - Apply / remove

    @discardableResult
    public static func apply(installRoot: String, dataDirectory: String) throws -> State {
        let fm = FileManager.default
        let indexURL = URL(fileURLWithPath: indexHTMLPath(installRoot))
        guard fm.fileExists(atPath: indexURL.path) else {
            throw OverlayError.missing(indexURL.path)
        }
        var html = try String(contentsOf: indexURL, encoding: .utf8)

        // Stash the pristine index.html exactly once, before any change.
        let pristine = pristinePath(dataDirectory)
        if !fm.fileExists(atPath: pristine), !html.contains(marker) {
            try fm.createDirectory(atPath: (pristine as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try html.write(toFile: pristine, atomically: true, encoding: .utf8)
        }

        // Idempotent injection: replace the marked block, or insert before </body>.
        let block = marker + "\n  " + injection
        if let range = html.range(of: marker + "\n  " + injection) {
            html.replaceSubrange(range, with: block)
        } else if let range = html.range(of: marker) {
            // marker present but block shape changed — rebuild around marker line
            if let newline = html.range(of: "\n", range: range.lowerBound..<html.endIndex) {
                html.replaceSubrange(range.lowerBound..<newline.upperBound, with: block + "\n")
            }
        } else if let bodyEnd = html.range(of: "</body>") {
            html.replaceSubrange(bodyEnd, with: "  " + block + "\n  " + "</body>")
        } else {
            html += block
        }
        try html.write(toFile: indexURL.path, atomically: true, encoding: .utf8)

        // The overlay script itself is a plain new static file.
        try overlayScript.write(toFile: overlayJSPath(installRoot), atomically: true, encoding: .utf8)
        return .on
    }

    @discardableResult
    public static func remove(installRoot: String, dataDirectory: String) throws -> State {
        let fm = FileManager.default
        let indexURL = URL(fileURLWithPath: indexHTMLPath(installRoot))
        guard fm.fileExists(atPath: indexURL.path) else {
            throw OverlayError.missing(indexURL.path)
        }
        let pristine = pristinePath(dataDirectory)
        if fm.fileExists(atPath: pristine),
           let original = try? String(contentsOf: URL(fileURLWithPath: pristine), encoding: .utf8) {
            try original.write(toFile: indexURL.path, atomically: true, encoding: .utf8)
        } else {
            // Fallback: strip the marked block even without a stash.
            var html = try String(contentsOf: indexURL, encoding: .utf8)
            for piece in [marker + "\n  " + injection + "\n  ", marker + "\n", injection + "\n  "] {
                html = html.replacingOccurrences(of: piece, with: "")
            }
            try html.write(toFile: indexURL.path, atomically: true, encoding: .utf8)
        }
        try? fm.removeItem(atPath: overlayJSPath(installRoot))
        return .off
    }

    public static func status(installRoot: String) -> State {
        let fm = FileManager.default
        guard var html = try? String(contentsOf: URL(fileURLWithPath: indexHTMLPath(installRoot)), encoding: .utf8) else {
            return .off
        }
        html = html as String
        return html.contains(marker) && fm.fileExists(atPath: overlayJSPath(installRoot)) ? .on : .off
    }

    /// True when an integrity mismatch on `file` is expected (overlay on).
    /// The one declared file is `web/index.html` — and never anything else.
    public static func isDeclaredDeviation(file: String, installRoot: String) -> Bool {
        status(installRoot: installRoot) == .on && file == "web/index.html"
    }

    public enum OverlayError: Error, CustomStringConvertible {
        case missing(String)
        public var description: String {
            switch self {
            case .missing(let path):
                return "\(path) not found — is the payload installed?"
            }
        }
    }
}

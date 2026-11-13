import Foundation
import Testing
@testable import MuseKit

/// The English overlay is a *managed* modification of exactly one
/// manifest-tracked file (web/index.html) plus one new untracked file
/// (web/muse-english.js). These tests pin the management guarantees:
/// idempotent apply, byte-perfect restore, and the declared-deviation rule
/// the doctor relies on.
struct EnglishOverlayTests {

    func makeInstall() throws -> (root: String, data: String, original: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-overlay-\(UUID().uuidString)")
        let root = base.appendingPathComponent("MuseCanvas").path
        let data = base.appendingPathComponent("data").path
        try FileManager.default.createDirectory(
            atPath: root + "/web", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: data, withIntermediateDirectories: true)
        let original = """
        <!doctype html>
        <html>
          <head><script src="/config.js"></script></head>
          <body><div id="root"></div></body>
        </html>
        """
        try original.write(toFile: root + "/web/index.html", atomically: true, encoding: .utf8)
        return (root, data, original)
    }

    @Test func applyInjectsScriptAndNewFileOnly() throws {
        let (root, data, _) = try makeInstall()
        _ = try EnglishOverlay.apply(installRoot: root, dataDirectory: data)
        let html = try String(contentsOf: URL(fileURLWithPath: root + "/web/index.html"), encoding: .utf8)
        #expect(html.contains(EnglishOverlay.marker))
        #expect(html.contains("<script src=\"/muse-english.js\"></script>"))
        #expect(html.contains("</body>"))                       // still valid HTML
        #expect(FileManager.default.fileExists(atPath: root + "/web/muse-english.js"))
        // Idempotent: second apply adds exactly zero new markers.
        _ = try EnglishOverlay.apply(installRoot: root, dataDirectory: data)
        let again = try String(contentsOf: URL(fileURLWithPath: root + "/web/index.html"), encoding: .utf8)
        #expect(again == html)
        #expect(again.components(separatedBy: EnglishOverlay.marker).count - 1 == 1)
    }

    @Test func removeRestoresPristineBytesExactly() throws {
        let (root, data, original) = try makeInstall()
        _ = try EnglishOverlay.apply(installRoot: root, dataDirectory: data)
        #expect(EnglishOverlay.status(installRoot: root) == .on)
        _ = try EnglishOverlay.remove(installRoot: root, dataDirectory: data)
        let restored = try String(contentsOf: URL(fileURLWithPath: root + "/web/index.html"), encoding: .utf8)
        #expect(restored == original)                           // byte-perfect
        #expect(!FileManager.default.fileExists(atPath: root + "/web/muse-english.js"))
        #expect(EnglishOverlay.status(installRoot: root) == .off)
        // Removing again is a harmless no-op.
        _ = try EnglishOverlay.remove(installRoot: root, dataDirectory: data)
        #expect(try String(contentsOf: URL(fileURLWithPath: root + "/web/index.html"), encoding: .utf8) == original)
    }

    @Test func declaredDeviationIsOnlyIndexHTMLWhileOn() throws {
        let (root, data, _) = try makeInstall()
        #expect(!EnglishOverlay.isDeclaredDeviation(file: "web/index.html", installRoot: root))
        _ = try EnglishOverlay.apply(installRoot: root, dataDirectory: data)
        #expect(EnglishOverlay.isDeclaredDeviation(file: "web/index.html", installRoot: root))
        #expect(!EnglishOverlay.isDeclaredDeviation(file: "web/config.js", installRoot: root))
        #expect(!EnglishOverlay.isDeclaredDeviation(file: "node/node", installRoot: root))
        #expect(!EnglishOverlay.isDeclaredDeviation(file: "web/muse-english.js", installRoot: root))
    }

    @Test func overlayScriptTranslatesUINeverContent() {
        let script = EnglishOverlay.overlayScript
        #expect(script.contains("并行生成"))
        #expect(script.contains("切换 / 添加模型"))
        #expect(script.contains("PHRASES.hasOwnProperty(t)"))   // exact-match design
        #expect(script.contains("SKIP_TAGS"))
        // Author names and template content must NOT appear in the map.
        #expect(!script.contains("宝玉"))
        #expect(!script.contains("苹果风格海报"))
    }
}

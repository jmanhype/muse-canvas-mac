/// Data-directory resolution — upstream's most consequential *implicit*
/// machine. Buried in Install.ps1 §5b: explicit flag wins → else inherit
/// from previous instance.json → else derive from the target user's
/// profile. Upgrades that accidentally fell through to "derive" would
/// silently point a "new version" at a fresh empty data dir, which looks
/// exactly like "upgrade deleted all my work". Naming the three cases is
/// the fix.
public enum DataDirectoryResolution: Equatable, Sendable {
    /// `--data-dir` / `-DataDirectory` given: use it verbatim.
    case explicit(String)
    /// Upgrade: previous instance.json pinned a directory; inherit it.
    case inheritedFromInstance(String)
    /// Fresh install: derive the platform default for the target user.
    case derivedDefault(String)

    public var path: String {
        switch self {
        case .explicit(let p), .inheritedFromInstance(let p), .derivedDefault(let p):
            return p
        }
    }

    /// The resolution rules, as one pure function of the inputs.
    ///
    /// - Parameters:
    ///   - explicit: user-supplied path, if any. Highest precedence.
    ///   - previous: the pinned directory of an existing install, if any.
    ///     Wins over derivation so upgrades keep their data.
    ///   - default: platform default (mac:
    ///     `~/Library/Application Support/MuseCanvas`).
    public static func resolve(
        explicit: String?,
        previous: String?,
        default defaultValue: String
    ) -> DataDirectoryResolution {
        if let explicit, !explicit.isEmpty { return .explicit(explicit) }
        if let previous, !previous.isEmpty { return .inheritedFromInstance(previous) }
        return .derivedDefault(defaultValue)
    }
}

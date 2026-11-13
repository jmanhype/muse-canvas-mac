/// The install / upgrade machine.
///
/// `Install.ps1` upstream runs this machine as straight-line script with
/// `$hadInstall` / `$prevDataDirectory` carrying the "fresh vs upgrade"
/// identity across steps, and rollback logic in one `try/catch`. It works,
/// but every safety property lives only in the reader's head. This type
/// names the steps, and for each step names what a failure there means —
/// including whether anything was mutated and what must be rolled back.
public enum InstallStep: String, Codable, CaseIterable, Sendable {
    /// Verify the payload tree has every required file. Nothing is touched
    /// before this passes (upstream rule: "Nothing was changed").
    case validateSource
    /// Refuse protected destinations and foreign content.
    case classifyDestination
    /// Copy payload to `<dest>.new-<stamp>` beside the destination, then
    /// verify the *staged* copy — a broken source changes nothing.
    case stageAndVerify
    /// Carry over user-added files that live inside the program folder
    /// (upstream: `models\` extras).
    case preserveUserFiles
    /// Stop the previous install's processes before the swap.
    case stopExisting
    /// Atomic-ish directory swap with rollback to `<dest>.old-<stamp>`.
    case swapDirectories
    /// Write `instance.json` pinning install dir, data dir, user, version —
    /// so every later Start/Stop/Status resolves the same data directory
    /// regardless of who runs it.
    case pinInstance
    /// Desktop shortcut / login autostart (mac: .app bundle + LaunchAgent).
    case configureLaunch
}

/// What a failure at a given step requires the engine to do before reporting.
public enum RollbackPlan: Equatable, Sendable {
    /// Failure predated any mutation — report and stop.
    case noneNeeded
    /// Staging directory exists; remove it. Destination untouched.
    case removeStaging
    /// Old directory was moved aside; move it back before reporting.
    case restorePreviousInstall
}

public struct InstallFailure: Equatable, Sendable {
    public let step: InstallStep
    public let reason: String
    public let rollback: RollbackPlan
    public init(step: InstallStep, reason: String, rollback: RollbackPlan) {
        self.step = step
        self.reason = reason
        self.rollback = rollback
    }
}

public struct InstallMachine: Sendable {

    /// Outcome handed to callers / the CLI / the dashboard.
    public enum Outcome: Equatable, Sendable {
        /// `fresh` distinguishes new install from in-place upgrade.
        case installed(fresh: Bool, dataDirectory: DataDirectoryResolution)
        case failed(InstallFailure)
    }

    /// The ordered steps. Engines must execute them in this order; tests
    /// assert the order and the failure/rollback table below.
    public static let orderedSteps: [InstallStep] = [
        .validateSource, .classifyDestination, .stageAndVerify, .preserveUserFiles,
        .stopExisting, .swapDirectories, .pinInstance, .configureLaunch,
    ]

    /// For each step: the rollback obligation if it fails *at that step*.
    /// This is the table upstream implements with scattered `throw`s and one
    /// `catch`. Steps before `stageAndVerify` mutate nothing; `swapDirectories`
    /// is the only step that can leave a half-swapped destination.
    public static func rollbackPlan(onFailureAt step: InstallStep) -> RollbackPlan {
        switch step {
        case .validateSource, .classifyDestination:
            return .noneNeeded
        case .stageAndVerify, .preserveUserFiles, .stopExisting:
            return .removeStaging
        case .swapDirectories:
            return .restorePreviousInstall
        case .pinInstance, .configureLaunch:
            // The swap already succeeded; a failure here leaves the new tree
            // installed. Not a rollback situation — report, remedy manually.
            return .noneNeeded
        }
    }

    /// Whether a step may mutate the destination at all. Asserted in tests:
    /// validate/classify must be side-effect free.
    public static func mutatesDestination(_ step: InstallStep) -> Bool {
        switch step {
        case .validateSource, .classifyDestination: return false
        default: return true
        }
    }

    public init() {}
}

/// How the previous installation's identity is carried (or not).
public enum PriorInstall: Equatable, Sendable {
    case none
    case install(dataDirectory: String?)
}

/// Classification of the destination folder — the check that lets the
/// installer refuse to touch a folder that "already contains other files
/// and is not a MuseCanvas installation".
public enum DestinationClassification: Equatable, Sendable {
    case missing
    case emptyDirectory
    case existingInstall(version: String?)
    case foreignContent(entries: Int)
    case protectedLocation
}

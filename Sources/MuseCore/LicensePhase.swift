/// License / update-check machine.
///
/// This exists because of a shipped bug, quoted from the 0.21.2 notes:
/// at startup, a transient failure to reach the license server would latch
/// a permanent "授权异常" state that blocked generation until restart or a
/// 6-hour timer. The fix: unreachable ⇒ retry every minute, auto-recover,
/// never block. The invariant that fell out of that incident is encoded
/// here as a function with tests: **only `.revoked` may block generation;
/// `.unreachable` never does.**
public enum LicensePhase: Equatable, Sendable {
    /// Fresh start; no check has completed yet. Does not block.
    case unknown
    /// Server reachable and this install is allowed. Does not block.
    case ok
    /// Server unreachable; retrying. Does NOT block — transient by
    /// contract. `retries` feeds the UI ("still unreachable after N
    /// tries") without changing behavior.
    case unreachable(retries: Int)
    /// Server reachable and said no. The ONLY blocking state.
    case revoked(reason: String)

    public enum Event: Equatable, Sendable {
        case checkSucceeded
        case checkFailed
        case revokedDetected(reason: String)
    }

    /// Pure reducer. Retry *cadence* is engine policy (upstream: 60s);
    /// retry *outcome* is what matters here.
    public static func step(_ phase: LicensePhase, on event: Event) -> LicensePhase {
        switch (phase, event) {
        case (_, .checkSucceeded):
            return .ok
        case (_, .checkFailed):
            if case .unreachable(let n) = phase { return .unreachable(retries: n + 1) }
            return .unreachable(retries: 1)
        case (_, .revokedDetected(let reason)):
            return .revoked(reason: reason)
        }
    }

    /// The incident invariant, as an assertion the compiler can check at
    /// test time and the UI can render without re-deriving.
    public var blocksGeneration: Bool {
        if case .revoked = self { return true }
        return false
    }
}

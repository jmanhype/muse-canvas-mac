/// The per-service lifecycle machine.
///
/// Upstream MuseCanvas implied this machine inside Manage scripts and inside
/// closed binaries: services were "started", "healthy", or silently dead, and
/// the 0.21.x release notes are a history of transition bugs (latched failure
/// states, tasks waiting ~4 minutes for a timeout that should have been ~90s,
/// "已连接" shown as proof of health). This type makes every one of those
/// transitions explicit, legal or rejected — nothing is silent.
///
/// The machine is pure: `step` never performs I/O and never reads a clock.
/// The engine (MuseKit.Supervisor) owns time and side effects, and feeds
/// events in. That separation is what makes the transition table testable
/// without launching anything.
public struct UnitMachine: Sendable, Equatable {

    // MARK: Phase

    /// Lifecycle phase of one supervised service ("unit").
    public enum Phase: Equatable, Sendable {
        /// Not running and not expected to run.
        case stopped
        /// Spawn requested; waiting for the health probe to pass.
        case starting(elapsedSeconds: Int)
        /// Running and answering health probes. `streak` counts consecutive
        /// successes so callers can distinguish "just came up" from "stable".
        case ready(streak: Int)
        /// Still running, but probes are failing. This is the *transient*
        /// state the 0.21.2 license fix formalized: degraded services retry
        /// and auto-recover; they are not failed.
        case degraded(consecutiveFailures: Int, lastReason: String)
        /// Stop requested; waiting for the process to exit (SIGTERM sent).
        case stopping
        /// Terminal for this attempt. `startRequested` is always a legal edge
        /// out of here — retry is never more than one event away.
        case failed(reason: FailureReason)
    }

    // MARK: Failure reasons — surfaced, never collapsed

    /// Why a unit failed. Upstream's release notes repeatedly fixed bugs
    /// caused by collapsing these into one "failed" boolean; each distinct
    /// cause stays distinct here so the UI, logs and doctor can tell the
    /// truth ("豆包的原话", the real HTTP status, the real exit code).
    public enum FailureReason: Equatable, Sendable {
        case spawnFailed(String)
        case startTimeout(seconds: Int)
        case exitedUnexpectedly(code: Int32?)
        case healthCollapsed(lastReason: String)
        case portConflict(port: Int)
    }

    // MARK: Events

    public enum Event: Equatable, Sendable {
        /// Engine intends to spawn the process.
        case startRequested
        /// Process spawned successfully (engine side effect happened).
        case processSpawned
        /// Engine failed to spawn.
        case spawnFailed(String)
        /// Health probe answered OK.
        case probeSucceeded
        /// Health probe answered non-OK (engine passes the real reason:
        /// HTTP status, connection error, timeout — never a canned string).
        case probeFailed(reason: String)
        /// A second elapsed while in `.starting` (engine tick).
        case startingTick
        /// The observed process exited.
        case processExited(code: Int32?)
        /// User or supervisor requested a stop (engine sends SIGTERM).
        case stopRequested
        /// Graceful stop window elapsed (engine escalates to SIGKILL).
        case stopTimedOut
    }

    // MARK: Policy

    /// Tunables that shape transitions without changing the machine's shape.
    /// Upstream shipped several of these as hardcoded constants that had to
    /// be *patched* per release (90s vs 4min video timeouts). Here they are
    /// data.
    public struct Policy: Equatable, Sendable {
        /// How long `.starting` may last before `.failed(.startTimeout)`.
        public var startTimeoutSeconds: Int
        /// Consecutive probe failures in `.ready`/`.degraded` before
        /// `.failed(.healthCollapsed)`.
        public var maxConsecutiveFailures: Int
        public init(startTimeoutSeconds: Int = 30, maxConsecutiveFailures: Int = 3) {
            self.startTimeoutSeconds = startTimeoutSeconds
            self.maxConsecutiveFailures = maxConsecutiveFailures
        }
        public static let standard = Policy()
        /// Pool-style policy mirroring upstream's faster no-response
        /// detection (0.21.1: ~90s fail instead of ~4min).
        public static let fastFail = Policy(startTimeoutSeconds: 90, maxConsecutiveFailures: 2)
    }

    // MARK: Transition

    /// The result of one event. `accepted == false` is *not an error* — it is
    /// a rejected edge, returned to the caller with a note, so the engine can
    /// log "ignored probeFailed while stopped" instead of corrupting state.
    public struct Transition: Equatable, Sendable {
        public let from: Phase
        public let to: Phase
        public let accepted: Bool
        public let note: String?

        static func accepted(_ from: Phase, _ to: Phase, note: String? = nil) -> Transition {
            Transition(from: from, to: to, accepted: true, note: note)
        }
        static func rejected(_ phase: Phase, why: String) -> Transition {
            Transition(from: phase, to: phase, accepted: false, note: why)
        }
    }

    public let policy: Policy

    public init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// Pure transition function. Exhaustive over `(Phase, Event)` — the
    /// compiler enforces that every pairing was *decided*, which is the
    /// entire point of extracting this from shell scripts.
    public func step(_ phase: Phase, on event: Event) -> Transition {
        switch (phase, event) {

        // -- from .stopped ------------------------------------------------
        case (.stopped, .startRequested):
            return .accepted(phase, .starting(elapsedSeconds: 0), note: "engine: spawn process")
        case (.stopped, .spawnFailed(let reason)):
            return .accepted(phase, .failed(reason: .spawnFailed(reason)))
        case (.stopped, .processExited):
            return .rejected(phase, why: "exit reported while stopped (reaped late?)")
        case (.stopped, .stopRequested):
            return .rejected(phase, why: "already stopped")
        case (.stopped, _):
            return .rejected(phase, why: "event not meaningful while stopped")

        // -- from .starting -----------------------------------------------
        case (.starting, .processSpawned):
            return .accepted(phase, phase, note: "spawned; probing")
        case (.starting(let e), .startingTick):
            let next = e + 1
            if next >= policy.startTimeoutSeconds {
                return .accepted(phase, .failed(reason: .startTimeout(seconds: policy.startTimeoutSeconds)),
                                 note: "engine: kill process")
            }
            return .accepted(phase, .starting(elapsedSeconds: next))
        case (.starting, .probeSucceeded):
            return .accepted(phase, .ready(streak: 1))
        case (.starting, .probeFailed):
            return .accepted(phase, .starting(elapsedSeconds: phase.elapsedSecondsOrZero),
                             note: "probe failing during startup is not yet fatal")
        case (.starting, .processExited(let code)):
            return .accepted(phase, .failed(reason: .exitedUnexpectedly(code: code)))
        case (.starting, .stopRequested):
            return .accepted(phase, .stopping, note: "engine: SIGTERM")
        case (.starting, .spawnFailed(let reason)):
            return .accepted(phase, .failed(reason: .spawnFailed(reason)))

        // -- from .ready --------------------------------------------------
        case (.ready(let streak), .probeSucceeded):
            return .accepted(phase, .ready(streak: streak + 1))
        case (.ready, .probeFailed(let reason)):
            return .accepted(phase, .degraded(consecutiveFailures: 1, lastReason: reason),
                             note: "transient: retry, do not block")
        case (.ready, .stopRequested):
            return .accepted(phase, .stopping, note: "engine: SIGTERM")
        case (.ready, .processExited(let code)):
            return .accepted(phase, .failed(reason: .exitedUnexpectedly(code: code)))
        case (.ready, .startRequested):
            return .rejected(phase, why: "already running")
        case (.ready, .startingTick):
            return .rejected(phase, why: "startup clock is not running while ready")

        // -- from .degraded -----------------------------------------------
        case (.degraded(let n, _), .probeFailed(let reason)):
            let next = n + 1
            if next >= policy.maxConsecutiveFailures {
                return .accepted(phase, .failed(reason: .healthCollapsed(lastReason: reason)),
                                 note: "engine: consider restart policy")
            }
            return .accepted(phase, .degraded(consecutiveFailures: next, lastReason: reason))
        case (.degraded, .probeSucceeded):
            // Auto-recovery — the edge upstream had to patch into the
            // license service in 0.21.2 ("连上后自动恢复").
            return .accepted(phase, .ready(streak: 1))
        case (.degraded, .stopRequested):
            return .accepted(phase, .stopping, note: "engine: SIGTERM")
        case (.degraded, .processExited(let code)):
            return .accepted(phase, .failed(reason: .exitedUnexpectedly(code: code)))
        case (.degraded, .startRequested):
            return .rejected(phase, why: "already running (degraded); stop first or wait for recovery")

        // -- from .stopping -----------------------------------------------
        case (.stopping, .processExited):
            return .accepted(phase, .stopped)
        case (.stopping, .stopTimedOut):
            return .accepted(phase, .stopped, note: "engine: SIGKILL, then confirm exit")
        case (.stopping, .stopRequested):
            return .accepted(phase, phase, note: "stop already in flight")
        case (.stopping, .startRequested):
            return .rejected(phase, why: "stop in flight; wait for .stopped before starting")

        // -- from .failed -------------------------------------------------
        case (.failed, .startRequested):
            return .accepted(phase, .starting(elapsedSeconds: 0), note: "engine: spawn process (retry)")
        case (.failed, .stopRequested):
            return .accepted(phase, .stopped, note: "nothing to stop; acknowledging")

        // -- catch-alls: the pairs that are *decidedly meaningless* in the
        //    given phase. Written per-phase so adding a new Event forces a
        //    compiler visit here too, not silence.
        case (.stopped, _):
            return .rejected(phase, why: "event not meaningful while stopped")
        case (.starting, .startRequested):
            return .rejected(phase, why: "already starting")
        case (.starting, .stopTimedOut):
            return .rejected(phase, why: "no stop was requested during startup")
        case (.starting, _):
            return .rejected(phase, why: "event not meaningful during startup")
        case (.ready, .processSpawned):
            return .rejected(phase, why: "already spawned and ready")
        case (.ready, .spawnFailed):
            return .rejected(phase, why: "spawn result after ready")
        case (.ready, .stopTimedOut):
            return .rejected(phase, why: "no stop in flight")
        case (.ready, _):
            return .rejected(phase, why: "event not meaningful while ready")
        case (.degraded, _):
            return .rejected(phase, why: "event not meaningful while degraded")
        case (.stopping, _):
            return .rejected(phase, why: "event not meaningful while stopping")
        case (.failed, _):
            return .rejected(phase, why: "event not meaningful after failure")
        }
    }
}

extension UnitMachine.Phase {
    /// Convenience for reading the starting-clock without a switch at call
    /// sites that only feed it back in.
    var elapsedSecondsOrZero: Int {
        if case .starting(let e) = self { return e }
        return 0
    }
}

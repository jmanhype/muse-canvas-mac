/// Whole-stack phase, derived — never mutated directly.
///
/// Upstream's docs speak of "五个服务正常" (five services normal) as a single
/// boolean in acceptance steps. Collapsing five units into one bit is how
/// "已连接" came to masquerade as "works". The stack phase is therefore a
/// *pure function* of the unit phases: it cannot disagree with them, and it
/// keeps names for the in-between states users actually experience while
/// services boot one by one.
public enum StackPhase: Equatable, Sendable {
    /// All units stopped; nothing has been requested.
    case cold
    /// Start requested; at least one unit still `.starting`.
    case booting(ready: [String], pending: [String])
    /// Every unit `.ready`.
    case running
    /// Running, but some units `.degraded` — usable, retrying, told the
    /// truth about it. This is the state the 0.21.2 fix made visible.
    case degraded(units: [String])
    /// One or more units `.failed` — named, with reasons available.
    case failed(units: [String])
    /// Stop requested; not all units have reported exit yet.
    case stopping
    /// All units stopped after having run.
    case stopped

    /// Derive the stack phase from unit phases.
    /// - Parameters:
    ///   - units: unit id → phase, for every unit in the profile.
    ///   - stopRequested: whether a stack-wide stop is in flight.
    public static func derive(
        units: [String: UnitMachine.Phase],
        stopRequested: Bool = false
    ) -> StackPhase {
        // No units at all is cold, not running — an empty truth.
        guard !units.isEmpty else { return .cold }

        let allStopped = units.values.allSatisfy {
            if case .stopped = $0 { return true }
            return false
        }
        if allStopped { return stopRequested ? .stopped : .cold }

        if stopRequested {
            // Some unit still winding down.
            if units.values.contains(where: { if case .stopping = $0 { return true }; return false }) {
                return .stopping
            }
            // Stop requested but a unit never observed the event; still
            // stopping from the stack's point of view.
            return .stopping
        }

        let starting = units.filter { if case .starting = $0.value { return true }; return false }
        if !starting.isEmpty {
            let ready = units.keys.filter { if case .ready = units[$0]! { return true }; return false }
                .sorted()
            return .booting(ready: ready, pending: starting.keys.sorted())
        }

        let failed = units.compactMap { id, phase -> String? in
            if case .failed = phase { return id }
            return nil
        }.sorted()
        if !failed.isEmpty { return .failed(units: failed) }

        let degraded = units.compactMap { id, phase -> String? in
            if case .degraded = phase { return id }
            return nil
        }.sorted()
        if !degraded.isEmpty { return .degraded(units: degraded) }

        return .running
    }
}

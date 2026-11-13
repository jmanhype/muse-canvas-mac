/// Doctor: the acceptance tri-state, as a type.
///
/// Upstream's DEPLOY.md §验收 forces a three-way classification by prose:
/// "分别记录通过、失败、未测试" (record passed / failed / untested
/// separately) and "不能掩盖缺项报全功能通过" (never report full success by
/// hiding missing items). Every release note since preview.1 repeats it.
/// Prose rules decay; types don't. `untested` is a first-class verdict with
/// a reason — most often "requires the user's own account; agents must not
/// attempt it" — which is also the AX contract for what an agent may
/// dogfood without permission.
public enum DoctorVerdict: String, Codable, Sendable, Equatable {
    case passed
    case failed
    case untested
}

public struct DoctorCheck: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let verdict: DoctorVerdict
    /// What was actually observed — evidence, not assertion. Upstream rule:
    /// "已连接"和模型自报身份不是工具证据 ("connected" is not proof).
    public let evidence: String
    /// What a human should do next, when verdict != passed.
    public let remedy: String?
    /// True when only the user can perform this check (account login,
    /// human-verification captcha, paid generation). Agents read this flag
    /// and stop; upstream enforces it by documentation, we enforce it by
    /// schema.
    public let userActionRequired: Bool

    public init(
        id: String, title: String, verdict: DoctorVerdict,
        evidence: String, remedy: String? = nil, userActionRequired: Bool = false
    ) {
        self.id = id
        self.title = title
        self.verdict = verdict
        self.evidence = evidence
        self.remedy = remedy
        self.userActionRequired = userActionRequired
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let generatedAtUnix: Int
    public let checks: [DoctorCheck]

    public init(generatedAtUnix: Int, checks: [DoctorCheck]) {
        self.generatedAtUnix = generatedAtUnix
        self.checks = checks
    }

    public var summary: (passed: Int, failed: Int, untested: Int) {
        var p = 0, f = 0, u = 0
        for c in checks {
            switch c.verdict {
            case .passed: p += 1
            case .failed: f += 1
            case .untested: u += 1
            }
        }
        return (p, f, u)
    }

    /// Overall honesty rule: never "all good" while anything is failed or
    /// untested. Returns the *worst* honest verdict.
    public var overall: DoctorVerdict {
        if checks.contains(where: { $0.verdict == .failed }) { return .failed }
        if checks.contains(where: { $0.verdict == .untested }) { return .untested }
        return .passed
    }
}

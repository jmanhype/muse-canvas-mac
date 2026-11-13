import Foundation
import Testing
@testable import MuseCore

/// Every invariant named in docs/STATE-MACHINES.md is pinned here. These
/// tests are the difference between "documented" and "guaranteed".
struct UnitMachineTests {

    let machine = UnitMachine(policy: .standard)

    // MARK: Happy path

    @Test func stoppedToReady() {
        var phase: UnitMachine.Phase = .stopped
        #expect(machine.step(phase, on: .startRequested).to == .starting(elapsedSeconds: 0))
        phase = .starting(elapsedSeconds: 0)
        #expect(machine.step(phase, on: .processSpawned).accepted)
        #expect(machine.step(phase, on: .probeSucceeded).to == .ready(streak: 1))
        phase = .ready(streak: 1)
        #expect(machine.step(phase, on: .probeSucceeded).to == .ready(streak: 2))
    }

    // MARK: Start timeout (the 90s-vs-4min class of fix, as structure)

    @Test func startTimeoutFiresAtPolicy() {
        let fast = UnitMachine(policy: .init(startTimeoutSeconds: 3, maxConsecutiveFailures: 3))
        var phase: UnitMachine.Phase = .starting(elapsedSeconds: 0)
        phase = fast.step(phase, on: .startingTick).to
        phase = fast.step(phase, on: .startingTick).to
        #expect(phase == .starting(elapsedSeconds: 2))
        let t = fast.step(phase, on: .startingTick)
        #expect(t.to == .failed(reason: .startTimeout(seconds: 3)))
        #expect(t.note == "engine: kill process")
    }

    @Test func probeFailureDuringStartIsNotFatal() {
        let t = machine.step(UnitMachine.Phase.starting(elapsedSeconds: 2), on: .probeFailed(reason: "connection refused"))
        #expect(t.accepted)
        guard case .starting(let e) = t.to else {
            Issue.record("expected still starting, got \(t.to)")
            return
        }
        #expect(e == 2)
    }

    // MARK: Degraded — transient by contract (the 0.21.2 license incident)

    @Test func degradedRecoversAutomatically() {
        var phase: UnitMachine.Phase = .ready(streak: 7)
        phase = machine.step(phase, on: .probeFailed(reason: "timeout")).to
        #expect(phase == .degraded(consecutiveFailures: 1, lastReason: "timeout"))
        // Upstream fix: "连上后自动恢复" — recovery is automatic.
        let t = machine.step(phase, on: .probeSucceeded)
        #expect(t.to == .ready(streak: 1))
    }

    @Test func degradedCollapsesAfterMaxFailures() {
        let strict = UnitMachine(policy: .init(startTimeoutSeconds: 30, maxConsecutiveFailures: 2))
        var phase: UnitMachine.Phase = .ready(streak: 3)
        phase = strict.step(phase, on: .probeFailed(reason: "503")).to
        phase = strict.step(phase, on: .probeFailed(reason: "503 again")).to
        #expect(phase == .failed(reason: .healthCollapsed(lastReason: "503 again")))
    }

    @Test func failureCarriesTheRealReason() {
        let phase = machine.step(.ready(streak: 1), on: .probeFailed(reason: "HTTP 429: quota exceeded")).to
        guard case .degraded(_, let reason) = phase else {
            Issue.record("expected degraded")
            return
        }
        #expect(reason == "HTTP 429: quota exceeded")
    }

    // MARK: Stop flow (kill_tree semantics: TERM → wait → KILL)

    @Test func stopFromReadyWaitsForExit() {
        let phase = machine.step(.ready(streak: 2), on: .stopRequested).to
        #expect(phase == .stopping)
        #expect(machine.step(phase, on: .processExited(code: 0)).to == .stopped)
    }

    @Test func stopTimedOutEscalatesToKilled() {
        let t = machine.step(.stopping, on: .stopTimedOut)
        #expect(t.to == .stopped)
        #expect(t.note == "engine: SIGKILL, then confirm exit")
    }

    // MARK: Retry is always one event away

    @Test func failedRetriesOnStart() {
        let phase = UnitMachine.Phase.failed(reason: .exitedUnexpectedly(code: 1))
        let t = machine.step(phase, on: .startRequested)
        #expect(t.accepted && t.to == .starting(elapsedSeconds: 0))
    }

    // MARK: Rejected edges are explicit, never silent

    @Test func rejectedEdges() {
        // start while already running
        #expect(!machine.step(.ready(streak: 1), on: .startRequested).accepted)
        // start while degraded (still alive)
        #expect(!machine.step(.degraded(consecutiveFailures: 1, lastReason: "x"), on: .startRequested).accepted)
        // start while stopping
        #expect(!machine.step(.stopping, on: .startRequested).accepted)
        // stop while already stopped
        #expect(!machine.step(.stopped, on: .stopRequested).accepted)
        // late exit report while stopped
        #expect(!machine.step(.stopped, on: .processExited(code: 0)).accepted)
        // probes for a dead process
        #expect(!machine.step(.failed(reason: .spawnFailed("no")), on: .probeSucceeded).accepted)
        // startup clock ticking outside startup
        #expect(!machine.step(.ready(streak: 1), on: .startingTick).accepted)
        // probes while stopping are noise
        #expect(!machine.step(.stopping, on: .probeSucceeded).accepted)
    }

    @Test func exitDuringStartFailsWithCode() {
        let t = machine.step(.starting(elapsedSeconds: 1), on: .processExited(code: 137))
        #expect(t.to == .failed(reason: .exitedUnexpectedly(code: 137)))
    }

    @Test func spawnFailureIsImmediateFailure() {
        let t = machine.step(.stopped, on: .spawnFailed("Permission denied"))
        #expect(t.to == .failed(reason: .spawnFailed("Permission denied")))
    }

    // MARK: Exhaustive sanity — every (phase, event) pair is decided

    @Test func everyPairIsDecided() {
        let phases: [UnitMachine.Phase] = [
            .stopped, .starting(elapsedSeconds: 0), .starting(elapsedSeconds: 100),
            .ready(streak: 0), .ready(streak: 9),
            .degraded(consecutiveFailures: 1, lastReason: "r"),
            .degraded(consecutiveFailures: 5, lastReason: "r"),
            .stopping, .failed(reason: .startTimeout(seconds: 1)),
        ]
        let events: [UnitMachine.Event] = [
            .startRequested, .processSpawned, .spawnFailed("x"), .probeSucceeded,
            .probeFailed(reason: "x"), .startingTick, .processExited(code: nil),
            .processExited(code: 3), .stopRequested, .stopTimedOut,
        ]
        var decided = 0
        for p in phases {
            for e in events {
                let t = machine.step(p, on: e)
                #expect(t.from == p)
                if t.accepted { decided += 1 }
            }
        }
        // The machine is useful, not paranoid: most pairs are legal.
        #expect(decided > phases.count * 3)
    }
}

struct StackPhaseTests {

    @Test func emptyIsColdNotRunning() {
        #expect(StackPhase.derive(units: [:]) == .cold)
    }

    @Test func allStoppedIsCold() {
        #expect(StackPhase.derive(units: ["web": .stopped, "pool": .stopped]) == .cold)
    }

    @Test func bootingNamesPendingUnits() {
        let units: [String: UnitMachine.Phase] = [
            "license": .ready(streak: 2), "agent": .ready(streak: 1),
            "merge": .starting(elapsedSeconds: 3), "pool": .stopped, "web": .stopped,
        ]
        let phase = StackPhase.derive(units: units)
        guard case .booting(let ready, let pending) = phase else {
            Issue.record("expected booting, got \(phase)")
            return
        }
        #expect(ready == ["agent", "license"])
        #expect(pending == ["merge"])
    }

    @Test func degradedBeforeFailed_namesSurvivors() {
        let units: [String: UnitMachine.Phase] = [
            "web": .ready(streak: 5),
            "license": .degraded(consecutiveFailures: 1, lastReason: "net unreachable"),
            "pool": .failed(reason: .exitedUnexpectedly(code: 1)),
        ]
        // A failed unit outranks degraded for the stack verdict.
        #expect(StackPhase.derive(units: units) == .failed(units: ["pool"]))
        var healthier = units
        healthier["pool"] = .ready(streak: 1)
        #expect(StackPhase.derive(units: healthier) == .degraded(units: ["license"]))
    }

    @Test func allReadyIsRunning() {
        let units = Dictionary(uniqueKeysWithValues: UnitTable.all.map { ($0.id, UnitMachine.Phase.ready(streak: 4)) })
        #expect(StackPhase.derive(units: units) == .running)
    }

    @Test func stopInFlightIsStopping() {
        let units: [String: UnitMachine.Phase] = ["web": .stopping, "pool": .stopped]
        #expect(StackPhase.derive(units: units, stopRequested: true) == .stopping)
        let allStopped: [String: UnitMachine.Phase] = ["web": .stopped, "pool": .stopped]
        #expect(StackPhase.derive(units: allStopped, stopRequested: true) == .stopped)
    }
}

struct InstallMachineTests {

    @Test func stepsInUpstreamOrder() {
        #expect(InstallMachine.orderedSteps.first == .validateSource)
        #expect(InstallMachine.orderedSteps.last == .configureLaunch)
        #expect(InstallMachine.orderedSteps.contains(.stopExisting))
        #expect(InstallMachine.orderedSteps.firstIndex(of: .stopExisting)!
                < InstallMachine.orderedSteps.firstIndex(of: .swapDirectories)!)
        #expect(InstallMachine.orderedSteps.firstIndex(of: .swapDirectories)!
                < InstallMachine.orderedSteps.firstIndex(of: .pinInstance)!)
    }

    /// The rollback table — upstream implements this with one try/catch;
    /// here it is a checked fact.
    @Test func rollbackObligations() {
        #expect(InstallMachine.rollbackPlan(onFailureAt: .validateSource) == .noneNeeded)
        #expect(InstallMachine.rollbackPlan(onFailureAt: .classifyDestination) == .noneNeeded)
        #expect(InstallMachine.rollbackPlan(onFailureAt: .stageAndVerify) == .removeStaging)
        #expect(InstallMachine.rollbackPlan(onFailureAt: .stopExisting) == .removeStaging)
        #expect(InstallMachine.rollbackPlan(onFailureAt: .swapDirectories) == .restorePreviousInstall)
        // After the swap succeeded, later failures leave a working install.
        #expect(InstallMachine.rollbackPlan(onFailureAt: .pinInstance) == .noneNeeded)
        #expect(InstallMachine.rollbackPlan(onFailureAt: .configureLaunch) == .noneNeeded)
    }

    @Test func preflightStepsMutateNothing() {
        #expect(!InstallMachine.mutatesDestination(.validateSource))
        #expect(!InstallMachine.mutatesDestination(.classifyDestination))
        for step in InstallMachine.orderedSteps.dropFirst(2) {
            #expect(InstallMachine.mutatesDestination(step))
        }
    }
}

struct DataDirectoryResolutionTests {

    @Test func explicitWins() {
        let r = DataDirectoryResolution.resolve(
            explicit: "/Volumes/Data/Muse", previous: "/old", default: "/default")
        #expect(r == .explicit("/Volumes/Data/Muse"))
    }

    @Test func upgradeInheritsOverDeriving() {
        // The case where silent derivation would look like data loss.
        let r = DataDirectoryResolution.resolve(
            explicit: nil, previous: "/Users/x/Library/Application Support/MuseCanvas/data", default: "/default")
        #expect(r == .inheritedFromInstance("/Users/x/Library/Application Support/MuseCanvas/data"))
    }

    @Test func freshInstallDerives() {
        let r = DataDirectoryResolution.resolve(explicit: nil, previous: nil, default: "/default")
        #expect(r == .derivedDefault("/default"))
    }

    @Test func emptyExplicitFallsThrough() {
        let r = DataDirectoryResolution.resolve(explicit: "", previous: "/prev", default: "/default")
        #expect(r == .inheritedFromInstance("/prev"))
    }
}

struct LicensePhaseTests {

    /// The 0.21.2 incident, as an invariant: unreachable NEVER blocks.
    @Test func unreachableNeverBlocks() {
        var phase = LicensePhase.unknown
        phase = LicensePhase.step(phase, on: .checkFailed)
        #expect(phase.blocksGeneration == false)
        for _ in 0..<10_000 {
            phase = LicensePhase.step(phase, on: .checkFailed)
        }
        #expect(phase.blocksGeneration == false)
        guard case .unreachable(let retries) = phase else {
            Issue.record("expected unreachable")
            return
        }
        #expect(retries == 10_001)
    }

    @Test func revokedIsTheOnlyBlocker() {
        let revoked = LicensePhase.step(.ok, on: .revokedDetected(reason: "disabled"))
        #expect(revoked.blocksGeneration == true)
        #expect(LicensePhase.unknown.blocksGeneration == false)
        #expect(LicensePhase.ok.blocksGeneration == false)
    }

    @Test func recoversFromUnreachableToOk() {
        var phase = LicensePhase.unreachable(retries: 5)
        phase = LicensePhase.step(phase, on: .checkSucceeded)
        #expect(phase == .ok)
    }
}

struct DoctorTests {

    @Test func overallIsTheWorstHonestVerdict() {
        let report = DoctorReport(generatedAtUnix: 0, checks: [
            DoctorCheck(id: "a", title: "A", verdict: .passed, evidence: "ok"),
            DoctorCheck(id: "b", title: "B", verdict: .untested, evidence: "needs user login", userActionRequired: true),
        ])
        #expect(report.overall == .untested)   // hiding gaps is lying
        let withFailure = DoctorReport(generatedAtUnix: 0, checks: report.checks + [
            DoctorCheck(id: "c", title: "C", verdict: .failed, evidence: "port 3000 occupied"),
        ])
        #expect(withFailure.overall == .failed)
        let clean = DoctorReport(generatedAtUnix: 0, checks: [
            DoctorCheck(id: "a", title: "A", verdict: .passed, evidence: "ok"),
        ])
        #expect(clean.overall == .passed)
        #expect(clean.summary == (1, 0, 0))
    }

    @Test func checksRoundTripAsJSON() throws {
        let report = DoctorReport(generatedAtUnix: 42, checks: [
            DoctorCheck(id: "port-web", title: "Web port", verdict: .passed, evidence: "free"),
            DoctorCheck(id: "pool-login", title: "Pool login", verdict: .untested,
                        evidence: "requires the user's own Muse account",
                        remedy: "Open the pool page and sign in", userActionRequired: true),
        ])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.checks[1].userActionRequired)
    }
}

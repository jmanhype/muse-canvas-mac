# muse-canvas-mac

A Mac-native supervisor for **MuseCanvas** ([upstream](https://github.com/fangrui202575/muse-canvas-deploy),
`v0.21.2-mac` arm64 payload): one explicit state machine instead of five
implicit ones, with a CLI, a menu bar app, and a local status dashboard.

It is **interoperable, not a fork**: same ports (3000 / 17371 / 17372 / 17373
/ 18610 / 19210 / 19400), same files (`instance.json`, `install.json`,
`processes.json`), same environment contract, same LaunchAgent label. A stack
started with `muse` is stopped correctly by upstream's `manage.sh`, and vice
versa. The closed-source services are untouched — this repo owns the
lifecycle around them.

## Why

Upstream's lifecycle lives in three excellent shell scripts
(`install-wizard.sh`, `install.sh`, `scripts/manage.sh`) — and in the
author's head. Every state machine in them is implicit: `$HAD_INSTALL`
carries fresh-vs-upgrade identity, a counting loop decides
stopped/partial/running, one linear script is the boot sequence, and the
release notes are a history of implicit-transition bugs (a transient license
outage latching into a 6-hour generation block, fixed in 0.21.2; a 4-minute
video timeout that should have been 90 s, fixed in 0.21.1).

**[docs/STATE-MACHINES.md](docs/STATE-MACHINES.md) catalogs all eighteen** —
with file-level evidence, the shipped bug each one caused, and the explicit
type + invariant + test that replaces it. The one rule that fell out:

> If a state affects what the user, the developer, or the agent may do next,
> it must be a named case in a type, rendered somewhere, and pinned by a test.

## What you get

| Surface | What it is |
|---|---|
| `muse` CLI | `install` (staging + rollback + per-file manifest verify), `start`/`stop` (idempotent, orphan-recovering), `status`/`doctor` (`--json`, tri-state), `open`, `autostart`, guarded `uninstall` |
| Dashboard | `muse start --watch` → `http://127.0.0.1:17370` — zero-build vanilla web (native `dialog`, `popover`, `light-dark()`), live per-unit phases, doctor table, actions. Loopback only, never includes secrets |
| Menu bar (`MuseBar`) | Native SwiftUI status item: stack phase, per-unit menu, start/stop/doctor/open |
| `MuseCore` | The pure state machines — `UnitMachine`, `StackPhase`, `InstallMachine`, `DataDirectoryResolution`, `LicensePhase`, `DoctorVerdict` — no I/O, fully tested |

Improvements over upstream's scripts, all found by dogfooding on a real Mac:

- **Idempotent start** — starting a running stack is a no-op success
  (upstream re-runs its script; a second spawn used to fight the first).
- **Orphan-recovering stop** — if `processes.json` ever lies, services are
  found by port *and* command-line attribution and stopped anyway.
- **Port preflight covers 19400** (doubao CDP), which upstream forgets.
- **Browser discovery does the 0.21.3 Windows fix on Mac** — default paths,
  `~/Applications`, and a Spotlight bundle-id query, not just two `/Applications` paths.
- **Per-file integrity** — optional `--verify full` checks all 5,135 files
  against the payload's own `MANIFEST.sha256` before anything is touched.
- **Honest failure** — every failed unit carries the real reason (exit code,
  HTTP status, last probe error), never "see logs".

## Quick start

```bash
git clone <this repo> && cd muse-canvas-mac
swift build                # Swift 6, zero external dependencies

# Get the real payload (upstream release, ~773 MB) and verify it:
curl -LO https://github.com/fangrui202575/muse-canvas-deploy/releases/download/v0.21.2-mac/MuseCanvas-0.21.2-mac-arm64.zip
shasum -a 256 MuseCanvas-0.21.2-mac-arm64.zip   # expect 56484080…6744a
unzip MuseCanvas-0.21.2-mac-arm64.zip

.build/debug/muse install --source MuseCanvas-0.21.2-mac-arm64 --dry-run   # see the plan
.build/debug/muse install --source MuseCanvas-0.21.2-mac-arm64 --yes
.build/debug/muse doctor          # passed / failed / untested — never fakes success
.build/debug/muse start --watch --no-browser
open http://127.0.0.1:17370       # dashboard
.build/debug/muse stop            # data always retained
```

Account login (Muse pool, Doubao, Codex/Claude) is **yours to do, in the
canvas UI** — the supervisor never touches accounts, quotas, or captchas.
`muse doctor` marks those checks `untested / userActionRequired` rather than
pretending.

The Mac test build is unsigned: if macOS blocks the payload's binaries on
first run, System Settings → Privacy & Security → *Open Anyway* (the
installer also strips quarantine from the staged tree, as upstream's does).

## Web dashboard dependencies — a decision, not an accident

The dashboard is deliberately **one file of modern vanilla web** (no
framework, no build step), following
[GoogleChrome/modern-web-guidance](https://github.com/GoogleChrome/modern-web-guidance)
(platform features over JS). If it grows into a real control panel — forms,
virtualized logs, multi-instance views — adopt
[vercel-labs/ui](https://github.com/vercel-labs/ui) at that point; that is
the recorded migration trigger. [expo/exact](https://github.com/expo/exact)
was evaluated for the native surface and passed on: pre-1.0 with no API
stability is the wrong foundation for a supervisor whose job is boring
reliability — SwiftUI + `status --json` gives agents the same observability
without the risk.

## Development

```bash
swift test        # 51 tests: every machine's transition table, parity with
                  # upstream's scripts, real process spawn/kill semantics
```

`Tests/MuseCoreTests` pins the parity contracts (boot order, health dialects,
the 24-variable environment contract, config migration semantics).
`Tests/MuseKitTests` exercises the real engine against the real filesystem
and real processes.

## Scope & honesty

- The five services themselves are upstream's closed binaries; this repo
  supervises them. Pool/account behavior (M13–M16 in the catalog) is
  documented, surfaced read-only, and never automated here.
- When the stack runs, the upstream license service contacts
  `license.fylmlgsb.xyz` per its own design (~6 h cadence, anonymous install
  id). `muse doctor` itself never contacts anything external.
- Dogfooded end-to-end on macOS 27 arm64: install → verify → doctor → start
  (all five healthy) → status/dashboard → forced-failure reconciliation →
  stop (all ports released) → upgrade (data + secrets preserved) → refusal
  paths. Not tested: real account generation (user-only, by design).

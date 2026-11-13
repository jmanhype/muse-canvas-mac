# AGENTS.md — contract for AI agents working on (or with) this repo

This project exists because its upstream ships an "AI installation prompt"
in its README — agent operation was a first-class requirement from day one.
This file is the machine-facing contract. Read it before touching anything.

## The one-paragraph mental model

Five closed-source services run on fixed loopback ports. This repo owns the
**lifecycle around them** as explicit state machines (`Sources/MuseCore`).
Every state that changes what may happen next is a named enum case, rendered
in `muse status` / the dashboard / the menu bar, and pinned by a test in
`Tests/`. If you find yourself adding an `if` that encodes a new state, add
the case to the machine instead.

## Safe by default / needs explicit user consent / never

| Action | Class | Why |
|---|---|---|
| `swift build`, `swift test` | safe | local only |
| `muse install --dry-run`, `muse doctor`, `muse status` | safe | read-only; doctor never contacts external services |
| `muse install` (writes `~/MuseCanvas`, data dir) | consent | changes the machine; always shows a plan first |
| `muse start` / `stop` | consent-ish | runs the real payload (license service phones home per its own design); stop is safe |
| Account login (Muse pool / Doubao / Codex / Claude), generation, export | **user only** | upstream rule, enforced here by `DoctorCheck.userActionRequired` — an agent must never attempt these, complete captchas, or spend quota |
| Deleting `processes.json`, regenerating `install.json` secrets, MCP tokens | **never** | M6/M15: create-once credentials. "Fixing" auth by regenerating tokens is the exact bug upstream's preview.1 shipped. |
| Killing processes that hold the ports but don't belong to this install | **never** | M10: "No existing process was stopped" — name them in the error instead |
| `muse uninstall --purge-data` | **user only** | irreversible; even the CLI demands typing DELETE |

## Exit-code contract (inherited from upstream's wizard — keep it)

```
0 done · 1 failed · 2 cancelled by user · 3 refused, nothing was changed
muse doctor: 0 all passed · 2 untested only · 1 any failed
```

Machines and scripts rely on these; don't repurpose them.

## JSON is the agent surface

`muse status --json`, `muse doctor --json`, `muse install --dry-run` (JSON
plan), `/status.json` + `/doctor.json` on the watcher (127.0.0.1:17370).
Never parse the human output. Never print secrets — the established format
is `first4…last4 (length)`; `status.json` contains no keys at all.

## Interop rules (do not break parity)

- `processes.json`, `instance.json`, `install.json` are shared contracts
  with upstream `manage.sh` — a `muse`-started stack must remain stoppable
  by `manage.sh stop` and vice versa.
- The environment contract (`MuseCore/EnvironmentContract.build`) must match
  `manage.sh`'s exports exactly; `RecordsTests.environmentContractKeys…`
  pins all 24 keys.
- Boot order and health dialects live in `MuseCore/UnitTable`; tests pin
  them against `manage.sh`'s `wait_health` calls.
- The LaunchAgent label is `xyz.fylmlgsb.musecanvas` (upstream's) so both
  tools manage the same agent.

## When editing the dashboard (`Resources/web/status.html`)

One file, no build step, modern platform features over JS libraries — run
the [modern-web-guidance](https://github.com/GoogleChrome/modern-web-guidance)
legacy-scan mindset over your change: prefer `dialog`/`popover`/`color-mix`/
`light-dark()` to any dependency. The migration trigger to
[vercel-labs/ui](https://github.com/vercel-labs/ui) is documented in the
README; don't pull it in for this page.

## Testing expectations

- Pure machines: extend the transition-table tests; rejected edges are
  results (`accepted: false`), not errors.
- Engine: `Tests/MuseKitTests` runs real processes (spawn/kill-tree) and
  real filesystem staging — keep it that way; no mocks of the supervisor.
- Dogfooding the real payload is the only acceptable end-to-end evidence;
  report results in the tri-state (passed / failed / untested) and say
  which checks were user-only.

## Diagnostics etiquette (from upstream DEPLOY.md, kept as law)

Log field names, lengths, statuses, and short fingerprints — never full
keys, cookies, tokens, or full run logs. When two identical failures repeat
without progress: stop, preserve evidence, report the blocker. Never retry
by clearing caches, swapping credentials, or reinstalling on luck.

# MuseCanvas implicit state machines — full catalog

Every state machine in MuseCanvas 0.21.2-mac that was **implicit** — encoded in
script order, sentinel variables, counting loops, or prose in README/DEPLOY —
with the evidence where it lives, the shipped bug it already caused (when one
is on record), and how the Mac port makes it **explicit**: a named type, a
stated invariant, and a test that pins the invariant.

Sources: `fangrui202575/muse-canvas-deploy` repo (README.md, DEPLOY.md,
Install.ps1, manifest.json), release notes v0.20.0-preview.1 → v0.21.3, and
the `MuseCanvas-0.21.2-mac-arm64.zip` payload scripts (`install-wizard.sh`,
`install.sh`, `scripts/manage.sh`, `services/entry.cjs`, `BUILD.json`,
`MANIFEST.sha256`).

> **Legend** — each machine gets: **Where** (file:behavior), **States** (the
> implicit ones), **Bug on record**, **Port** (the explicit type in this
> repo). Types live in `Sources/MuseCore`; invariants are pinned in
> `Tests/MuseCoreTests`.

| # | Machine | Where it hides today | Explicit type in this repo |
|---|---------|----------------------|----------------------------|
| M1 | Install/upgrade pipeline | `install.sh` §1–6 | `InstallMachine` |
| M2 | Data-directory resolution | `install.sh` §5b, `manage.sh` header | `DataDirectoryResolution` |
| M3 | Single-install detection | `install-wizard.sh` root scan | Installer preflight |
| M4 | Fresh-install eligibility | wizard port/disk/browser checks | `Doctor` checks |
| M5 | Wizard interaction / exit codes | `install-wizard.sh` header comment | `muse install` contract |
| M6 | Config creation vs migration | `manage.sh` config block | `InstallConfig` schema |
| M7 | Recorded-vs-actual process truth | `manage.sh` `record_running` | `UnitMachine` + record parity |
| M8 | Boot sequence with rollback | `manage.sh` `start_owned`/`abort_start` | `Supervisor` + `UnitMachine` |
| M9 | Stop escalation | `manage.sh` `kill_tree` | `UnitMachine` `.stopping` edges |
| M10 | Port preflight | `manage.sh` port loop | `Doctor` + preflight |
| M11 | License/update check | README 联网说明 + 0.21.2 fix | `LicensePhase` |
| M12 | Per-service health dialects | `manage.sh` `wait_health` calls | `UnitSpec` |
| M13 | Pool task / Doubao account | closed binaries, release notes | documented; surfaced read-only |
| M14 | Browser/CDP discovery & attach | 0.21.3 fix notes; mac wizard gap | `BrowserFinder` (doctor) |
| M15 | Agent runtime & auth | DEPLOY 启动与登录, preview notes | doctor checks + AGENTS rules |
| M16 | Export/merge pipeline | DEPLOY 验收 6; preview.2 fix | doctor probe (read-only) |
| M17 | Acceptance tri-state | DEPLOY 验收 prose | `DoctorVerdict` |
| M18 | Autostart LaunchAgent | `manage.sh` `do_autostart` | `muse autostart` (same plist) |

---

## M1 · Install/upgrade pipeline

**Where.** `install.sh` (port of `Install.ps1`): validate source → classify
destination → stage to `<dest>.new-<stamp>` → re-verify staged → preserve
user `models/` files → `manage.sh stop` → `mv` old to `<dest>.old-<stamp>` →
`mv` staged in (single `try`-shaped rollback) → write `musecanvas.json` +
`instance.json` → desktop launcher → optional autostart.

**Implicit states.** `$HAD_INSTALL`, `$PREV_DATA_DIRECTORY`, `$STAGING`,
`$BACKUP`, `$SWAP_OK` — five shell variables ARE the machine. "Nothing was
changed" is asserted in error strings rather than guaranteed by structure.

**Bug on record.** None shipped in the swap itself; but rollback exists only
as one `if`, and DEPLOY.md warns "不保证功能失败时自动降级" (no guaranteed
auto-downgrade) — i.e. the authors know the failure lattice outgrew the
script.

**Port.** `InstallMachine.orderedSteps` + `rollbackPlan(onFailureAt:)` table:
steps before staging mutate nothing; staging failures owe `removeStaging`;
only the swap owes `restorePreviousInstall`; post-swap failures owe nothing
(the new tree is already installed — report, don't roll back). Tests assert
the table.

## M2 · Data-directory resolution

**Where.** `install.sh` §5b and `manage.sh` ("instance.json wins"). Precedence:
explicit flag → previous `instance.json` → platform default
(`~/Library/Application Support/MuseCanvas/data`).

**Implicit states.** Three mutually exclusive provenances for the same path.

**Bug on record.** The wizard exists to defend this machine: if a recorded
data dir is missing it *refuses* ("联系卖家") rather than silently deriving a
fresh one — because a silent fall-through is indistinguishable from "the
upgrade deleted my work". The defense is prose + refusal, not a type.

**Port.** `DataDirectoryResolution.resolve(explicit:previous:default:)` —
pure function; `.inheritedFromInstance` is a distinct case, so a UI can say
"reusing your existing data" instead of merely printing a path.

## M3 · Single-install detection

**Where.** `install-wizard.sh`: scans `$HOME/MuseCanvas` plus every
`~/Desktop/MuseCanvas*.command` launcher (each embeds a `# MuseCanvas install
root:` marker), dedupes, and refuses if count > 1; refuses if run from inside
an installed tree.

**Implicit states.** `{none, exactly-one, multiple, running-from-install-dir}`.

**Port.** Installer preflight + doctor check with the same discovery rules
(default root + launcher markers). Invariant: an upgrade must resolve to
exactly one target or refuse with all candidates listed.

## M4 · Fresh-install eligibility

**Where.** Wizard: 6 ports LISTEN-free (3000, 17371, 17372, 17373, 18610,
19210 — note: `doubaoCdp` 19400 is in `install.json` but **not** checked),
≥4 GB free disk, Chrome or Edge present.

**Bug on record.** v0.21.3 (Windows) fixed "browser is installed but the
installer says it can't find it" by searching beyond default folders. **The
mac wizard still checks only `/Applications/Google Chrome.app` and
`/Applications/Microsoft Edge.app`** — the same bug class, unfixed on mac.

**Port.** Doctor checks: ports (including 19400), disk, and
`BrowserFinder` doing the 0.21.3-style broad search on mac — default paths,
`~/Applications`, and a Spotlight (`mdfind`) bundle-id query — bringing the
Windows fix to the Mac.

## M5 · Wizard interaction contract

**Where.** `install-wizard.sh` header: exit codes `0` done / `1` install
failed / `2` cancelled / `3` refused-nothing-changed; `--detect-only` prints
`NEW <path>` or `UPGRADE <path>`.

**Why it matters.** This is the payload's best AX idea — a machine-usable
installer — and it's already half-explicit. The port keeps the contract
verbatim and extends it: `muse install --dry-run` emits the same
NEW/UPGRADE decision plus every refusal reason as JSON.

## M6 · Config creation vs migration

**Where.** `manage.sh` config block: if `install.json` exists, an inline
node one-liner mutates it (stamp version, dataDir, add missing
`ports.license`, `ports.doubaoCdp`); else create fresh with newly generated
`poolKey` + `serviceKey` (`openssl rand -hex 32`).

**Implicit states.** `{absent→create-with-secrets, present→migrate-in-place}`.
Invariants hiding in prose: never regenerate secrets on an existing install
(DEPLOY: "池子密钥、导出服务密钥和 Agent 令牌必须分开" — keys must stay
distinct per purpose/instance).

**Port.** `InstallConfig` model with schema-versioned fields; migration is
additive-only and idempotent; secret generation happens exactly once, at
creation. Tests pin: migrate never invents keys.

## M7 · Recorded-vs-actual process truth

**Where.** `manage.sh` `record_running`: a `processes.json` record
(name, pid, executable, startedTicks) counts as running iff pid alive AND
start time matches AND command line contains the executable — a pid-reuse
guard. `status` recomputes liveness per record; `start` treats
`ACTIVE ∈ {0, 5}` as clean and `1–4` as "partially running" error.

**Implicit states.** Per record: `alive-matching / alive-reused / dead`.
Stack: `stopped / partial / running` by counting.

**Bug on record.** The partial state's only remedy is "run stop, then
start" — a manual reset of a machine the user can't see.

**Port.** `UnitMachine` owns per-unit truth (with `.degraded` for
probe-failing-but-alive — a state the original cannot express);
`processes.json` is still written in the upstream format so `manage.sh
stop/status` keeps working on a `muse`-started stack (both-ways parity).

## M8 · Boot sequence with rollback

**Where.** `manage.sh`: fixed order `license → agent → merge → pool → web`,
each spawned with the full env-var contract, then health gates; any failure
runs `abort_start` — kill everything started, blank the records.

**Implicit states.** The order, the per-service health dialects (M12), and
"all-or-nothing" are all implicit in one linear script. Partial failure
reports one line: "`web did not become ready. See <logs>`".

**Port.** `Supervisor` drives one `UnitMachine` per unit — same order, same
env, same dialects — but per-unit phases are live and observable (`status
--json`, menu bar, dashboard) instead of discoverable only by reading logs
after a failure.

## M9 · Stop escalation

**Where.** `kill_tree`: `TERM` the process group → 6 × 0.5 s → `KILL`.

**Port.** `UnitMachine` `.stopping → stopped` with `.stopTimedOut` = engine
escalates to SIGKILL. Same tree-kill semantics in the engine.

## M10 · Port preflight

**Where.** `manage.sh` start: each of 6 ports must have no LISTEN socket;
occupied ⇒ abort with "No existing process was stopped" (never kills
squatters — matches DEPLOY "不擅自结束其他进程").

**Port.** Identical rule, plus 19400 (doubaoCdp) which the original omits,
surfaced in both preflight and `muse doctor`.

## M11 · License / update check

**Where.** README 联网说明: every 6 h ask `license.fylmlgsb.xyz` for
status + new version; hourly公告 read; ~anonymous install id.

**Bug on record.** v0.21.0/0.21.1: a transient startup failure to reach the
server latched a permanent "授权异常" state that blocked generation until
restart or a 6-hour timer. v0.21.2 fixed it: unreachable ⇒ retry every
minute, auto-recover on success, never block.

**Port.** `LicensePhase` with the incident's invariant as law:
`blocksGeneration` is true **only** for `.revoked`. Test-enforced, so the
0.21.2 class of bug cannot be reintroduced silently.

## M12 · Per-service health dialects

**Where.** `wait_health` call sites: web `/health`; agent `/health`; pool
`/healthz` (240 tries); license `/health` **with** `x-canvas-service-key`;
merge `/health` returning JSON that must contain `ffmpeg: yes` (30 × 1 s).

**Implicit states.** "Ready" means five different things. Nothing records
which dialect applies — it's positional knowledge in the script.

**Port.** `UnitSpec`: one declarative row per service — executable, args,
env additions, health path, auth header, ready predicate, timeout budget.
The supervisor's behavior is derived from this table; tests pin each row.

## M13 · Pool task / Doubao account machines (closed binaries)

**Where.** `pool/MusePool` (PyInstaller). Behavior is documented by release
notes: task `queued → dispatched → running → done | refused(fail-fast with
the platform's own words) | no-response(timeout ~90 s, was ~4 min)`;
Doubao per-account `idle ↔ busy (1 task)`, `quota-exhausted → switch to
other account`, `login-expired → re-login`, `human-verification → USER must
complete; the program must not`. Canvas "stop" only stops the canvas
waiting; backend Doubao tasks run to completion (documented limitation).

**Port.** Not reimplemented (closed). Surfaced honestly: the dashboard/CLI
show pool health and per-account login state read-only; every check that
would require touching an account is `untested / userActionRequired`.

## M14 · Browser / CDP discovery & attach

**Where.** Pool drives a real Chrome/Edge over CDP (`MUSE2API_CDP_PORT`
19210; Doubao uses a separate visible window + profile,
`MC_DOUBAO_CDP_PORT` 19400). Discovery = M4's browser search; attach =
launch with remote-debugging port → connect → per-profile login state.

**Port.** `BrowserFinder` (doctor): default locations + `~/Applications` +
Spotlight query. Never launches, never touches profiles — read-only.

## M15 · Agent runtime & auth

**Where.** DEPLOY 启动与登录 + preview notes: per-instance MCP registration
on every Claude start; Claude Code installed via one-click (signature
verified) or user's own npm; auth via member browser flow or API key +
protocol (anthropic/openai).

**Bug on record.** preview.1: MCP `invalid token` because the config dir
wasn't passed; the failure mode was "silently mint another token". Fix:
missing config must be a hard error; never regenerate tokens.

**Port.** Doctor checks agent health and MCP config presence; AGENTS.md
makes "never regenerate keys/tokens to fix auth" a stated rule for agents.

## M16 · Export / merge pipeline

**Where.** DEPLOY 验收 6: select segments → preview → trim → export →
merged video node (its appearance is *normal*, not duplication). Error
dialect: `401` = missing service key, `404` = wrong path (distinct states);
preview.2 fixed multipart boundary parsing so PowerShell clients stopped
being misdiagnosed as "empty manifest".

**Port.** Doctor probes merge `/health` read-only (with the instance key)
and reports ffmpeg readiness. No export is ever performed without the user.

## M17 · Acceptance tri-state

**Where.** DEPLOY 验收: "分别记录通过、失败、未测试 … 不能掩盖缺项报全功能
通过" — record passed/failed/untested separately; never report full success
while hiding gaps. Repeated in nearly every release note.

**Port.** `DoctorVerdict = passed | failed | untested` and
`DoctorReport.overall` returns the *worst honest* verdict. `untested`
carries `userActionRequired` when only the user can perform it (account
login, captcha, paid generation) — the schema now enforces what prose asked.

## M18 · Autostart LaunchAgent

**Where.** `manage.sh do_autostart`: opt-in; enable writes
`~/Library/LaunchAgents/xyz.fylmlgsb.musecanvas.plist` (RunAtLoad →
`manage.sh start --no-browser`) and loads it; disable unloads + removes;
status checks file presence.

**Port.** `muse autostart enable|disable|status` writing the **same plist
label**, so either tool manages the same agent — parity, not replacement.

---

## The one design rule that came out of this catalog

Every machine above failed (or nearly failed) the same way: a state that
existed only in the author's head, confronted reality. So the port's rule:

> **If a state affects what the user, the developer, or the agent may do
> next, it must be a named case in a type, rendered somewhere, and pinned by
> a test.** Everything else is a tunable.

`UnitMachine.Policy` holds the tunables (the 90 s vs 4 min class of fixes);
the phase lattice holds the truths.

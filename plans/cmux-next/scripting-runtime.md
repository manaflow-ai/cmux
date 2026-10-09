# cmux script: one scripting runtime for config, automation, REPL and agents

Status: accepted 2026-10-08 (decisions in section 9); phase 1 built (section 10.1). Owner: the scripting runtime lead. Related plans: [code-mode.md](code-mode.md), [app-commands-codemode.md](app-commands-codemode.md) (R73, decisions D1 to D8), [app-platform.md](app-platform.md) (sections 4, 12, 13), [browser-host.md](browser-host.md), [browser-repl/README.md](browser-repl/README.md), [computer-use.md](computer-use.md), [automations-runtime.md](automations-runtime.md), [keybindings.md](keybindings.md), [customization.md](customization.md), spec `cmux-tui/spec/programmability.md`, `bindings.md`, `events.md`.

Goal (Lawrence, 2026-10-08): cmux-next gets a full CLI plus scripting surface (config as code, custom actions, key bindings, key sequences and modes, event handlers, scripted layouts, a self-describing API, multi-host targeting, program status) in JavaScript, designed from first principles around the parts only cmux-next has: ACP agents, the Chromium and WebKit browser host, computer use, terminals on any host, Cloud and team VMs, and iOS.

## 1. What exists today (feat-cmux-next c6a0cd6d999)

cmux-next already has four JavaScript execution paths and one typed API. None of them is a user scripting runtime.

| Path | Engine and process | Who calls it | API | Sandbox |
| --- | --- | --- | --- | --- |
| Browser REPL (`cmux browser repl`, MCP `browser_repl_*`, ops `browser.repl.open/eval/close/list/reset/guide` in `cmux-tui/spec/browser-host-operations.json`) | QuickJS-ng through rquickjs, one VM per REPL session on its own thread inside the Rust browser host (`cmux-tui/crates/cmux-browser-host/src/vm.rs:1,225-240`), one host per daemon; no OS sandbox on the host process | agents and people | Playwright model (`page`, `tabs`, `snapshot`, `screenshot`, `fetch` with tab cookies, `fs` limited to the session dir, `sites`, `secret`, `tools`), runtime JS in `cmux-browser-host/js/` | policy gate, secret vault and masking in Rust below the VM (`gate.rs`, `policy.rs`, `secrets.rs`); 5 s bound outside a cell |
| App host (apps and App Store) | QuickJS-ng through rquickjs (`=0.14.0`), one `cmux-app-host` process per running app (`cmux-tui/crates/cmux-app-host/src/vm.rs:228`, limits `vm.rs:42-55`), spawned by the daemon supervisor (`cmux-tui-core/src/apps.rs`, `apps/host.rs:78-135` with `env_clear()` and only fd 3, `apps/hosts.rs:183-250`); the script arrives over the wire, the host never opens a file. The Mac app still runs apps in a DEV JavaScriptCore prototype (`CmuxNextApps/Engine/AppEngine.swift`, no OS sandbox, first-party and `local/` apps only) | installed apps | generated `cmux` global (`generated/cmux-app.d.ts`, `ops.json`, `scopes.json`, from `tools/gen-cmux-global.ts` over resource ops, cloud ops, `action-surfaces.json` and first-party app fragments; `--check` in `scripts/cmux-next/check-app-platform.sh`) | OS sandbox applied before the first read (`main.rs:27-31`; macOS `sandbox_init` deny-default, Linux Landlock + seccomp denying open, socket, exec, fork); 32 MiB, 250 ms per entry, 64 pending calls; the daemon checks every call (`apps/calls.rs:39-135`, `apps/grants.rs:84-122` `ScopeTable::check`), tiers and consent (`apps/mirror.rs`), gesture tokens (`grants.rs:145-262`) |
| Code mode (`cmux run <script.ts>`, to become `cmux code run`; Bun MCP tools `cmux_docs` + `cmux_exec`) | Bun under bwrap (Linux only; on macOS `cmux run` fails closed until a native sandbox ships, `cmux-tui/bindings/typescript/code-mode/README.md:20`), `scripts/cmux-next/cmux-code-mode-runner` + `proxy.mjs`, CLI entry `cmux-tui/crates/cmux-tui/src/cli/code_mode.rs` | agents | generated TypeScript SDK over the resource catalog | no network, no home, one socket; proxy checks op names only, no principal (R73 D3 to D5 plan the principal-bound proxy and daemon-owned lifecycle) |
| Automations | workerd (Cloudflare Workflows API plus `env.cmux`), cloud tier and pinned self-host tier | the Chief and teams | Workflows API | isolates; the VM is the boundary |

Other script-like paths: journal hooks (`session.journal.hook.put/list`, spec `cmux-tui/spec/session-journal.md:487-567`, runner `cmux-tui-core/src/journal_hooks.rs`) run an absolute-argv executable on matching journal events with durable cursors, receipts, retries and causal loop prevention; `cmux.json` `actions.<name>` (`type: command | agent`) become `cmuxConfig.<name>` actions (`CmuxNextSettings/ConfigActionParser.swift:10-46`); the agent pane's `~/.config/cmux/agent-pane/registry.js` runs in the page's main world with the native bridge and no sandbox (`CmuxNextAgentPane/AgentPaneCustomization.swift:63-68`). The palette ranker uses JavaScriptCore internally (not user code). Approvals exist in the cloud backend only (G8: `backend/apps/api/src/integrations/approvals.ts`, `approval-gate.ts:100`); there is no local approval sheet for agent ops yet.

The typed API: `cmux.protocol/2`, 196 operations plus 6 local operations in `cmux-tui/spec/resource-operations-v2.json` (session 23, terminal 23, browser 15, pane 14, workspace 14, tab 11, screen 10, git 9, tab_group 9, room 8, client 7, ...), events in `cmux-tui/spec/events.md`, SDKs per language in `cmux-tui/spec/bindings.md`, the noun-first Rust CLI (`cmux-tui/spec/cli.md`), `cmux mcp serve`, `cmux docs search`. The app action catalog (`plans/cmux-next/actions.md`, `action-surfaces.json`) is separate and reaches the resource API through `action.run`. OSC 7501 program status is implemented in the daemon (`cmux-tui/crates/cmux-tui-core/src/program_status.rs`) and mirrored in Swift (`CmuxNextDaemon/State/ProgramStatusRecord.swift`). acpmux (`cmux-tui/crates/acpmux`) speaks ACP plus `_acpmux/*` on its own socket; it is not in the resource catalog. Computer use (cmux-cua) has its own MCP and socket; `cua.*` ops are planned in computer-use.md section 6, not in the catalog.

How agents drive the browser and computer use today. Browser: an agent calls the MCP tool `browser_repl_eval` (from `cmux mcp serve`, `cli/mcp/browser_tools.rs`) or `cmux-browser-host eval --session S CODE`; the request goes as JSON lines over the per-daemon socket `CMUX_BROWSER_HOST_SOCKET` to the Rust browser host, which the daemon starts on demand; the code runs in that session's QuickJS-ng VM; every driver call passes the Rust policy gate and goes to headless Chromium (CDP over a pipe), in-app CEF (raw CDP relayed over the authenticated provider socket to the Swift app) or in-app WebKit (driver protocol to the Swift `WebKitDriver`); page-side helpers run in an isolated world per frame. `cmux browser repl` is not wired into the Rust CLI yet (`plans/cmux-next/cli.md:264`). Separately, `cmux browser tab_… eval|snapshot|click` call the app's `browser.page.*` methods. Computer use: an agent calls MCP tools on `cmux-cua mcp` (stdio, injected by acpmux, `acpmux/src/agent_tools.rs`), which forwards JSON lines to `cmux-cua serve` inside the signed helper app; each step is one tool call or a `perform_actions` batch of up to 20; there is no JavaScript REPL for computer use. ACP agents: acpmux is linked into the `cmux` binary (`cmux acp ...`, `cmux-tui/src/acp.rs`) and speaks ACP plus about 60 `_acpmux/*` methods on its own socket. The Swift CLI is deleted on this branch (`scripts/cmux-next/check-no-swift-cli.sh`); the Rust CLI's mux grammar is hand-written per scope and checked against the catalog by tests (`cli/command.rs`); MCP tools are generated from the v2 catalog, the browser host catalog and the live app `action.list` (876 actions, 419 offered to MCP).

Missing for a scripting surface: no user-facing script command beyond the agent-only code mode, no event handlers in scripts, no user actions defined in code, no key sequences or modes, `keybindings.json` loader unused (customization.md), no config as code, no REPL over the whole API, and ACP, computer use and Cloud VM lifecycle are outside the catalog.

## 2. Goals and non-goals

Goals:

1. One runtime, one API, every surface. The CLI, MCP, apps, scripts, the REPL, automations' code bodies and the Chief CLI call the same generated operations with the same principal checks. A new catalog op appears in all of them with no hand-written binding.
2. Parity with a modern multiplexer's scripting surface: run a script file, inline code or stdin with arguments and a JSON result; define actions with typed arguments that the palette, keys, CLI and API run; bind keys, key sequences and modes to actions or functions; react to events with long-lived handlers and blocking waits; build layouts declaratively; target other hosts; read terminal screens and program status.
3. Exceed it with cmux-next's own powers: drive ACP agents (spawn, prompt, stream turns, answer permission questions), drive browser tabs with the Playwright model, run computer use sessions, manage Cloud and team VMs, run on any host the daemon runs on (Mac, Linux, VM, later Windows), and show results on iOS.
4. Safe by default: no ambient filesystem, network or process access; capabilities by scope; agent-written code goes through `agent_view`, approvals and audit.
5. Fast: a one-shot script starts in under 30 ms end to end on a warm daemon; event handlers add no polling and no idle CPU.

Non-goals: a second scripting language; npm packages and Node compatibility in v1; a general-purpose JavaScript platform (people who need it run `node` or `bun` in a terminal and call the CLI); a second CLI or SDK for any feature; scripts changing settings that belong to the settings schema except through settings ops.

## 3. Engine choice

### 3.1 Requirements

Linux, Windows and remote hosts (the daemon runs there, and scripts must run headless where the work is); per-run memory and time limits with interrupt; Promise and async integration with tokio; an OS sandbox around the process; TypeScript input; small binary; permissive license; deterministic behavior between platforms; a debugger story.

### 3.2 Options

| Engine | For | Against | Verdict |
| --- | --- | --- | --- |
| QuickJS-ng via rquickjs | already ships twice in cmux-next (browser host, app host) with limits, interrupt, sandbox and tokio integration; about 1 MB binary, 169 KB per isolated context; runs on every daemon platform including Windows; ES2023, async/await; MIT | interpreter (10 to 50 times slower than a JIT on compute); memory-safety CVE history (contained by the per-process OS sandbox); debugger support is thin | the daemon engine for every headless, agent, remote and downloaded script |
| JavaScriptCore | on every Mac and iPhone, zero binary cost, JIT on macOS, Web Inspector | Apple only (no Linux daemon, no Windows); the JIT needs `allow-jit` in a hardened process and is unavailable on iOS; an in-app engine puts code inside the UI process with no OS sandbox; 794 KB per isolated context | client-local trusted user code in the app only (section 3.4) |
| V8 (deno_core) | fastest, best debugger (Chrome DevTools protocol), mature isolates | 30 to 40 MB, slow and fragile builds, per-isolate cost about 1 MB+ and 5 to 20 ms | reserved as the swap target if a measured gate fails (browser-host.md already reserves it) |
| Bun (current code mode) | TypeScript and npm out of the box | separate install on every host, a full runtime with ambient powers that the sandbox must remove, `sandbox-exec` deprecated on macOS, no Windows sandbox | replaced by the script host after measurement (revisits R73 D3 with data) |
| Boa | pure Rust | conformance and speed below QuickJS-ng | no |
| workerd | Workers API compatibility for automations | heavy, server-oriented | stays for automations only; their `code` body calls the same script ops |

Strongest expert objection to QuickJS-ng: "an interpreter is too slow and has had memory bugs; JavaScriptCore is free and fast on the Mac." Answer: scripts are glue whose cost is IPC to the daemon (each op is a socket round trip of 50 to 300 microseconds), not JavaScript compute, so a JIT buys nothing measurable; the memory-safety risk is contained by running each principal's scripts in an OS-sandboxed process with no ambient rights, the same model the app host ships; and one engine on every platform removes a class of "works on Mac, fails on the VM" bugs. The engine sits behind the existing host ABI (`cmux-app-host/js/ABI.md`), so a V8 or JavaScriptCore backend can replace it if a measured gate fails.

TypeScript: the host strips types at load (oxc transformer in Rust, MIT, no type check), so `.ts` files run directly; editors get types from the generated `cmux-script.d.ts`, and `cmux script types` prints the caller's view. Imports: relative files and `cmux:*` modules only, resolved and bundled by the host; no npm, no `node:*`, no dynamic import in v1.

Debugging: v1 has `cmux script repl` (the REPL is the debugger for glue code), stack traces with source maps from the type strip, and `cmux.log`. A Chrome DevTools protocol bridge is a later step and needs measurement.

### 3.3 Measurements (cmux-lawrence-2, macOS 27.0.1 arm64, Apple clang 21, 2026-10-08)

Method: one stripped host binary per engine that creates a runtime and context and evaluates `1+1`; footprint is `phys_footprint` delta over 200 instances.

| Engine | Binary size added (stripped) | Memory per isolated runtime + context | Extra context in a shared runtime or group | Create time |
| --- | --- | --- | --- | --- |
| QuickJS-ng 0.16.2 (the sources rquickjs-sys 0.14.0 bundles), C | 914 KB at -O2, 656 KB at -Os with dead strip (static lib 1.23 MB / 0.97 MB) | 169 KB (87 KB malloc) | 56 KB | 56 µs |
| rquickjs 0.14.0 in a Rust release binary (LTO) | 1,017 KB over an empty Rust binary | as above | as above | as above |
| JavaScriptCore (system framework) | 0 (in the OS) | 794 KB | 94 KB | 151 µs |

These costs are negligible here: the app bundle is hundreds of MB, QuickJS-ng already ships twice (app host, browser host) so reusing `cmux-app-host` adds 0 bytes, and a script host process holds a handful of contexts, not thousands.

### 3.4 Decision shape: one API, two engines by placement

Lawrence's direction (2026-10-08): JavaScriptCore in the app, QuickJS-ng in the daemon, one API. This plan adopts it with a strict split by trust and placement:

- Daemon, QuickJS-ng (every platform): every script that is headless, persistent, remote, agent-written, automation-run or downloaded (apps), and every one-shot `cmux script run`. Runs in the OS-sandboxed `cmux-app-host` process with the caller's principal.
- App, JavaScriptCore (macOS and iOS): only client-local, user-trusted code that needs app-side state or zero-hop latency: key-binding functions and frontend actions that read client presentation state (focus geometry, selection, the frontend action adapter of programmability.md), the in-app console's local completion and value rendering, and app-only UI helpers (`cmux.ui.pick`, `cmux.ui.input`). JIT stays off (`JSContextGroupSetExecutionTimeLimit`-style watchdog as in `AppWatchdog.swift`); every op it calls goes through the same daemon router with the user principal, so it gains no rights by being in-process. It never runs agent code, downloaded code or apps (app-platform-critique C9 stays: no third-party code in the UI process).
- One API: the same generated `cmux` global and the same host ABI (`cmux-app-host/js/ABI.md`, `__cmuxAppNative`) on both engines; the Swift side already implements it (`CmuxNextApps/Engine/AppEngine*.swift`). A conformance suite runs every script-API test on both engines in CI, so engine differences fail a test instead of a user.
- A script declares where it runs only through what it uses: a file that binds a key to a function and reads client state is client-local; everything else runs in the daemon. `cmux.client(fn)` marks an explicit client-local function inside a daemon script (it runs in the app engine of the client that triggered it).

Strongest objection to the split: "two engines double the bug surface and behavior can diverge." Answer: the client engine is limited to a small, trusted, latency-sensitive set, both engines run one ABI and one generated global, and the conformance suite covers both; the alternative of a daemon round trip for every key function costs 50 to 300 µs per call and cannot read client presentation state at all.

## 4. Where scripts run

In the daemon's supervision, not in the client. The daemon (cmux-tui-core) owns a `script` module: it spawns script host processes, holds the caller's principal, routes every nested op through the normal op router, enforces limits, and writes the audit. This is R73 D4 applied to every script, not only agent code mode.

- Script host process: the `cmux-app-host` binary in script mode (one crate, one sandbox, one ABI, one generated global), one process per principal and trust level. A one-shot run reuses a warm process of its principal when one is idle.
- The Mac app runs only client-local code in JavaScriptCore (section 3.4). The in-app console is a view over `script.repl.*` ops; its evaluation runs in the daemon.
- iOS runs client-local code in JavaScriptCore (interpreter only on iOS) under the same rules; the iOS console sends code to the paired host's daemon, and results stream back over the existing relay.
- Remote hosts: a script runs on the daemon it was sent to; `cmux.machine("mini")` addresses another daemon through the relay with the same selectors the resource API already has (`machine`, `session` ancestors).
- Persistent handlers (event handlers and actions from config) live in a long-lived script host owned by the daemon, so they keep running with no client, no terminal and no open CLI. Handlers that live only while a CLI process runs would stop when the terminal closes; daemon ownership avoids that.
- Persistent handlers reuse the journal hook machinery instead of a second event pipeline: a config script's `cmux.on(...)` registers a journal hook whose delivery is `script {host, handler}` instead of `exec.argv`. It inherits the durable cursor, receipts, bounded retries and causal loop prevention that `journal_hooks.rs` already has, so a handler that misses events while the host restarts resumes from its cursor. One-shot `cmux.wait` and `cmux.events` read `session.journal.subscribe` with the same filters (kinds, subjects, regex), so matching happens in the daemon and the script receives only matching events.

## 5. The API: generated once

The script global is the app global with a script profile, generated by the same generator (`tools/gen-cmux-global.ts`, later the D7 merged IR emitter) from the same catalogs:

- `cmux.<family>.<op>(args)` for every resource op, app op, browser-host op, cloud op and (after their relays land) `cua.*` and `acp.*` ops, filtered to the caller's view. `cmux.call(name, args)` is the untyped fallback. Errors throw `CmuxError {code, message, details, retryable}` (programmability.md "Errors").
- `cmux.ops.list()`, `cmux.ops.describe(name)`: the self-describing API, from the same catalog that `cmux docs search` reads.
- Events: `cmux.on(name, filter?, fn)` and `await cmux.wait(name, filter?, {timeoutMs})`, generated from `events.md` names and payload types; `for await (const ev of cmux.events(names, {scope}))` for streams. Scopes: the current workspace (default), `{session}`, `{all: true}`. Terminal events include output, bell, title, cwd, process, exit, notification, OSC 7501 `program_status_changed` and `program_status_removed`.
- Actions: `cmux.action({name, title, args, run})` defines a user action `user.<name>`. The existing `cmux.json` `actions.<name>` entries (`type: command | agent`, today `cmuxConfig.<name>`) become the declarative form of the same thing: one registry, one id namespace, one palette and keymap path. Args use the catalog's TypeIR or JSON Schema. `run(ctx, args)` gets `ctx = {origin: key|palette|cli|mcp|api|script, workspace, pane, tab, terminal, client}` and returns a JSON result. A user action appears in the palette, the keymap, `cmux action run user.<name>`, MCP (opt in), and the API, through the existing action catalog surfaces.
- Keys: `cmux.keys.bind("cmd+k>s", "user.save_all")`, `cmux.keys.bind("ctrl+[KeyA]", fn)`, `cmux.keys.mode("resize", {exclusive})`, `cmux.keys.bind("resize/left", "pane.resize", {direction: "left"})`, `cmux.keys.unbind(...)`, `cmux.keys.list()`. These write the keybindings owner's layers (keybindings.md section 8), so the Settings page, `cmux keymap` and collision diagnostics see them. Priority: built-in defaults, then script bindings, then bindings set in Settings.
- Layouts: `cmux.layout.terminal({command, cwd, input})`, `.browser({url, profile})`, `.agent({harness, prompt})`, `.split("right", 0.6, a, b)`; `cmux.workspace.create({layout})` applies one tree in one op with one idempotency key.
- Domain modules, all thin over catalog ops:
  - `cmux.terminal`: `send`, `sendKeys`, `screen({format: text|html|vt})`, `waitExit`, `programStatus`, `waitFor(regex)` (server-side match on the journal, no client polling).
  - `cmux.browser`: discrete ops plus `cmux.browser.repl(session).eval(code)`; v2 option: the Playwright runtime in the script VM with driver calls through the browser host's gate (section 9, decision 5).
  - `cmux.agents`: spawn an ACP session with a harness, cwd and policy; `prompt`; `for await (const turn of agent.stream())`; answer permission questions; cancel, fork, change model or mode; read the transcript. Needs acpmux ops in the catalog through an owner relay (gap G3).
  - `cmux.cua`: `session({label})` with `observe`, `act`, `timeline`, following computer-use.md section 6 (gap G4).
  - `cmux.cloud`: machines list, create, pause, resume, snapshot, team VMs, from the cloud catalog through the host broker (code-mode.md, credentials stay outside the sandbox).
  - `cmux.notify`, `cmux.status` (sidebar status and progress), `cmux.ui.pick(items)` and `cmux.ui.input(prompt)` (native palette pickers; user principal only).
- Script values: `cmux.args`, `cmux.context` (the caller's workspace, pane, terminal), `cmux.log(level, ...)`, `cmux.exit(code)`, bounded `setTimeout` and `cmux.sleep(ms)`.
- Not available: `fetch`, filesystem, environment, process spawn. A script that needs a shell command runs it in a terminal through `cmux.terminal` ops, so the effect is visible and owned by the terminal. Scopes `net:fetch {origins}` and `fs:read {paths}` can be granted per script later (decision 6).

The Chief CLI (OptChat performance program, hq-6d) is `cmux chief` in the Rust CLI with a pipe mode and a TTY UI over the daemon socket. Today the conversation commands it needs (`conversation-list`, `-snapshot`, `-history`, `-op`, `-search`, `-typing`, `cloud-conversation-*`) exist only in the private v12 `sdk-schema.json`; `cmux.protocol/2` has only `room.*`. To keep one API, they become v2 resource ops first: `conversation.list/get/history/search/send` (the client message id is the v2 idempotency key) and one stream op `conversation.events` carrying changed, typing and draft events; Chief control (`chief.stop`, `chief.engine.get/set`) is v2 ops with risk metadata. `cmux chief` is then a CLI area over those ops, its TTY UI is presentation only, and scripts get `cmux.conversation.*` and `cmux.chief.*` from the same generator, with the same `agent_view` and approval rules. Cloud conversations go through the daemon that holds the person lease, the same broker pattern as `cmux.cloud`.

## 6. Surfaces

| Surface | Form |
| --- | --- |
| One-shot | `cmux script run <file.ts \| -e CODE \| ->` with `key=value` arguments or `--args JSON\|@file`, `--json` result, `--for 10m`, `--fail-fast`, `--machine M`. Exit codes follow `cli.md` (0 ok, 1 failed, 2 usage, 3 target not found or ambiguous, 4 daemon unreachable, 130 interrupted). |
| Action by name | `cmux action run <id> [args]` (existing action surface); `cmux script run file.ts --action NAME` loads a file's actions without installing them, for fast iteration. |
| REPL | `cmux script repl [--machine M]`: persistent session, top-level `const`/`let` kept, last value printed, completion from the generated types. In-app console pane (Mac) and iOS console are views over the same `script.repl.*` ops. |
| Config as code | `~/.config/cmux/scripts/*.ts` (and `init.ts` as the entry when present), loaded by the daemon into the persistent user script host; reload on file change with last-good kept on error; `cmux script check [path]` validates without applying; `cmux script reload`. JSON settings stay in `cmux-next.json`; scripts never duplicate a settings key. |
| Keys | bindings from scripts appear in Settings > Keyboard with source `script:<file>:<line>`. |
| MCP | `cmux_docs`, `cmux_exec`, `cmux_wait` (R73 section 3.1) call `script.exec` with the agent principal. |
| Apps | apps keep their manifest and scopes; an app's code runs in the same host with the app principal. |
| Automations | the `code` body calls `script.exec` on the target host. |
| Self-describing API | `cmux docs search`, `cmux docs describe <op>`, `cmux api call <op> JSON` (raw, typed errors). |

Daemon ops (owner `script` module of cmux-tui-core): `script.exec {code | path, args, timeout_ms, yield_ms, max_output, idempotency_key}`, `script.wait {cell, yield_ms}`, `script.cancel {cell}`, `script.cells.list`, `script.repl.open/eval/close/list/reset`, `script.config.status/check/reload`, `script.audit.list`. These extend R73's `cmux.code.*` ops; R73 and this plan land as one set of ops, not two.

## 7. Security model

Principals and trust levels, all checked by the daemon router per nested op, never by the script:

| Principal | Source | Default view | Extra rules |
| --- | --- | --- | --- |
| user | `cmux script run` from a person's terminal, config scripts, the in-app console | the user's full catalog view minus `never` ops | config scripts get no new rights by being config; destructive ops from a key binding run without a sheet (the key press is the gesture), from an event handler they need the user's standing grant for that action |
| agent | code from an agent terminal, MCP `cmux_exec`, ACP sessions | `agent_view(op, principal)` (R73 section 4): secrets excluded; destructive, send-external, money and restricted scopes need an approval | approval sheet on Mac and in Home; "allow for this session" creates a standing grant; audit of every nested call and the script text |
| app | installed apps | the app's granted scopes | intersection rule when an agent calls an app op |
| automation | Chief or team automations | the automation's declared scopes | team policy |

Rules: run tokens per cell (R73 3.4), never visible to the script; empty environment; OS sandbox per host process; memory 64 MiB per one-shot cell and 256 MiB per persistent host (settings `script.*`), wall time 60 s default for one-shot cells, unbounded for persistent handlers but every handler entry is bounded (250 ms CPU per entry, then the handler is disabled and the user is notified); output 256 KiB per answer; no script can raise its own principal; identity is stamped by the connection.

The agent pane `registry.js` (unsandboxed, main world, native bridge) is the one existing path that runs user JavaScript with ambient rights; this plan does not extend it, and a follow-up should move renderer extensions behind the app scope model.

Downloaded scripts are apps: sharing a script means packaging it as an app (manifest, scopes, store or local install), so there is one install, consent and update path.

## 8. Capability map

| Capability | cmux today | After this plan |
| --- | --- | --- |
| New session, run, split, send, send key, capture screen, wait for exit, zoom | resource ops and Rust CLI (`workspace`, `pane`, `tab`, `terminal` areas) | same, plus script modules |
| Run a script file, inline code, stdin, args, JSON result | code mode for agents only | `cmux script run` |
| Custom actions with typed args, run from palette, keys, CLI, API | built-in actions only | `cmux.action` |
| Key bindings to actions or functions, physical keys | per-action shortcut settings | `cmux.keys.bind` |
| Key sequences (prefix keys) and modes | none | dispatcher support (keybindings lead) plus `cmux.keys` |
| Merged keymap listing with sources | none | `cmux keymap` |
| Long-lived event handlers, blocking waits | `subscribe` stream on the socket | `cmux.on`, `cmux.wait`, persistent handlers in the daemon |
| Server events (clients, sessions, keymap changes) | events.md | same names, typed |
| Self-describing API (list, describe, call with JSON Schema) | `cmux docs search`, catalog | `cmux docs describe`, `cmux api call` |
| Other hosts by label | machines, relay, Cloud | `cmux.machine(label)`, `--machine` |
| Config file with reload and check | JSON settings with live reload | plus `scripts/*.ts`, `cmux script check/reload` |
| Program status OSC 7501 | implemented in the daemon and sidebar | exposed as typed events and `terminal.programStatus()` |
| Floating layers, detached blocks | none | out of scope here (layout model owner) |
| Agents, browser, computer use, Cloud VMs, iOS | separate surfaces | one script API (section 5) |

## 9. Decisions (Lawrence and the coordinator, 2026-10-08)

1. Engines: JavaScriptCore in the app for trusted client-local code only, QuickJS-ng in the daemon for everything else, one ABI and one generated global.
2. Code mode: replace the Bun runner with the script host after the phase 1 data.
3. Config as code: `~/.config/cmux/scripts/*.ts`; JSON settings stay unchanged.
4. Persistent handlers belong to the daemon.
5. Browser in scripts: `cmux.browser.repl(session).eval(code)` plus discrete ops in v1.
6. No file or network access in v1; grantable scopes later.
7. A one-time config importer in phase 5.

## 10. Phases (each lands with a failing test commit first)

| Phase | Scope | Behavior tests |
| --- | --- | --- |
| P1 (first shippable slice) | daemon `script` module with `script.exec/wait/cancel` and `script.repl.*`; `cmux-app-host` script mode; generated `cmux-script.d.ts` and global over resource ops; `cmux.on`/`cmux.wait` over existing subscribe events; type strip; CLI `cmux script run`, `cmux script repl`, `cmux script types`; user principal only | on a Linux Testbox daemon: a script creates a workspace with a split layout, sends a command, waits for a program status `done` record and returns JSON; `-e` and stdin forms; args parse; an infinite loop ends at the deadline with exit 1; memory cap ends the cell; `fetch`, `require`, `process` are undefined; a wait times out with a typed error; REPL keeps `const` across evals; generated global has one method per catalog op (artifact check of the generator output) |
| P2 | user actions, key bindings, sequences, modes; config scripts with reload and check; `cmux keymap` | a bound sequence runs a user action; a broken config keeps the last good load and reports file and line; palette lists the action; origin is `key` |
| P3 | agent principal: run tokens, `agent_view`, approvals, audit; MCP `cmux_exec/cmux_docs/cmux_wait` on the script host; retire the Bun runner | an agent cell cannot call an excluded op; decline fails the nested call; audit has one record per call |
| P4 | `cmux.agents` (acpmux relay ops), `cmux.cua` (relay), `cmux.cloud` (broker), `cmux.browser.repl` | spawn an ACP session, prompt, stream a turn, answer a permission question; a CUA session act and timeline read; a cloud machine list |
| P5 | remote `cmux.machine`, in-app console pane, iOS console, Windows daemon, config importer | script on host A drives a terminal on host B; iOS console eval round trip |

### 10.1 Phase 1 as built

- Host: `cmux-app-host --profile script` (64 MiB, 2 s per step without yielding). The session driver is `cmux_app_host::script` (no engine needed, so the daemon links it): it spawns the host, sends a `main` made of acorn, the browser REPL's cell host (`cmux-browser-host/js/repl-host.js`) and `js/script-prelude.js`, and runs each cell as the `eval` command. Cells have top-level await, keep top-level bindings, and answer the value of the last expression statement as JSON.
- Daemon: `cmux-tui-core::scripts` owns sessions per connection and routes a script's ops into the daemon's own dispatcher as the local user with origin `agent` (the rights of the CLI that started it), only ops the daemon owns. Wire commands `script-run`, `script-repl-open`, `script-repl-eval`, `script-repl-close`, event `script-log`, cancel through `cancel-request`. Agent-bound and remote connections are refused.
- Limits: 8 one-shot runs and 8 REPL sessions per connection, 32 sessions per daemon, 64 op calls in flight per session, 200 console lines per cell (the rest are counted and reported as `dropped_log_lines`), a result up to the host's 4 MiB line limit. A request id is required; `cancel-request` and a closed connection also end a session whose host is still starting.
- Events: every committed resource change (journal epoch) publishes `resource.changed` and the five family streams; `cmux.wait(stream, predicate, {timeoutMs})` re-checks its predicate on each. Terminal output is not a stream yet.
- CLI: `cmux script run (FILE | -e CODE | -) [KEY=VALUE ...] [--args JSON] [--timeout MS]`, `cmux script repl`, `cmux script types` (the generated `cmux-app.d.ts` plus `js/script-globals.d.ts`).
- Not in phase 1: the TypeScript type strip (it needs a new parser crate and a Cargo.lock change; `.ts` files are refused with a message until then), `cmux help script`, provider ops such as `action.run`, and Windows (the daemon answers nothing for `script-*` there; there is no Windows sandbox for the host yet).

Gates: Rust on a Blacksmith Testbox (fmt, clippy, focused tests), Swift on cmux-lawrence-2 for the console pane, review subagent for every daemon, protocol and security slice.

## 11. Ownership

The `script` module of cmux-tui-core owns cells, REPL sessions, persistent hosts, run tokens and the script audit (single writer). The keybindings owner owns binding layers; scripts write them through ops. The action catalog owner owns `user.*` action registration through ops. The app platform lead owns the host binary and ABI; script mode is a profile of it. Each domain owner (browser host, CUA host, acpmux, cloud) owns its relay ops.

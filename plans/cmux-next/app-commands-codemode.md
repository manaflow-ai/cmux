# App commands, app MCP tools and code mode (R73)

Status: proposal, app commands + codemode lead, 2026-10-04. Not implemented. Request R73 (Lawrence, 2026-10-04): "we need to allow apps to bring over their own scoped cli commands, and mcp commands. we need to have first class support for codemode in cmux as well. and the mcp commands that people bring over need to be in codemode support too."

Binding: ONE-CATALOG, UI-STACK, REACT-PAGES, PASSWORDS (spec decisions.md), identity-and-permissions.md (spec), app-platform.md sections 12.5, 13, 15, pane-protocol.md (R60), mcp.md, code-mode.md, actions.md.

## 0. What exists today (read 2026-10-04 on feat-cmux-next c4b5e502139)

- App ops already declare surfaces. Every first-party catalog fragment (`first-party-apps/*/catalog/*.json`, schema `cmux-app-host/schema/v2/cmux-app-catalog.schema.json`) has per op `cli: {path, visible}` and `mcp: {expose: default|opt_in|never, group?}`, plus `risk`, `class`, `idempotency`, `input`/`output` JSON Schema. `cli.path` is free text: most are `apps run cmux/<app> <verb>`, remote desktop uses top-level `rd open`. The validator (`cmux-app-manifest`) checks no CLI or MCP rule. No Rust CLI verb and no MCP tool reads the fragments yet. There is no daemon app supervisor yet (`apps-v1` is a plan, section 13).
- `cmux mcp serve` (Rust, `cli/mcp/*`) gives one tool per curated resource op, browser host op and app action. It has no app-op tools.
- Code mode prototype (code-mode.md): `cmux docs search`, `cmux run <script.ts>`, and a Bun MCP server with `cmux_docs` + `cmux_exec`. The script runs in Bun under bwrap (Linux) or `sandbox-exec` (macOS) behind `proxy.mjs`, which allows a request when its op name is in the embedded catalog. Bun must be installed. The proxy does not know the caller, so there is no per-principal scope check, no confirmation, no audit and no app ops.
- Identity: the daemon has no actor on resource ops. identity-and-permissions.md section 5: "until the actor stamp lands, agent requests are attributed as plain CLI". Any agent in a cmux terminal can already run the full `cmux` CLI.
- Prior art. Codex code mode (`codex-rs/code-mode-*`, Apache-2.0): two tools `exec` (raw JS in a fresh V8 isolate, nested tools on a `tools` global, `text()`, `store/load`, `yield_control()`, `ALL_TOOLS` for search, `yield_time_ms` and `max_output_tokens` pragmas) and `wait {cell_id, yield_time_ms, max_tokens, terminate}`. Nested calls go back through the normal Codex tool router, so approvals apply per nested call. Cloudflare Code Mode: MCP schemas become a TypeScript API, the script runs in a Worker isolate whose only bindings are the API. The Home mux (PR 16279) uses a Worker Loader code mode in the cloud.

## 1. App CLI commands

Decision proposed (D1): two forms, both generated from the op declarations in the app's catalog fragment (no separate `contributes.cli` block: one catalog).

- Short form `cmux <cli-name> <verb...> [flags]`, for example `cmux notes capture --text "buy milk"`, `cmux rd connect --host mini`. `cli-name` is one new manifest field (`cli: {name}`, `^[a-z][a-z0-9-]{1,23}$`).
- Qualified form `cmux apps run <app-id> <verb...> [flags]`, for example `cmux apps run cmux/notes capture --text x`. It always works. Scripts, docs for agents and automations use it.

Why not `cmux app <id> <verb>`: `cmux app` is already the app-owned scope (`cmux app new-window`, cli.md), so an app id there would collide with action verbs. Why not only the short form: a later built-in noun or a second app could take the name. Rules:

1. Built-in nouns always win. The short form is resolved only after the built-in grammar fails to match the first word, so an app can never shadow or intercept a built-in command.
2. The validator refuses a `cli.name` in the reserved list (every current built-in noun and alias, plus reserved future words: `code`, `docs`, `apps`, `app`, `mcp`, `run`, `help`, `x`, ...; the list lives in one JSON next to `scope-classes.json`). The registry keeps listed `cli.name` values unique per publisher-verified listing.
3. Two installed apps with the same `cli.name` (local and dev apps): neither gets the short form, the CLI prints both qualified forms, and the App Store shows a warning row.
4. `cli.path` becomes the verb path relative to the app (`capture`, `session start`). Validator: unique per app, `^[a-z][a-z0-9-]*( [a-z][a-z0-9-]*){0,2}$`. Existing fragments are migrated in the same change (the `apps run cmux/<app>` prefix is dropped).

Arguments come from the op's `input` JSON Schema: each top-level property is `--kebab-name`; booleans are `--x/--no-x`; enums are checked and completed; arrays repeat the flag; nested objects take JSON (`--filter '{...}'`); `--args '{...}'` or `--args-file -` gives the whole object; `cli.positional: ["text"]` (optional, new) maps positionals. Required fields are checked locally; the owner validates again. `--json` prints the typed result.

Help: `cmux notes --help` and `cmux notes capture --help` are generated from `docs`, property `description` and the manifest `strings` (English and Japanese; the user's language picks). The help says the app name, the publisher and the scopes that the op needs.

Resolution at run time: the supervisor writes `installed-catalog.json` (merged fragments of installed and enabled apps, with a revision) atomically into its state dir. The CLI reads that file for parsing, help and completion, so completion never waits on a socket. The call itself goes to the supervisor (`apps-run` today, `cmux.apps.run` in the IR) with the caller's principal. A disabled, hidden-but-enabled or uninstalled app: hidden apps keep their commands; disabled and uninstalled apps answer `app.not_enabled` with the enable command.

Completion: `cmux completion zsh|bash|fish` (new if absent) calls `cmux __complete <words>` which reads built-in grammar plus `installed-catalog.json`.

Scopes: the op's scope (IR `scope`) is checked by the owner for the caller's principal, and the app's own grant is checked too (confused deputy rule, spec app-platform.md: an agent calling an app op runs with the intersection of the agent's grant and the app's grant).

## 2. App MCP tools

Same op declarations, same filter as code mode (section 4), in `cmux mcp serve`:

- Tool name: op full name with `.` and `-` as `_` (`notes_capture`, `acme_diff_open`). The merged registry refuses two ops with the same tool name (validator for one app; supervisor at install time for two apps: the second install shows the conflict and is refused until one is removed). Names longer than 48 characters (client prefixes take the rest of 64) are refused by the validator.
- Input schema: the op's `input`; description: `docs` plus "(app <name>)".
- Listed only while the app is installed and enabled and `mcp.expose` is `default`, or `opt_in` and the user turned it on for that agent class. `never` is never a tool and is never in code mode.
- `tools.listChanged`: the server already watches the app; it also watches `apps-changed {revision}` and sends `notifications/tools/list_changed`.
- Risky ops: see section 4 (native confirmation).

## 3. Code mode as a first-class surface

### 3.1 Surfaces

- MCP profile `cmux mcp serve --profile code` with three tools: `cmux_docs {query?, ops?}` (search when `query`; with `ops` it returns the TypeScript declarations of those ops and their types), `cmux_exec {script, timeout_ms?, yield_ms?, max_output_bytes?}` and `cmux_wait {cell, yield_ms?, terminate?}`. The names keep the two landed tools; `cmux_wait` follows Codex `wait` for long scripts.
- CLI: `cmux code run <file.ts | ->` (stdin script), `cmux code types [--ops ...]` (prints the generated `.d.ts` for the caller's view), `cmux docs search|describe` stays the discovery verb. D2: rename the unreleased `cmux run <script>` to `cmux code run`; `cmux run` is too valuable a word and `pane run`/`workspace run` already mean "run a shell command".
- The Home mux, automations `code` bodies (automations-runtime.md) and the CLI use the same daemon op (3.3), so there is one implementation.

### 3.2 The script API

The script sees one global `cmux`, generated from the merged registry: the IR (pane-protocol.json, including the cloud catalog input) plus the fragments of installed and enabled apps. It is the same generator output as the app host's `cmux` global (`cmux-app-host/generated/`, `gen-cmux-global.ts` until emit-ir replaces it), filtered to the caller's view. First-party ops are `cmux.workspace.list()`, `cmux.notes.capture({text})`; third-party ops are `cmux.app("acme.diff").open({...})`; `cmux.call(name, args)` is the untyped fallback. Helpers: `text()`, `json()`, `image()` (output items), `cmux.stream(op, args)` (async iterator over a stream op, bounded by the cell's limits), `args` (CLI positionals after `--`). No `fetch`, `require`, dynamic `import()`, timers beyond `setTimeout` bounded by the cell, filesystem, environment or process access.

The model reads types through `cmux_docs {ops}` (generated TSDoc from `docs`), not by loading the whole catalog (74k tokens today). The script is TypeScript; types are stripped (no type check) before it runs. A wrong argument fails at the owner's schema validation with a typed error that names the field, which the model can fix in the next exec.

### 3.3 Where code runs (D4)

In the daemon, not in the client. New ops owned by a `code` module of the daemon (cmux-tui-core): `cmux.code.exec {script, timeout_ms?, yield_ms?, max_output_bytes?, idempotency_key}` returns `{cell, state: done|running, output[], result?, error?}`; `cmux.code.wait {cell, yield_ms?}`; `cmux.code.cancel {cell}`; `cmux.code.cells.list` (the caller's cells). Reasons: the daemon is where the caller's principal is known and checked, it already runs on Macs, Linux servers and cloud VMs, cells survive a restarted MCP client, and the Home mux and automations reach it without a second runtime.

Every nested call from the script is dispatched by the daemon's normal op router with the principal of the connection that called `code.exec`, marked `origin: script`, `via: code_cell <id>`. The cell never holds a token; it cannot widen its rights because it has no other way out than that router. App ops go to the supervisor like any other caller.

### 3.4 Sandbox (D3)

Recommendation: QuickJS-ng through rquickjs, the engine the Rust app host already uses (app-platform.md 13.1), in a child process `cmux-app-host --mode script`, one process per cell, spawned by the daemon with a socketpair (fd 3) and the app host's OS sandbox (macOS `sandbox_init` profile: no network, no exec, no file reads outside the runtime; Linux: seccomp + Landlock; the same on Freestyle VMs). TypeScript is stripped in the daemon with oxc before it is sent.

| Option | For | Against |
| --- | --- | --- |
| QuickJS-ng (chosen) | about 1 MB, builds everywhere Rust builds, hard memory limit and interrupt handler, no built-in I/O, same engine, ABI and generated global as apps (one runtime to secure) | interpreter, 10-50x slower than a JIT on CPU-heavy code (orchestration is I/O bound); a history of memory-safety CVEs, so the OS sandbox and process-per-cell are required, not optional |
| V8 (Codex, Deno) | fastest, mature isolate sandbox | 30-40 MB per binary, slow and fragile builds (the Codex fork needs prebuilt rusty_v8 artifacts; the default download 404s), a second engine next to the app host |
| JavaScriptCore | on every Mac | Linux needs WebKitGTK; not on servers |
| Bun + bwrap/sandbox-exec (landed prototype) | works now | needs Bun on every host; bwrap is often unavailable (no user namespaces on hardened servers); `sandbox-exec` is deprecated; the proxy only filters op names |

The strongest expert objection to QuickJS is engine memory safety. Answer: a script that escapes the engine lands in a process with no network, no exec, no file access and one socket whose every request is checked by the daemon for the caller's principal. The escape gains nothing the script could not already call.

Limits (defaults, settings under `code.*`): memory 64 MiB per cell (`set_memory_limit`), stack 1 MiB, wall time 60 s (max 600 s), script 256 KiB, output 256 KiB per exec or wait answer (cut with `truncated`), 64 nested calls in flight, 4 running cells per principal, 16 per daemon, cells kept 10 minutes after they end. The interrupt handler checks the deadline and the cancel flag. Cancellation (`code.cancel`, MCP `notifications/cancelled`, Ctrl-C in `cmux code run`, client disconnect for a CLI run): the daemon sets the flag, sends `request.cancel` for nested calls in flight, kills the process after 2 s, and reports each in-flight mutation's state (`not_run`, `applied`, `in_progress` with its idempotency key).

Streaming: output items stream as they are produced: MCP `notifications/progress` with the text, `cmux code run` prints them as they come (NDJSON with `--json`), `cmux.code.exec` with `yield_ms` returns early with `state: running` and the items so far.

## 4. Security

One function decides agent exposure for every surface (CLI app commands for agent principals, MCP tools, code mode): `agent_view(op, principal) -> Offered | NeedsApproval | Excluded{reason}`. Its inputs are IR fields only (`scope`, risk class from `scope-classes.json`, `mcp.expose`, `secret_output`, owner) and the principal's grant. Tests run it over the whole merged registry.

- No secrets: excluded for every agent principal, in every surface, with a reason: password ops (PASSWORDS P2), `*:keys` scopes, credential handles, account connect and sign-in, grant and policy changes, install and uninstall, `cmux.apps.grant.set`, ops whose output schema has a field marked `x-cmux-secret` (new IR flag, request to hq-48). The script process has an empty environment.
- Confirmation: ops with risk `destructive`, `send-external`, `money` or a restricted scope need an approval when the actor is an agent: the daemon sends `approval.request {op, args summary, principal, cell}`; the user answers in a native sheet (Mac) or the Home approval part; the nested call waits (the cell reports `awaiting_approval` through `wait`); decline answers `approval.declined`; no answer in 10 minutes answers `approval.timeout`. "Allow for this session" creates a standing grant for that exact op and resource for that principal. A `confirm: true` argument from an agent is not an approval (D6).
- Audit: the daemon appends one record per nested call `{ts, principal, on_behalf_of, origin, cell, script_sha256, op, args_digest, status, duration_ms, approval?}` and one per cell with the full script text (bounded, 30 days, then deleted). Read with `cmux.code.audit.list` (user origin and the user's own clients only).
- The per-agent part depends on the actor stamp (D5). Until agents present a launch credential, every local caller is "the user through the CLI", so "never more rights than the caller" holds, but per-agent grants and the agent-only confirmation rule cannot be enforced against an agent that also has a shell. The rules and tests land now; enforcement for agents switches on with the stamp.

## 5. Decisions needed (for Lawrence through the coordinator)

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | App CLI form | short `cmux <cli-name> <verb>` (built-ins win, reserved list, collisions lose the short form) + qualified `cmux apps run <app-id> <verb>` |
| D2 | `cmux run <script>` | rename to `cmux code run` (unreleased) |
| D3 | Sandbox | QuickJS-ng app host in script mode; delete the Bun runner, `proxy.mjs`, `mcp.mjs` and `run.ts` at parity |
| D4 | Where code runs | daemon op `cmux.code.exec`; clients only call it |
| D5 | Actor stamp | needed for real per-agent scopes; who builds it, and when? I can take the daemon side if no one owns it |
| D6 | Agent confirmation | native approval for agent principals replaces the self-asserted `confirm: true` (changes the 2026-10-01 MCP decision) |
| D7 | Default MCP profile for agents that cmux launches | `--profile code`; per-op tools stay available with `--profile tools` |
| D8 | `fetch` in scripts | none in v1, even with a `net:` scope |

## 6. Slices (red test commit first in each)

| # | Slice | Where | Red tests | Needs |
| --- | --- | --- | --- | --- |
| S1 | Manifest: `cli.name`, relative `cli.path`, `cli.positional`, reserved names, tool-name length and collision rules; migrate fragments | `cmux-app-manifest`, schema v2, `first-party-apps/*/catalog` | invalid fixtures: reserved name, duplicate verb, tool name collision, too long | crate slot; app platform lead agrees the fields |
| S2 | `agent_view` exposure function over the merged registry | new module in `cmux-tui-core` (or crate `cmux-op-policy`) | password, keys and credential ops excluded; destructive needs approval; `never` excluded; disabled app excluded | cmux-tui window; IR fields from hq-48 |
| S3 | CLI app commands: resolution from `installed-catalog.json`, schema-to-flags, help, completion | `cmux-tui/src/cli/app_commands*` | `cmux notes capture --text x` builds the run params; built-in wins; collision prints qualified forms; enum and required checks | cmux-tui window; supervisor writes the file (app platform lead) |
| S4 | MCP app-op tools + `list_changed` on `apps-changed` | `cli/mcp/app_op_tools.rs` | parity: every exposed app op is a tool or an exclusion with a reason | cmux-tui window |
| S5 | Script runtime: `cmux-app-host --mode script`, oxc strip, limits, cancel | `cmux-app-host`, `cmux-tui-core::code` | infinite loop stops at the deadline; memory bomb fails; no `fetch`/`require`/`import()`; cancel during an await; output cut | cmux-tui window; depends on the Rust app host landing |
| S6 | Daemon ops `cmux.code.exec/wait/cancel/cells.list/audit.list`, caller-principal dispatch, approvals, audit | `cmux-tui-core::code` | script cannot call an excluded op; approval decline fails the call; one audit record per nested call | cmux-tui window; IR entries (hq-48) |
| S7 | Surfaces: `cmux code run`, `cmux mcp serve --profile code`, `cmux_docs {ops}` d.ts; delete the Bun path; update `skills/cmux-code-mode` | CLI, scripts, skills | end-to-end: the four measurement tasks in code-mode-measurements.md | cmux-tui window |

All Rust builds and tests run on a Blacksmith Testbox. S1 and S2 can start now. S5 waits for the Rust app host (app platform lead, section 13); if that slips, S5 can host QuickJS in a small `cmux-code-host` binary with the same ABI and fold into the app host later.

## 7. Coordination

- App platform lead: `cli` block fields (S1), the supervisor's `installed-catalog.json` and install-time tool-name conflict check, `--mode script` in the app host (S5).
- hq-48 (pane protocol IR): per-op `scope`, `mcp.expose`, `cli`, `x-cmux-secret` in the IR; `cmux.code.*` ops declared with schemars; the TS generator emits the `.d.ts` that `cmux_docs {ops}` returns.
- Home lead and automations runtime: consume `cmux.code.exec` instead of a second runtime (the cloud mux keeps the Worker Loader until a cloud daemon serves the op).
- code-mode.md owner: this plan replaces the Bun runner; code-mode.md and code-mode-measurements.md stay as the measurement record.

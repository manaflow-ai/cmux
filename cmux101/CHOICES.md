# cmux101 — Engineering Choices

This document records the load-bearing decisions for cmux101. Each section
captures the choice, the alternatives considered, and the reason. Future
contributors should re-open these decisions only when the reasons change.

## 1. Language & runtime: TypeScript on Bun

**Decision.** cmux101 is written in TypeScript and runs on Bun. We target
Bun ≥ 1.2 and ship a compiled single-binary via `bun build --compile`.

**Why over the alternatives.**

| Option | Why not (for this project) |
|---|---|
| Rust (like Codex CLI) | Best sandboxing story, but provider SDK churn is brutal in Rust — every new model feature (cache breakpoints, thinking blocks, MCP, response API) lands in TS/Python first and trickles to Rust months later. For a coding agent that has to keep up with seven providers, that lag is the project. |
| Go (charm.sh TUI) | Excellent CLI ergonomics and a beautiful TUI ecosystem, but the same SDK-lag problem as Rust, and worse — no first-party Anthropic Go SDK at parity with the TS one. We would re-implement provider clients ourselves. |
| Python | Best SDK coverage. Loses on cold-start (~200ms even with `-S`), distribution (uv/pipx is fine but not a single binary), and concurrency for parallel subagents. |

**Why Bun specifically over Node.**

* Cold start ~30–40ms vs Node's ~80–120ms — meaningful for a CLI a human types
  dozens of times a day, and for `--print` mode used in scripts.
* `bun build --compile` gives a real single binary with embedded runtime. No
  `pkg`/`nexe` hacks. Cross-compilation to linux-x64/linux-arm64/darwin-arm64
  works out of the box.
* `bun:test` is fast enough that we run tests in the inner loop without
  setting up Jest/Vitest.
* `bun shell` ($`...`) gives ergonomic, safe shell composition for tools that
  shell out (cmux integration, git plumbing) without exec-injection footguns.
* Built-in TS, JSX, `.env` loading, `fetch`, web streams. We skip 6 build-tool
  dependencies on day one.

**The cost we accept.** Bun is younger than Node; some npm packages with
native bindings occasionally break. We mitigate by pinning to mainstream
packages (the official provider SDKs, `zod`, `ink`, `@modelcontextprotocol/sdk`)
and keeping a Node-compat fallback path for `bunx` invocation of MCP servers.

## 2. Provider abstraction shape

**Decision.** One internal `Provider` interface that exposes a single method:
`stream(request) -> AsyncIterable<StreamEvent>`. Streams emit normalized
events (`text-delta`, `tool-call`, `tool-call-delta`, `thinking`,
`message-stop`, `usage`). Each provider adapter is responsible for translating
its native SSE/JSON-lines format into these events.

**Why.**

* Streaming is the only API shape that supports a snappy TUI. Non-streaming
  endpoints are wrapped to emit a single delta then stop.
* Tool-call normalization is the part that breaks if you let providers leak
  through. Anthropic emits `tool_use` content blocks with `input_json_delta`
  events; OpenAI emits `tool_calls` with `arguments` deltas; Gemini emits
  `functionCall` parts; OpenRouter inherits from OpenAI but with quirks. We
  normalize once at the adapter boundary so the runner is provider-blind.
* The interface is intentionally small. Anything provider-specific
  (cache breakpoints, thinking budgets, safety settings) is passed through an
  opaque `providerOptions` field that adapters can introspect.

**The alternative we rejected.** A "lowest common denominator" approach where
the abstraction does message translation but exposes provider-native tool
shapes. That pushes provider conditionals into every tool-call site in the
runner. Bad.

## 3. Tool system: capability-gated, runner-mediated

**Decision.** Tools are plain TS modules that export `{ name, description,
inputSchema, run(input, ctx) }`. The `ctx` includes a `permissions` object,
the session, an `abortSignal`, and a `subagentDispatcher`. Tools never read
provider responses directly — everything flows through the runner.

**Why.**

* zod schemas double as JSON Schema for the model (`zod-to-json-schema`) and
  as runtime validators for the tool input. One source of truth.
* Permissions live in `ctx`, not as decorators or a global. A subagent can be
  given a `ctx` with a narrower `permissions` than its parent; that is how
  scoped allowlists work — there is no separate enforcement layer.
* Tools are pure(ish) async functions, easy to unit-test without spinning up
  a model.

## 4. cmux integration: shell out, don't link

**Decision.** cmux integration is a tool pack that shells out to the `cmux`
binary (`cmux help` enumerates the surface). We do NOT link against any cmux
internals or its Unix socket directly. The tool pack is loaded conditionally
when `cmux --version` succeeds at startup.

**Why.**

* cmux's CLI is its public contract. Its socket protocol is not. Shelling out
  through `cmux` insulates us from socket-format changes.
* It keeps cmux101 truly cross-platform — the cmux pack just refuses to load
  on systems without cmux, and everything else still works.
* We get auth, path discovery, and password handling for free from the
  `cmux` binary.

## 5. TUI: Ink + a thin rendering layer

**Decision.** Interactive mode uses [Ink](https://github.com/vadimdemedes/ink)
(React for terminals) with a hand-written component tree. `--print` mode
bypasses Ink and writes plain text to stdout.

**Why.** Ink gets us flexbox, focus management, and component testability
without writing a TUI framework. The alternatives (raw ANSI like Codex CLI,
or bubbletea via FFI) cost more iteration time than they save. We accept
Ink's ~30ms-per-frame ceiling because a coding agent doesn't render at 60fps.

`--print` is intentionally separate. Many users will invoke cmux101 from
shell scripts (`cmux101 -p "summarize this diff"`); they want stdout to be
pipeable plain text, not ANSI-laden.

## 6. Session persistence: JSONL on disk

**Decision.** Each session is a directory under
`~/.cmux101/sessions/<session-id>/` containing `transcript.jsonl` (one
event per line, append-only), `meta.json` (model, cwd, started_at), and
optionally `snapshots/` for tool outputs over 64KB.

**Why.** Append-only JSONL survives crashes, is trivial to tail, and is
diffable. SQLite was tempting (Claude Code uses it) but adds a native
dependency and a schema-migration burden that JSONL does not.

## 7. Hooks: subprocess + stdin/stdout JSON

**Decision.** Hooks are external programs registered in `~/.cmux101/config.json`
or `<project>/.cmux101/hooks.json`, invoked with the event name as argv[1]
and the event payload on stdin. The hook's stdout is parsed as a JSON
response that can `block`, `transform`, or `pass`.

**Why.** Treating hooks as subprocesses (not in-process JS) means users can
write them in any language and that a broken hook can never crash cmux101.

## 8. Auth & secrets

**Decision.** Per-provider credentials live in the OS keychain when
available (`keytar`-style via Bun's `Bun.password` + a thin wrapper around
`security` on macOS, `secret-tool` on Linux, `wincred` on Windows). Env vars
override keychain. A plain-file fallback (`~/.cmux101/credentials.json`
chmod 600) is offered with an explicit confirmation.

**Why.** Coding agents that store API keys in plaintext dotfiles are how
keys end up in `git status` output and Slack screenshots.

## 9. What we explicitly do NOT do (yet)

* No agent-side rate-limit retry with exponential backoff beyond a single
  retry — providers' own SDKs handle this and adding another layer hides
  the real signal that you're being throttled.
* No "auto" model routing. The user picks the model. Magical routing
  (Sonnet for code, Haiku for chit-chat) is opaque and hard to debug.
* No background daemon. Each `cmux101` invocation is self-contained. State
  lives on disk.

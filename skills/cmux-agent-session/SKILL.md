---
name: cmux-agent-session
description: "Agent-session and Kanban-live subsystem rules for cmux: the one-spawn / many-observers process store, provider-specific stdout parsing, the WKWebView renderer + native bridge, and webview build discipline. Use when editing AgentSessionProcessStore, AgentSessionEventFanOut, ClaudeStreamJSONAccumulator, OpenCode/Codex stream parsing, CmuxLiveBackend/CmuxNativeBackend, the AgentSession or Kanban web renderer coordinators, the webviews/ agent-session or kanban bridges, or adding a new agent provider."
---

# cmux Agent Session & Kanban Live

The agentSession surface and the Kanban "Live" card share one runtime: a native subprocess store that fans its output to multiple observers, a provider-specific stdout parser, and a WKWebView renderer driven by a native-authoritative bridge. These are the rules that keep that runtime correct. For broader Swift package/concurrency discipline, also load `cmux-architecture`; for the WKWebView find/socket/focus rules see `cmux-socket-policy`.

## Subsystem map

- `Sources/Panels/AgentSessionProcessStore.swift` — owns one agent subprocess (`Process` + `Pipe`) and fans its events out via `AgentSessionEventFanOut`.
- `Sources/Panels/AgentSessionRunningSession.swift` — per-session state (process, pipes, input writer, stdout/stderr drain tasks, termination escalation, the per-provider accumulators).
- `Sources/AgentSessionProvider.swift` — `AgentSessionProviderID` (codex / claude / opencode): launch arguments, env, and `shouldAutoStartSession`.
- `Sources/Panels/ClaudeStreamJSONAccumulator.swift` — Claude/Codex/OpenCode stream-JSON parser feeding assistant text to the UI.
- `Sources/Panels/AgentSessionWebRendererCoordinator.swift` — the WKWebView host for the `agentSession` panel.
- `Sources/Kanban/CmuxLiveBackend.swift` / `CmuxNativeBackend.swift` — the two Kanban `DispatchBackend`s.
- `Sources/Kanban/KanbanWebRendererCoordinator.swift` — the WKWebView host for the `kanban` board.
- `webviews/src/agent-session/*`, `webviews/src/kanban/*`, `webviews/src/shared/nativeBridge.ts` — the JS side (React + Solid renderers, shared bridge).

## One spawn, many observers (the core invariant)

- `AgentSessionProcessStore` spawns the agent process **exactly once** and is the single source of truth for that process's lifecycle.
- Multiple consumers attach to the **same** store through `AgentSessionEventFanOut` — a primary sink **plus** keyed additional observers. A visible agentSession surface owns the spawn; a Kanban live card observes the same store.
- **`CmuxLiveBackend` must never call `store.start()`** — it attaches as an observer (`addEventObserver`) to a store a visible surface already started. Only the surface (or `CmuxNativeBackend`, which runs its own headless per-card agent) spawns. A live backend that spawns its own process double-runs the agent.
- When adding a consumer, register it as a keyed observer. **Never** replace the fan-out's primary sink with a plain closure when a second observer may be attached — that silently drops every other observer.
- `CmuxNativeBackend` (headless per-card) and `CmuxLiveBackend` (observe-a-visible-store) are not interchangeable; pick by whether a visible surface owns the run.

## Provider-specific stdout routing

- Stdout/stderr are drained on detached tasks keyed by the raw fd (an `Int32` is `Sendable`; a `FileHandle` is not). Keep that shape when touching the drain loop.
- Provider launch contract lives in `AgentSessionProvider`. Claude runs in stdin streaming mode: `-p --output-format stream-json --input-format stream-json --include-partial-messages --verbose`, and `shouldAutoStartSession == false` (claude waits for the first prompt over stdin; do not auto-start it).
- `ClaudeStreamJSONAccumulator` handles **two** assistant-text shapes: incremental `content_block_delta` (streaming SSE) **and** full `assistant` message objects (non-streaming). For non-streaming, it emits only the not-yet-sent suffix using a per-message-ID character count — do not re-emit whole messages on repeated delivery.
- Turn completion is any of `type == "result" | "message_stop" | "done"` (covering Claude, Codex, and OpenCode). A nested `message_stop` inside a `stream_event` envelope must be unwrapped before turn-tracking logic runs; do not reset turn tracking on the envelope.
- Adding a new provider = add an `AgentSessionProviderID` case with its launch args/env + `shouldAutoStartSession`, route its stdout through the matching accumulator, and add the turn-completion sentinels it emits. Do not special-case a provider inside the fan-out.

## Webview renderer + native bridge

- The coordinator loads the webview chunk over `file://`. Any `WKWebViewConfiguration` for a code-split React/Solid surface **must** enable both file-access SPI keys — `allowFileAccessFromFileURLs` (on `preferences`) and `allowUniversalAccessFromFileURLs` (on the configuration) — via the shared file-URL-access helper. Without both, WebKit rejects the cross-origin module fetches, `main.mjs` never runs, and the panel is a **silent blank** (no JS executes, so in-page error hooks cannot fire). The single-file inlined Solid bundle sidesteps this; a new React/`import()`-based surface does not.
- The bridge is installed synchronously at module eval: `window.cmuxAgentBridge` / `window.cmuxKanbanBridge` via `createNativeBridge`. JS→native goes through `window.webkit.messageHandlers.<handler>.postMessage`; native→JS pushes call `window.cmux*Bridge.receive(event)`.
- State is **native-authoritative**: every reply and every pushed event replaces the whole session/board model in the JS reducer (`agent-session/shared/sessionModel.ts`, `kanban/shared/boardModel.ts`). Do not maintain a divergent client-side copy; the native side is the single source of truth.
- For Kanban, theme must be applied eagerly in `loadInitialBoard` — native applies theme before the bridge is registered, so a late theme push is lost.

## Build & test discipline

- **Rebuild webview assets with `./scripts/build-webviews-app.sh` (or `--check`), never bare `bun run build`.** Vite's `emptyOutDir: true` deletes the HTML shells (`agent-session.html`, `kanban.html`) that the wrapper writes post-Vite (it also inlines `marked.min.js` and normalizes whitespace). A bare `bun run build` leaves a broken bundle.
- Verify webview TS with `cd webviews && bun run typecheck` and `bun run test`.
- Cover the native side with the package/app test suites: `CmuxLiveBackendTests`, `AgentSessionEventFanOutTests`, `AgentSessionWebRendererTests`, `CodexAppServerSessionTests`. New stream-parser or fan-out behavior needs a behavior-level test (a runtime debug build writes its event log to `/tmp/cmux-debug-<tag>.log`).
- New Swift here follows `cmux-architecture` (Swift 6 `actor`/`@Observable`/async; no Combine/`@Published`, no locks-as-mutex except the documented one-shot-resume carve-out for racing `Process`/timeout continuations).

---
name: cmux-kanban
description: "Rules for the cmux Kanban autonomous-agent board: the CmuxKanbanCore engine, the DispatchBackend protocol, WIP/column policy, cancel routing, and the board WKWebView. Use when editing Packages/macOS/CmuxKanbanCore, KanbanEngine, DispatchBackend implementations (CmuxNativeBackend/CmuxLiveBackend), KanbanWebRendererCoordinator, or the kanban webview."
---

# cmux Kanban

The Kanban board dispatches autonomous agents to cards. Its model and orchestration live in the standalone package `Packages/macOS/CmuxKanbanCore`; the app wires two dispatch backends and a WKWebView board panel on top.

## CmuxKanbanCore package

- Value model: `KanbanBoard`, `KanbanCard`, `KanbanColumn` (cases `backlog`, `ready`, `building`, `testing`, `done`, `blocked`, `failed`), `KanbanCardProgress`, `KanbanDispatchHandle`, `KanbanDispatchSession`, `KanbanDispatchProgress`, `KanbanBackendKind`, plus `KanbanBoardRepository` for persistence.
- `KanbanEngine` is an **actor** — the single serialized source of truth. `moveCard`, `dispatch`, and **every backend progress event** are serialized through it. Backends report raw lifecycle facts; the engine owns column-transition policy. Do not move column-transition logic into a backend.
- **WIP:** `KanbanColumn.occupiesWipSlot` is `true` for `.building` and `.testing` only; `KanbanBoard` defaults `wipLimit` to `2`. Respect the WIP limit through the engine — don't dispatch around it.

## DispatchBackend protocol

- `public protocol DispatchBackend: Sendable` with `dispatch(card:workingDirectory:) async throws -> KanbanDispatchSession` and `cancel(_ handle: KanbanDispatchHandle) async`.
- The engine holds two backends: `backend` (the default, **headless** per-card agent — `CmuxNativeBackend`) and `liveBackend` (for `dispatchLive(cardId:)`, an interactive **visible** agent session; defaults to `backend` when not provided).
- **Cancel routing invariant:** the engine stores a per-running-card handle **paired with the backend that started it** (`handles: [UUID: (handle, backend)]`). `cancel` routes to *that* backend, never a global/shared store. When adding a dispatch path, keep the started-by backend paired with its handle so cancel reaches the right one.
- `CmuxLiveBackend` is the live `DispatchBackend`: it **observes** a shared `AgentSessionProcessStore` owned by a visible surface and **must not spawn** its own process (`store.start()`). The headless `CmuxNativeBackend` runs its own per-card agent. See `cmux-agent-session` for the one-spawn/many-observers contract.

## Board WKWebView

- `Sources/Kanban/KanbanWebRendererCoordinator.swift` hosts the board `WKWebView` and lazily creates the `KanbanEngine` + both backends.
- State is **native-authoritative**: a `boardUpdated` event replaces the whole board model in the JS reducer (`webviews/src/kanban/shared/boardModel.ts`). Theme must be applied eagerly in `loadInitialBoard` (native applies theme before the bridge registers).
- The board is a code-split React surface loaded over `file://`, so the coordinator must set the file-URL SPI keys (see `cmux-webviews`).

## Tests

- Package tests: `swift test --package-path Packages/macOS/CmuxKanbanCore` (`KanbanEngineTests`, the `ScriptedDispatchBackend` fixture). App-level live wiring: `CmuxLiveBackendTests`.
- New engine behavior (column transitions, WIP, cancel routing) needs a behavior-level test driven by a scripted backend, not just a compile check.

## Related

- New Swift in the package follows `cmux-architecture` (Swift 6 actor/`@Observable`/async; DocC on public symbols; constructor injection).
- The live agent runtime feeding live cards: `cmux-agent-session`. The webview side: `cmux-webviews`.

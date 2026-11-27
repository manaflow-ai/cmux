# Fully data-driven custom sidebars: data, commands, hooks

Goal for the release: an interpreted sidebar can **read all cmux runtime state**, **invoke any cmux command**, and **react to any cmux event/hook**. This documents the real surface (grounded in the v2 dispatcher + event bus) and the architecture/waves to get there.

## The realization: one protocol already backs all three

cmux's v2 socket dispatcher (`TerminalController.processV2Command`, `Sources/TerminalController.swift:3335`) is the single source of truth for both reads and writes, and `CmuxEventBus` is the single source of truth for hooks. So we do not hand-maintain three parallel surfaces; we project the dispatcher + bus into the interpreter:

- **Commands (write)** — `cmux(method, params)` already routes through `runV2CommandLine` → the full 248-method dispatcher. Every command is *already invokable*. What's missing is discoverability (a catalog), typed-param robustness, and capability scoping.
- **Data (read)** — the dispatcher's query methods already assemble rich payloads. Project those into a `data` value tree instead of the current hand-built 4-key context.
- **Hooks (events)** — `CmuxEventBus` already emits every lifecycle event with a uniform schema. Subscribe to all of it and surface it to the interpreter.

## Command surface (248 methods)

| namespace | count | notable |
|---|---|---|
| browser | 84 | navigate/click/eval/screenshot/network/cookies/storage/tabs/... |
| workspace | 44 | list/current/select/new/close/reorder/group.*/remote.*/rename/color |
| surface | 24 | list/current/focus/new/close/send/send-key/report_*/resume.* |
| debug | 39 | (debug-only) |
| notification | 10 | list/create/read/remove/clear/create_for_target |
| pane | 9 | list/focus/split/close/... |
| feed | 6 | list/tui/clear/... |
| system | 6 | — |
| vm | 6 | list/attach_info/ssh_info/new/rm/exec |
| window | 5 | list/current/new/focus/close |
| auth | 4 | status/login/sign_out/begin_sign_in |
| app/feedback/events/extension/file/markdown/session/settings/tab | 1–2 each | — |

Full machine catalog: `cmux capabilities` (method list) — should be generated into the authoring docs + skill so authors/agents know every method and its params.

## Data surface (read)

Query methods returning structured payloads (project all into the `data` tree):
- `workspace.list` / `workspace.current` / `workspace.group.list` — id, ref, title, description, selected, pinned, listening_ports, remote, current_directory, custom_color, latest_conversation_message, latest_submitted_message, latest_submitted_at, index.
- `extension.sidebar.snapshot` (richest) — adds root_path, project_root_path, branch_summary, remote_display_target, remote_connection_state, unread_count, latest_notification_text, pull_request_urls, panel_directories, git_branches. (`TerminalController.swift:5525`)
- `surface.list` / `surface.current` — id, ref, index, type, title, focused, pane_id, working dir, initial_command, resume_binding; browser: developer_tools_visible. (`:8615`)
- `pane.list`, `window.list`/`window.current`, `notification.list`, `feed.list`, `vm.list`, `auth.status`, `workspace.remote.status`.

Underlying model (`Workspace.swift:10243+`) carries even more per-workspace/per-surface state: `gitBranch`/`panelGitBranches` (branch + dirty), `pullRequest`/`panelPullRequests`, `surfaceListeningPorts`, `remote*` (connection state, detected/forwarded/conflicting ports, live SSH session count), `latestConversationMessage`/`latestSubmittedMessage`, `progress`, `logEntries`, `statusEntries`, `metadataBlocks`, `manualUnreadPanelIds`, `panelShellActivityStates`, `agentPIDs`/`agentPIDPanelIdsByKey`.

**Gaps not yet queryable (need new exposure for "fully data-driven"):** agent/session process state (`agentPIDs`), per-surface shell activity (`panelShellActivityStates`), per-surface ports in `surface.list`, per-surface resume bindings in bulk, terminal TTY/process info, browser content state (URL/title outside `browser.*`), sidebar `statusEntries`/`metadataBlocks`.

## Hook/event surface (CmuxEventBus)

Uniform event schema (`CmuxEventBus.swift:181`): type, protocol, version, boot_id, seq, id, **name**, **category**, source, occurred_at, workspace_id, surface_id, pane_id, window_id, payload.

Emitted names by category (`CmuxEventPublishing.swift`):
- `workspace.*` — created, closed, selected, reordered, prompt_submitted
- `surface.*` — created, closed, selected, focused
- `pane.*` — created, closed, focused
- `notification.*` — created, read, removed, cleared
- `window.*` — lifecycle
- `workstream.*` — start / progress / complete

Subscribe via `CmuxEventBus.subscribe(afterSequence:names:categories:)`; the socket `events` command streams them. Agent lifecycle hooks (`CLI/CMUXCLI+AgentHookDefinitions.swift`) exist for codex/grok/cursor/gemini/kiro/antigravity/hermes — session-start/prompt-submit/stop/notification/session-end/shell-exec — recorded to `~/.cmuxterm/{agent}-hook-sessions.json`.

## Architecture

```
interpreted sidebar (.swift)
        │  reads                         │  writes               │  reacts
        ▼                                ▼                       ▼
   data.* value tree            cmux(method, params)        on(event) / event.*
        │                                │                       │
   DataContextProvider          SidebarActionDispatch      EventBridge
        │  (projects)                    │ (already全)            │ (subscribes all)
        └──────────────► TerminalController v2 dispatcher ◄───── CmuxEventBus
```

- **DataContextProvider** (host): builds the `data` SwiftValue tree each refresh by reusing the same payload builders the v2 query methods use (workspace summary, extension snapshot, surface/pane/window/notification/feed/vm/auth). Exhaustive-by-construction: every field the dispatcher can return is projected. Lives in the app target (touches `TerminalController`/`Workspace`), feeds the package via the existing `dataContext` param.
- **SidebarActionDispatch** (exists): `cmux(method, params)` → `runV2CommandLine`. Extend param typing (numbers/bools/arrays), add a **capability scope** (allow/deny method globs) so untrusted authored sidebars can't call `auth.sign_out`/`browser.eval`/`vm.rm`.
- **EventBridge** (host): one `CmuxEventBus.subscribe` over all names/categories; pushes `events.latest`, `events.recent[]`, per-category counts, and agent-hook lifecycle state into the data tree, and triggers a re-walk on each event (replacing/augmenting the 1s TimelineView tick with event-driven refresh). With the state engine (below), exposes author `on(event)` handlers.

## Waves

- **Wave A — Full read surface (fully data-driven).** Replace the 4-key `customSidebarDataContext` with the `DataContextProvider` projecting all query payloads + the rich `Workspace` model fields. Additive, low-risk. Personas immediately populate with real data. Includes surfacing the current gaps (agent state, shell activity, per-surface ports) as new fields.
- **Wave B — Events/hooks reactive.** EventBridge subscribes to the whole bus; expose `events.*` + agent-hook state; event-driven re-render. Surface every event name/category.
- **Wave C — State engine + reactivity + input controls.** SwiftUI-surface roadmap Phase 2: a host-owned `@State`/`$binding` engine. Unlocks TextField/Toggle/Picker/Slider, write-actions beyond `cmux()`, and author `on(event){…}` handlers. The largest lift; gates ~interactivity.
- **Wave D — Command catalog + capability scoping + typed params.** Generate the full `cmux capabilities` catalog into authoring docs and a Swift interpreter knowledge reference; add capability scoping (default-deny dangerous namespaces for untrusted sidebars); robust param coercion. Security gate for "all commands exposed."
- **Interleave — leaf SwiftUI views/modifiers** from `docs/swiftui-interpreter-surface.md` Phase 1 (List/Section/LazyVStack/Grid/Label/ProgressView/gradients/overlay-background/styles) so the richer data has richer views to render into.

## Open decision: scope of "all commands / all hooks" for authored sidebars
Exposing all 248 methods to any `.swift` file a user or in-pane agent drops in includes destructive/sensitive ones (`auth.sign_out`, `browser.eval`, `vm.rm`, `workspace.close`). Options: (1) expose everything (trust local author); (2) default-safe allowlist with an opt-in "trusted" flag per file/dir; (3) capability manifest each sidebar declares. This must be decided before Wave D ships.

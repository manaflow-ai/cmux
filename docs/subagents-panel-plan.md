# Subagents right-sidebar panel

Status: first pass shipped (data context + `panel-subagents` example). This
document records the data source decision, the t3code-inspired presentation,
and the follow-up plan for dragging an agent out of the panel into a terminal
pane.

## What t3code does (reference UI)

t3code (pingdotgg/t3code) renders subagents in a dedicated right-panel surface,
`apps/web/src/components/AgentsPanel.tsx`, fed by a source-neutral panel model
in `packages/client-runtime/src/state/subagentRuntime.ts`
(`AgentPanelModel`: `workflows[]`, `directAgents[]`, running/waiting/idle/
settled counts, `totalTokens`). The parts worth copying:

- One roster surface. The chat timeline carries only a compact "spawned N
  agents" CTA row per spawn batch (`MessagesTimeline.tsx`); the full roster
  renders exactly once, in the panel.
- Fixed-shape rows. Each agent row reserves three lines: identity (status dot,
  title, role pill, right-aligned elapsed), activity (current tool/progress,
  or the outcome once settled), metrics (model, token count, tool uses).
  Changing data never changes row height.
- Collapsed status vocabulary. Every in-flight state renders as one steady
  "Working" blue dot; only settled states differentiate (green completed, red
  failed, muted stopped/idle). Detail belongs in the activity sub-line, not in
  the dot color.
- Stable order. Spawn order is stable; activity updates rows in place.
- Grouping. Workflow runs are collapsible sections with a phase rail (one
  mini status dot per member); direct spawns are a flat section. A live
  workflow stays expanded when it settles.
- Cheap liveness. Elapsed timers tick via direct DOM writes (no re-render);
  the footer shows `N working / N idle / N settled` plus total tokens; the
  panel tab badges the live agent count.

## What cmux knows about running agents

cmux has no first-class subagent (child agent) tree. `SubagentStart` /
`SubagentStop` hook events arrive but are deliberately dropped for parent
state (`Sources/Feed/WorkstreamEvent+FeedIngress.swift`,
`Sources/Mobile/AgentChat/AgentChatSessionRegistry+Lifecycle.swift`); no child
record or parent-child edge is stored. The only real hierarchy (codex-teams)
lives in the CLI watcher process and surfaces to the app solely as startup env
vars on the spawned pane (`CMUX_AGENT_MANAGED_SUBAGENT`,
`CMUX_CODEX_TEAMS_THREAD_ID` / `_PARENT_THREAD_ID` / `_DEPTH`, readable via
`TerminalSurface.startupEnvironmentValue(_:)`).

What does exist, live and authoritative, is one agent session per terminal
surface: `AgentChatSessionRegistry`
(`Sources/Mobile/AgentChat/AgentChatSessionRegistry.swift`, main-actor,
hook-event driven, with per-pid exit watchers and a process-table observe
floor), exposed through `AgentChatTranscriptService.sessionRecords(...)` and
reachable as `TerminalController.shared.agentChatTranscriptService`. Each
`AgentChatSessionRecord` carries `sessionID`, `agentKind` (claude / codex /
other), `workspaceID`, `surfaceID` (the hosting terminal panel UUID),
`workingDirectory`, `transcriptPath`, `state` (`idle` / `working(since:)` /
`needsInput(since:)` / `ended`), `lastActivityAt`, `title` (first user
prompt), `pid`, and a monotonic `version`.

### Chosen data source

`AgentChatTranscriptService.sessionRecords(workspaceID: nil)`, projected per
workspace in `Sources/Workspace+CustomSidebarSnapshot.swift`. Reasons:

- It is the only record that joins identity + kind + state-with-timestamps +
  title + transcript path + terminal binding in one place, exactly the row
  t3code renders.
- It is already started unconditionally at app launch
  (`Sources/AppDelegate.swift`), fed by the same hook pipeline that drives
  notifications, and cheap to read (an in-memory dictionary filter/sort).
- The per-panel lifecycle maps that drive the left sidebar's spinner
  (`WorkspaceSidebarAgentRuntimeObservationModel`) know status but not
  identity (no session id, title, or transcript), so they cannot label rows.
- `RestorableAgentSessionIndex` / `SharedLiveAgentIndex` is disk + sysctl
  backed (~350ms-1.8s per load, 60s TTL) and must never run on the 1 Hz
  sidebar tick.

Workspace attribution: a record binds to a workspace when its `surfaceID`
(panel UUID) is one of that workspace's live terminal panels; records without
a surface binding fall back to their stored `workspaceID` string. A record
whose panel lives elsewhere is excluded even when the stored workspace id
matches, because workspace ids are re-minted across relaunches while the
panel binding stays authoritative (same rule the mobile chat list applies in
`Sources/TerminalController+MobileChat.swift`).

## Data-context keys (shipped)

`workspaces[i].agents` (omitted when empty), most recent first, capped at 24
per workspace. Each `agents[j]`:

| key | always | meaning |
| --- | --- | --- |
| `id` | yes | agent session id |
| `kind` | yes | raw runtime source: `claude`, `codex`, ... |
| `name` | yes | display name: `Claude`, `Codex`, ... |
| `status` | yes | `idle` \| `working` \| `needs_input` \| `ended` |
| `lastActivityAt` | yes | epoch seconds of last hook/transcript activity |
| `sinceEpoch` | working / needs_input | when the current state began |
| `title` | when known | conversation title (first user prompt) |
| `panelId` | when bound | hosting terminal panel UUID (= `tabs[k].id`) |
| `surfaceId` | when bound | hosting tab surface UUID (= `tabs[k].surfaceId`, accepted by `surface.focus`) |
| `directory` | when known | session working directory |
| `transcriptPath` | when resolved | absolute transcript JSONL path |
| `pid` | when known | agent process id |

Types and projection: `CustomSidebarAgentSnapshot` +
`CustomSidebarDataContextBuilder.agentValue(_:)` in the CmuxSidebar package;
live mapping in `Workspace.customSidebarAgentSnapshots()` inside
`Sources/Workspace+CustomSidebarSnapshot.swift`. Because the mapping lives in
the shared `customSidebarWorkspaceSnapshot(...)` choke point, all three data
context assembly sites (left sidebar `ContentView.customSidebarDataContext`,
right sidebar `rightSidebarCustomSidebarDataContext`, pane-hosted
`CustomSidebarPanelView`) emit the key with no per-site wiring. Updates ride
the existing 1 Hz `TimelineView` tick; timestamps are static in the data and
elapsed strings are computed in JS from `clock.epoch`, so rows tick without
data churn.

## Panel layout (shipped: `Examples/CustomSidebars/panel-subagents.js`)

t3code's presentation adapted to the cmux JS sidebar runtime:

- Header: "Agents" + a `● N working · N idle · N ended` summary (t3code's
  footer counts, moved to the top where the right panel keeps its title).
- Scope toggle (This workspace / All), an Ended visibility toggle, and live
  search over title, kind, workspace, and directory (panel-sessions pattern).
- One flat keyed ForEach of workspace header rows + agent rows (the
  workspaces.js flat-list pattern). Headers show the workspace title plus one
  mini status dot per agent, t3code's phase-rail idea at workspace
  granularity.
- Agent rows: status dot + title (first prompt, falling back to the runtime
  name) + right-aligned monospaced time column (live elapsed for working /
  needs-input, "Ns ago" for settled), then a second line with the status
  label and `name · directory-tail` metadata.
- Status vocabulary: needs-input orange (ranked first), working blue, idle
  green, ended muted. Within a workspace rows sort by that rank, then by
  recency.
- Ended sessions stay visible for 15 minutes after their last activity, then
  hide behind the Ended toggle, so a just-finished agent is still news but
  the roster does not silt up.
- Row tap selects the workspace and focuses the agent's terminal surface
  (`workspace.select` + `surface.focus`).

## Follow-up: drag an agent row into a terminal pane to view it

Goal: drag a row out of the panel and drop it on a pane to open that agent's
transcript (or attach a viewer) there, like dragging a file into a split.

The JS sidebar lane has no drag-out today: `Reorderable` is internal
reordering only, and the interpreted runtime exposes no `onDrag` source. The
work splits into four pieces, all in the scene-renderer / host layer (no JS
API change required for v1):

1. UTType. Declare `com.cmux.agent-session-transfer` in `Resources/Info.plist`
   under `UTExportedTypeDeclarations`, conforming to `public.data`, exactly
   like the existing `com.cmux.sidebar-tab-reorder` and
   `com.splittabbar.tabtransfer` precedents. Payload: JSON
   `{ sessionId, kind, workspaceId, panelId, transcriptPath }`.
2. Drag source. Add a `.draggable(payload)` chainable in the JS runtime
   (scene node prop, host-side `NSItemProvider` with the new UTType), applied
   by the panel to agent rows: `row.draggable({ type: "agent-session", id:
   a.id, ... })`. The host renderer (`CmuxSwiftRenderUI` scene host and the
   remote-render worker) attaches `onDrag` / `NSItemProvider` the same way
   `Reorderable` already lifts rows, so both renderers keep parity.
3. Drop handling. Terminal panes already accept drops for tab transfer; extend
   the pane drop delegate (bonsplit surface host) to accept
   `com.cmux.agent-session-transfer` and route it to a shared action:
   `agentSession.open(sessionId:in:paneId:)`.
4. Open action. Resolve the record via
   `AgentChatTranscriptService.sessionRecord(sessionID:)`. If the hosting
   surface is alive, focus it (drop on the same workspace) or offer
   move-to-pane; if the session has only a transcript (ended), open a
   read-only transcript viewer surface in the target pane (the session index
   viewer already renders transcript JSONL). Expose the same verb over the
   socket (`cmux agent open <session-id> --pane <id>`) so the palette / CLI /
   drag all share one path.

Non-goals for that follow-up: no live child-agent tree (cmux does not track
Task-tool subagents; their hooks are dropped by design), and no dragging INTO
the panel.

## Deferred / known gaps

- Status changes surface on the next 1 Hz tick, not instantly; the pane cache
  (`CustomSidebarPaneDataContextCache`) keys on second granularity so this
  holds for pane-hosted sidebars too. If sub-second flips matter later, key
  the cache on an agent generation counter and attach the agent-runtime
  observation stream to the custom-sidebar branch.
- `workspaces[i].agents` includes only sessions whose terminal still exists
  (or whose stored workspace id still matches); orphaned ended sessions are
  invisible by design, the session index panel remains the historical browser.
- Codex-teams pane hierarchy (`CMUX_CODEX_TEAMS_*` env) is not yet projected;
  when the drag follow-up lands, `tabs[k].subagentDepth` / `parentThreadId`
  from `TerminalSurface.startupEnvironmentValue(_:)` would let the panel
  indent teams children under their parent.

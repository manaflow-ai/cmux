# Agent Session Tracking — Single Source of Truth (Technical Spec)

Status: DRAFT, living doc. Owner: Aziz. Last updated: 2026-06-22.

Tracks the redesign of how cmux tracks whether a terminal surface has a coding
agent (Claude Code / Codex) session, for the iOS GUI ("coding agent") mode.

## Goal

The iOS GUI must reliably know, for any cmux surface: is there an agent session,
what is its live state, and where is its transcript. "Reliably" is the whole
point. No heuristic that can show the wrong conversation or none.

## Principles

1. **Single source of truth.** One authoritative `AgentSession` record per
   surface, on the Mac. Everything else derives from it.
2. **Deterministic binding, no heuristics.** Surface to session binding is
   established by construction at terminal/agent start, keyed by a cmux-minted
   token. Never from terminal-title string matching. Never from newest-file-by-
   mtime scans. Never from any signal that can mis-attribute.
3. **No unreliable fallback.** If the reliable path has a gap, close the gap in
   the launch/env binding. Do not paper over it with a heuristic fallback.
4. **Push is best-effort; pull is authoritative.** Mac to iOS push events are
   hints. iOS can always re-fetch the authoritative current snapshot and
   reconcile. A missed or duplicated push self-heals on the next pull.
5. **Don't rely on perfect hook delivery.** Neither agent-to-Mac hooks nor
   Mac-to-iOS pushes are assumed delivered. Reliable backstops only (owned
   process exit; the agent's own transcript file), never titles/mtime.
6. **`ended` is retained, not deleted.** GUI stays shown after the agent ends.
   Ended is a flag that disables the input/bottom bar. It must not gate
   presence and must not delete the session.
7. **Bind on a durable surface identity.** The binding key is the surface id,
   which MUST be invariant for a terminal's whole life (persisted, rehydrated
   verbatim on restore, never re-minted). Workspace id is volatile and is never
   the key. See "Identity and the binding key".
8. **No file I/O or JSON/JSONL parsing on the main thread.** The main actor
   receives only already-parsed `Sendable` value snapshots. See "Threading
   discipline".

## Phase 1 audit findings (2026-06-22)

The reliable binding mechanism ALREADY EXISTS; the heuristic layer was redundant.

Env token, unconditional. Every local terminal surface injects
`CMUX_SURFACE_ID` / `CMUX_WORKSPACE_ID` / `CMUX_PANEL_ID` / `CMUX_TAB_ID` as
PROTECTED env keys at spawn (`TerminalSurface+StartupEnvironment.swift:45-62`,
`applyManagedCmuxContextEnvironment`). Remote shells inject the same via
placeholder substitution (`RemoteInteractiveShellBootstrapBuilder.swift:191-196`).
So a hand-typed `claude`/`codex` in any cmux terminal already inherits the
surface token.

Hook surface resolution is multi-signal and cmux-owned
(`CLI/cmux.swift:22901-22935`, `resolveCallerTerminalBindingByTTY:24336`,
`resolveAgentProcessTerminalBinding:24343`, `resolveTerminalBinding:24419`).
A fired hook resolves its surface by, in order:
1. explicit `--workspace` / `--surface` flags,
2. inherited env `CMUX_SURFACE_ID` / `CMUX_WORKSPACE_ID`,
3. tty -> surface: the agent's controlling tty matched against the app's
   `debug.terminals` table (`tty` -> `surface_id`),
4. process-tree: the agent pid found under a surface's `top_level_pids` /
   process tree via `system.top`.
Signals 3 and 4 need no env at all; they map the agent's real tty/pid to the
surface cmux owns. This is the deterministic binding the redesign blesses.

Entrypoint coverage (each ends with a hook whose surface resolves by the above):
- `cmux claude-teams` / hand-typed `claude`: COVERED. Hooks injected via
  `--settings` by `cmux-claude-wrapper`; env inherited; tty/pid backstop.
- `cmux new-surface --type agent-session` (UI/CLI): COVERED. App injects
  `CMUX_SURFACE_ID` into the launch env (`AppDelegate.swift:6256`).
- Session restore, fork-session, remote/ssh: COVERED (env + tty/pid).
- `codex` (bare or `codex-teams`): PARTIAL. No `--settings`-style auto-inject
  wrapper; relies on `cmux hooks setup codex` having installed `~/.codex` hooks.
  Once installed, the fired hook resolves the surface identically. GAP = ensure
  setup ran; not a per-launch binding gap.
- Degraded mode: `cmux-claude-wrapper` execs claude WITHOUT hook injection when
  the socket ping fails (`cmux-claude-wrapper:414`). Acceptable: the agent still
  runs; we simply do not track it until the socket returns and the next
  hook/pull reconciles. Never a correctness hole, only staleness.

Conclusion: do NOT build a new binding mechanism. Make the authority consume the
already-resolved hook events (+ process-exit), add versioning/pull, and DELETE
the title/mtime layer. Codex parity = guarantee hook setup; that is the only
genuine launch-path gap.

## The binding: surface resolution at hook time (already reliable)

cmux owns every cmux terminal's environment. When it spawns a surface's shell,
it injects:

- `CMUX_SURFACE_ID` — stable, cmux-owned, the binding key.
- `CMUX_WORKSPACE_ID`.
- the agent hook config, so `cmux hooks <agent> <event>` fires for any agent
  started in that shell and carries the surface token.

Because the token lives at the shell/env layer (which cmux always controls for
its own terminals), even a hand-typed `claude`/`codex` inherits it and its hooks
bind to the correct surface. This is what lets us delete the title/mtime
fallback: there is no gap for a cmux-owned surface. An agent in a terminal cmux
does NOT own (ssh/remote/external) is not a cmux surface and has nothing to show
in GUI mode, so no fallback is needed.

Open task: enumerate every way an agent can start in a cmux surface (new-agent
action, CLI, fork-agent, restored session, hand-typed in shell) and confirm each
inherits the surface env token + hook config. This audit is the prerequisite for
deleting the heuristics. See "First PR" below.

## Identity and the binding key (durability of cmux IDs)

Reality today (evidence: `Sources/Workspace.swift`, `Sources/TabManager.swift`):

- **Surface id** (`CMUX_SURFACE_ID` / `CMUX_PANEL_ID`; == panel id == ghostty
  surface id): persisted in the session snapshot and, since a recent fix
  (commit `44dc053e`, 2026-06-12), REUSED verbatim on restore so agent bindings
  survive relaunch (`Workspace.swift:1340`). Regenerated ONLY on collision: when
  a live surface already holds that id (restore-into-a-running-instance,
  duplicate-workspace). On a normal quit-then-reopen there is no collision, so
  it is stable.
- **Workspace id** (`CMUX_WORKSPACE_ID` / `CMUX_TAB_ID`): ALWAYS regenerated on
  restore. Restore builds a brand-new Workspace via the normal initializer
  (`UUID()`); the saved id is kept only to remap closed-panel history
  (`TabManager.swift:5963`), never rehydrated as the live id.
- **Pane id**: internal, layout-only, not persisted, not an env var.
- **Window**: OS-managed (`NSWindow`), not a cmux model identity.

Why they change: session restore reconstructs the object graph through standard
initializers, each minting a fresh `UUID()`. Only the surface id was
special-cased to be preserved, and only recently, precisely because regenerating
it was breaking agent-session bindings (the reason
`AgentChatSessionRegistry.refreshBindingsFromHookStore` exists). It is not a
deliberate "ids should rotate"; it is "restore mints fresh objects, and only the
id something depended on was preserved."

Consequence for this design:

- The binding key is the SURFACE id, and the design REQUIRES it to be a durable
  identity: minted once at surface creation, persisted, rehydrated verbatim on
  restore, never re-minted. The recent reuse fix is the right direction; this
  design depends on it AND requires closing the collision-regeneration hole
  (handle restore-into-live by not duplicating the surface rather than by
  re-id'ing it), so `CMUX_SURFACE_ID` is invariant for a terminal's whole life.
- Do NOT key the binding on workspace id. It is volatile across relaunch.
  `workspaceID` is a mutable ATTRIBUTE of the AgentSession (for filtering /
  display), refreshed from hook events, never the identity.
- Blocking prerequisite (alongside the entrypoint audit): audit and guarantee
  surface-id durability (persist + verbatim rehydrate + no collision re-id).
  Until that invariant holds, "bind by surface id" is not yet reliable.

## The authority: one AgentSession per surface

Replace the multi-map registry (records + liveSessionIDBySurfaceID + claim sets)
with a single authoritative record, keyed by surface:

```
AgentSession {
  surfaceID        // binding key, stable, cmux-owned
  workspaceID
  agentKind        // claude | codex
  sessionID        // from the first hook event for this surface token
  transcriptPath   // recorded from the hook; never guessed
  state            // launching | idle | working | needsInput | ended
  pid              // process cmux spawned (or adopted via the env token)
  version          // monotonically increasing; bumped on every change
  lastActivityAt
}
```

- GUI mode = "this surface has an AgentSession."
- Input/bottom bar enabled/disabled is driven by `state` (disabled on `ended`),
  not by presence.
- `version` is the reconciliation key for the pull/push model below.

## State source: hook events tied to the token

State transitions come from exactly one channel: agent hook events over the
socket, each carrying `CMUX_SURFACE_ID`, so each event maps unambiguously to one
AgentSession. No reconciliation across same-cwd sessions, no "which one is this."

State machine (from the existing `nextState`):

- `sessionStart` -> idle
- `userPromptSubmit | preToolUse | postToolUse | todoWrite` -> working
- `permissionRequest | askUserQuestion | exitPlanMode | notification` -> needsInput
- `stop` -> idle
- `subagentStop` -> unchanged (a Task subagent finishing says nothing about the parent)
- `sessionEnd` -> ended

Every applied event bumps `version` and `lastActivityAt`.

## Reliability model: authoritative state + versioned pull, push as hint

This is the core of "super reliable" and "voluntarily readable."

### Mac side (authoritative)

- The Mac holds the authoritative AgentSession per surface. This is the single
  source of truth.
- `version` increments on every state or binding change.
- Backstops that do NOT depend on hook delivery:
  - **Owned-process exit.** cmux spawned (or adopted) the agent pid, so a child
    `terminationHandler` / `waitpid` gives `ended` deterministically even if the
    `sessionEnd` hook never arrives. This replaces the `kill(pid,0)` polling
    sweep.
  - **Transcript corroboration.** The agent's own transcript JSONL is a reliable
    record (unlike titles). A completed assistant turn observed in the tail can
    clear a stuck `working`. Used only to correct, never to invent presence.

### Mac -> iOS (push is best-effort)

- Push events (`chat.message`, state/descriptor changes) are delivery hints.
  Each carries the new `version`. Never assume a push arrived.

### iOS -> Mac (pull is authoritative)

iOS can fetch the authoritative current snapshot at any time:

- `mobile.chat.sessions` — full descriptors for a workspace (state + version +
  transcript binding). The list-level snapshot.
- per-session/surface snapshot fetch — current state + version for one session.
- `mobile.chat.history` — seq-based transcript paging (already pull-capable).

iOS pulls on: (re)connect, app foreground, (re)subscribe, detected version gap
(received version is not lastSeen+1, or any push it cannot reconcile), and
explicit user refresh.

### Reconciliation (iOS)

- Apply a push only if its `version` is greater than the last applied version
  for that session. Monotonic, so duplicates and reorderings are no-ops.
- On pull, replace local state with the snapshot's state+version.
- Transcript: paged by seq; a `.reset` (transcript rotation, inode change) drops
  the cursor and re-pages.

Result: any missed push is corrected by the next pull; any stale local state is
overwritten by an authoritative snapshot. Delivery failures degrade to "slightly
stale until next pull," never to "wrong or missing forever."

## Threading discipline

Hard rule: no file I/O and no JSON/JSONL parsing on the main thread/actor. The
main actor receives only already-parsed `Sendable` value snapshots.

- Reference pattern (already correct): `AgentChatTranscriptTailer` is a dedicated
  `actor` (not `@MainActor`). It memory-maps the transcript, scans newlines and
  parses JSONL off the main executor, and pushes `Sendable` `Batch` values out.
  Keep this shape for all transcript work.
- Current violation to remove: `AgentChatSessionRegistry` is `@MainActor` and
  reads + JSON-parses the hook store (`Data(contentsOf:)` + `JSONSerialization`)
  inline in `seedFromHookStores` / `noteHookEvent`. That is the main-actor
  disk+parse cost the 30s throttle was bounding. The redesign deletes the
  hook-store-as-truth, so this parse leaves the main actor entirely.
- Going forward: hook-event decode (`WorkstreamEvent`), any session-state
  persistence read/write, and all transcript work run off-main. The authority
  applies only small pre-parsed value mutations on the main actor (or is itself a
  non-main actor that publishes `Sendable` snapshots to the UI). No whole-file
  reads, no `JSONSerialization`, no `Codable` decode on the main thread.

## Persistence across app relaunch

Bind by token, not by regenerated panel UUIDs (today's relaunch regenerates
panel UUIDs and re-consults the JSON store to re-bind):

- Persist the per-surface AgentSession keyed by the stable surface token.
- On restore, re-attach by token (the live agent process still carries
  `CMUX_SURFACE_ID`; cmux can re-adopt the pid it owns), or mark `ended` if the
  process is gone. Deterministic either way.

## What gets deleted

- `AgentChatTranscriptService+TitleDetection.swift` in full.
- `claudeTitleDetectionKey` / `specificClaudeTitleKey` title matching.
- `newestClaudeTranscript` + the `excludingSessionIDs` / forced-retry / claim
  machinery, the `$HOME` junk-drawer guard, the `/tmp` vs `/private/tmp`
  cwd-encoding gymnastics.
- `~/.cmuxterm/<agent>-hook-sessions.json` as a read-side source of truth (it may
  remain a CLI-side scratch artifact, but the app stops reading it on the hot
  path).
- the 30s store-read throttle (no store reads on the hot path; state was always
  real-time from hooks, the throttle was only on disk re-consult for missing IDs).
- the `kill(pid,0)` liveness sweep (replaced by owned-process termination).

## What stays

- The hook event -> state machine (`nextState`).
- The JSONL transcript tailer (`AgentChatTranscriptTailer`) for streaming
  history. It reads the recorded `transcriptPath` only.
- The iOS RPC surface (`mobile.chat.sessions / history / subscribe / send /
  interrupt / answer`), extended with explicit `version` on descriptors and a
  per-session snapshot fetch.

## RPC surface (target)

- `mobile.chat.sessions(workspaceID?) -> [SessionDescriptor]` where each
  descriptor includes `state` and `version` and the transcript binding.
- `mobile.chat.session(surfaceID | sessionID) -> SessionDescriptor` (snapshot of
  one).
- `mobile.chat.history(sessionID, beforeSeq?, limit) -> page` (pull transcript).
- `mobile.events.subscribe / unsubscribe` (best-effort push, carries `version`).
- `mobile.chat.send / interrupt / answer` (input; gated off when `state == ended`).

## Implementation plan (slices)

Phase 1 audit is DONE (see "Phase 1 audit findings"). The reliable binding
already exists, so the remaining work is additive-then-subtractive, in
reviewable slices. Each runtime slice ends in a tagged build + dogfood handoff
(runtime PRs do not merge before dogfood approval).

- **Slice A — Versioning + pull snapshot (additive, no deletes).** Add a
  monotonic `version` to each session descriptor, bumped on every registry
  change. `mobile.chat.sessions` carries `version`; add `mobile.chat.session`
  (single-session snapshot pull). iOS reconciles by version and pulls on
  (re)connect / foreground / version gap / manual refresh. Pure reliability win,
  no behavior removed. Lowest risk, ships first.
- **Slice B — Owned-process-exit backstop.** Observe the agent pid cmux owns via
  a termination handler; deterministic `ended` without the `sessionEnd` hook.
  Keep `ended` retained (disables input bar, stays visible). Remove the
  `kill(pid,0)` polling sweep once the handler covers it.
- **Slice C — Off-main parsing.** Move the hook-store JSON read off `@MainActor`
  (interim, before it is deleted) and assert no `Data(contentsOf:)` /
  `JSONSerialization` / `Codable` decode on the main actor in this subsystem.
- **Slice D — Delete the heuristics.** Remove
  `AgentChatTranscriptService+TitleDetection.swift`, `newestClaudeTranscript` +
  claim/forced-retry machinery, the hook-store as read-side source of truth, and
  the 30s throttle. Gated on Slices A-B proving the resolved-hook + pull path is
  sufficient.
- **Slice E — Surface-id invariance (only if needed).** Close the collision
  regeneration (restore-into-live / duplicate-workspace) so `CMUX_SURFACE_ID` is
  invariant; extend verbatim-rehydrate to non-terminal panels if the GUI uses an
  `agent-session` panel surface. Touch points:
  `Workspace.swift:1347-1348,1421,1435,1446,1470`, `*Panel.swift` inits.
  Deferred unless a concrete relaunch-rebinding bug demands it; the
  terminal-agent model rehydrates verbatim on normal relaunch already.
- **Slice F — Codex parity.** Guarantee `cmux hooks setup codex` is in effect so
  codex hooks fire and resolve the surface like claude.

## Verification

- Build/compile via tagged `-derivedDataPath /tmp/cmux-<tag>` (never untagged).
- Tests run on AWS M4 Pro or GitHub Actions, never locally (test host launches a
  `cmux DEV` app).
- Each runtime slice: tagged reload + dogfood handoff with prior-bad vs expected
  behavior, merge only on explicit dogfood approval.

## Open questions

- Exact shape of the persisted per-surface AgentSession (where it lives, how it
  survives relaunch without the old UUID-regeneration problem).
- Whether the transcript corroboration backstop is needed at all once
  owned-process exit + hook events are solid, or whether it stays only for the
  Claude weekly-limit "no Stop hook" case.
- Codex parity for every mechanism (token inheritance, hook events, transcript
  path recording).

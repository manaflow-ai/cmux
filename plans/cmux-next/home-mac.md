# cmux-next Mac Home view: data protocol (lane 16)

Status: agreed with the Home lead, 2026-10-03. Decision IOS3 = B
(`plans/cmux-next/mac-home-rendering.md`): the Mac Home transcript is the
shared render core `Packages/Shared/CmuxHomeRender` hosted by an AppKit view
in `CmuxNextHome`. Ownership split (coordinator H14): lane 16 owns the view,
the render core and its AppKit host; the Home lead owns the data (daemon
conversation tabs, the home workspace, the chief conversation, the ops) and
wires the view to it through this protocol.

Rules: OWNERSHIP-PRINCIPLES.md (single writer per entity, typed ops with
idempotency keys, clients are mirror + intent log, client view state stays
client). The view adds no model type: it reads CmuxHomeCore types only.

## 1. What the view reads

One conversation per view. All values are CmuxHomeCore types.

| Input | Type | Source (Home lead) | When |
| --- | --- | --- | --- |
| conversation | `ConversationID` | the tab / home workspace | at creation; a new id makes a new view |
| me | `ParticipantID` | `HomeStore.me` | at creation |
| transcript | `[TranscriptItem]` (confirmed messages + my pending intents, in order) | `HomeStore.transcript(for:)` | every change of `HomeStore.transcriptVersion[conversation]` |
| summary | `ConversationSummary?` (participants, read cursors, kind, title) | `HomeStore.summary(_:)` | with the transcript |
| typing | `Set<ParticipantID>` | `HomeStore.typing[conversation]` | on change |
| hasOlder | `Bool` | `HomeStore.hasOlderMessages(in:)` | with the transcript |
| connection | `HomeConnection` | `HomeStore.connection` | on change (offline banner, send state) |

Cost: `update` with an unchanged transcript, summary, typing set and
paging state returns before any layout, animation or callback (the binding
refreshes on every inbox change; test `UnchangedUpdateTests` counts layout
passes).

Delivery: the host calls `HomeController.update(items:summary:typing:hasOlder:)`
with the whole current value; the controller diffs (`TranscriptChange`) and
animates. `HomeStoreBinding` (in CmuxHomeRender) does this with Observation
tracking, one update per store change, no polling. The view never reads the
daemon, the socket or the database.

## 2. What the view emits

Only typed CmuxHomeCore intents. Each carries its `IdempotencyKey`; the owner
deduplicates.

| User action | Intent | Owner call |
| --- | --- | --- |
| Return / Send in the composer | `HomeIntent(.sendMessage(conversation:parts:))` | `HomeStore.perform(op, key:)` |
| Newest row visible while the window is visible and the app is active | `HomeIntent(.setReadCursor(conversation:seq:))` (only forward) | `HomeStore.perform` |
| Scroll reaches the oldest loaded row while `hasOlder` | `onNeedsOlder()` | `HomeStore.loadOlder(_:)` (once per page) |
| Retry a failed send | `HomeIntent` key | `HomeStore.retry(_:)` |
| Discard a failed send | key | `HomeStore.discardFailed(_:)` |
| Tapback (later) | `.addReaction(message:conversation:reaction:partIndex:)` | `HomeStore.perform` |

Not offered on local conversations: create group, create chief, start
conversation, invite, pin and mute. The local owner refuses them with
`HomeRejection.invalid("unsupported_on_local_owner")` until the cloud owner
lands, so the view shows no control for them (test
`HomeLocalOwnerActionTests`).

Offline (H17): Send is off and the text stays a draft
(`HomeNativeTranscriptView.isSendEnabled`, set from `HomeStore.connection`). The intent log only
covers ops sent before the disconnect.

A send the owner refuses before it is logged returns the text to the
composer (`HomeController.restoreDraft(for:)`). The view never edits the
transcript itself; a pending row is the intent log's `TranscriptItem` with
`delivery == .pending`.

## 3. Client view state (never sent, never persisted)

Scroll position (pinned to newest, or an anchor row key + offset), momentum,
composer draft text, selection and IME marked range, the measured row
layouts and the bitmap cache, the palette (from the theme and window key
state), Reduce Motion, the animation speed, and `isVisibleToUser`. A window
restore may keep the draft in the window's own restoration state; that is a
client decision, not an op.

## 4. Host duties (CmuxNextHome, lane 16)

- An `NSView` that layer-hosts `HomeController.rootLayer`, forwards resizes,
  `NSTextInputClient` (IME), scroll phases and momentum as `HomeInput`, and
  exposes `accessibilityItems()` as accessibility children.
- Builds `HomePalette.themed(_:active:)` from the Ghostty theme (accent from
  the theme or the user's setting; no blue default) and swaps it on window
  key changes.
- Injects a `HomeDeadline` adapter over `DemandTimer` (CmuxNextWakeups).
- Uses the window's `FrameScheduler` only while momentum runs.
- Selftest and audit run on cmux-lawrence-2 only (GUI rule).

## 5. Agreed with the Home lead (2026-10-03)

The chief conversation is a normal local conversation (`agent_mux`, agent
class `.chief`), shown by the same view. One `HomeStore` per daemon session,
owned by the app; the view never creates one. Offline Send is off (H17).

## 6. Open follow-ups from the lane 16 re-check (2026-10-05)

Accepted for merge; not fixed on feat-cmux-next-home-cloud-source.

- P3-2, a delivery can reach nobody. `HomeStore.liveHooks(for:)`
  (Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Store/HomeStore.swift:1257)
  holds the hooks strongly for the whole delivery. When the last binding of
  the conversation loses its last reference on a background thread during
  that delivery, its hooks stay in the snapshot, but their `[weak self]`
  closures
  (Packages/Shared/CmuxHomeRender/Sources/CmuxHomeRender/Public/HomeStoreBinding.swift:68-75)
  find no binding. `reportRefusal` and `reportUnanswered` (HomeStore.swift:1265,
  1273) saw a non-empty list, so the store's own `onRefusal`/`onUnanswered`
  are not called either. Fix direction: hooks report whether they delivered,
  and the store falls back when no hook did.
- P3-3, edit-echo deadline race. `editDeadlinePassed`
  (Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/CloudHomeSource+EditEcho.swift:61-67)
  checks only the generation and `inFlight == 0`. A deadline callback that
  was already dispatched when `beginEdit` (:11) cancelled it can run after
  a later edit finished (:28) and end that edit's subscription before its
  echo or its own `editEchoDeadline`. Fix direction: a per-schedule token in
  `EditHold` that the callback must match.
- P3-4, a repeated close drops an in-flight inbox edit's hold. `close`
  (CloudHomeSource+HomeSource.swift:141-156) removes `editHolds[conversation]` (:146) and
  the target whether or not an edit is in flight. A second close of a
  conversation that is not on screen (an inbox edit in flight through
  `requireEditable`) unsubscribes mid-edit; `finishEdit` (CloudHomeSource+EditEcho.swift:30) then finds
  no hold and returns, so the echo is never awaited. Fix direction: close
  ends only a hold with `inFlight == 0`, and an in-flight hold keeps the
  target until its edits finish.

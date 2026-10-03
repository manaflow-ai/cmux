# cmux-next Mac Home view: data protocol (lane 16)

Status: proposal for review by the Home lead, 2026-10-03. Decision IOS3 = B
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

## 5. Questions for the Home lead

1. Does the chief conversation use the same `ConversationID` space and
   `HomeStore` as other conversations (one view type for all)?
2. Who creates the `HomeStore` for a window: the home workspace (one per
   window) or the app (one per daemon session)? The view needs one store
   reference and never creates it.
3. Should `connection != .online` disable Send, or queue it in the intent
   log (recommended: queue; the row shows pending)?

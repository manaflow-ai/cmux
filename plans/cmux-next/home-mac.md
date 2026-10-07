# cmux-next Mac Home view: data protocol (lane 16)

Status: agreed with the Home lead, 2026-10-03. Decision IOS3 = B
(`plans/cmux-next/mac-home-rendering.md`): the Mac Home transcript is the
shared render core `Packages/Shared/CmuxHomeRender` hosted by an AppKit view
in `CmuxNextHome`. Ownership split (coordinator H14): lane 16 owns the view,
the render core and its AppKit host; the Home lead owns the data (daemon
conversation tabs, the home workspace, the chief conversation, the ops) and
wires the view to it through this protocol.

Update 2026-10-04 (Lawrence: "using the code behind MessagesLabAppKitNative
is very important, since the animation is significantly better"): on the
Mac the view is MessagesLabAppKitNative's own code, vendored at MessagesLab
3a53206 in `Packages/Shared/CmuxMessagesLab` (vendor.tsv;
`scripts/cmux-next/check-messageslab-vendor.sh` lists the blocker edits).
`HomeProjection` replaces `HomeStoreBinding` on the Mac: HomeStore
snapshots become MessagesLab actions on a projection store, sends and
tapbacks become the intents in section 2. The data protocol below is
unchanged; `HomeController` names apply to iOS, which keeps
CmuxHomeRender until the Mac passes the harness
(`scripts/cmux-next/home-messageslab-harness.sh`).

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

## 7. The Home page's conversation list (2026-10-05, feat-cmux-next-home-sidebar-dms)

Lawrence: "left sidebar UI for DMing each other too and creating multiple
chiefs, optionally". Coordinator ruling: the list lives inside the Home top
page as its left column (`TopHomePageView`: `HomeConversationListView` on
the left, `HomeHostView` on the right), never in the window sidebar.

- Rows are `HomeStore.rows` (the merged local and cloud inbox), in sections:
  Chiefs, Pinned, Direct Messages and Groups (newest first), Invited (DMs
  whose only peer has not joined). Empty sections are left out, so a user
  without Chiefs sees only messages. Rows carry unread and mention badges
  (`ConversationSummary.mentionCount` from the inbox entry's `mentions`).
- New Message: team members (`team.members.list`) plus the active people of
  the user's DMs, or a typed email address. One person is `dm.open` with
  their participant id (`HomeOp.openDirect`), several are
  `conversation.create`, addresses are DM invites. `not_reachable` offers
  Invite by Email; `home.rate_limited` says to wait.
- Invite to cmux-next: `HomeOp.invite` (cloud: `dm.open` with the address).
  A verified-domain team invite is not in the backend yet (no `org.invite`).
- New Chief and Archive Chief: UserDO `chief.create` / `chief.archive`
  through `FeedService.call` (the API Worker as the signed-in user, origin
  `FeedService.apiBaseURL`; `CMUX_NEXT_FEED_API_URL` overrides it), because
  the daemon's cloud proxy forwards only conversation ops. An archived
  Chief's conversation leaves the list.
- Actions (HomeActionCatalog): `home.newMessage`, `home.invite`
  (`cmux home invite`), `home.newChief` (`cmux home new-chief`),
  `home.archiveChief` (`cmux home archive-chief`), `home.openConversation`.
- Not built: pin and mute from the list (the daemon proxy refuses
  `inbox.pin`/`inbox.mute`), a delivery state for an invite the staging
  allow list refused after commit, the row menu through `ActionMenuContext`.
- 2026-10-07: the list is MessagesLab's vendored sidebar (`HomeSidebarView`
  over `HomeSidebarSource`) in a split with the transcript. The divider
  keeps the list between its 76 pt minimum and half the window, a
  double-click resets it to 320 pt, and each window keeps its width. The
  column draws no background of its own. Below 180 pt (avatars only) the
  search field hides instead of clipping.
- Home's list is native UI that no close path reaches, so it is not a
  cmux-tui dock pane and the app marks no column permanent. The daemon's
  `permanent` flag (`permanent-dock-v1`) is for docked panes a client must
  keep: undock, edge moves, replacement and closes that would remove it
  are refused with `dock-column-permanent`. A user's close the daemon
  refuses beeps and shows the refusal HUD ("This column stays docked and
  can't be closed.").

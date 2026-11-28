# Agent chat progressive disclosure

The transcript should make the current state easy to trust at a glance. Older
history, raw tool output, and coordination chatter can remain available without
occupying the whole viewport. The attached reference shows the useful pattern:
older content becomes a compact count such as “30 previous messages”, and each
intermediate disclosure opens only when the reader asks for it. The default view
communicates progress; the expanded view preserves the complete record.

## What exists today

`agent-chat/src/components/Transcript.tsx` already has a good foundation:

- completed turns render a collapsed `TurnActivity` summary by default;
- activity rows have a second disclosure level for tool output, thinking,
  changed files, and errors;
- `compactActivity` hides live intermediate activity by default and is persisted
  in local storage;
- disclosure height is measured and animated, and long transcripts are
  virtualized;
- the gallery demonstrates collapsed, expanded, and one-item-expanded states.

The missing layer is history compaction. Every prior user/assistant turn still
appears in the main stream, and cross-task or “sent by another task” messages
are still visually equivalent to the current conversation. The existing
turn-level disclosure therefore reduces activity noise but does not reduce the
accumulated transcript noise shown in the reference.

## Proposed behavior

1. Keep the active turn and the latest completed turn visible. Older contiguous
   turns fold into one semantic boundary: `N previous messages` (or `N previous
   turns` when a turn contains multiple messages).
2. Keep the boundary stable while new events arrive. Expanding it reveals the
   saved turns in their original order; it must not rewrite or lose transcript
   state.
3. Add a second boundary for dense intermediate activity inside a long expanded
   range. The summary should expose counts and important outcomes, for example
   `12 tool calls · 2 files changed · 1 warning`, while tool output remains behind
   the existing row disclosure.
4. Preserve high-signal content outside the fold: the current user prompt, the
   current assistant answer, errors, failed tools, unresolved questions, and
   unread/new content. A failed operation should never disappear into a generic
   “previous messages” label.
5. Offer explicit local controls: expand this range, expand all history, and
   collapse older history. Keyboard focus, `aria-expanded`, and the scroll anchor
   must survive each transition. Respect reduced-motion settings.
6. Make compaction a presentation state, not data loss. The transcript model and
   copy/export actions continue to see every original block. Virtualization and
   disclosure state need stable group IDs rather than array indexes alone.

## Suggested first slice

Add a `historyDisclosure` layer around `groups` in `Blocks`:

- derive a compacted prefix from completed groups, with a small configurable
  visible-tail count;
- render a `PreviousTurnsDisclosure` row before that prefix;
- store expansion by a stable range key and keep the current visible range in
  the existing virtualizer;
- add gallery fixtures for 30 previous messages, a failed tool inside the folded
  range, a cross-task message, and a live turn arriving while the range is open;
- add tests for stable expansion, failure preservation, scroll anchoring, and
  reduced motion before tuning the visual styling.

Do not start by changing the current `TurnActivity` disclosure. It already gives
the right nested interaction. The next improvement should add the history layer
above it, then use the same disclosure motion, summary language, and accessibility
rules at every level.

## Acceptance criteria

- A long transcript opens with a compact prior-history row and the current work
  remains readable without scrolling through raw activity.
- Expanding and collapsing any level preserves the exact transcript and scroll
  position well enough that the reader does not lose their place.
- Errors, failed tools, unresolved questions, and new messages remain visible or
  are called out in the summary.
- The gallery shows collapsed, partially expanded, fully expanded, live-update,
  failure, and reduced-motion states at narrow and wide viewports.
- Existing compact-activity, disclosure-motion, virtualization, and selection
  behavior stays intact.

The previous repository work on compact activity (`ab4ff8a00dc`) and measured
disclosure/virtualized transcript behavior is useful prior art. This note keeps
those pieces and defines the missing transcript-level compaction rather than
replacing the current interaction model.

## Dictation, rail, and motion follow-through

The companion interaction should feel like one calm surface rather than a set
of unrelated controls:

- **Dictation:** cmux NEXT already has a native `AgentPaneDictation` session,
  permission/error states, a mic beside Send, level-meter support, and a
  `cmuxAcpmuxBridge.dictation` text splice. Keep the button visible and
  discoverable, use the existing hide/show preference, and make the states
  explicit: idle, listening, finalizing, unavailable, denied, and stopped.
  Dictation and bidirectional realtime voice remain separate capabilities; a
  realtime failure must leave one-shot dictation usable.
- **Left rail:** the model picker already uses a vertical provider rail with
  active, missing, loading, keyboard navigation, and scrollable behavior. The
  next pass should add a stable scroll bookmark/active marker when the rail is
  taller than its viewport, preserve the selected provider while the list
  scrolls, and keep the marker out of the content hit target. The bookmark is a
  navigation aid, not another selection state.
- **Motion:** reuse the measured disclosure animation approach already present in
  `Transcript.tsx`. For rail scrolling, image-preview hover, and dictation
  transitions, use short ease-out entry and ease-in exit curves, interrupt from
  the current measured frame, and honor `prefers-reduced-motion`. Avoid a
  constant-duration slide that feels abrupt when the distance changes.
- **Image previews:** give each preview a quiet hairline rim, a small contrast
  lift on hover/focus, and a restrained scale or shadow change. Keep the hover
  treatment subordinate to the disclosure state and keyboard equivalent; do not
  make the image jump or steal focus.

These are follow-up slices after transcript-level history compaction. They share
the same acceptance rules: keyboard and accessibility state, reduced motion,
stable scroll anchoring, and no loss of the underlying transcript or dictation
text.

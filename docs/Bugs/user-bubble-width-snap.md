# Fix: user prompt bubble renders extended-width on send, then snaps to fit

Symptom: a chat bubble for a prompt the user just sent renders at an over-wide width the instant it appears, then a moment later snaps in to fit the actual text width.

## Root cause

Environment-value resolution timing gap. The user bubble caps its width with `.frame(maxWidth: bubbleMaxWidth, alignment:)` where `bubbleMaxWidth` comes from the `\.chatBubbleMaxWidth` environment, computed as `tableWidth * theme.bubbleMaxWidthFraction` (0.78).

- Bubble view: `Packages/iOS/CmuxAgentChatUI/Sources/CmuxAgentChatUI/Transcript/Rows/ChatProseBubbleView.swift:41-71` (HStack with `Spacer(minLength: 64)` on the user side + `.frame(maxWidth: bubbleMaxWidth)`).
- Width injection: `Packages/iOS/.../Transcript/ChatTranscriptTableView.swift:430-431` sets `\.chatBubbleMaxWidth` to `tableWidth > 0 ? tableWidth * fraction : .infinity`.

On the first render of a freshly-inserted pending row, `tableWidth` is not yet resolved, so the environment value is `.infinity`. The bubble then measures against the text's intrinsic width with no cap; the `Spacer(minLength: 64)` distributes the leftover width and pushes the bubble to the trailing edge, so it looks full-width. On the next layout pass `tableWidth` resolves, the env updates to `tableWidth * 0.78`, and the bubble snaps to the narrower cap. There is no insert animation; the snap is the two-pass relayout.

Pending-message path (why it's specifically "on send"): `store.send` appends a `ChatPendingOutbound`; projector appends `.pendingOutbound(item)` (`ChatTranscriptProjector.swift:83-85`); the table calls `reloadData()` so the new cell is created and laid out before `tableWidth` is stable for that cell.

## Fix

Supply the container width before first layout so the cap is correct on the bubble's first render, instead of defaulting to `.infinity`.

- Compute `bubbleMaxWidth` from `tableView.bounds.width` at cell-configuration time and inject it into the `UIHostingConfiguration` environment, rather than relying on a later geometry callback. `ChatTranscriptTableView.swift` around the cell config (≈165-169 / 414, 489-495).
- Guard: when bounds width is still 0 (very first pass before the table has any size), prefer the window/screen width as a provisional cap instead of `.infinity`, so the bubble never measures uncapped.

This keeps the current design (78% cap, trailing alignment) and removes the wide-then-narrow snap. If a clean rebuild lands later (see `docs/agent-gui-component-map.md`, Layer 3), size the bubble to intrinsic content with one hard cap and no spacer-driven distribution; this fix is the targeted version for the current view.

# iOS pane/tab redesign: miniature-first hub

Replaces the toolbar `TerminalPickerMenu` with a three-level, live-preview navigation model. Decisions below were locked in a product-owner interview on 2026-07-13 and are requirements, not suggestions. Supersedes the UX direction of issue https://github.com/manaflow-ai/cmux/issues/6347 while delivering its intent.

## Navigation model

Three levels inside a workspace. The existing workspace list screen is unchanged.

1. **Workspace miniature hub.** Tapping a workspace in the list lands on a live-updating miniature of the Mac's real split-pane layout for that workspace: each pane rendered at its true relative position and size, showing a live preview of its active tab plus name, tab count, and agent status. Tap a pane to enter it. This is the only pane selector; panes are selectable, never swipeable.
2. **In-pane view.** Full-screen render of the pane's active tab with a bottom thumbnail strip. Back-swipe (or back button) returns to the miniature hub.
3. **Tab strip.** Horizontal strip of live preview thumbnails for the pane's tabs, in the Mac's tab order. Tap to switch. Auto-hides after typing/scrolling begins, leaving a thin handle; swipe up or tap the handle to reveal. Keyboard-aware: never occludes input, collapses gracefully when the keyboard is up.

## Attention shelf

A toggle at the left edge of the strip. Off: strip is exactly Mac order. On: surfaces needing attention (agent waiting for input, unread bell, finished run) sort to the front, then the rest in Mac order. The toggle is the only thing that ever reorders; there is no per-tab pinning concept anywhere in this design.

## Previews

Live and continuously updating (throttled) at all three levels: miniature panes, strip thumbnails, and any tab cards. Rendered client-side from `terminal.render_grid` cell-grid frames; `text_vt` fidelity (layout without full ANSI color) is accepted for v1. No bitmap RPC.

## Surfaces

- Terminal tabs: preview cards/thumbnails as above.
- Browser: a normal tab card with a visual preview. The Mac's real browser panes/tabs are mirrored to the phone (new RPC + preview path); the phone-local browser surface remains and must stay visually distinct from mirrored Mac browsers.
- Agent chat: each chat session gets its own card, not a badge on its bound terminal.

## Explicitly out of scope for v1

- Horizontal tab-paging gesture. Dropped due to gesture conflicts; only revisit if it can ride a horizontal swipe on the terminal content itself.
- Per-tab pinning, in any form.
- Physical-device verification (simulator is the target this round).
- Full-color styled-cell exporter (previews may be text_vt fidelity).

## Architecture notes (current-code constraints)

- The phone has no pane topology today: `MobileWorkspacePreview` carries a flat `terminals` array. M1 adds a topology RPC (pane tree with rects/ratios, tabs per pane with kind, active tab, ordering) plus a push topic for layout mutations (split add/remove/resize, tab create/close/rename/reorder/select).
- Mac-side `MobileTerminalRenderObserver` already emits render-grid frames for all registered surfaces when any client subscribes to `terminal.render_grid`; the iOS client only opens one sink (the mounted `GhosttySurfaceRepresentable`, keyed `.id(terminalID)`). M2 adds N concurrent throttled preview subscriptions with per-surface gating so background previews are cheap, plus a lightweight cell-grid thumbnail renderer usable at strip, card, and miniature sizes.
- Terminal input latency on the focused surface must be unaffected by preview streaming.

## Milestones (one integrated branch, dogfood only when the full experience works)

M1 topology RPC → M2 preview streaming + thumbnail renderer → M3 miniature hub → M4 in-pane view + strip + attention shelf (removes `TerminalPickerMenu`) → M5 browser mirroring + chat cards → M6 polish (transitions, gesture arbitration, iPad, localization, perf) → M7 evidence + review + verification + dogfood.

Acceptance criteria and the evidence plan live in `docs/ios-pane-tab-redesign-acceptance.md`.

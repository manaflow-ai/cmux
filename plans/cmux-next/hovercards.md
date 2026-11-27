# cmux-next hover cards: one owner, one card

User request (2026-10-01): "need to formally verify that only one hover card
can appear at a time. we need to make sure the logic for showing cards is
bulletproof too. consider if window/pane/column moves when mouse doesnt move
at all, via scroll etc. need to make sure to be ram/cpu/disk efficient in
general too."

## Inventory (before)

| Popover | Owner before | Shown by | Hidden by |
| --- | --- | --- | --- |
| Tab hover card | `TabHoverCardController`, one per tab strip, each with its own `NSPanel` and its own `Task.sleep` delay | strip `mouseMoved`/`mouseEntered` | strip exit, click, middle click, context menu, wheel, new-tab menu, drag, group drag, rename, group editor, drop placeholder, token change, strip leaving its window, tab removed |
| Group chip card | same controller (group content) | chip hover | same |
| Pinned tab card ("Show Resource Usage") | same controller + `PinnedCardDismissal` (its own event monitor and 10 s timer) | `ResourceHandlers` action | key, click, wheel, 10 s |
| Workspace card | `WorkspaceHoverCardController`, one per sidebar (window), own `NSPanel`, own `DemandTimer` | sidebar row hover | exit, click, drag, workspace removed |
| Pinned workspace card | same + `PinnedCardDismissal` | action | key, click, wheel, 10 s |
| Workspace row tooltip under Reduce Motion | `WorkspaceRowView.toolTip` | row hover | row unhover |
| AppKit tooltips on buttons (tab bar buttons, browser chrome, bookmarks, extensions, sidebar icon buttons, profile bar, notifications, incognito badge, page-info chip) | AppKit's tooltip manager (one tooltip app-wide) | AppKit | AppKit |
| Click popovers (page info, bookmark editor, group editor, back/forward menu) | their views | clicks | clicks, Escape |

Every strip and every sidebar owned its own card window and timer, so
nothing made "one card at a time" true: a pinned card in one place and a
hover card in another showed together, a card fading out in one strip
overlapped one fading in elsewhere, and no code re-hit-tested the pointer
when content moved under it (`HoverStillPointerTests`: a strip scrolled
under a still pointer kept its hover and card on the tab that moved away).

## Design (after)

- `HoverCardMachine` (CmuxNextDesign, pure): phases idle | pending(target,
  token) | shown(target) | pinned(target, token) | grace(token); events
  hit(target?, moved), deadline(token), dismiss(reason),
  suppress/unsuppress(drag, scroll), targetRemoved(id), pin(target);
  effects schedule/cancel the one timer and show/hide the one card. Targets
  are stable ids (`tab:<id>`, `ws:<id>`) with a window and a delay.
- `HoverCardCoordinator` (AppServices.hoverCards, injected into every strip
  and sidebar): the only `HoverCardPanel` (created on the first card,
  reused; the tab and workspace bodies are one reused view each per
  source), the only timer (one-shot `DemandTimer`), and the only event
  monitor (key, click, wheel; installed only while a card is pending or
  shown). Sources (`TabHoverCardController`, `WorkspaceHoverCardController`)
  hit-test their own targets, supply anchors and bodies, and sample
  resources while their target is active.
- Still pointer: every geometry change (strip `applyFrames`: scroll,
  reflow, close, animation frames; the pane moving in its window: column
  scroll, split resize; sidebar rows realized or scrolled; window move or
  resize) re-hit-tests `NSEvent.mouseLocation` against the topmost window's
  sources and feeds `hit(_, moved: false)`. While shown, the card follows its
  target; a target that moves away hides it; a new target under the pointer
  goes through the normal delay. After a dismissal or suppression a still
  pointer starts nothing on the target it already rests on.
- Reduce Motion: the workspace card wraps the whole name (3 lines), so the
  row no longer adds a tooltip (that was a second popover for one hover).
- AppKit tooltips and click popovers are not hover cards and stay as they
  are (see "Not verified").

## Verification

- `HoverCardModelCheckTests`: the reducer plus a world (card, timer) driven
  only by effects; 2 windows, 3 targets, current and stale token, 19 event
  kinds. Invariants after every step: I1 card and timer are the machine's
  (so at most one card and one timer app-wide), I2 a hover card is for what
  the pointer is over, I3 a stale deadline changes nothing, I4 a removed
  target has no card, I5 dismissal and suppression end idle, I6 nothing
  active while suppressed, I7 tokens are used once, I8 no card is lost while
  the pointer rests on a target. Liveness from every reachable state.
- `plans/cmux-next/formal/hovercard.tla` + `.cfg`, run with `tlc.sh`
  (pinned tla2tools.jar 1.8.0, sha256-checked): the same invariants, the
  stale-deadline step property, and liveness (a pointer that rests on a
  target gets its card and keeps it). Two mutants (no resume after a
  suppression; a firing timer that does not show) are each caught.
- Debug builds: `debug.desync` invariant H1 (at most one card window exists
  and shows, and it shows the machine's target); `debug.hover_cards` reports
  the machine, card window, timer and monitor.

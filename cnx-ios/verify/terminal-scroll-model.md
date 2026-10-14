# Terminal scroll model

One owner of the terminal page's scroll position. It replaces separate rules
that each set the content offset: the follow policy's resize and input rules,
the composer and tab-return pins (F4, F8), the origin-shift correction and
the "keep the end" rule (F2). Code: `CnxTerminal/Session/TerminalScrollModel.swift`,
applied by `TerminalViewController.applyScroll()`. Unit tests:
`TerminalScrollModelTests`.

## States

| State | Meaning | Offset |
| --- | --- | --- |
| `following` | Pinned to the bottom; new output keeps it there. | The bottom (`TerminalDocumentLayout.bottomOffset`). |
| `reading(anchor)` | The person scrolled away. | The anchored row's content y plus its pixel remainder. |
| `interacting` | A finger is down, or the page decelerates. | Not touched: UIKit owns it. |

The anchor is a content row's identity: its absolute row in Ghostty's
scrollback and the offset's remainder below that row's top. Output that
appends, a TUI redrawing rows below the cursor, or a document whose top moves
(the blank mirror rows found or cleared) change the document, not the anchor,
so the rows being read stay exactly where they are.

## Transitions

Only the person's input or a real reset moves between states:

- drag start (`scrollViewWillBeginDragging`) → `interacting`;
- release without deceleration, or the end of a deceleration → `following`
  within 2 rows of the bottom (8 rows when the gesture touched the bottom edge,
  since streaming output grows the end meanwhile), else `reading` anchored at
  the top row;
- typing, a paste, the key bar (`revealCursorForInput`) → `following`;
- Jump to bottom → `following`;
- a mirror reset (reattach, resize replay), a cleared scrollback, leaving a TUI
  → `following`;
- the keyboard following the finger in a drag that began at the prompt (M6)
  → stays `interacting`, with the prompt pinned on the composer for the rest
  of the gesture, then `following`.

A deceleration stopped by a touch that never became a drag ends no gesture;
the next `applyScroll` settles it.

## Who sets the offset

`applyScroll()` is the only place outside UIKit's own gestures that sets the
content offset, apart from two named exceptions: the keyboard-drag pin (M6)
and the DEBUG fling animator. It runs after layout (`viewDidLayoutSubviews`,
so inside the keyboard's animation when the insets change) and after each
processed output batch (at most one per display frame, the flood work's
coalescing). In `following` it sets the bottom; in `reading` the anchored
rows; in `interacting` nothing. One function computes the bottom
(`maxOffsetY`).

## What it fixed

- **Oscillation near the bottom** (user video 13:37): several rules set the
  offset in the same frames (the document-resize follow rule, the inset pin,
  the F4 clamp, the tab-return pin) and a resize's held frame stood over a
  moving page. Now only the model sets it, a held frame is never taken while
  the page moves, and no resize is sent for a transient composer height
  (`ea78dc83`).
- **Scrolled up while the agent streams** (F2 and the "super buggy" report):
  the reader's rows are an anchor, so the end moving up during a TUI redraw,
  or output appended below, no longer resumes following or moves them.

## Verification

- Rig `scroll_while_streaming`: ~20 lines/s with a status line redrawn below;
  drag up, fling up, drag down, fling to the bottom, 60 fps: no frame of
  another region, no black frame, following at the end.
- Rig `scroll_to_bottom_stable`: scrolling into the bottom of a long styled
  transcript: no frame of another region; settled.
- Rig `codex_scroll_hold` (real Codex, `CNX_E2E_REAL_CODEX=1`): scrolled up
  while Codex streams, 12 frames over 7 s identical.
- Also passing on the same build: `reattach_no_jumps`, `composer_bottom_pin`,
  `shell_pull_keyboard_up`, `tui_quit_keyboard_up`, `term_scrollback`,
  `tab_switch_last_row`, `keybar_swipe_no_back`, `relaunch_restore`.
- Not verified here: a main-thread hitch trace (Instruments) during scrolling;
  the user's two exact device scenarios were not reproduced on the simulator
  rig on either the old or the new build.

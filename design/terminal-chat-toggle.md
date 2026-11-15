# Toggle Terminal and Chat

One keystroke and one visible control swap the same live agent session between its terminal and its chat.

Leo, 2026-11-12: "we do want the option for people to just say like, okay, we can toggle it, like from the
terminal into the GUI, or vice versa, back and forth, right? Like that's the whole joy of the thing. That's
our sauce right there."

Gallery: `design/terminal-chat-toggle-gallery.html` (variants 1 to 4, on the terminal face and the chat face,
light and dark, plain and over a wallpaper). Stills: `design/terminal-chat-toggle-gallery/`.

## References

From the design references repository (private: ids only).

- `claude/live/code-home-after-login`: a two-icon Chat | Code segmented toggle at the top of the window. It is the
  closest prior art for one session in two modes.
- `cmux/live/agent-pane-search-ask-toggle`: our own Search | Ask segmented control, the house look of a two-state
  switch.
- `cmux/live/tabs-panels-toolbar-toggled-highlight` and `cmux/live/pane-toolbar-vertical-ellipsis-spacing`: the
  pane's top-right icon row; a toggled tool sits on a rounded fill.
- `cmux/live/toolbar-horizontal-ellipsis-square-padding`: square padding for every toolbar tool.
- `cmux/live/tabs-top-right-buttons-shift`: the trailing area must not move through tab changes.
- `cmux/live/sidebar-transcript-gui-layout`: a GUI experience rather than a terminal-style TUI.

## Model

- A **pair** is a terminal tab and a View Only chat tab (acpmux `watch`) of the same Claude Code or Codex session,
  in the same pane.
- A swap is a tab selection. Both views stay parked in the pane (`PaneContentView+Parking`), so nothing reloads or
  resizes and the chat's scroll is kept.
- Whether a tab is half of a pair is the Rust route's answer (`cmux-window-rules` `tabs::terminal_chat_toggle`)
  for the facts the action builds (`TerminalChatHandler.facts`). A refusal (`notAgentTab`, `noSession`,
  `unsupportedHarness`) shows no control. Every other answer (to chat, to terminal, resume in a terminal, a
  hand-off in progress, busy) shows it, so the control appears exactly where the key acts.
- From a chat no terminal runs, the action stops the chat's run, opens the harness's resume command in a new
  terminal, and replaces the stopped chat with a View Only chat of that session right after the terminal. That
  one hand-off loads the chat once. Every swap after it is a tab selection.

## Same turn, both ways

A swap lands at the same turn in the other view. The person's prompts are the pivot: both views show them, so
each prompt's row in the terminal pairs the two.

- The chat names its prompts (oldest first) and the turn in view: the prompt at or above its resting row
  (`webviews/.../conversation/togglePlace.ts`). The terminal hands over its whole screen, one line per scrollbar
  row, and its viewport's top.
- Rust pairs them (`cmux-window-rules` `tabs::place`). It finds the newest prompt first, each one above the next.
  A row the harness marked as a prompt (`> `, `› `) wins over a reply line that starts with the same words.
- To the terminal, the turn's prompt row scrolls to the viewport's top (`scroll_to_row`). If the screen lost that
  prompt, the nearest older one it still has is used.
- To the chat, the newest prompt at or above the terminal's top row is placed at the top of the view
  (VirtualTranscript `placeNow`). This is one cut, with no glide, while the chat is still hidden.
- Either face at its latest brings the other to its latest. When both are already at their latest, the swap asks
  nothing of the page and stays a plain tab selection.
- The face about to show moves before it shows, so the first frame is already in place. The page gets 60 ms to
  answer. If it misses that, the view shows where it is.

## Placement

- Native Swift chrome: the pane toolbar's trailing slot (`CmuxNextTabs/PaneTerminalChatToggleView`, in
  `PaneToolbarView`), left of the "…" slot and of Exit Zoom.
- The same x on both faces. Beside a chat the bar keeps "…"'s slot right of the control (the chat has no pane
  "…"), and the chat's own header tools move left by the bar's width (`PaneContentView` `offerTabRow`
  `trailingInset`).
- Room is kept for the pane: while any tab of the pane is half of a pair, the bar keeps the control's width
  whichever tab is selected, so the strip and the pins never hop (Lawrence 2026-10-19, `PaneToolbar.State`).
- Clear on glass (`design/surface-materials.md`: window chrome, no new backing). Each segment is a
  `TitlebarBandButton` square at the chrome's one button size, as the other toolbar tools.

## States

| State | Look |
| --- | --- |
| Terminal face selected | `>_` lit (the toggled tool's rounded fill, the lit glyph), bubble in the secondary glyph |
| Chat face selected | bubble lit, `>_` in the secondary glyph |
| Hover on the other face | the chrome's hover fill on that segment |
| Hover on the lit face | no change; a press does nothing |
| A tab that is not half of a pair | no control; its room is kept while the pane holds a pair |
| No pair in the pane | no control and no room |

The control shows at rest (`alwaysVisible`): it never fades with the bar's other tools
(`tabs.restingControlOpacity`).

## Keystroke and tooltip

- The action is `palette.toggleTerminalChat` (Toggle Terminal and Chat). A press on the other face runs it through
  the action registry with the selected tab as its target, the same path as the key.
- The tooltip is the action's title and its shortcut from the catalog (`ActionRegistry.shortcutDisplay`), never a
  hard-coded key. It has no default key (Leo, 2026-11-15: "idk if the terminal gui should even get a hotkey by
  default"): a person binds one in Settings > Keyboard Shortcuts; the Command Palette, the pane control and the tab's
  right-click run it unbound.
- VoiceOver reads a radio group, "Toggle Terminal and Chat", of two radio buttons, "Terminal" and "Chat", the lit
  one selected.

## Stable zone

`design/transcript-overlays.md`: stable zones hold what never moves when something arrives, and the identity of a
view is never news. Which face of a session you are on is identity, so the control lives in the pane's stable
top-right row, at one x on both faces, and nothing arriving in the chat or the terminal moves it.

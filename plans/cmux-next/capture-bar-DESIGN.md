# Capture bar (cmux NEXT)

Leo, 2026-11-07: "could we also have a more native screenshot/screensharer (ergonomic one)/video
recording of the app type thing/route?"

One shortcut (⌃⇧⌘5) and a menu item (View > Capture…, also in the palette) open a small capture bar
on the composer of the chat the person is working in. It takes a screenshot (Region, Window, Pane,
or the cmux window) or records the cmux window as a video, with the pointer and clicks drawn when
the person wants them. What it makes lands in that chat's composer as an attachment by default; Copy
and Save are the other destinations.

## Where it lives

- Web (`webviews/src/agent-session/acpmux/capture/`): the bar, its modes, targets, options and
  destination, the recording state (timer and Stop), and where the result goes. The bar is the
  composer hat's glass, opens on the shortcut with no fade (menus and popovers open at once), and
  its mode switch moves on the house curve.
- Rust (`cmux-action-catalog`): the `capture.open` action (title, shortcut, menu, palette).
- Swift (thin bridge, `CmuxNextAgentPane/AgentPaneCapture*.swift`): the pixels. A Region or Window
  pick is macOS `screencapture`'s own. The cmux window and a pane come from ScreenCaptureKit's
  `SCShareableContent.currentProcess`, which needs no Screen Recording grant. A recording is an
  `SCStream` of the cmux window written to an H.264 `.mp4` in the temporary folder.

## Contract

Native to page (the chat the action picked: the focused chat, else the most recent chat shown in
the window):

- event `captureBar`, value `{toggle: true}`; script
  `window.cmuxAcpmuxBridge?.captureBar?.({toggle:true})`. A second press while recording stops
  the recording; otherwise it toggles the bar.
- event `captureBar`, value `{ended: true}`: a recording ended by itself (5 minutes, its window
  closed, a failure). The page collects the movie with `capture.record.stop`, as Stop does.

A recording lands in the chat it was started from. When another chat is shown by then, or the chat
runs on another computer, or a Save is cancelled, the movie goes to the clipboard instead: a
recording is never dropped.

Page to native (`callNative`):

| Method | Params | Answer |
|---|---|---|
| `composer.capture` | `{mode: "screen" \| "window" \| "app" \| "pane"}` | `{name, mimeType, data, source}`, `{tooLarge, name}`, `{cancelled}` (unchanged shape). `app`: the cmux window. `pane`: the pane that was focused when the bar opened. |
| `capture.record.start` | `{cursor: bool, clicks: bool}` | `{started: true}` |
| `capture.record.stop` | `{}` | `{path, name, seconds}` of the `.mp4` (or `{cancelled}` when it had no frames) |
| `capture.copy` | `{data, mimeType}` or `{path}` | `{copied: true}` |
| `capture.save` | `{data, mimeType, name}` or `{path, name}` | `{saved: path}` or `{cancelled}` |

`composer.capture` and `capture.record.start` keep the existing rule: the page asks only after the
person's own click or key in the pane (`gestures.consume()`).

A recording stops by itself after 5 minutes (`maxSeconds`), when the window closes, or when the
app quits, and its stream and writer are released then. A recording that is never attached is
deleted with the temporary folder.

## Not in this step

- Live screen share from the bar. It reuses the WebRTC screen stream (cmux#36074) and the chat
  share link (cmux#37766, #37819) and comes next; the bar shows no Share button until it works.
- Report to cmux (the backend feedback route) pairs with the opt-in usage recordings lane.

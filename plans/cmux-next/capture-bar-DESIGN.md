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
  `SCStream` of the cmux window and its child windows only (never another cmux window over it)
  written to an H.264 `.mp4` in the temporary folder.

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
| `capture.done` | `{}` | `{done: true}`: the chat took the last screenshot, so its Copy and Save are spent |

`composer.capture` keeps the existing rule for a Region or Window pick: the page asks only after
the person's own click or key in the pane (`gestures.consume()`). `capture.record.start` and a
shot of the cmux window or the pane, which no system pick confirms, need the person's own click
in the last 1.5 s (`AgentPaneCapture.personClicked`): a credit left by typing never starts one. `capture.copy` and `capture.save`
take image bytes only when they are the screenshot `composer.capture` just gave that pane (once,
within 30 s, and not after `capture.done`),
and a file only when it is a movie this bridge wrote, so a page never puts bytes of its own on the
clipboard. A recording that ended by itself and is not collected before another starts waits for
its own pane's `capture.record.stop`; it is discarded only when that pane is gone.

Only the pane whose page started a recording may stop it and take its movie; another pane's
`capture.record.stop` answers `{cancelled}`. A collected movie of a chat on this Mac moves into
that chat's Chat Uploads folder, so a draft or a sent message keeps its video past a relaunch, as
long as the chat's other uploads. A recording stops by itself after 5 minutes (`maxSeconds`), when
the window closes, or when the app quits, and its stream and writer are released then. A quit
waits for it after the composers are saved: the movie is finalized, kept in its chat's Chat
Uploads folder and put on the clipboard, since no page collects it any more. An incognito
chat's recording is discarded with the chat instead. One still starting (ScreenCaptureKit's
start takes up to 20 seconds) is cancelled before its first frame, and no new one starts. A recording
that is never collected is deleted with the temporary folder, after a day.

## Not in this step

- Live screen share from the bar. It reuses the WebRTC screen stream (cmux#36074) and the chat
  share link (cmux#37766, #37819) and comes next; the bar shows no Share button until it works.
- Report to cmux (the backend feedback route) pairs with the opt-in usage recordings lane.

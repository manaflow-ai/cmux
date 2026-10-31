# Share screen with Chief

Lawrence, 2026-10-30 (Home chat 17929): "let's build a screen sharing feature into chief so i can
share screen with chief and have it incorporated into memories".

## What the person gets

- **Share Screen with Chief** in the Chief chat header (a toggle beside the Chief's name), the
  command palette (Cmd-Shift-P), the CLI (`cmux chief share-screen`, `cmux chief stop-sharing-screen`,
  `cmux chief look-at-screen`) and the MCP tools that follow the CLI.
- While sharing, a menu bar item (visible from every app) says "Chief can see your screen" and has
  **Stop Sharing**, and the header toggle shows in the accent colour. macOS adds its own capture
  indicator on top. One click on either stops it.
- While sharing, Chief gets what changed on screen, as words, in its memory. It can also look at
  the screen now: `cmux chief look-at-screen` captures a fresh frame and answers its file and text.
- Off means off: no capture, no timer, no frame written, and the "current screen" file is deleted.

## How it works (first principles: least CPU, memory and disk)

```
ChiefScreenShare (@MainActor @Observable, CmuxNextChiefScreenShare)
  DemandTimer, one shot per 5 s while sharing (no repeating timer, nothing while off)
    -> ChiefScreenCapturing.capture(changedSince:)        off main (@concurrent)
         ScreenCaptureKit still of the main display, 1440 px wide, cursor hidden,
         cmux and password managers excluded (SCContentFilter excludingApplications)
         32x20 grey signature; unchanged (< 2% mean difference) -> nil, no OCR, no JPEG
         changed -> Vision text recognition (.fast, on device) + JPEG (q 0.6)
    -> ChiefScreenJournal (actor)                         files only, nothing leaves the Mac
         latest.jpg + latest.json      the current screen, for "look now"
         frames/<day>/<time>.jpg       the source frame of each memory entry
         inbox/<ms>.json               one entry per changed frame whose text changed
optchat-chief brain (Rust, screen_share.rs)
    at each turn start: the inbox's entries become ONE quiet note in the Chief's log
    ("screen share 17:40-17:52, 3 changed frames: ..."), with each frame's file; the
    entries leave the inbox, the frames stay. Notes never wake the Chief.
OptChat compaction then summarizes those notes like any other line, so the view keeps a
dated summary that `zoom` opens back to the note and the note names the frame on disk.
```

Why this shape:

- **No video.** A still per 5 s, compared on a 640-byte thumbnail, is the whole cost while the
  screen is still. Text recognition and JPEG encoding run only for a changed frame. Nothing is
  uploaded: only words reach the Chief's log; frames stay in the Chief home (`optchat/`, mode 0700).
- **Memory, not a feed.** The Chief does not take a turn per frame (that would burn tokens and
  interrupt). Entries wait in the inbox and join the log as one note when the Chief next takes a
  turn, so the person's next message, a subagent report or any other wake carries "what was on
  screen" into that turn, and compaction folds it into the long-term view.
- **One shared action path.** Header toggle, palette, CLI and MCP all run the same registered
  actions (`chief.screenShare.toggle|start|stop|look`), which call one model.

## Privacy rules

- Never on by itself: only the person's action starts it, every launch starts with it off.
- Excluded from every frame: cmux itself (the Chief's own chat would echo back), 1Password,
  Bitwarden, Dashlane, LastPass, KeePassXC, Keychain Access and Apple Passwords
  (`ChiefScreenShareExclusions`).
- MCP may stop sharing and look while it is on, but cannot start it (`systemChange` exemption):
  an agent never turns on capture of the person's screen.
- Screen Recording not granted: the first start asks macOS; when that is refused the share stays
  off, the action says why and opens System Settings > Privacy & Security > Screen Recording.

## First slice (this change)

- `CmuxNextChiefScreenShare`: the model, the ScreenCaptureKit capturer, the journal, exclusions.
- App: the four actions, the header toggle (shown on the local Chief's chat even while the other
  header toggles are off), the menu bar indicator with Stop Sharing.
- optchat-chief: the inbox becomes a note at each turn start.
- Tests: the model (start, change-only capture, stop leaves nothing running, permission refused,
  look), the journal (files, dedupe, prune), the brain's note (one note, inbox emptied, frames kept).

## Later slices

- Pick what to share: one window or one display (SCContentSharingPicker), not only the main display.
- SCStream at 0.5 fps instead of stills: WindowServer reports idle frames itself, so an unchanged
  screen costs nothing at all; measure both on the fleet before switching.
- Per-pane privacy: cmux panes marked private are blanked instead of excluding all of cmux.
- A model-written summary per sharing session (the compactor's deny-all model, as image
  descriptions do), and sending a frame to the turn as an image when the person asks "what do you see".
- Named Chiefs and the Cloud Chief: today only this Mac's main Chief home gets the notes.
- Frame retention setting (today: the newest 1000 frames are kept, older ones deleted).

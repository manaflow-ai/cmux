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
    -> ChiefScreenHelperCapture.capture(changedSince:)    off main (@concurrent)
         host socket -> cmux Computer Use helper, host-only `display_still`
           (scripts/cmux-cua-display-still.patch): a WindowServer still of the main
           display, 1440 px wide, cmux and password managers' windows left out (by pid)
           32x20 grey signature; unchanged (< 2% mean difference) -> no JPEG in the reply
           changed -> JPEG (q 60) in the reply
         changed -> Vision text recognition (.fast, on device) in cmux
    -> ChiefScreenJournal (actor)                         files only, nothing leaves the Mac
         latest.jpg + latest.json      the current screen, for "look now"
         frames/<day>/<time>.jpg       the source frame of each memory entry
         inbox/<ms>.json               one entry per changed frame whose text changed
optchat-chief brain (Rust, screen_share.rs)
    at each turn start: the inbox's entries become quiet notes in the Chief's log, one
    per 20 frames ("screen share 17:40-17:52, 3 changed frames: ..."), each line naming
    its frame's file; no entry is dropped; the entries leave the inbox, the frames
    stay. Notes never wake the Chief.
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

- Never on by itself: only the person's action starts it, every launch starts with it off and
  deletes any current-screen files a quit or a crash left behind.
- Excluded from every frame: cmux itself (the Chief's own chat would echo back), 1Password,
  Bitwarden, Dashlane, LastPass, KeePassXC, Keychain Access and Apple Passwords
  (`ChiefScreenShareExclusions`).
- Only the person starts it: Share and Toggle are person-only actions (the control socket refuses
  them, so neither `cmux chief share-screen` from a terminal agent nor MCP can start capture).
  Stop and Look Now are open to the CLI and MCP while sharing is on.
- Screen Recording belongs to the cmux Computer Use helper, never cmux.app: cmux never captures
  the screen or asks macOS for it (a test scans the Share Screen sources for capture calls). The
  first start asks macOS for the helper; while it is not allowed the share stays on but reads
  nothing (`needsPermission`), the action says why and opens System Settings > Privacy & Security >
  Screen & System Audio Recording. Granting it makes macOS "Quit & Reopen" only the helper; its
  owner (`ComputerUseHelperDaemon`) starts it again, sharing waits (`waitingForHelper`) and starts
  by itself on the next check (every 5 s), with no second click and no relaunch of cmux.
- The helper runs while Computer Use is on (legacy driver). With it off, sharing waits and says so.

## First slice (this change)

- `CmuxNextChiefScreenShare`: the model, the helper-backed capturer, the journal, exclusions.
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
- Frame retention setting (today: the newest 1000 frames and inbox entries are kept, older ones
  deleted, so an old note can name a frame that is gone).
- Delete the current-screen files at quit as well (today: at the next launch).

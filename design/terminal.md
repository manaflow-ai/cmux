# Terminal pane: in-between states

A terminal pane has one material: the window's glass (or the opaque theme color on an opaque
window), the same as every other pane. Its in-between states keep it.

Leo, 2026-11-07: "the loading in-between indicator shouldn't all of a sudden become opaque ...
we can just have the small symbols as loading indicators, like really transparent things, if
even. ... don't add some sort of weird backing to the Chromium thing to make that opaque when
everything else is just the one level of transparency. And likewise, don't do that for the
terminal."

## States

- **Restoring (launch).** The pane shows the terminal's last frame until its first live frame
  (`TerminalLaunchFrames`). A frame with clear pixels (a see-through window) is saved as a PNG
  and keeps them, so the glass shows through it. An opaque frame is a JPEG.
- **Restoring, Reconnecting (transient).** These states wait out a reveal delay and usually clear
  first. When one lasts, it shows the shared loading mark: 14 pt, 40% opacity, centered 12 pt
  above the bottom. It has no fill and no edge. Its words are its VoiceOver label only.
- **Lasting states** (Disconnected, Process exited, Terminal lost, a stalled shell). They show
  their words on the small raised label, because the person has to read and act on them.

## Other surfaces, same rule

- Chromium: a committed page that has not painted is see-through (fork API 17). The pane's own
  ground shows until the document paints, then the document's background takes over.
- WebKit: draws no background during its hold (`WebKitTab+LoadingBackground`).
- Agent pane: its loading view paints the page's own under-page color and the shared mark.

Variants: `design/in-between-states-gallery.html`.

## Selecting text while a program has the mouse

A full-screen TUI (Claude Code, Codex, vim with `mouse=a`) takes every click and drag. Option-drag
selects text anyway, as in other Mac terminals, and so does Shift-drag (Ghostty's own override);
Option-Shift-drag is the rectangle selection. Cmd-C then copies exactly that selection. Without a
program on the mouse, Option-drag stays the rectangle selection.

The first plain drag a TUI takes in a terminal shows the hint once: the shared modifier-hint glass
chip (`ShortcutHintChipView`, the one held Command or Option shows), centered 12 pt above the
bottom, "Option or Shift + drag selects text". It fades in (`Motion.overlays`), stays four seconds
(a one-shot `DemandTimer`), fades out, and clicks go through it.

Variants: `design/terminal-selection-hint-gallery.html`.

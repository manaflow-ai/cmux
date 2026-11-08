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

## Fix on a failed command

A command that ends with a nonzero status (except 130, a Ctrl-C the person typed) shows the Fix chip
in the bottom-trailing corner, clear of the scroller, above the "Sized for" chip when both show. It
is the same small raised label as "Sized for": "Exit 101", a small Fix button and a close button.
It fades in on the overlays motion category (none under Reduce Motion) and never moves the
terminal's text. Return (the next command), a successful command, Fix or the close button hides it.
Fix puts the command, its output tail, its status and its folder in the workspace's agent chat
after its draft, or in a new chat beside the terminal; nothing is sent until the person presses
Return. Variants: `design/terminal-fix-chip-gallery.html` (A shipped).

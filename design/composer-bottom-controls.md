# Composer controls stay at the bottom as it grows

Leo, 2026-11-23, of +, Send and the mic left on the top line of a four-line draft: "buttons need to
be at the bottom. ... why ... if your composer grows in length, should the buttons you ... reach for
stray away from you? obviously, just do it right. period." And of the draft's scrollbar: "i already
told you guys to move the thumb inside, and it should only appear briefly when the length changes,
or when you scroll. not all the time. never all the time."

## Rules

1. **The controls are pinned to the last line.** +, the mic and Send/Stop (and every control in
   their columns: Codex's bolt, steer's return) are centred on the draft's last visible line at
   every height: one line, every line as it grows, the cap, and past the cap with the draft scrolled
   inside the box. The inset under them is the prompt's bottom inset, so a one-line composer looks
   the same as before. The controls move only when the composer grows; they are never left behind
   at the top. Attachments over the prompt change nothing at the bottom.
   (`composerLocation.css`, `.acpmux-composer-inner` children: `align-self: end`.)
2. **The thumb is inside the box, and transient.** The draft's thin thumb runs down the box's own
   right edge, inside its rim, its track stopping above Send. It shows only for a moment: when the
   draft's length changes while it overflows (a line typed, pasted or deleted past the cap, a
   rewrap) or when the draft scrolls, then fades out. While the pointer is over its lane it shows
   so it can be grabbed. It is never drawn at rest. (`scrollers.ts` `MINIMAL_SCROLLER_CSS`,
   `composerScrollLane.ts` `flashThumbOnLength`.)
3. **What sits on the composer's top edge rides with it.** The tucked hat's pull tab ("^ 3") and
   the Jump to latest stack are placed from the composer's top, so they move up as it grows and
   never end up over its text or its controls.

## Evidence

- Gallery: `agent-pane.composer-growth` (1, 3, 8 lines and past the cap scrolled, narrow and wide).
- Test: `webviews/test/composer-bottom-controls.browser.test.ts` measures each control's centre
  against the last line's centre at every height, the pill against the composer's top, and the
  thumb's ink at rest and after a length change.

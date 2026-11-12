# Transcript overlays: zones, the unread marker and the jump pair

The agent chat's transcript (webviews `agent-session/acpmux`) draws a few controls over its rows. This page
says where each one lives and why, and specifies the unread marker and the jump pair. Galleries:
`agent-pane.since-divider` (the looks, in light, dark and over an image) and `agent-pane.unread-marker`
(the whole pane).

## The principle: stable zones and dynamic zones

Leo, 2026-11-10: the top left "is just where your eye naturally settles, as in like this is just where you
expect certain things to come in, that dynamism versus like what parts of the UI you expect to not change."

- **Dynamic zones** are where arrival and status come and go. Each kind of news has one predictable place,
  so a reader learns where to look once.
- **Stable zones** hold what never moves when something arrives. Nothing new lands in them.
- Every overlay over the transcript is listed in `overlayLayout.ts` (`TRANSCRIPT_OVERLAYS`) with its zone.
  `unreadMarker.test.ts` fails when an overlay has no zone, when two overlays share a zone without being one
  stack, or when a sheet places one outside its zone. A new overlay starts by picking its zone here.

| Zone | Kind | What lives there | Why |
| --- | --- | --- | --- |
| Top start of the text column | dynamic | The unread banner | What's new arrives where the eye settles on entering a chat |
| Bottom center, on the composer's center line | dynamic | Jump to latest (or the Needs you pill), with Jump up stacked on it | Where to go next waits next to where you type |
| Top center, under the header | stable | The pinned "Subagent of" pill | Identity of the view, never news |
| End edge | stable | Session Info | Pushes the column or floats in the gutter; never covers a dynamic zone |

The top zones start at the transcript's clear line (under the header and the tab row) and under a pinned
pill (`topZoneOffset`). The top-start zone keeps to the column's insets (`--cv-inset`, `--cv-inset-end`),
so Session Info's push and the computer use preview never overlap the banner. The bottom-center zone
follows the composer card's center while Session Info pushes.

## The unread marker

Leo, 2026-11-10: "everybody likes it, likes the feature itself, but ... it looks a little bad. Like the
line is weird and the placement is weird ... you can take a lot of inspiration from, say, like [other chat
apps]." It has two parts. Prior art: the common chat-app unread rule with a filled NEW tag at its end, its
"N new messages since 3:42 PM, Mark as read" bar, and the accent "New" line with a "New messages" pill; and two
design notes of ours: "let arrival yell; let unread state persist quietly" and "preserve geography; adapt
salience".

### The static view: the New line

- Where the person left a chat that kept working (acpmux `seenSeq`), one row placed when the chat opens and
  kept until another chat is selected (`direct.ts placeSince`), so it never appears or goes under the reader.
- A hairline in the theme's accent (`--cmux-app-accent`) across the text column, with a small filled "New"
  tag pinned to its end (`--cmux-app-on-accent` on the accent, `--ds-radius-sm`, caption type). Not a fixed
  blue: the line belongs to every theme, light, dark and over a background image.
- One control row tall (`--ds-control-row`, the 28px `model.ts` estimates), the recap's card under it. It
  sits in the message rhythm and never overlaps or moves a row.
- Read (Mark read, or the line seen and then the latest message reached by the reader): the rule and the tag
  fade in place over `--agent-motion-calm`. The row keeps its height, so nothing jumps; the recap stays.
- Right-click: Mark read, and Hide unread banner or Show unread banner (the setting).
- Looks compared: `tag` (chosen), `text` (accent words, no fill), `labelled` (the first look on
  tokens: "New since you looked · 3 turns" leading the rule).

### The moving view: the unread banner

- A compact glass bar in the top-start zone while the line is off screen and not yet reached:
  "↑ 3 new turns since 3:42 PM | Mark read | ‹". The arrow points to where the line is.
- The body jumps to the line. Pressed, or once the reader reaches the latest message by their own move, it
  has done its job for that mark (`sinceDone`, as #40072 has it for #40065).
- Collapsed: a small pill, "↑ 3 ›". The chevron collapses and expands it and keeps the choice. Collapsing
  folds the middle on `--agent-motion-move` while the chevron and the bar's end ride it, so everything that
  moves moves together.
- Mark read fades the line and hides the banner until the next return (a new mark).
- Right-click: Jump to new, Collapse or Expand, Mark read, Hide unread banner. Hidden, the line's right-click
  has Show unread banner.
- The setting: `agentPane.display.unreadBanner`, `expanded` (default), `collapsed` or `off`
  (Settings > Agent Chat > Chat Layout > Unread Banner).
- It fades in and out in place with the pane's motion tokens and never slides.

## The jump pair

Leo, 2026-11-10: "having a jump up button, like jumping up since like the last time you interacted manually
seems like very good. Because it's like, okay, you get jump to bottom, but then jump to, like, the last
thread."

- **Jump to latest**: a glass control on the composer's center line while the reader is scrolled up.
- **Jump up** stands one control and one gap above it (`jumpPair.css`): the same look, size, glass, focus and
  fade, its arrow up. The two read as one column, and neither moves for the other.
- **The look** is the `jump-pair-look` experiment (`jumpPair.experiment.ts`; gallery
  `agent-pane.jump-pair-look`, view Compare arms). Leo, 2026-11-12, of the fisheye disc: "I feel like this
  jump to top button is a little bit strange-looking, no?" Prior art: the common chat apps draw a small
  frosted or solid circle with a down arrow, centered over the composer, a hairline rim and a soft shadow;
  the messaging apps a small chevron button in the same material as their bars. None bends the page under it.
  - `frosted` (ships): a 32 px disc at the composer's glass level (the popover level, glass.css GLASS
    LEVELS), the arrow. The words under it frost; nothing bends.
  - `labeled`: the same glass as a rounded rectangle with the arrow and its words, the Needs you pill's
    shape and type.
  - `stacked`: frosted rounded squares in the Needs you pill's radius, a hairline (`--ds-space-1`) apart.
  - `lens`: the fisheye disc before (Leo, 2026-10-21: "I want more fisheye!"); gallery
    `agent-pane.jump-latest-lens` keeps its strengths and glass levels.
  Every arm keeps the glass (never opaque; Lens and Spectrum glass keep their own tint), the 32 px height
  (so Jump up stands over the Needs you pill as over Jump to latest), the center line, the fade in place
  and the behavior. Try one in the app: `cmux.experiments` = `{"jump-pair-look":"labeled"}` in the pane's
  web inspector, then reload.
- It goes to where the reader left off (`jumpUp.ts`): the New line while it is unread, else the newer of the
  person's last sent prompt and where they last stopped scrolling by hand.
- It shows only while that place is off screen.
- Pressed, it holds where the view was and points down: a second press, or Esc, goes back there. A scroll by
  hand lets go of the way back. Esc that something else takes (the composer's Stop, a menu) is left to it.

## Putting a waiting card away

Leo, 2026-11-11, on the composer hat holding a started chat's question: "there's no close button :(".
Every card over the composer that waits on the person can be put away (the composer hat's questions,
`question/HatQuestions.tsx`; the shared notice, `ui/Notice.tsx`):

- One control: the shared × (`ui/DismissButton.tsx`), a 12 pt glyph in a `--ds-control-icon` box.
  Escape with the focus inside the card does the same; Esc that a control inside used first is left to it.
- The hat's × fades in while the pointer is over the band or the focus is in it, and keeps its room at
  rest: the head's text is laid out beside it either way, so revealing it moves nothing. With no hover
  (touch) it shows at rest. Never over the card's corner in no room of its own (it would cover the pager).
- Dismissing marks the question seen in that chat, on this device (`question/hatSeen.ts`, kept with the
  pinned asks' dismissals in `waitingAskStore.ts`): it leaves the hat; the ask itself still waits where it
  was asked (its card, its chat, the sidebar's Needs you dot).
- A started chat's name has the head's line to itself and its question the line under it, so neither is
  cut at a fixed share of the band.

## Tokens only

Every colour, radius, size and motion of these controls is a token: `unread.css`, `jumpPair.css` and
`SinceDivider.tsx` are `TOKEN_ONLY_FILES` in `webviews/scripts/check-design-tokens.ts`, which refuses a
literal colour, duration or easing in them even as a var() fallback, and a radius that is not a token
(`test/design-tokens.test.ts`).

## Platforms

The transcript is shared web on macOS (cmux NEXT's agent pane). The iOS chat is native
(`cmux-next-ios/CmuxMobileKit` `CmuxMobileAgentChat`) and has no unread line yet; when it gets one it follows
this page.

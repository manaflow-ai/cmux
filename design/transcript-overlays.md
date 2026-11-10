# Transcript overlays: zones, the unread marker and the jump control

The agent chat's transcript (webviews `agent-session/acpmux`) draws a few controls over its rows. This page
says where each one lives and why, and specifies the unread marker and the jump control. Galleries:
`agent-pane.since-divider` (the line's looks, in light, dark and over an image), `agent-pane.unread-marker`
(the whole pane) and `agent-pane.jump-control` (every state of the one control).

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
| Bottom center, on the composer's center line | dynamic | The one jump control: up to unread turns, down to the latest message, or the Needs you pill | Where to go next waits next to where you type |
| Top center, under the header | stable | The pinned "Subagent of" pill | Identity of the view, never news |
| End edge | stable | Session Info | Pushes the column or floats in the gutter; never covers a dynamic zone |

The bottom-center zone follows the composer card's center while Session Info pushes. The top-start zone
is free: what is new is reached from the one jump control, never from a second control over the top.

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

## The jump control

Leo, 2026-11-10, of a capture with Jump up stacked on Jump to latest and the collapsed unread pill
under them: "There's also no point doubling up on this." And of Jump up: "this jump to last read is
not themed, like the jump to top thing. And it's also, like, well, what is the point of that if it's
just, like, if it's always there? Like, this should be more selective. And it also needs to work better
with when there is truly some unread stuff from the past."

- **One control** (`VirtualTranscript.tsx` JumpToLatest, `jumpControl.ts`): Jump to latest's own disc,
  its fisheye glass, size, rim, place on the composer's center line and fade. Never a second disc, a
  pill over the top or anything stacked on it. It does the jump the view needs:
  - **Up**, while "New since you looked" lies above the view and the reader has not reached it (never
    on screen, not pressed, the latest message not reached by hand, not Mark read): the arrow turns up
    in place and the disc carries the count of new turns as a small badge in the line's accent
    (`jumpControl.css`). A press goes to the first unread message. When that lies in history not
    loaded yet, the rows through the last record the reader had seen are read in first
    (`direct.ts loadThrough`), so it lands on the line with what came before it above.
  - **Down**, while scrolled up from the latest message: Jump to latest, or the Needs your input pill
    while an ask waits below or in a chat this one started (an ask comes before the unread count).
  - **Hidden** otherwise. Nothing sends it up but truly unread turns: not the reader's last prompt, not
    where they last stopped scrolling.
- Hidden, it keeps the arrow it last drew while it fades out, so the arrow never turns mid-fade.
- The setting `agentPane.display.unreadBanner` `off` (the line's right-click, Hide unread banner)
  keeps the control from pointing up; the line stays.

## Tokens only

Every colour, radius, size and motion of these controls is a token: `unread.css`, `jumpControl.css` and
`SinceDivider.tsx` are `TOKEN_ONLY_FILES` in `webviews/scripts/check-design-tokens.ts`, which refuses a
literal colour, duration or easing in them even as a var() fallback, and a radius that is not a token
(`test/design-tokens.test.ts`).

## Platforms

The transcript is shared web on macOS (cmux NEXT's agent pane). The iOS chat is native
(`cmux-next-ios/CmuxMobileKit` `CmuxMobileAgentChat`) and has no unread line yet; when it gets one it follows
this page.

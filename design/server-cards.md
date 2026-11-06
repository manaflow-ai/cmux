# Server cards: one floating card family

The cards that pair and add machines (Pair Another Machine and the join consent ask now; Add
Device, Add Server, the approver and Add Machine next) are one family: one floating panel, one
React page, one card per route. The join consent ask alone has a panel of its own (below). Swift keeps the panel and the services that touch the system (the cloud
calls, the invite socket, the clipboard); every card's look and every step it walks are React
(`webviews/src/pages/server-cards`).

## The host

- **One panel** (`WebCardPanel`, CmuxNextPages): a borderless, non-activating glass panel, 14 px
  corners, near the top center of the cmux window: its top edge 56 px below the window's top,
  centered on the window, kept inside the screen. It shows on every Space and over full screen and
  never activates the app. A card a person opened takes the keys; one that arrived on its own (a
  pairing link) shows without them, so typing in the window behind goes on.
- **One page** (`cmux.server-cards`), made on the first opening and kept warm: a later opening
  changes the route (`#/pair-invite`, `#/add-device`, ...) and never loads a page. One card shows
  at a time; opening another closes the one before (its session ends).
- **A card plugs in** as a `WebCard`: its own ops (`cmux.<card>.status`, the stream
  `cmux.<card>.changes`, its actions) and two calls from the panel, opened and closed.
- **Closing:** the card's Cancel or Done (`cmux.card.close`), Escape in the page or on the panel
  (the panel sends `cancel` to the card, which runs its own Cancel), another card opening, or its
  owner hiding it. Every way ends the card's session (a socket stops, an approval is dropped).

## Size and motion

- The card sets the panel's size: the page measures its card (`cmux.card.resize`) and the panel
  takes that size, keeping its top edge where the person saw it and growing or shrinking downward.
  The header and everything above the change stay still; only the bottom edge moves.
- **First opening:** the panel orders in only once the page has reported the card's size (or after
  400 ms), so the card never draws at a wrong height and then jumps. A card the page has measured
  before shows at once at its last size and then follows the page.
- **Width:** each card's own (Pair Another Machine 460 px). The page is transparent; the panel's
  glass is the only background.
- **Motion:** the panel's appearance follows the overlays motion setting (`Motion.overlays`); the
  steps inside a card change in one frame, with the panel's frame set from the same measurement.

## Security

An action that pairs a machine or lets one in (Confirm, Try Again, an approver's Approve) answers
only the person's own click on the card: the panel reads the click from its own events (a left
click from the HID system, not a key, an Accessibility press, a posted event or a script), begun at
least a double-click interval after the card last drew (a machine arrived and Confirm appeared
under a pointer aimed at what was there before), and spent once (`WebCardPanel.isPersonClick`).
Copy, New Code and options need the person's own click or key (`userGesture`). A copied code is
written concealed and transient so clipboard managers do not keep it.

## Pair Another Machine (`#/pair-invite`)

The reverse of Add Server: this Mac shows an invite code, the new machine runs `cmux pair CODE`,
and this Mac confirms it. The card's step comes from the host's status (`pairInvite/model.ts`):

| Step | Shows | Buttons |
| --- | --- | --- |
| minting | the title, a spinner, "Making a code…" | Cancel |
| showing | the help line, the code large (half again the heading step) with Copy Code, the countdown ("Expires in 9:41", the attention color under a minute) and "It works once", the QR on a white tile beside it, the `cmux pair` line and the install line each with Copy, then "Waiting for the machine" | Cancel |
| lookingUp | "A machine used your code", "Reading its details…" | Cancel |
| review | the machine's facts (name; OS, version, region), the four words two by two, the warning, Name, the Chief option, the click-only note | Cancel, Confirm (click only) |
| approving | the same, Confirm disabled, a spinner in the footer | Cancel, Confirm |
| approveFailed | the same, the refusal in the danger color | Cancel, Try Again (click only) |
| paired | "build-box paired", "It is paired with your team." | Done |
| voided, expired, lost, failed | the reason | Cancel, New Code |
| signedOut | "Sign in to cmux to pair another machine." | Cancel |

- **Start → end:** opening mints a code (minting → showing). An arrival replaces the invite with
  the machine (showing → lookingUp → review: the card grows downward to fit the words). Confirm
  (review → approving → paired: the card shrinks to its two lines). A second machine, the expiry or
  a lost socket end the invite (→ voided, expired, lost), and New Code goes back to minting.
- An expiry or a lost socket after the machine arrived changes nothing: the machine's own pairing
  outlives the invite, so Confirm still answers.
- The countdown ticks once a second only while an unused invite shows, and stops at expiry, on
  arrival, at the invite's end and on close. Nothing else repeats: the socket pushes every change.
- Return presses the default button (New Code, Done), never Confirm or Try Again.

### Variants (gallery `pages.server-cards-pair-invite`)

References: server settings panels that show a pairing address beside its action, and the copied
confirmation that swaps a button's label for a moment.

- **side** (shipped): the code and its meta in a column, the QR to its right, then the two lines.
  The code and the QR are the two ways to carry the invite, so they sit side by side at the same
  height and read as one choice; the lines below are for the person who types.
- **stacked:** the QR above the code, centered. Reads well for a phone camera, but the card grows
  132 px taller and the lines fall below the fold of a small screen.
- **line-first:** the `cmux pair` line first, the code and QR after it. It favors a person who
  pastes into a terminal, but the large code, which people read aloud, loses its place as the
  card's first thing.

Picked: **side**: the shortest card, the code first, and the QR in reach for a camera without a
second column of text.

## Join Consent (`#/join-consent`)

The join consent's one-time ask (`#/join-consent`): the first request acpmux refused with
`consent_required` asks the person at this Mac once whether the team's machines may see this screen
or control this Mac. `JoinConsentModel` (Swift) keeps the person line, the grant gate and the device
owner's confirm; `JoinConsentCardProvider` serves `cmux.joinConsent.*`; the card draws:

- the title: who asked for what (`devices.join.ask.screen` or `.control`, with the requester);
- the question (`devices.join.ask.screenQuestion` or `.controlQuestion`);
- the note (`devices.join.ask.note`): it can change later in Settings > Devices;
- why the last Allow did not take, in the danger color, when it did not;
- Deny and Allow, Allow the default. Both are off, with a spinner in the footer, while a write is in
  flight.

### The panel

The ask has a panel of its own, never the shared card panel:

- 380 pt wide, at the top right of the main screen, 16 pt in from both edges;
- at the status bar level, on every Space and over full screen, stationary, never moved by its
  background;
- it orders in over every app without activating cmux and never takes the keys;
- out of screen capture and screen sharing (`sharingType = .none`), so no screenshot, recording or
  agent's capture shows Allow, and Computer Use refuses the window.

### What answers

- Allow answers only the person's own click on the card, read by the panel from the click's own
  events (`WebCardPanel.isPersonClick`, with the app's strict HID-source check): never a key, page
  script, an Accessibility press, a posted or programmatic click, a click begun before the card last
  drew, or the same click twice (cmux#33066, HQ#5121). Neither button has a key.
- Deny answers the person's click or key; it writes nothing.
- Escape and the panel's cancel do nothing: only Deny or Allow ends the ask.

### Variants (gallery `pages.server-cards-join-consent`)

The gallery entry `pages.server-cards-join-consent` shows three layouts over the same ask, then the pick
asking for control, writing and showing an error:

- **stacked** (the pick): the title, the question and the note each on their own line. The question
  reads first after the title and the note sits apart as a caption, so the decision reads at a glance
  at the corner of the screen.
- **compact**: the note runs on after the question, with tighter padding. Shorter, but the note
  competes with the question.
- **banner**: an accent mark at the leading edge, the words beside it. It reads as a notification,
  which undersells a decision about the screen.

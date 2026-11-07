# Server cards: one floating card family

The cards that pair and add machines (Pair Another Machine now; Add Device, Add Server, the
approver, Add Machine and the join consent next) are one family: one floating panel, one React
page, one card per route. Swift keeps the panel and the services that touch the system (the cloud
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

An action that pairs a machine or lets one in (Confirm, Try Again, an approver's Approve) is not a
page control: a grant needs a control the page cannot press, name, move or hide. The card names it
(`PersonControl`: its title and whether it is enabled, from the card's own state), and while it
shows the panel lays out its own native footer under the page with that control at its own size
at the trailing edge; the page's size covers only the content above, and the page has no Confirm.
While the footer shows the panel never gets smaller than it (whatever size the page asks for), and
the control takes a click only while it shows whole. Its click reaches the card
(`WebCard.personPressed`) only as the person's own left click from the HID system (not a key, an
Accessibility press, a posted event or a script) that went down and up on it, on the key panel,
begun at least the system's double-click interval (and 500 ms) after the card last drew or the
control last moved on screen (any move or resize of the panel). The page has no approve op; the
Name field reaches the card by `setName`. This one control stays in Swift as the security boundary.
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

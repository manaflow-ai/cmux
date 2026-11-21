# Server cards: one floating card family

The cards that pair and add machines (Pair Another Machine and Add Machine now; Add Device, Add Server, the
approver and the join consent next) are one family: one floating panel, one React
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

## Add Machine (`#/add-machine`)

Type a host you reach with ssh, or pick a machine on your tailnet, and cmux enrolls it
(plans/cmux-next/add-machine-DESIGN.md); Check Machine runs the same checklist for a machine the
app has, with Fix. Swift keeps the runs (`AddMachineRuns`: the `cmux-tui acp host enroll|doctor`
runs, the app's own install when enroll cannot put its build on the host, connect, the Machines
section's health record); the card folds each run's events into its checklist
(`add-machine/model.ts`, `checklist.ts`). A destination from the CLI or MCP only fills the field:
Add and Fix run only from the person's own click or key in the card (`userGesture`).

| Phase | Shows | Buttons |
| --- | --- | --- |
| pick | the title and help line, the host field (focused), Name (its placeholder the short host, or a picked agent peer's name), the tailnet's machines (greyed with why: Added, Offline, ssh off; an agent peer says so and stays pickable) | Cancel ⎋, Add ↩ (off until the field is a host ssh takes) |
| running | "Adding dev-box" (or "Checking dev-box"), one line "Step 3 of 9: Start the agent daemon" with Show Details, a working glyph in the footer | Cancel ⎋, Adding… (off) |
| ready | the done glyph, "dev-box is ready", its help line | Done ⎋, Open Workspace ↩ |
| failed | the error glyph, "dev-box could not be added", every step with its glyph; the failed one open with its whole detail and fix | Copy Details, Change Host, Try Again ↩ |
| check, failed | "dev-box needs attention", the same list | Copy Details, Fix ↩ |
| joined check | only the steps the joined machine's check sends | Cancel ⎋ / Copy Details, Done ↩ |

- **Start → end:** Add (pick → running): the field and the list leave and the checklist takes
  their place in the same frame; the header and the footer stay put, and the card shrinks or grows
  from its bottom edge. A step that fails or warns opens the whole list (running → failed, or a
  warning while it runs): the card grows downward. Change Host (failed → pick) brings the fields
  back as they were typed. A reopen while a run goes shows that run; any other reopen starts on
  fresh fields.
- **Size:** 460 px wide; the tailnet list scrolls inside at about five rows (168 px), so a long
  tailnet keeps the card's size and draws only the rows in view.
- The running step and the list's loading show a still working glyph, never a spinner.

### Variants (gallery `pages.server-cards.add-machine`)

References: setup checklists that collapse to one line while all goes well, step rails, and full
step lists.

- **progress** (shipped): one line while the run goes well ("Step 3 of 9: …", Show Details), the
  whole list only when a step needs the person. People asked for exactly this: a ready card that
  listed every step, skips and warnings included, read as a problem (2026-10-31).
- **list**: every step with its glyph from the start. Honest, but nine rows for a run that needs
  nothing from the person, and the card grows on every Add.
- **rail**: one glyph per step in a row, the running step named under it. Compact, but the glyphs
  alone do not say which step is which, and a failure still needs the list.

**Pick: progress.** It keeps the card one size while nothing needs the person, and opens the list
exactly when something does, so the only growth is the one the person must read.

## The server panel, pairing code, Health and Add Server

`webviews/src/pages/server-cards/server/`: the Mac server's own surfaces on the page. One Swift
`ServerModel` owns the state (the owner's snapshot, the intents in flight, the Add Server draft;
the Pair Another Machine approver shares it), and `ServerPageProvider` serves it
(`cmux.server.status`, `cmux.server.send`, `cmux.server.approver.*`, stream `cmux.server.changes`).
The page derives every layout, the health order, the overall line, the buttons and the keys
(`server/model.ts`). Swift keeps the menu bar item, its popover (`ServerPanelPopover`, a warm page
view sized by `cmux.card.resize`), the card panel, and the sources that run the CLI, fix checks
and call the cloud.

### Purpose

- **Panel** (`#/server-panel`, the menu bar item's popover): is this Mac serving, what does it run,
  is it healthy, and the on/off switch. Few labels: glyphs and dots carry state.
- **Health** (`#/server-health`, the panel's Health row or the Health command): every check the
  server runs with its state and a Fix.
- **Pairing code** (`#/server-pairing`): what this Mac shows while a signed-in device approves it.
- **Add Server** (`#/add-server`, also `#/approver`; palette "Add Server…" and pairing links):
  enter a server's code, check its facts and four words, name it, Approve or Deny.

### States (start → end)

- Panel: connecting (header only) → connected (header, rows, store line) or unreachable ("Server is
  not running", no rows). The switch is disabled while its intent is in flight and moves on the
  owner's echo. A refusal shows one red caption line above the store line, cleared by the next
  intent.
- Health row → Health: the popover's route changes to Health, drawn from the status already read,
  and the popover takes Health's size from its top edge in the same frame. Before this the row did
  nothing visible.
- Pairing: unpaired without a code (Pair This Server) → unpaired with a code (code, QR, words,
  expiry) → pairing (badge) → paired (badge with team and owner).
- Add Server: enterCode → lookingUp (spinner line) → codeRefused (red line, field outlined) or
  review (facts, words, name, team choice when more than one, Run my Chief) → approving (spinner
  in the footer, review disabled) → added (one success block, Done) or approveFailed (banner, Try
  Again). Every step has a default and an Escape button: Escape is the card's Cancel (or Deny once a
  server is on the card); Return presses Done, never Approve or Try Again, which are the card
  panel's native footer button under the page (the page leaves their slot). Typing a different code
  drops the found server; a late answer for an older code is dropped (the model's own rule). The
  fields keep what the person typed; a new opening (`approver.session`) starts them from the
  model's draft.

### Security

The switch, Show Pairing Code, Fix and Revoke (`cmux.server.send`) and Run my Chief answer only the
person's own click or key in the page (`userGesture`, the host's record), else `cmux.app.user_only`.
Approve and Try Again add a server to the person's team, so they are not page controls (the family
rule above): `ServerPageProvider` names the card's `PersonControl` from the model's step whenever its
state changes (Approve while the found server shows, Adding… disabled while it adds, Try Again after
a refusal, none otherwise), the card panel lays it out in its own footer, and only the person's own
click on it reaches the provider (`WebCard.personPressed`), which approves once the model can. The
page has no approve op; the Name field reaches the draft by `approver.setName`, and Return never
approves. `send` takes only those four intents; a lookup or an approve never goes through it. Team must be one of the found server's teams. The QR comes from the app's one encoder
(`PairingQRCode`, the same as mobile pairing and Pair Another Machine) as a PNG data URL; the key
fingerprint never reaches the page, only the code, the words and the image.

### Sizes

- Panel 340 px wide (dashboard 360), Health 360, pairing 340, Add Server 380 (the card frame of
  this page); heights follow the content. Rows 32 px, 8 px insets, 4 px rhythm.
- The QR code stays dark on white in every theme, drawn pixel-exact.

### Motion

- No animation outside the switch thumb (`ui/Switch`, the quick step) and the spinners (still
  under Reduce Motion). A layout change (a server found, an error) is one frame: the host resizes
  the popover or card from its top edge with the content, so nothing jumps or pops in after.

### Variants and the picks

References: menu bar status panels that lead with one state line and a switch, and settings panes
that list every check with its fix beside it. Gallery `pages.server-cards-server-surfaces` (panel,
Health, pairing) and `pages.server-cards-add-server` show every variant over the canned servers
(healthy Mac, MacBook on battery, fresh Mac with a code, headless Linux box):

- Panel: **compact** (status, switch, four rows), dashboard (a tile per role), list (apps, health,
  devices). Picked compact: it answers "is it serving and healthy" in one glance at menu bar size;
  the dashboard doubles the height for numbers a person rarely reads, and the list grows with every
  app and device.
- Pairing: **code** (large code, small QR, words), qr (large QR first), words (words first, code in
  a field). Picked code: a person types it on the other device, so it leads; the QR and words stay
  one glance away.
- Health: **checklist** (every check), summary (open issues only), timeline (alerts over time).
  Picked checklist: it shows what passes as well as what fails, so a clean server reads as checked
  rather than empty.
- Add Server words check: **grid** (two by two, numbered), row (four across), line (one sentence).
  Picked grid: numbered cells read aloud in order and keep their width in every language, and it
  matches Pair Another Machine's words.

The picks are the defaults the Debug Settings switches had (`server.panel.style`,
`server.pairing.style`, `server.health.style`), so nothing a person sees changes; the switches are
gone and their layouts live on as gallery variants.

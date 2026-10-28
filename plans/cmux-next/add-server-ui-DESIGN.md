# Add Server: a floating card, not a menu bar popover

User (2026-10-20): "add server UI is very bad", then "I don't like that pair thing shows up in the
menu bar. If it were a floating thing that pops up over the app, that would be better."

## What was bad

The approver was `ServerApproverView` in an `NSPopover` hung from the server's menu bar item
(`ServerMenuBarController.open(.approver)`).

- **Place.** Add Server put an icon in the menu bar and opened under it, far from the window the
  user works in. The popover was transient: a click in the terminal to copy the code closed it.
- **Hierarchy.** One 14 pt title, then a bare field with the placeholder `XXXX-XXXX`. Nothing said
  what to type or where the code comes from.
- **Type.** Eight raw font sizes (11, 11.5, 12, 13, 14, 18) and a medium weight, off the type scale.
- **States.** Only two layouts: a field, or the field plus the server. No lookup spinner, no
  approving state (the button only greyed out), no success (the popover vanished on approve), and a
  refused code was one red line with no next step. An expired code read the same as a typo.
- **Errors.** `lastReject` stayed on screen while the user typed a new code, and a refused approve
  looked like a refused code.
- **Keys.** Approve and Cancel were `PillButton`s: no Return or Escape, no key hints (u2647).
- **Focus.** The code field did not take the keyboard when the popover opened.
- **Words.** The four words, the one real security check, sat under a passive caption ("Approve only
  if these words match") at the same weight as the rest.
- **Noise.** Team chips showed with one team; the Chief checkbox always showed.
- **Stale result.** The model is kept between openings, so `lastApproved` from the last add could
  close the next popover at once.

The fleet render of every old state: `Packages/macOS/CmuxNext/.build/add-server-shots.png` from
`AddServerShotsTests` at `078c4e42c0b` (copy in the gallery as `before.png`).

## Designs

Local gallery (`~/fun/cmux-worktrees/add-server-gallery/index.html`, served on 127.0.0.1:8812,
opened in Home's right pane):

- **F. Floating card over the window (built).** Rounded glass card near the top center of the cmux
  window, contents as A. The user's pick.
- **A. Guided sheet.** One sheet that grows in place: title and one line of instruction, a large
  focused code field with its status under it, the server, the words under a real question, Name,
  Team only with two or more teams, Chief checkbox, Approve (Return) and Cancel or Deny (Escape),
  then an Added page with Done.
- **B. Code slots.** Eight boxes, words in one row. Worse with paste and input methods.
- **C. Confirm the words.** A required "the words match" checkbox. One more click every time.
- **D. Three steps.** Code, Check, Done pages. Slow for the common case.
- **E. Wide, two columns.** Nothing moves when the server is found, but 560 pt is too wide.

## What was built (F)

**Card.** `AddServerCardPanel` (CmuxNextServer): a borderless, non-activating floating panel,
`canJoinAllSpaces` and `fullScreenAuxiliary`, the `ServerHostView` glass (Liquid Glass on macOS 26,
tinted blur before, opaque under Reduce Transparency) with its 14 pt corners. It sits 56 pt below
the top of the front cmux window, centered, kept on screen; it grows and shrinks from its top edge
as the content changes (`onGeometryChange` through `ServerHostView.onContentSize`).

**Focus.** Opened by hand (palette "Add Server…", Settings > Machines > Add Server…) the card takes
the keys for the code field (`WindowActivation .raise`, never app activation). A code that arrives
from outside (`ServerMenuBarController.openCard(code:)`, `ServerModel.beginApproval(code:)`) shows the
card with `.bringForward`: the user keeps typing where they were until they click the card.

**States.** `ServerModel.addServerStep` derives one `AddServerStep` from the model: `enterCode`,
`lookingUp`, `codeRefused`, `review`, `approving`, `approveFailed`, `added`. The view draws one layout
per step. A refusal is cleared when the code changes; opening the card clears the last result and
looks a typed code up again.

**Keys.** `ServerModel.addServerButtons` gives each step an Escape button (Cancel, or Deny once a
server is shown) and a Return button (Approve, Adding…, Try Again, or Done alone after an add).
Each is a `CmuxDialogActionButton`, which shows and binds its key; the click and the key both run
`ServerModel.perform(_:)`. Escape on the panel runs the same Cancel.

**Type and style.** `Typography` fonts and `TypeScale` sizes only, `Metrics` spacing, theme colors,
`glassButtonStyle()` buttons as in the update sheet.

**Menu bar.** Add Server no longer shows or uses the menu bar item. The server panel and health
views keep it for now (they are prototypes behind Debug Settings).

## What did not change

- The pairing protocol and its intents: the card sends the same `lookupCode` and `approveCode` as
  before. Deny drops the draft; the server's code expires on its own (10 minutes). There is no deny
  op in the protocol, and adding one is out of scope.
- a196's headless path (`ServerHeadlessApproval`, `ServerHandlers`, `cmux servers add`, the
  `app_servers_add` MCP tool) is untouched. Both paths send the same intents to the same source;
  the card's step logic lives on `ServerModel` so a future caller (for example a code that arrives
  without its words) opens the card with `beginApproval(code:)` instead of a second approval flow.

## Limits

- The cloud does not push "a server is waiting" to approving Macs: a pending pairing lives in one
  `PairingDO` per code, with no list per team. So the card cannot pop up by itself when a server
  starts pairing. It opens from the palette, Settings, or a caller that has the code. A push needs a
  protocol change (a team-scoped pending list or feed event) and is left for the server lead.
- Translations other than English and Japanese are machine translations marked `needs_review`.

## Tests

- `AddServerFlowTests`: step flow, refusal clearing, retry, Return and Escape per step, Done, Cancel,
  clean reopen, re-lookup on reopen, code field takes the keyboard.
- `AddServerCardTests`: panel style and collection behavior, top-center placement and clamping, an
  arriving request does not take the keys, Approve and Deny titles.
- `hostSections.test.tsx`: Settings > Machines > Add Server… runs `server.addServer` with no code.
- `AddServerShotsTests`: renders all states to one PNG (look, not a pass/fail gate beyond size).

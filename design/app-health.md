# App health

Part of the app can stop answering while the rest still works: a page whose script hangs, a web
renderer at full CPU, a session daemon that restarts every two minutes because each start spends
its life restoring a huge registry, an acpmux link that went quiet. Before this, the person saw
only the effect: workspace clicks did nothing, a tab selected and snapped back, a close X did not
close. The host's health model (the Rust health model, fed by the Swift host) watches each part,
repairs what it can, and reports one small snapshot. The web shows it.

Leo, 2026-11-09: "these sorts of stuck situations... i feel like we maybe need to be displaying a
tiny situation somewhere in the app that lets the user know... or better yet, figure out how to auto
repair that kinda thing, and even better of course, prevent it from ever happening in the future."

## What appears

The start state is an ordinary app with nothing extra on screen. When a part leaves healthy, or the
host queues an action of the person's while it is unreachable, the sidebar footer shows a tiny dot
and one plain line: "Agent chat: Repairing", "Sessions: Slow", "Reconnecting; will close
Background task when back". The dot takes the danger color when a part is stuck or its repairs ran
out, and the attention color while the app repairs it or it is slow but making progress. A queued
action alone has a muted dot.

The line sits on the footer row right after the profile avatar (and Swift live mode's mark),
before the spaces strip, and truncates to fit; with no room it steps out of the row. It does not
fade with the footer. A click on the line, or Details on the "Restoring sessions…" card, opens the
popover (`#/app-health` on the server card page, hosted as the server Health popover is). It shows the worst part's line and its detail in plain words, with one
**Repair now** when that part can be repaired; every other non-healthy part with its detail and a
**Repair** when it can be repaired; the queued actions; and **Recent repairs**, collapsed, the
receipts newest first. A restore that still makes progress and workspace data that is merely large
get no button: the app never kills a restore. Repair sends `cmux.app.health.repair_now {id}` from the
person's click only.

The end state is the start state again. When the last part returns to healthy and nothing is
queued, the dot and line leave together and the popover renders nothing. The indicator sits in a
slot one line tall, so its arrival and departure move nothing beside it.

There is no animation, pulse, timer or observer in the indicator or the popover, including a
"repairing" state: a new snapshot is a state transition, drawn in one frame. The page's heartbeat
is the only timer, in the page layer (`pages/shared/pageHealth.ts`), and it stops while the page is
hidden.

## Queued actions never apply and revert

While the session daemon or page host is unreachable, a tab click or close is queued by the host
and shown as pending ("Reconnecting; will close Background task when back"), or refused with that
status. It never selects for a moment and snaps back. Leo, 2026-11-09, on the restart loop: "so in
this case even just clicking on the top bar made it flicker. i couldnt close the background task tab
for some reason".

## Pages keep their place

Every page that boots through the page bridge beats every 2 s while visible with its handled input
count, and keeps its scroll position and focused draft in sessionStorage, so a repair's reload
returns the person to where they were. The agent chat composer keeps its own draft
(`composerDraft.ts`) and is left alone.

## Treatment

Native gallery: `AAAppHealthIndicatorGalleryTests` renders the footer line as `a-line` (shipped),
`b-chip` and `c-dot` in four states, and the restoring card with Details. Web gallery: `ui.app-health` shows three treatments, each in seven states (page repairing, renderer
failed, session daemon restart loop held, restoring workspaces, oversize workspace data, pending
tab close while reconnecting, healthy):

- A, `footer-*`: the sidebar footer's dot and line. Selected.
- B, `titlebar-*`: a dot alone at the titlebar's trailing edge, the line as its tooltip.
- C, `pill-*`: an inline pill with the worst part's Repair.

A is the selected treatment. It says what is wrong in words without a hover, at the edge of the
window where status already lives, and it stays out of the content and the titlebar's controls. B
hides the words a person needs during exactly the moment clicks stop working, and a lone colored
dot in the titlebar reads as a notification badge. C puts a repair button into the flow of the
window, which invites clicking it before reading what it will do; the popover's Repair now, beside
the detail, is where that choice belongs.

The reference is the private design collection's usage status popover capture
(`cmux-design-references` refs-review `index.json`): a small status mark that opens into labelled
detail. Existing danger, attention, muted text, typography and spacing tokens supply the treatment.

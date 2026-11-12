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

The start state is an ordinary app with nothing extra on screen. When a part is stuck, being repaired or
out of repairs, or the host queues an action of the person's while it is unreachable, a tiny dot and one
line appear at the sidebar's bottom-left. The line names the part and what is happening to it, in words
the person can act on: "Agent chat isn't responding" (a click opens Repair now), "Repairing Agent chat…"
(the app is on it), "Agent chat needs a repair" (its repairs ran out), "Reconnecting; will close
Background task when back". The dot takes the danger color when a part is stuck or its repairs ran out,
the attention color while the app repairs it, and is muted for a queued action alone.

A part that is only **slow** shows nothing there. Slow means it still answers, late: a page whose
heartbeat is 5 to 10 s behind, most often because the Mac is busy. If it stops answering the model makes
it stuck at 10 s and repairs it, which the line then says. Leo, 2026-11-11, after a heavily loaded Mac
showed "Agent pane: Slow" again and again: "the agent pane: slow indicator on the bottom left is uselsss
and layout shifts the space. it's bad". The popover still lists a slow part with its detail, and the
"Restoring sessions…" card already covers a slow restore. The agent pane's page is named "Agent chat",
not its resource's "Agent pane".

The line never takes room in the footer row. It floats on its own small chip in the sidebar
cards' veil (the chip radius; never a solid fill) just above the row and any card over it, at the avatar's leading
edge, over the list's bottom; the spaces strip, the update button and Search keep their frames when it
comes and goes (SidebarProfileChipTests `theHealthLineMovesNothingInTheFooterRow`). Before, it sat in the
row after the avatar and its width pushed the strip and the update button along. It does not fade with
the footer. A click on the line, or Details on the "Restoring sessions…" card, opens the popover
(`#/app-health` on the server card page, hosted as the server Health popover is). It shows the worst
part's line and its detail in plain words, with one **Repair now** when that part can be repaired; every
other non-healthy part, slow ones included, with its detail and a **Repair** when it can be repaired; the
queued actions; and **Recent repairs**, collapsed, the receipts newest first. A restore that still makes
progress and workspace data that is merely large get no button: the app never kills a restore. Repair
sends `cmux.app.health.repair_now {id}` from the person's click only.

The end state is the start state again. When the last part returns to healthy and nothing is
queued, the dot and line leave together and the popover renders nothing. The indicator is placed over
the sidebar, outside the footer row's flow, so its arrival and departure move nothing beside it.

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

Where it sits. Native gallery: `AAAppHealthIndicatorGalleryTests` renders `a-overlay` (shipped), `b-dot`
and `c-hidden` in six states (healthy, only slow, not responding, repairing, needs a repair, a queued
close), and the restoring card with Details. Web gallery: `ui.app-health.footer-row` draws the sidebar's
bottom twice per variant, at rest and with the indicator, in the same five states:

- `before`: the line in the footer row after the avatar, as #39112 shipped it. The strip and the update
  button move when it comes and goes, and a slow page says "Agent pane: Slow".
- `overlay`, selected: the line on its own chip above the row. It says what is wrong in words without a
  hover, at the edge of the window where status already lives, and the row never moves.
- `badge`: a dot on the avatar's top-trailing corner, the line its tooltip. Nothing moves and it takes
  the least space, but the words a person needs at exactly the moment clicks stop working need a hover.
- `hidden`: nothing; the popover still opens from the restoring card's Details. Choosing it is one line
  (`AppHealthIndicatorView.style`).

What it looks like. Web gallery `ui.app-health` keeps three treatments of the line itself, each in seven
states (page repairing, renderer failed, session daemon restart loop held, restoring workspaces, oversize
workspace data, pending tab close while reconnecting, healthy):

- A, `footer-*`: the dot and line. Selected (drawn on the overlay chip natively).
- B, `titlebar-*`: a dot alone at the titlebar's trailing edge, the line as its tooltip.
- C, `pill-*`: an inline pill with the worst part's Repair.

B hides the words a person needs during exactly the moment clicks stop working, and a lone colored dot in
the titlebar reads as a notification badge. C puts a repair button into the flow of the window, which
invites clicking it before reading what it will do; the popover's Repair now, beside the detail, is where
that choice belongs.

The reference is the private design collection's usage status popover capture
(`cmux-design-references` refs-review `index.json`): a small status mark that opens into labelled
detail. Existing danger, attention, muted text, typography and spacing tokens supply the treatment.

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

Nothing. The app repairs a stuck part in silence: no line, dot or badge anywhere says that a part is
stuck, being repaired or out of repairs. Leo asked for the sidebar's bottom-left line to go four times:

- 2026-11-11: "the agent pane: slow indicator on the bottom left is uselsss and layout shifts the space.
  it's bad" (the Slow state was removed and the line moved out of the row; the line stayed).
- 2026-11-12: "and the agent pane: slow thing on the bottom left i thought we removed that?"
- 2026-11-16: "then the bottom left sidebar just above the updated ot nightly it said repairing..."
- 2026-11-22: "i see in the sidebar a repair connection to agent service... which i have requested to
  remove a while ago. or some similar message to it a while ago. we dont need it. ever."

Each earlier fix removed one state of the line and kept the line. The line itself is now gone
(`AppHealthIndicatorView`, its web twin and their galleries are deleted), with every state it could say:
"… isn't responding", "Repairing …", "… needs a repair", "Reconnecting; will … when back". Do not add
another always-on surface for health; the model, its repairs and the debug socket's `debug.health` stay.

Details on the "Restoring sessions…" card, opens the native card
(`AppHealthPopover`), the one view of health. It shows the worst
part's line and its detail in plain words, with one **Repair now** when that part can be repaired; every
other non-healthy part, slow ones included, with its detail and a **Repair** when it can be repaired; the
queued actions; and **Recent repairs**, collapsed, the receipts newest first. A restore that still makes
progress and workspace data that is merely large get no button: the app never kills a restore. Repair
sends `cmux.app.health.repair_now {id}` from the person's click only.

The card follows the snapshot while it is open and says all is well once the last part is healthy.

There is no animation, pulse, timer or observer in the card, including a
"repairing" state: a new snapshot is a state transition, drawn in one frame. The page's heartbeat
is the only timer, in the page layer (`pages/shared/pageHealth.ts`), and it stops while the page is
hidden.

## Which chat, and no click it does not need

David Beyer, 2026-11-20, on a call: "Agent chat needs a repair" did not say which chat, with several
open. A page part is named by the title its tab shows, in the line and the card's title ("“Fix the
login bug” needs a repair"); the card's first line says where it is ("Agent chat in cmux-next"), and
**Show chat** goes there. A stuck page is always on screen (a hidden page is never timed), so Show
chat brings its window forward and gives the page the keyboard, through the focus route. The place
comes from the daemon's store (`AppHealthPlaces(store:)`: the tab the page shows, its title, the
workspace that holds its pane), read only when a line or the card is drawn, never on a heartbeat. A
page in no tab (Home's dock, a floating chat) keeps the label "Agent chat".

The cap is 3 repairs in 10 minutes, not 3 for good. A part that is out of repairs keeps one deadline,
when its oldest attempt leaves the window; then, still stuck, it tries again by itself from step 1,
and its signal coming back drops the alert. Repair now still starts at once. A repair is still never
run over unsaved edits: the page's reload refuses, and the next step comes.

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

A page with nothing happening in it rests (CMUX-571, idle wakeups: a beat is several app wakeups, so
open pages woke the app every 2 s forever). After 5 quiet beats (10 s: no key, press, wheel, scroll or
input, and no unsaved edits) it sends one `{rest: true}` beat and arms no timer until something happens.
The model stops timing a resting page's silence; input the host sends it is still owed an answer, so a
page that hangs while resting reads as stuck once someone types or clicks in it. The page rests only
when its last beat was answered `{rest: true}`: the host says so only when the linked health model
takes rests (`CMUX_HEALTH_ABI_VERSION` 2), so an older pinned model keeps the 2 s beat.

A repair that loads the page again (reload, renderer restart) waits at least `PAGE_BOOT_MS` (30 s)
for the new document before the next step; its load ends the episode. With the 2 s backoff alone, a
busy agent chat on a loaded Mac was still loading when its renderer was killed, twice, and the pane
stayed blank (Leo, 2026-11-11: "i tried uploading this video to my nightly app and it just made the
screen blank").

## Treatment

The card only. Native gallery: `AAAppHealthCardGalleryTests` (`app-health-card-gallery`). The footer line's
galleries (`AAAppHealthIndicatorGalleryTests`, web `ui.app-health`, `ui.app-health.footer-row`) went with it.

The reference is the private design collection's usage status popover capture
(`cmux-design-references` refs-review `index.json`): a small status mark that opens into labelled
detail. Existing danger, attention, muted text, typography and spacing tokens supply the treatment.

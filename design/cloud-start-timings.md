# Cloud start timings (DEV and NIGHTLY)

A debug view of the Cloud page (`cmux-page://cmux.cloud/#/timings`) that shows where a Cloud start
spends its time: one start as a waterfall, each hop's p50 and p95 over the last day, and the day's
starts to pick from. It answers Leo's ask for "the developer debug thing to be able to visualize the
sort of breakdown of the timings for the, like the cloud startups among all areas".

## Reach and gate

The page calls `cmux.cloud.start_trace.list` and `.get` on the Cloud app server, which relays the
platform's start-trace JSON verbatim. The server serves them only in DEV and NIGHTLY builds; a release
build answers unsupported. The page reads the list once after sign-in, and shows the header button
**Start timings** only when that read answered. No web code reads a build channel, and no default
changes.

## Look

Three looks are in the gallery (`pages.cloud-start-timings`): `lanes` (the waterfall, then a table of
p50 and p95), `bands` (the day's p50 to p95 drawn behind each bar, with its numbers beside it) and
`columns` (the day's starts in a list beside the waterfall). The page uses `bands`: one glance tells
whether this start's hop was normal (the bar ends inside the band) or slow (past it, with the warning
dot and "Slower than p95").

- Rows are the contract's hops in order. A row's bar is at the hop's offset from the start; network's
  pieces (the server's prepare and attach, the client's connect) are separate bars on one row.
- One hue, the text ink: a bar the Cloud service measured is the strong step; a client's (app, CLI,
  machine) is the light step with a 45 degree hatch, so the two read apart without color. A legend
  names both.
- The status color is used only for the slow mark, which always has its words.
- Hover on a bar says the hop, its length, its offset and who measured it (and its part).

## What is not timed

The app's create is the app's own, and the app does not time the click yet. So a start begins at the
server's receipt of the create, and the view says so above the waterfall. The `click` row shows only
when a client (the CLI, a journey) posted a span for it.

## State

No timer and no polling: the list is read after sign-in, when the view opens, and on Refresh; a start
is read when picked. A failed read shows its error and keeps the last answer.

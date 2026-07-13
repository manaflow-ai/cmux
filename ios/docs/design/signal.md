# 04 Signal — Swiss status board

Mission control for agents. Tufte's data-ink ratio: every pixel informs or is deleted; color exists only as signal, defined once in a legend the user learns and then sees applied identically on every screen (Norman's mapping — the same slot always means the same thing). Highest density of the four; the whole fleet is visible without scrolling.

## Color

| Token | Light | Dark |
|---|---|---|
| bg0 (app) | #F5F5F4 | #121212 |
| surface | #FFFFFF | #1C1C1A |
| ink | #111111 | #F2F2F0 |
| text.secondary | #555550 | #A3A39E |
| hairline | #111111 12% | #F2F2F0 14% |
| signal.needsYou | #E8A200 | #F0B429 |
| signal.running | #0A7AFF | #4A9EFF |
| signal.done | #1F9E55 | #34C471 |
| signal.failed | #D93025 | #F0554A |
| signal.idle | #8A8A85 | #6E6E69 |

Signal colors appear only as: 2pt row rails (left edge), 6pt squares (not dots — squares read as legend marks), and bar fills. Never as text color, never as tints, never decorative.

## Type

SF Pro with hard weight contrast: screen title 28 heavy; section labels 11 semibold UPPERCASE, tracking +0.08em; body 15 regular; ALL data (times, counts, durations, branches, ports) SF Mono 13. Timestamps absolute (`14:32`), never relative — a board is read, not felt.

## Shape, density, spacing

Radius 4 everywhere (near-square). Rows 44pt. Screen margins 16, intra-section spacing 1px hairlines, section gaps 24. True column alignment on the Hub: name | state | elapsed share fixed columns across all rows (mapping rule).

## Glass

Exactly one site: the pinned summary strip at the top of Hub and Activity gets glass so the board visibly scrolls beneath it — glass as functional layering proof, not decoration. Gated via `mobileGlass*`.

## Motion

120ms crossfades only. Running state shows a determinate-feeling 2px progress bar shimmer (linear, 1.5s) inside the row rail. No springs, no scale, no pulse. This system is what Reduce Motion already looks like.

## Ergonomics

Fixed bottom triage bar (surface, hairline top): shows the single highest-priority item (`NEEDS YOU · cmux/feat-gallery · 14:32`) with a `Go` button — one thumb tap from anywhere to the next decision. Row tap opens; row long-press shows a plain action sheet. Nothing hidden behind swipe.

## Screens

- **Hub**: glass summary strip: five legend squares with mono counts (`■3 ■1 ■2 ■0 ■1`) + label row. Below, a true table grouped by state, uppercase section labels (`NEEDS YOU`, `RUNNING`, `DONE`), rows with 2pt rail, name (semibold 15), branch mono 13 secondary, elapsed mono right-aligned in a fixed column. Triage bar bottom.
- **Session**: metadata header as a two-column spec table (AGENT, STATE, BRANCH, ELAPSED, PORT — labels uppercase 11, values mono 13) above the terminal panel (surface, radius 4, mono 12); actions as a plain button row (`Approve` filled ink, `Deny` outlined) below the header, not floating.
- **Chat**: transcript as a log — each entry has an uppercase role label (AGENT / YOU / TOOL) and mono timestamp in the left gutter, text right of gutter; tool entries in a hairline box with mono command; approval entry ends with the same `Approve`/`Deny` row as Session (one action design app-wide).
- **Activity**: same table grammar as Hub — time (mono, absolute) | signal square | event text; day boundaries as uppercase labels; unread events in semibold ink, read in secondary.
- **Settings**: sectioned table, uppercase group labels, mono values right; a `LEGEND` section restating the five signals with meanings — the system teaches itself.
- **Specimen**: the legend, ink/surface palette, weight-contrast type scale, table row anatomy, triage bar, buttons.

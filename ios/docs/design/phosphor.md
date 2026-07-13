# 01 Phosphor — terminal-native instrument

The terminal is the hero; chrome recedes into layered near-black and never competes with it. Norman's "visibility of system status" is the prime directive: agent state is the loudest thing on every screen, encoded three ways (color, glyph, elapsed time). Dark-first because agents get supervised at night; light mode is a full peer, not an inversion.

## Color

| Token | Dark | Light |
|---|---|---|
| bg0 (app) | #0A0B0D | #F2F3F5 |
| bg1 (card/row) | #111318 | #FFFFFF |
| bg2 (elevated/pressed) | #1A1D24 | #E9EBEE |
| hairline | white 8% | black 10% |
| text.primary | #E8EAED | #1A1D24 |
| text.secondary | #9BA1AC | #5C6370 |
| text.tertiary | #5C6370 | #9BA1AC |
| accent | #4D9DFF | #1D6FE0 |
| status.needsYou | #FFB224 | #B87700 |
| status.running | #4D9DFF | #1D6FE0 |
| status.done | #3DD68C | #17804F |
| status.failed | #FF5D5D | #C93030 |
| status.idle | #5C6370 | #9BA1AC |

Status colors appear as 8pt dots, chip tints at 16% opacity fills, and terminal-header accents. Never as large area fills.

## Type

- Chrome: SF Pro. Title 17 semibold, body 15 regular, caption 12 regular.
- Data (branch names, ports, durations, counts, paths): SF Mono 13, monospaced digits everywhere numbers appear.
- Terminal: SF Mono 12 default (user-scaled), line height 1.3.

## Shape, density, spacing

4pt grid. Screen margins 12. Rows 52pt. Radius: cards 8, chips 6, sheets 12. No shadows; separation is hairlines and bg-layer steps only.

## Glass

Two sites only: the floating bottom command bar (Hub) and the terminal input accessory (Session). Everything else opaque — glass over terminal content is banned for legibility. Use the `mobileGlass*` gated helpers.

## Motion

150–180ms easeOut. Rows appear with 4pt y-shift + fade. `needsYou` rows carry a 2s amber opacity pulse (0.6→1.0) on the status dot only. No springs on chrome, no bounce.

## Ergonomics

Floating bottom command bar with the two highest-value actions in thumb reach: `Approve` (when a needs-you item exists) and `New workspace`. Row swipe left = approve/reply, swipe right = mark read. All targets ≥44pt despite dense rows (row is the target).

## Screens

- **Hub**: attention queue, not a folder tree. Sorted needsYou > failed > running > done > idle. Row: status dot + workspace name (SF Pro semibold 15) + branch in SF Mono 12 secondary + right-aligned elapsed (mono). NeedsYou rows get a 16%-amber tint fill and 1px amber hairline. Sticky top strip: mono summary `1 needs you · 2 running · 1 done`.
- **Session**: sticky status header (dot + agent name + state + elapsed, bg1, hairline below) above a full-bleed mock terminal block (bg0, mono 12, ANSI-colored fixture lines). Bottom: glass input accessory with mono text field + send.
- **Chat**: flat message list, no bubbles for the agent (left-aligned text on bg0), user messages right-aligned in bg2 chip. Tool-call = bordered card, mono command line, collapsed output preview (3 lines, tertiary). Approval request = amber-hairline card with `Approve` / `Deny` side-by-side buttons pinned inside the card bottom.
- **Activity**: single dense feed, day headers as 12pt uppercase tertiary labels, rows 44pt: status dot, event text (needs-you events semibold), mono relative time right.
- **Settings**: standard grouped list re-skinned on bg1/bg2 with hairlines, mono values on the right (paired Mac name, version).
- **Specimen**: palette swatches with hex labels (mono), type scale, dots/chips in all five states, command bar, buttons, tool-card.

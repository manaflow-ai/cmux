# 02 Atelier — warm humanist companion

Supervising agents is anxious work; Atelier's job is to lower the pulse. Warm paper surfaces, serif display type, generous space, and state expressed in plain words ("Waiting for you", "Working…", "Finished"). Inspired by the Claude iOS app's warmth. Fewer things on screen, each with a clear next action — Norman's one-good-conceptual-model over exhaustive display.

## Color

| Token | Light | Dark |
|---|---|---|
| bg0 (app) | #F7F3EC | #201C18 |
| bg1 (card) | #FFFFFF | #2A251F |
| bg2 (inset/pressed) | #EFE9DE | #363028 |
| hairline | #2A2520 10% | #EDE7DE 10% |
| text.primary (ink) | #2A2520 | #EDE7DE |
| text.secondary | #6B6259 | #B3A99C |
| text.tertiary | #A39B8F | #7A7166 |
| accent (terracotta) | #C15F3C | #D97757 |
| status.needsYou (ochre) | #B07818 | #D9A03F |
| status.running (slate) | #5F7484 | #8FA5B5 |
| status.done (sage) | #5F7D58 | #8CAB84 |
| status.failed (brick) | #A84632 | #CC6B55 |
| status.idle | #A39B8F | #7A7166 |

Cards carry a soft shadow (y2, blur 12, black 6%) in light mode; dark mode uses bg-layer steps only.

## Type

- Display/titles and workspace names: New York (serif) — screen title 28 semibold, card title 19 semibold.
- Body: SF Pro 16 regular, line height 1.4. Captions 13.
- Mono only inside terminal/tool blocks: SF Mono 12.
- State words are typeset, not badged: 13pt medium in the state's color.

## Shape, density, spacing

8pt grid. Screen margins 20. Cards radius 18, inner elements 12, composer pill 24 (capsule). Row/card min height 64. One agent = one card; the Hub shows ~4 cards per screen height, on purpose.

## Glass

Soft and warm, two sites: navigation bar background on scroll, and the bottom composer pill (Chat/Session). Warm-tinted (`bg0` at 50% under the material). Never on cards or content. Gated via `mobileGlass*` helpers.

## Motion

Gentle springs (response 0.5, damping 0.85) for card presses and sheet presentation. Status dot on "Working…" breathes (scale 1→1.15, 3s ease-in-out loop). Content transitions are 250ms fades. Nothing pulses in color.

## Ergonomics

Primary action is embedded in the card that needs it: a needs-you card ends with a full-width soft-terracotta `Review request` button (52pt). No swipe-only affordances; everything reachable by tap. Bottom composer pill is the single fixed control on conversational screens.

## Screens

- **Hub**: serif greeting header ("Your agents"), then cards. A needs-you card is promoted to the top with an ochre left-edge accent bar, a one-line quote of the agent's question in italic serif, and the `Review request` button. Running/done/idle cards: serif name, plain-word state line with dot, last-activity sentence in secondary.
- **Session**: terminal presented as a framed artifact — a bg1 card with 18pt radius holding a dark terminal inset (always #201C18 even in light mode, mono 12), state line above it in words, composer pill below.
- **Chat**: agent messages as plain text on bg0 with generous 24pt paragraph spacing; user messages in terracotta-tinted (10%) rounded card right-aligned. Tool call = bg2 inset card with serif label "Ran a command" + mono line. Approval = bg1 card, italic serif question, `Approve` (filled terracotta) above `Not yet` (plain text button), stacked full-width.
- **Activity**: journal style — day headings in serif 20, entries as sentences ("Claude finished the sidebar fix · 3:12 PM") with state-colored dot, 16pt spacing, no boxes.
- **Settings**: cards per group (Account, Paired Mac, Appearance, Notifications), serif section labels, roomy 56pt rows.
- **Specimen**: palette as paint chips with names ("Terracotta", "Sage"), serif/type scale, state words row, buttons, cards, composer pill.

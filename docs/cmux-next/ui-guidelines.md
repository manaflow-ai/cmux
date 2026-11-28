# Chevrons: spacing, targets, motion

Leo, 2026-11-27, on chevrons sitting on their labels (a sender chip "acpmux⌄", a machine "· host⌄", the
composer hat's `‹ 1 of 3 ›` pager): "these chevrons are too close dont we have any guidelines for these
yet?" There was none: this page is it.

A chevron (`‹ › ⌄ ⌃`, `disclosure.*`, `ChevronLeft/Right`) is drawn at 12 px (`--ds-icon-12`,
`design/icons/call-site-sizes.md`). These rules say how far it stands from what is beside it, how big the
thing you click is, and how fast it moves. The numbers live in `webviews/src/ui/chevronSpacing.ts` and the layout grid
(`--grid-chevron-gap`, `--grid-gap`, `--grid-hit-min`).

## Spacing

- **8 px floor** (`--ds-space-2`), for a chevron that is its own target or glyph slot: its 12 px glyph box
  stands at least 8 px from the nearest text or glyph beside it: a pager's count, a row's label, another
  chevron. The box, not the ink: a chevron's ink
  is narrower than its box, so 8 px box to box reads as about 10 px of air.
- **Pagers** (`‹ n of m ›`, `‹ n/m ›`): 24 px steps with a `--ds-space-1` gap to the count, which puts the
  glyph 10 px from the words. The count keeps tabular numerals so the chevrons do not move as it changes.
  Today: the composer hat 10, the question card 11.5, the version switcher 11.
- **A label and its chevron** (`label ⌄`: a menu trigger, a picker chip such as the composer strip's host,
  folder and model, a transcript row's fold, a sender's chip with its row chevron) is one control, so it is
  measured in ink: **3 to 8 px** from the last visible letter's ink to the chevron's ink. One token sets
  it: `--grid-chevron-gap` (4 px, `schemas/layout-grid/layout-grid.json`, also Swift
  `LayoutGrid.chevronGap`) is the box gap between the label and the 12 px chevron, which with the glyph's
  side bearing gives about 6 px of air. The web alias is `--ui-disclosure-gap` (`webviews/src/ui/ghost.css`);
  a control never sets its own margin, gap or negative pull on its chevron. These are the chevrons Leo
  pictured.
- **After a chip's box** (a sender's link chip ending a line, a pill with a fill): the chevron's ink stands
  at least 8 px (`--grid-gap`) from the chip's edge; the chip's padding is not room.
- **Draw it with the shared pair.** Web: `<DisclosureFace>{label}</DisclosureFace>` or
  `<DisclosureChevron />` after words a control lays out itself
  (`webviews/src/agent-session/acpmux/DisclosureFace.tsx`). Swift: place the chevron
  `LayoutGrid.chevronGap` after the label's frame, more if the label's own padding would put its ink
  nearer than the floor (`ChiefTeleportChip.afterLabel`).
- **Never a text "⌄".** A font's chevron glyph sits on the baseline with the fallback font's side
  bearing, so its room changes per font and machine. `check:disclosure-chevron` fails a TSX file that
  draws one.
- **Truncation:** the label ellipsizes first (`min-width: 0`, `text-overflow: ellipsis`); the chevron is
  `flex: none`, never cut, never drawn over the words. A first line squeezed under 24 px beside a row's
  chevron goes, and the chevron comes back to its words (`AgentMessageRow.tsx`, `[data-squeezed]`).
- **A disclosure chevron leading a row** sits in the row's icon slot, with the row's own icon-to-label gap
  (never less than 8 px to the label).
- **Two chevrons side by side** with no words between them (a `‹ ›` pair) stand 8 px apart, box to box,
  so they read as two targets, not one glyph.

## Hit targets

- A chevron that is a button on its own (a pager step, a tuck, a back button) is a **24 px** target
  (`--ds-control-compact`) or larger. A step in a tight head row keeps the row's height with a negative
  block margin (the composer hat's pager), never by shrinking the target.
- A chevron inside a larger control (a disclosure row, a menu's trailing mark, a picker pill) has no target
  of its own: the whole row or pill takes the click.
- Hover and pressed fills cover the whole target (`design/pressed-state.md`); the glyph does not move or
  scale on press.

## Motion

- A disclosure chevron's turn (closed `›` to open `⌄`): `--cmux-motion-micro` (120 ms), `--cmux-ease-out`.
- A chevron that follows a fold or a slide it belongs to takes that fold's duration, at most
  `--cmux-motion-standard` (180 ms), never `--cmux-motion-large`.
- Hover and focus on a chevron's target: `--cmux-motion-quick` (80 ms).
- Always a token (or a surface's alias of one), never a literal: one change of the scale reaches every
  chevron. Reduced motion turns the chevron at once.

## Checks

- `webviews/test/chevron-spacing.test.ts` draws every pager in Chromium from its gallery entry
  (`agent-pane.hat-questions`, `agent-pane.question-card`, `agent-pane.fork-switcher`) and fails a chevron
  under 8 px from its count or a step under 24 px. It also draws the hat's old look (`pager-before`) and
  expects it to fail, so the check keeps biting.
- `webviews/test/chevron-motion.test.ts` reads every stylesheet and fails a chevron or disclosure rule that
  times its `transform` with a literal or with a token slower than `--cmux-motion-standard`.
- `webviews/test/disclosure-chevron-gap.test.ts` measures every label + chevron pair in the shared face,
  the composer and the hybrid holders chip (`test/support/disclosureChevrons.ts`) and fails ink under
  3 px or over 8 px after the words, or a chevron cut by a clipping box.
- `webviews/test/composer-chevron-after-label.test.ts` does the same over the composer strip's pickers.
- `webviews/test/transcript-chevron-after-label.test.ts` keeps each transcript chevron 3 to 8 px after its
  words and 8 px from a chip's box, and a showing first line at least 24 px wide.
- `webviews/test/hybrid-chip-chevron-gap.test.ts`: the hybrid button's holders name and its chevron.
- Swift: `ChiefTeleportChipChevronGapTests` keeps the Teleport chip's chevron 8 pt from its label's ink.
- `bun run check:disclosure-chevron`: no text "⌄" chevron in shipped TSX.
- A new pager adds its gallery entry to `PAGERS` in `chevron-spacing.test.ts`.

## Variants

Gallery `agent-pane.hat-questions`, `pager-*` (`<html data-pager-look>`): `pager-before` (20 px steps, no
gap: 4 px), `pager-gap` (20 px, 4 px gap: 8 px, the floor on a small target), `pager-shipped` (24 px steps,
4 px gap: 10 px), `pager-roomy` (24 px, 8 px gap: 14 px). Pick: `pager-shipped`. It matches the version
switcher and the question card, and the head row keeps its height. Roomy pulls the chevrons away from the
count, so the pager reads as three separate things.

Gallery `ui.disclosure-face` compares 2, 4 and 8 px box gaps on the two chips Leo flagged and a label cut at
120 px. At 2 px the chevron reads as a letter; at 8 px it floats off its label; 4 px gives about the
transcript's room, which Leo picked as ChatGPT's ("this how chatgpt does their chevrons", 2026-11-03).

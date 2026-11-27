# Chevrons: spacing, targets, motion

Leo, 2026-11-27, on the composer hat's `‹ 1 of 3 ›` pager: "these chevrons are too close dont we have any
guidelines for these yet?"

A chevron (`‹ › ⌄ ⌃`, `disclosure.*`, `ChevronLeft/Right`) is drawn at 12 px (`--ds-icon-12`,
`design/icons/call-site-sizes.md`). These rules say how far it stands from what is beside it, how big the
thing you click is, and how fast it moves. The numbers live in `webviews/src/ui/chevronSpacing.ts`.

## Spacing

- **8 px floor** (`--ds-space-2`): a chevron's 12 px glyph box stands at least 8 px from the nearest text or
  glyph beside it: a pager's count, a row's label, another chevron. The box, not the ink: a chevron's ink
  is narrower than its box, so 8 px box to box reads as about 10 px of air.
- **Pagers** (`‹ n of m ›`, `‹ n/m ›`): 24 px steps with a `--ds-space-1` gap to the count, which puts the
  glyph 10 px from the words. The count keeps tabular numerals so the chevrons do not move as it changes.
  Today: the composer hat 10, the question card 11.5, the version switcher 11.
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
- A new pager adds its gallery entry to `PAGERS` in `chevron-spacing.test.ts`.

## Variants

Gallery `agent-pane.hat-questions`, `pager-*` (`<html data-pager-look>`): `pager-before` (20 px steps, no
gap: 4 px), `pager-gap` (20 px, 4 px gap: 8 px, the floor on a small target), `pager-shipped` (24 px steps,
4 px gap: 10 px), `pager-roomy` (24 px, 8 px gap: 14 px). Pick: `pager-shipped`. It matches the version
switcher and the question card, and the head row keeps its height. Roomy pulls the chevrons away from the
count, so the pager reads as three separate things.

# cmux NEXT UI guidelines: icon and chevron spacing, hit targets, motion

Leo, 2026-11-27 (ask-1e078315d5): "these chevrons are too close dont we have any guidelines for these yet?"

There were guidelines, but in pieces: the grid and icon scale live in leo-workspace `design/grid.md` and
`design/icons.md`, motion in [`plans/cmux-next/motion.md`](../../plans/cmux-next/motion.md) and
`schemas/motion-scale/motion-scale.json`, and no number for a chevron's gap or a hit target existed, so no check
could fail. This page is the one place that states the numbers a component must meet, names the tokens, and names the
check. It extends those documents; it does not replace them.

## Tokens

Spacing and size tokens are in `schemas/layout-grid/layout-grid.json` (written to `--grid-*` in
`webviews/src/pages/shared/desktop.css` and to `LayoutGrid.swift`); duration tokens are in
`schemas/motion-scale/motion-scale.json` (`--cmux-motion-*`, `scale.generated.ts`). Use the token, never the number.

| Token | Value | Use |
| --- | --- | --- |
| `--grid-half-step` | 2 | optical offset and highlight inset only |
| `--grid-base` | 4 | the unit; every edge, gap and size is a multiple |
| `--grid-chevron-gap` | 4 | least ink-to-ink space between a label and its chevron |
| `--grid-gap` | 8 | space after an icon or control box (icon to text) |
| `--grid-gap-inner` / `-run` / `-block` / `-turn` | 12 / 16 / 24 / 32 | vertical rhythm (grid.md rule 4) |
| `--grid-icon-box` | 16 | the box a 12 to 16 glyph is centered in |
| `--grid-hit-min` | 24 | least width and height of a clickable icon, chevron or icon-only button |
| `--grid-row` | 28 | compact row and the usual control height |
| `--cmux-motion-quick` | 80 ms | hover, press and focus fills; everything leaving |
| `--cmux-motion-micro` | 120 ms | small things arriving: a chip, a popup, a tooltip, a fade in |
| `--cmux-motion-standard` | 180 ms | structural changes: a row or card moving, a fold opening |
| `--cmux-motion-large` | 240 ms | the ceiling: a split, a zoom, a window closing |

## Spacing

- Padding and gaps come from the 4 scale: 4, 8, 12, 16, 24, 32. 2 is a half-step in the three places grid.md names.
- Icon to text: `--grid-gap` (8) after the icon's 16 box, so the ink of a 12 or 14 glyph sits 8 to 10 from the text.
  An icon inline with running text (an inline chip) may use 3, the one named exception (grid.md section 1).
- A chevron and its label: at least `--grid-chevron-gap` (4) of ink between them, on whichever side the label is.
  The transcript's disclosure chevron after a label uses 5 (`--cv-chevron-gap`, the ChatGPT reference); both pass.
  Measure ink (the glyph's strokes), not the 16 box: a 12 glyph in a 16 box already has 2 of space on each side, so
  `margin: 0` on a box is about 2 of ink gap and fails.
- A chevron that is not part of a label (a column-end disclosure on `trail`) sits on the trailing column and is
  not measured against the label.
- A gap belongs to its container (`gap` on the flex row); a chevron never adds its own outer margin to make one
  (grid.md rule 5).

## Hit targets

- A clickable icon, a chevron button or any icon-only button is at least `--grid-hit-min` (24) wide and high. The
  glyph stays 12 to 16; the box grows around it (padding, `min-width`, `min-height`), and may overhang its column by
  at most 6 (grid.md rule 6).
- A labelled trigger with a chevron (a picker pill) is at least 24 high; its width follows its label.
- A control that is deliberately smaller (a density mode) says so with `data-hit-exempt` and a reason beside it.

## Motion

Durations come from the scale (motion.md). Hard rules:

- Nothing timed runs past 240 ms (`--cmux-motion-large`). Loops (spinners, breathing) are not transitions and are
  exempt.
- Enter: 120 ms (`micro`) for small things, 180 ms (`standard`) for structural changes. Ease out.
- Exit is faster than enter and at most 80 ms (`quick`): a popup, notice, chip or row that leaves fades out in
  `--cmux-motion-quick`.
- Hover, pressed and focus transitions on a control: at most 120 ms; the pressed state is instant.
- Reduce Motion: movement is instant; opacity changes stay at 100 ms or less.

## The check

`webviews/src/gallery/invariants.ts` measures every gallery state: `chevron-gap`, `hit-target`, `motion-max` and
`motion-exit`. Gallery health fails a state that breaks a rule its row in
`scripts/gallery-matrix/invariant-baseline.json` does not list (rows only shrink; `invariant-baseline.ts`).
`test/ui-guidelines.browser.test.ts` runs the same measurement over the gallery states that draw chevrons, on the
browser lane of every web PR, and `test/gallery-invariants.test.ts` unit-tests the rules. A new component that breaks
one fails there; fix the component, do not add it to the baseline.

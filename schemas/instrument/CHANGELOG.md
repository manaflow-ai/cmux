# Instrument tokens: changelog

The versions of `schemas/instrument/instrument.json`, the one token file of Instrument, the cmux design
system (cmuxterm-hq RFD 0034). A version moves when a token's Instrument value or its value today moves.
`scripts/cmux-next/gen-instrument-tokens.py --check` fails when the file's version has no entry here.

Semver for a design system: a patch moves no pixel (a source, a note, a renamed path); a minor applies
pending values (a default moves, the pending list shrinks); a major changes a seed or a rule.

## 0.1.0 (2026-11-22)

First version: the token table of Instrument v0.1 as the 2026-11-22 debate adopted it, one row per token.

- Every token records Instrument's value and the value the app draws today, read from the file that sets
  it now (design-scale, type-scale, layout-grid, surface-roles, the settings schema).
- Nothing applied. The generated sheet, `webviews/src/ui/instrument.generated.css`, carries today's values;
  the Instrument value of a pending token is a comment beside it. No default and no pixel moves.
- Pending, by what each waits on:
  - Leo's four questions: two tones by default (`tone.step`); the corner values (`corner.pane` 8 to 12,
    `corner.card` 14 to 12, `corner.popup` 8 to 12, `corner.toast` 9 to 12, `corner.composer` 18 to 16,
    `corner.dialog` 14 to 20, `corner.chip` 6 to 4); the prose column (`prose.measure` 800 to 560-720,
    `prose.line-height` 1.625 to 1.4286, `tool-row.size`); the name (Instrument or Frame).
  - The skin: `selection.row` (accent to neutral), `join.curve`.
  - The skeleton, not drawn yet: `band.height` 32 to 36, `ink.hover` 6% to 8%, `ink.selected` 10% to 12%,
    `ink.text-muted` and `ink.text-dim` as solid mixes, `type.weights` without 700.
  - No token in the app yet: the fixed ink ladder hexes, `selection.tab`, `tone.seam`, `corner.rule`,
    `corner.capsule`, `ink.step`, `code.inline-break`.
- Already drawn: the three seeds (grid 4, control 28, text 13), the control heights, `corner.control` 8,
  `corner.tooltip` 8, `ink.frame` 4%, `ink.outline` 16%, the three status hues, `prose.size` 14, the spacing
  scale.

# Neko round 3: six-action line experiments

Twelve original SVGs: two directions, each drawing all six gallery actions (copy, retry, speak,
bookmark, pin, more). The file name is the pack icon the drawing would replace. Every drawing is a
24-unit grid, monochrome `currentColor`, 1.5 round stroke, per `design/icons/SPEC.md`.
`scripts/icons/build_pack.py` turns them into overlays (`nekoRounds.json`) that the gallery draws
through the shared `Icon` renderer, beside the unchanged default row.

- **tail/**: one cue everywhere. An open line ends in a small tail curl (copy's rear sheet, retry's
  arc, speak's outer wave, bookmark's lower-right point, pin's needle); More's dots become toe beans.
- **mix/**: the cue that suits each noun. Ear corners on the copy sheet and the bookmark star, tail
  curls on retry, speak and pin, toe-bean More.

These are experiments, not accepted artwork; `manifest.json` records each drawing's base geometry and
change. Verdicts live in `design/icons/neko-evaluation.md`.

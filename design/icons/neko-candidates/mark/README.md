# Neko cat mark: one accent, not a family

Three original drawings of a single cat mark. Each is a candidate replacement for `app.cmux` (the
prompt mark) that a user could pick as an accent: the sidebar glyph, an empty-state hero, or the
glyph on an app-icon tile. Each is a 24-unit grid, monochrome `currentColor`, 1.5 round stroke, per
`design/icons/SPEC.md`. `scripts/icons/build_pack.py` turns them into overlays (`nekoRounds.json`)
that the Neko gallery draws through the shared `Icon` renderer beside the unchanged default.

- **head/**: the default prompt (`>_`) drawn as the face of a cat head with two pointed ears.
- **tile/**: the default prompt inside a rounded tile whose top corners rise into ears.
- **tail/**: the default prompt unchanged, except that the underscore turns up into a tail.

Experiments only. Nothing is enabled; `manifest.json` records geometry and intent. The verdict lives
in `design/icons/neko-evaluation.md`.

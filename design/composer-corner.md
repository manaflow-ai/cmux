# Composer corner and the + chip

The composer box's corner, the shape of the + highlight, and what the hat and the strips over the
box share. Code: `webviews/src/agent-session/acpmux/composerLocation.css`
(`--grid-composer-radius`, `--grid-composer-plus-radius`), `schemas/layout-grid/layout-grid.json`
(`composer-radius`), gallery `agent-pane.composer-round`.

## Rule (Leo 2026-11-23)

> "now the composer is a bit too round i think ... just do the claude code roundedness. the chatgpt
> roundedness only makes sense for the chatgpt replica ... we dont want codex parity for the
> composer. the more minimal single line claude code version is more favourable."

> "because for the chatgpt parity, if you're going to have it be that round, it necessarily has to
> be at baseline longer than one line. and the highlight also necessarily has to be a circle
> instead of a rounded square. that's just design."

- The composer is Claude Code desktop's single-line minimal composer: corner 12 (`composer-radius`),
  one-line box 48. The running tray (hat), the queue, the trust bar and the subagent strip take the
  same corner.
- The + highlight follows the composer's corner shape. At this radius it is a rounded square: a
  28 control (the mic and Send size), inset 8 from the box's edge and 10 from its top and bottom,
  corner 8, subtle at rest and brighter on hover. Its glyph is a 16 box with 13.5 of ink. The tooltip
  is "Add" (`composer.add`).
- A circle highlight belongs only to a ChatGPT-round composer (corner at or above half the box). That
  corner needs a baseline taller than one line, so it is a different layout, not a radius setting.
  It lives only in the ChatGPT replica, never in the cmux composer.
- Measured from Claude Code's composer (140 x 122 crop at 2x): box corner about 12, chip 28 square,
  chip corner about 8, 8 between the box edge and the chip, 8 between the chip and the text.

## Candidates seen (gallery, Leo 2026-11-23)

8, 10, 12 (selected), 14, 16 and the old 22. 22 was "half a round control plus the inset" (#50920);
it is ChatGPT-round and wrong for a one-line composer.

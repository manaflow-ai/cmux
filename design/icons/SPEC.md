# cmux-next in-app icon set: drawing spec

Leo picked the sidebar/toolbar glyph styles from `../glyphs.json` (Line, Solid, Cat accent). This set
extends them to every icon cmux-next renders (`inventory.json`, `core-names.tsv`). Everything here is
hand-written SVG. Match the reference glyphs in `../glyphs.json` exactly in weight and feel.

## Grid and geometry (all styles)
- `viewBox='0 0 24 24'`. Live area 3 to 21 (2 px padding is 3; wide shapes may touch 2.5 to 21.5).
- Coordinates on a 0.5 grid. Strokes 1.5 wide, so straight 1.5 strokes sit on .75 / .25 offsets where it
  matters for crispness at 16 px (e.g. a horizontal line at y=12 is fine; boxes use x=3, width=18).
- Corner radius 2.5 on frames (windows, panes, cards), 2 on small tiles, 1 on tiny marks.
- Optical sizes: plain circles smaller than squares, full squares smaller than open glyphs (see Centering and optical size below); diamonds a bit larger.
- Minimal detail: an icon must read at 16 px and in compact rows at 12-13 px. At most ~4 strokes inside a
  frame. If an idea needs more, simplify the idea.
- No text glyphs from fonts. Letters, if unavoidable, are drawn paths.
- No brand logos. For third-party brands (GitHub, arXiv), draw a neutral generic stand-in and note it.

## Line style
`<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='currentColor'
stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'>...</svg>`
currentColor only. SF-Symbols restraint. Reference: `glyphs.json` line set.

## Solid style (selected and active states)
Same footprint as Line: filled silhouette where Line has an outline; inner details knocked out with a
`<mask>` whose id is `cmxs-<icon-name-with-dashes>` (unique per icon), as in `glyphs.json` solid set. Open
shapes with no interior (arrows, chevrons, x, plus) stay identical to Line but at stroke-width 2.
Solid must stay distinguishable from Line at 16 px.

## Cat accent (optional flavor)
Line style plus ONE small cue in `class='accent' stroke='var(--accent)'` (or fill var(--accent)): ear
notches on a frame top, a tail curl on a line end, a sleeper z, paw dots. 1-2 short strokes. Only add it
where it is natural and legible; most icons should NOT get one (aim for 15-25% of a batch). Never on
status, security, permission-denied, error or destructive icons.

## Consistency rules (the inventory found these drawn many ways; there is ONE icon each now)
- close = x (two 1.5 strokes, 6..18), used for tab close, dismiss, field clear (field.clear may be x in a
  circle). add/new = plus; "new X" = X with a small plus badge at bottom-right (badge: plus 5 px wide
  with a 1.5 knockout gap ring), not a different metaphor per noun.
- chevrons: one geometry (6 px wide, 90 degree) for disclosure, nav, menus.
- search = one magnifier (circle r=6 at 10.5,10.5 + handle to 20,20).
- status family: one circle language: success = check in circle, warning = triangle with bang,
  error = x in circle (NOT the triangle), info = i in circle, running = 3/4 arc (static; animation is
  the app's job), needs input = circle with dot pulse ring, idle = hollow circle, off = slashed circle.
- fork (agent.fork) and git.branch must differ: branch = git graph (two nodes and a curve); fork = one
  line splitting into two arrowheads (Y). handoff = baton: arrow passing between two hands is too
  detailed; use an arrow crossing from one small rounded square into another.
- permission (site permissions) icons: the noun icon (camera, mic, location...); ".blocked" variants =
  same icon with a diagonal slash (slash drawn with a 1.5 knockout gap on its left side).
- checkpoint = flag (reference glyph). terminal = `>_` window (reference). agent.chat = bubble with two
  eyes (reference). workspace = window with sidebar (reference). spaces = 2x2 tiles (reference).

## Centering and optical size (checked by `src/measure.py`, fixed by `src/optical.py`)
- The ink box (stroke included) is centered on 12,12 within 0.5 units on both axes. Exceptions: the
  play triangle sits 0.75 right and the collapsed chevron 1 right (optical), and Cat variants keep the Line base where it is, so the ears
  raise their box.
- Ink extent is at least 15 units for every glyph except dots (raised from 13.5 when row icons moved to
  1.2x the label font). Pairs (collapsed/expanded, back/forward)
  have the same extent.
- Exception, plain circles: a bare ring, dot or status circle reads larger than an open or square glyph
  of the same extent. Those (`state.idle`, `state.off`, `status.*`, `task.status.*`, listed in
  `optical.py` CIRCLES) target 16.25 units of ink (about r 7.4, 12% under the old r 8.5), floor 13.
  Composite circles, a ring with content inside (account, field/icon/color clear, globe, clock,
  download), keep full size (r 8.5): clear must not read smaller than close. This replaces the old "circles a bit larger
  than squares" rule above.
- Coverage trim (`src/coverage_trim.py`, measured by `src/measure.py`): glyphs that fill most of the
  box read bigger than open glyphs at the same extent: square frames, octagons, folders, servers, a
  full globe or disc, a badge on a full shape. Score = max(silhouette fill / 324, line ink / 324 + 0.3),
  where the silhouette is everything the outline encloses after closing 2-unit gaps (so dashed frames
  count) and 324 is the 18x18 live area. At a score of 0.90 or more, scale about the ink center by 6%,
  rising linearly to 10% at 1.05. The rule runs once per drawing (`measure/coverage-trims.json`).
  Exception by name: `task.ai`, a sparkle whose thin points reach the edges, takes 6%.
- `disclosure.collapsed` is its own drawing, not the expanded chevron rotated: about 92 degrees, 7 wide,
  sitting 1 unit right of center, so the gap to its label matches an expanded row's. The play triangle
  sits 0.75 right for the same optical reason.
- Apply fixes to the geometry, never with a wrapping transform, so strokes stay 1.5.

## Hard meanings: multiple tries
For names marked hard (`H` in core-names.tsv) or that you find ambiguous, draw 2-3 alternates, each a
different metaphor, and say which you prefer and why.

## Output
Write `icons/<batch>.json`:
```json
{"batch":"<batch>","icons":[{"name":"action.close","meaning":"...","line":"<svg...>","solid":"<svg...>",
  "cat":null,"alts":[{"label":"...","line":"<svg...>","solid":"<svg...>"}],"note":"...","replaces":["xmark","xmark.circle.fill"]}]}
```
`replaces` lists the current sources from inventory.json. `cat` is a full Line svg with the accent, or null.

## Verify visually before reporting
Render every icon at 12, 16, 24 and 64 px on `#ffffff` (ink `#1d1d1f`, accent `#8839ef`) and `#2b2d3f`
(ink `#cdd6f4`, accent `#cba6f7`), Line and Solid side by side, with
`google-chrome --headless=new --disable-gpu --hide-scrollbars --window-size=1400,H --screenshot=out.png file:///...html`,
view the PNG with Read (crop with PIL if tall), and iterate until every icon is crisp, balanced, distinct
from its neighbours at 16 px, and consistent with the reference glyphs. Keep preview files in `previews/`.

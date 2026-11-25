# Scene engine

The one first-party program that draws every motion scene (plans/cmux-next/motion-scenes.md). It
is not a wallpaper by itself (no `wallpaper.json`): build.rs translates it once with the scene
prelude (`src/scene_prelude.wgsl`) into `SCENE_ENGINE_MSL` and `SCENE_ENGINE_GLSL`, and every
folder whose manifest names a `scene` or `lottie` file embeds that file and the engine's Metal.

- Reads: `frame` (paper, ink for an eye's pupil, `size.z` for handle and edge widths), `scene` (the
  128-row block Rust packs each frame, `Player::evaluate`), and the image slot (`scene_image`,
  `scene_sampler`; one `textureSampleLevel`, so no control-flow rule applies).
- Order, one pass: field (or paper), shapes 0..n, guides, ropes, image, light, grain. Composited
  premultiplied in linear light; the result is opaque.
- Field: four points, wide Gaussian weights `exp(-0.9 (d / radius)²)`, normalized, blended in sqrt space
  (roughly perceptual) so the lavender, peach, orange and blue blends stay luminous. The warp bends
  the sample point with two nested sinusoids whose time terms are whole multiples of the loop
  phase (`2π · phase`), so the loop is seamless. No field (row 3's w is 0): paper.
- Shapes, in local space (unturned, then un-squashed by a body's twist; distances are scaled back
  by the squash so the edge stays one pixel): circle and ellipse (Quilez's approximation, exact for
  circles), half disc (ellipse ∩ y ≤ 0), lens (a vesica: one mirrored circle through the box's
  ends and the thickness), eye (the full-height lens plus a pupil: color 1 for a gradient fill, the
  fill pulled 65% toward ink for a solid one, the fill for a stroked one), arcs (a closed-form band
  test: `fract(ρ / step)`, no loop over rings), round rect, cube and ring (an elliptical band).
- Cube: an isometric hexagon whose top face is `shape · half height` tall. Glass, not paint: each
  face passes the backdrop through, tinted by the fill (it absorbs: the top 35% toward color 0, the
  side facing the light 50% toward color 1, the far side 90% toward color 1 and darker), then adds
  a reflection (a sheen fading down the face, and the light by `lit`). Edges: the silhouette and
  the three edges meeting at the near corner, 0.7 points wide, color 0 toward white and brighter
  on the side facing the light; the three hidden back edges show at 50% through the glass; a
  faint rim outside the silhouette, darkened toward color 1, keeps the edge legible on a pale
  field. `opacity` scales all of it.
- Fills: solid; linear from color 0 to color 1 along the angle in the shape's own frame (it turns
  with the shape: 0 points +x, right; π/2 points +y, down); radial, color 0 at the center to color 1
  at the box's edge.
- Edges: a one-rendered-pixel linear ramp; `soften` widens it to `1 + soften` px and eases it into a
  smoothstep. `stroke` > 0 draws an outline that wide, centered on the edge (not on the cube).
- `lit`: the light's Gaussian at the pixel × `lit`, stronger on the side facing it (25% to 100%).
- Guides: ends snapped to pixel centers, so level and plumb lines land on one row or column and
  stay crisp (unsnapped, a line on a pixel boundary splits into two half-strength ones and
  vanishes under the grain). A line under a pixel wide is drawn one pixel wide, fainter only
  under two thirds of one. Dashes are `dash` px on, `dash` px off, measured from `from`.
  Handles: hollow squares 5 points across (a whole number of pixels), 0.75 points of line, and
  the guide stops at their edge.
- Ropes: one polyline per rope (min distance over its segments), its width and color.
- Image: a rounded rect turned and squashed with its body, sampled at its own uv (premultiplied,
  linear: the host's texture is sRGB).
- Light: additive, `0.35 · intensity · exp(-(d / radius)²)` of its color.
- Grain: two integer hashes per `size`-px cell (a triangular distribution), added in sqrt space
  at `0.6 · amount`, so it reads evenly in shadows and highlights. Seed 0 keeps it still.

## Cost

Every loop runs to a count in row 0, capped by the block's limits, so the worst case is fixed:
16 shapes, 8 guides, 16 rope points (14 segments in two ropes), the image, light and grain. A
shape whose bounding circle (plus blur and stroke) misses the pixel costs about 10 ALU ops and
returns, so a typical pixel pays for the two to four shapes under it.

Worst case, per pixel (every shape a lit cube covering the whole backdrop, each guide and rope
segment evaluated), counted from the WGSL as scalar ALU operations:

| part | ALU ops | transcendentals |
|---|---|---|
| field (warp, 4 points, sqrt-space mix) | ~75 | 4 sin, 4 exp, 15 sqrt |
| 16 cubes (reject test, turn, hexagon, faces, 5 edge segments, fill, light, 4 coverages, 2 overs) | 16 × ~210 = ~3360 | 16 × (sin, cos, 2 exp, ~8 sqrt or rsqrt) |
| 8 guides (segment, dash, two handles, coverage, over) | 8 × ~75 = ~600 | 8 sqrt |
| ropes (14 segments, 2 coverages) | ~230 | 14 sqrt |
| image (turn, round rect, coverage, 1 texture sample) | ~45 | sin, cos, 1 sqrt |
| light and grain (2 integer hashes, sqrt space) | ~50 | 1 exp, 3 sqrt |
| total | ~4400 | ~230 |

Other kinds cost less than the cube (circle ~110, arcs ~120, eye ~140 with its pupil). For
comparison, Grain and Silk is about 230 ALU ops a pixel, so the worst-case scene is ~19 times
that and a typical sample scene (8 shapes, 2 guides, the reject test passing for 2 to 4 shapes a
pixel) about 3 to 5 times. The cost does not depend on time or the window beyond its pixel count; a
scene manifest with `"scale": 0.5` quarters it. The number that decides is the GPU ms per frame
from `scripts/measure/wallpaper-cost.sh` on a fleet Mac (plans/cmux-next/motion-scenes.md,
"Measures").

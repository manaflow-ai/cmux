# Motion scenes

Leo, 2026-11-19 04:21Z, on a Behance motion study (soft mesh gradients, heavy film grain, flat
geometric shapes with gradient fills, a glass cube, thin blueprint guides with square handles):

> this is kind of interesting how can we add these sorts of effects and whatnot to our customizations?

Leo, later, on a blog post about an interactive 3D event badge (a card hanging on a lanyard you can drag):

> what do u think ab this i remember this was p cool back then and still is

A motion scene is a live wallpaper ([live-wallpapers.md](live-wallpapers.md)) described as data. It has
no program of its own. `wallpaper.json` names a `scene.json` (or a Lottie file) instead of a
`wallpaper.wgsl`. One first-party program, `scene-engine`, draws every scene. It reads a second
uniform, the `Scene` block, which Rust fills each frame from the scene's keyframes and physics.

The engine is first-party, so it is translated at build time like every other first-party program. A
scene is JSON, so a scene from an extension, a user folder or a Lottie import loads in the app with no
shader compiler. Authored WGSL is checked by the same sandbox as before. Only the engine may read
`scene` and the image slot.

Opt-in only: nothing changes the default backdrop.

## The scene file

Coordinates: `at` is a fraction of the backdrop (`[0,0]` top left, `[1,1]` bottom right). Sizes,
widths and lengths are fractions of the backdrop's shorter side, so a circle stays round. Angles are
degrees. Colors are `#RRGGBB` (sRGB), `#RRGGBBAA`, or a theme token: `ink`, `paper`, `accent`, or a
token with a mix, `"accent 40% paper"`.

Every number, point and color may be animated: in place of the value, write
`{"keys": [[t, value], [t, value, ease], ...]}`. `t` is seconds into the loop. The ease, on a key,
shapes the way into that key: `linear` (the default), `hold`, `in`, `out`, `inOut` (cubic), `sine`,
or `[x1, y1, x2, y2]` (a CSS cubic-bezier). Before the first key the value is the first key's; after
the last it is the last's, until the loop wraps.

```jsonc
{
  "loop": 16,                          // seconds; every track wraps here (default 10)
  "field": {                           // the mesh gradient: 4 colored points blended by distance
    "points": [
      { "at": [0.1, 0.2], "color": "#C9B8F0", "radius": 0.9 },
      { "at": [0.9, 0.1], "color": "#F6C9A8" },
      { "at": [0.8, 0.9], "color": "#F08A4B" },
      { "at": [0.2, 0.8], "color": "#A9C4F5" }
    ],
    "warp": 0.25                       // 0..1, slow noise warp of the blend
  },
  "grain": { "amount": 0.12, "size": 1.0, "animated": false },
  "light": { "at": [0.7, 0.2], "color": "#FFFFFF", "intensity": 0.6, "radius": 0.8, "followPointer": 0.3 },
  "shapes": [                          // at most 16, drawn in order
    {
      "kind": "circle",                // circle | halfDisc | lens | eye | arcs | roundRect | cube | ring
      "at": [0.5, 0.5], "size": [0.4, 0.4], "rotate": 0,
      "fill": { "type": "linear", "from": "#F08A4B", "to": "#C9B8F0", "angle": 90 },  // solid | linear | radial
      // angle: the direction from `from` to `to`, in the shape's own frame (it turns with the shape):
      // 0 points right, 90 down. A radial fill runs from the center (`from`) to the edge (`to`).
      "opacity": 1, "soften": 0.0,     // soften: edge blur, a fraction of the shorter side
      "stroke": 0,                     // 0 fills; > 0 draws an outline this wide
      "lit": 0.0,                      // 0..1, how much the light brightens it
      "shape": 0.5,                    // per kind: lens/eye thickness, arcs count, roundRect corner, cube depth, ring width
      "body": "card"                   // optional: a physics body moves it (at and rotate become offsets)
    }
  ],
  "guides": [                          // at most 8 thin lines
    { "from": [0.1, 0.5], "to": [0.9, 0.5], "width": 0.0015, "opacity": 0.5, "color": "ink", "handles": true, "dash": 0 }
  ],
  "physics": { ... },                  // optional, below
  "image": { "slot": "badge", "body": "card", "inset": 0.06 }   // optional, below
}
```

Limits: 16 shapes, 8 guides, 4 field points, 1 light, 2 ropes of up to 7 segments, 2 bodies, 256
keys per track, 64 KiB per file. Too many is an error, never a silent cut.

Shape kinds (`size` is the bounding box):
- `circle`: an ellipse.
- `halfDisc`: the half of the ellipse above its center line (rotate to turn it).
- `lens`: two circle arcs meeting at the box's left and right ends. `shape` is its thickness, 0..1.
- `eye`: a lens with a round pupil. `shape` is the pupil's size, 0..1.
- `arcs`: stacked concentric half-rings. `shape` is the count (1..8).
- `roundRect`: `shape` is the corner radius, a fraction of the short side.
- `cube`: an isometric glass cube with three faces. `fill` shades the faces, and the light lights the
  edges. `shape` is the depth.
- `ring`: an elliptical ring. `shape` is its width.

`lit` and the cube's edges use the light. With `followPointer` above 0, the light eases toward the
pointer by that share.

### Physics

```jsonc
"physics": {
  "gravity": [0, 2.4],                 // shorter sides per s²
  "bodies": [
    { "id": "card", "at": [0.5, 0.6], "size": [0.2, 0.28], "mass": 1, "draggable": true, "damping": 0.6 }
  ],
  "ropes": [
    { "id": "strap", "anchor": [0.5, -0.02], "to": "card", "toAt": [0, -0.5], "length": 0.45,
      "segments": 7, "width": 0.012, "color": "accent" }
  ]
}
```

Rust steps the world at a fixed 1/60 s. Each drawn frame gets the state blended between the last two
steps (`alpha` = leftover time ÷ step), so motion is smooth at any frame rate, as in that badge
post. Bodies are 2D rigid boxes with a small twist about the vertical axis, drawn as a horizontal
squash, so a swinging card turns. Ropes are position-based chains with distance constraints. Each rope
end is pinned to its anchor or to a point on its body. A press on a draggable body grabs it there, and
the press point drags it with a soft spring until the button comes up.

Sleep: when every body's speed and spin have stayed under the rest threshold for 0.5 s and nothing is
held, the world sleeps. It stops stepping and costs nothing. A scene with no keyframes and a sleeping
world is at rest, and the scheduler holds it (`HoldReason::AtRest`), so the display link stops. A
press on a draggable body wakes it. Rope segments are rope joints: they resist stretching, not
shortening. Rotation turns from +x toward +y, clockwise on screen.

Defaults: gravity `[0, 2.4]`; a body has mass 1 (0.01..1000), damping 0.4 (the share of velocity lost per
second, 0..1) and is not draggable; a rope has 6 segments (1..7), width 0.01, color `ink`, `toAt`
`[0, 0]`. A step runs 12 constraint passes; an `advance` runs at most 8 steps and drops a longer backlog.
Rest is under 0.005 shorter sides per second and 0.02 rad/s.

### The image slot

A scene may show one image: `image.slot` names what the host draws into it. `badge` is the person's
avatar and name, laid out by the host. The image is drawn on the body's card, inset by `inset`. The
engine samples it from one texture (`scene_image`, binding 2) with one sampler (binding 3). The host
binds a 1×1 clear texture when there is no image.

## Lottie

`wallpaper.json` may name `"lottie": "animation.json"` in place of `"scene"`. Rust translates the
Lottie file to a scene when the wallpaper loads (pure, no I/O). It maps:
- shape layers with ellipses (`el`) and rects (`rc`);
- solid (`fl`) and 2-stop gradient (`gf`) fills, and the layer transform (`ks`: position, scale,
  rotation, opacity, anchor);
- keyframes with their bezier easing (`i`/`o`) and holds (`h`);
- `ip`/`op`/`fr`, which set the loop.

Anything else (paths, masks, mattes, trim paths, effects, text, images, more than 16 shapes) gets a lint
line naming the layer and the feature. A file with any refused feature is not loaded, and its report
says what to change. For full After Effects output, export a video and use it as a moving wallpaper.

Rive is not in this step. Its `.riv` object catalogue is only documented by the C++ runtime's generated
definitions, and its state machine needs scene-level inputs that the scene does not have yet.

## The packed block

`Scene` is 128 `vec4<f32>` rows, 2048 bytes: the same layout in Metal, WGSL and GLSL std140. It sits at
binding 1 (Metal fragment buffer 1, `setFragmentBytes`, well under its 4 KiB limit). Positions and sizes
are in rendered pixels, and colors are linear and already mixed with the theme.

| rows | what | x | y | z | w |
|---|---|---|---|---|---|
| 0 | header | shape count | guide count | rope 0 point count | rope 1 point count |
| 1 | grain | amount | size px | seed (0 = still grain) | image shown (0/1) |
| 2+2i | field point i (i < 4) | x px | y px | radius px | point 0: warp 0..1; point 1: loop phase 0..1; else 0 |
| 3+2i | field point i color | r | g | b | 1 |
| 10 | light | x px | y px | radius px | intensity (0: no light) |
| 11 | light color | r | g | b | 0 |
| 12+5i .. 16+5i | shape i (i < 16) | see below | | | |
| 92+3i | guide i (i < 8) | x0 px | y0 px | x1 px | y1 px |
| 93+3i | guide i | width px | opacity | handles 0/1 | dash px (0 = solid) |
| 94+3i | guide i color | r | g | b | 0 |
| 116..124 | rope points, two to a row: rope 0's, then rope 1's | xa | ya | xb | yb |
| 124 | rope 0 | r | g | b | width px |
| 125 | rope 1 | r | g | b | width px |
| 126 | image | center x px | center y px | half width px | half height px |
| 127 | image | rotation rad | twist squash 0..1 | corner px | opacity |

Shape rows, `s = 12 + 5i`:

| row | x | y | z | w |
|---|---|---|---|---|
| s | kind (1 circle, 2 halfDisc, 3 lens, 4 eye, 5 arcs, 6 roundRect, 7 cube, 8 ring) | center x px | center y px | rotation rad |
| s+1 | half width px | half height px | shape param | squash 0..1 (1 = none; a body's twist) |
| s+2 | color 0 r | g | b | opacity |
| s+3 | color 1 r | g | b | fill (0 solid, 1 linear, 2 radial) |
| s+4 | gradient angle rad | soften px | stroke px (0 fills) | lit 0..1 |

Unused rows are zero, and the engine reads only up to the
counts in row 0. Its loops run to the counts and are bounded by the limits. The worst case (16 shapes,
8 guides, 16 rope points) sets the cost, and that cost does not grow with the window or with time.

## Code

- `cmux-wallpaper/src/scene/`: `mod.rs` (the parsed scene and `evaluate(t, frame) -> [f32; 512]`),
  `value.rs` (tracks, easing, colors), `physics.rs` (the world, fixed step, interpolation, sleep),
  `lottie.rs` (the translator and its lint).
- `cmux-wallpaper/src/scene_prelude.wgsl`: `Scene`, `scene` and the image slot, added after the
  `Frame` prelude for the engine only.
- `cmux-wallpaper/wallpapers/scene-engine/`: the engine program (WGSL), not a wallpaper by itself.
- Scene wallpapers live under `wallpapers/<id>/` with `wallpaper.json` and `scene.json`, and embed the
  engine's Metal by reference.
- `cmux-app-ffi`: `cmux_wallpaper_scene_*`. A scene handle is made from a manifest and scene bytes, and
  `evaluate` writes the block. Pointer and button go in, and an at-rest flag comes out for the
  scheduler.
- The Swift host (`BackdropLiveView`) binds the block at fragment buffer 1 and the image at texture 0.

## Measures

The frame-time number comes from `scripts/measure/wallpaper-cost.sh` on one fleet Mac: GPU ms per
frame, the Rust evaluate µs per frame, and CPU and RAM while running, at rest and occluded.

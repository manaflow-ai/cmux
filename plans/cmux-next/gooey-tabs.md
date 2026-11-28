# Gooey tabs: the material, the springs, the levels

Owner: `tabs-refine` (Eden), holding "Tab strip and hover cards" while this is built. This file is the contract: the
Rust core, the Swift setting and the Swift strip build against it in parallel.

Leo, 2026-11-23:

- "refine my two-tone thing and my gooey tabs thing. proper contrast that is only as contrasty as necessary ... and
  then simply properly unifying the transparency and/or translucency and/or highlighting of the gooey things".
- "my argument is spunk ... we can be so much more free and creative with animations with this kind of thing.
  sprinyness, the goo itself, the various edge cases of delight. joy. ... built it out ultra fully and rigorously so
  we can have some fun with it."
- "presumably a less intense version should have a better case to be the default. so you guys need to try that.
  like. subtle goo."

## Levels

`appearance.gooeyTabs`: `off` | `subtle` | `full`. **`off` is the default** and changes nothing anyone sees today:
Lawrence's one-tone, non-gooey tabs, critically damped strip tweens. `subtle` and `full` are variants:

| | off | subtle | full |
|---|---|---|---|
| Shape | today's `appearance.cornerFlush` | flush-goo (fillets) | flush-goo, wider fillets |
| Frame | today's `appearance.titleAreaTone` | Subtle Tone at the theme-derived share (`FrameTone`) | same |
| Springs | tokens (critically damped) | goo springs, damping 0.86 to 0.9 | goo springs, damping 0.55 to 0.7 |
| Stretch on select | none | 0.12 | 0.45 |
| Drag-out neck | none | short, snaps early | long, necks and snaps off |
| Settle wobble | none | about 1 px | 2 to 4 px |

The ink-ladder rules for color still hold at every level (FrameTone). The goo is in motion and shape only: no extra
text, chrome or glow.

Lawrence's rule that every spring *token* is critically damped (cmux-motion build.rs, 2026-11-10) is untouched.
The goo springs are not tokens. They are this variant's own tuning, read only under `subtle` or `full`.

## Where the logic lives

- **Rust, `cmux-tui/crates/cmux-motion/src/goo/`.** Levels, tunings, the spring tracks, the blob outlines and the
  event plans. Pure functions: no globals, no allocation in the FFI path, and they never panic.
- **C ABI, `cmux-tui/crates/cmux-app-ffi/src/goo.rs`.** This goes into `include/cmux_motion_ffi.h` (cbindgen) and
  bumps `ABI_VERSION`.
- **Swift.** Core Animation layers and the settings only. A strip computes a plan once per event, through the
  FFI, and hands Core Animation keyframes (`CAKeyframeAnimation` of `path` and `position`). The render server draws
  the frames. Nothing steps on the main thread per frame (the TabMotion rule), so 120 fps costs the main thread
  nothing while a plan runs. A drag updates on mouse events, not per frame.

## The spring track (Rust `goo::track`)

`Track { x0, v0, target, params: GooSpring { response, damping_fraction }, start: f64 }`. The step is closed form
and underdamped-capable (`SpringValue::solve` already handles fractions under 1).

- `state(t) -> (x, v)`
- `rest_time(epsilon)`
- `sample(hz, out: &mut [f32]) -> usize`: values from `start` to rest, at most `out.len()`.
- `retarget(t, new_target) -> Track`: starts from `state(t)`, keeping the velocity. **This is the interruption
  rule: a new gesture mid-animation never snaps.** Swift keeps the plan's start time and its tracks. On a new event
  it retargets from now, and replaces the layer's animation with the new keyframes (`removeAnimation` plus `add`
  in one transaction, with `beginTime` = now).

## The blob (Rust `goo::blob`)

One **selection blob** per strip: the selected tab's body, running into the card, plus its two fillets. The shade
cuts exactly this out. It replaces the static `folderPath` and `feetPath` while a plan runs, and equals them at
rest, to the pixel. `GooTest::rest_matches_folder_path` checks this against the Swift static path's geometry.

An outline is always **`GOO_OUTLINE_POINTS` cubic segments (fixed, e.g. 24)**, so Core Animation can interpolate
any two of them, and the shade's even-odd path, which embeds it, keeps a constant element count.

- `blob(left, right, top, baseline, corner_radius, feet_radius, lean) -> Outline`. `left` and `right` are the
  body's edges, driven by two tracks. The leading edge takes the stiffer spring and the trailing one the softer,
  which stretches the body on a move (Stretch). `lean` skews the top corners toward the travel, scaled by the
  level.
- `neck(blob, other: RoundedRect, k) -> Outline`. A smooth union (polynomial smooth-min of the two signed
  distance fields, `k` = the goo threshold) of the blob and a second rounded rect on the same baseline: a hovered
  neighbour (full only, within `k`), or a dragged tab lifted off the strip. It is sampled along the outline's fixed
  parameterization, so the count stays fixed.
- `drag_neck(slot, tab, offset) -> DragNeck { outline, attached: bool }`. While a dragged tab is within
  `break_distance` of its strip, the neck joins the tab to its slot, narrowing with distance. Past it,
  `attached = false`: the neck **snaps off** (it retracts into the slot on a goo spring, with a settle wobble) and
  the tab carries a small blob of its own. Coming back within `capture_distance` (less than `break_distance`, so it
  does not flicker) the tab is **absorbed**: the neck regrows and the slot swells, then settles.

## Event plans (Rust `goo::plan`)

`plan(event, geometry, tuning, now) -> Plan`: the tracks and keyframe counts for each event.

- **select**: the blob's two edges travel to the new tab. Stretch, lean, and a wobble on settle.
- **open**: a new tab buds out of the blob's neighbour, or out of the new-tab button when it is selected at once.
  Its width springs from 0. The blob follows.
- **close**: the closing tab pinches. Its fillets shrink before its width. A selected one hands the blob to the
  next selection.
- **close the last tab**: the blob shrinks into the card's top edge, and the fillets flatten to the card's
  straight edge. No pop.
- **reorder**: the blob rides the dragged tab, and neighbours part on the goo spring.
- **drag-out**: `drag_neck` per mouse event.
- **drop back**: absorb.
- **drag across windows**: the source strip snaps off and the target strip absorbs. Each strip plans alone.
- **overflow, many tabs**: only the selection blob, at most one neck, and the dragged tab animate. Cost is
  constant in the tab count (the plan never walks the tabs). Scroll-reveal moves the blob with the strip's
  scroll spring, so it is never left behind.
- **one tab**: the blob sits on the card's leading edge (no leading fillet: `skipsLeading`) and still wobbles on
  select.
- **pinned tabs**: the same blob. Pinned widths are fixed, so stretch is capped at the pinned width.
- **rapid open/close spam**: every event retargets the running tracks (never restarts from rest), and keyframe
  work is bounded per event. A burst of N events costs N small plans and never stacks animations: one key per
  layer, replaced.
- **theme switch mid-animation**: colors are not part of a plan. A theme switch recolors the layers with actions
  off, and the path keyframes keep running.
- **reduced motion**: `subtle` and `full` keep the goo *shape* (fillets, the blob at rest, a static neck while
  dragging) and drop the motion. Geometry moves at once, with a 0.1 s cross-fade at most, and no wobble or stretch.
  It is calm and still gooey.
- **translucent windows and background pictures**: the blob is a hole in the shade (the card shows through), so
  it is the card's material by construction. The dragged tab is the floating lift of the card's surface
  (`Metrics.frameLiftSurface`).

## Knobs

Every spring (response and damping fraction per event: select, open, close, reorder, snap, absorb, wobble) and every
goo parameter (`stretch`, `lean`, `feet_radius` scale, `k` threshold, `break_distance`, `capture_distance`,
`wobble_amplitude`) is a `Tunable` in `GooTunables` (CmuxNextTabs). They show on the Debug Settings tuning page under
"Gooey tabs", one section per level, defaulting to Rust's `GooTuning::for_level`, and apply live.

## Performance budget

- The main thread does one plan per event: at most 2 FFI calls and at most `GOO_KEYFRAMES_MAX` (120) outlines.
  That stays under 0.2 ms at 50 tabs and is constant in tab count.
- The render server draws the frames. Target: no dropped frame at 120 Hz with 50+ tabs, select and drag.
- Before and after frame times from one harness (the strip perf suite), at 10, 50 and 200 tabs, plus a duress
  number (chat-sim running).

## The C ABI (exact; Rust implements it, Swift calls it)

```c
#define CMUX_GOO_OUTLINE_POINTS 24      /* cubic segments per outline */
#define CMUX_GOO_KEYFRAMES_MAX 120

typedef enum { CmuxGooLevelOff = 0, CmuxGooLevelSubtle = 1, CmuxGooLevelFull = 2 } CmuxGooLevel;
typedef enum { CmuxGooEventSelect = 0, CmuxGooEventOpen = 1, CmuxGooEventClose = 2, CmuxGooEventCloseLast = 3,
               CmuxGooEventReorder = 4, CmuxGooEventSnap = 5, CmuxGooEventAbsorb = 6 } CmuxGooEvent;

typedef struct { double response; double damping_fraction; } CmuxGooSpring;
typedef struct {
  CmuxGooSpring select, open, close, reorder, snap, absorb, wobble;
  double stretch, lean, feet_scale, k, break_distance, capture_distance, wobble_amplitude;
} CmuxGooTuning;

/* One edge or scalar in flight: closed-form spring from (x0, v0) toward target, started at `start` (media time). */
typedef struct { double x0, v0, target, start; CmuxGooSpring spring; } CmuxGooTrack;

/* The blob's geometry in the strip's layer coordinates (flipped: baseline is the card's top, y grows down). */
typedef struct { double left, right, top, baseline, corner_radius, feet_radius; bool skips_leading; } CmuxGooBlob;
typedef struct { double x, y; } CmuxGooPoint;
/* 1 + 3*N points: a closed path of N cubics (move-to p0, then (c1, c2, p) per segment). */
typedef struct { CmuxGooPoint p[1 + 3 * CMUX_GOO_OUTLINE_POINTS]; } CmuxGooOutline;

CmuxGooTuning cmux_goo_tuning_for_level(CmuxGooLevel level);
/* x and velocity of `track` at `t` (media time). */
void cmux_goo_track_state(const CmuxGooTrack *track, double t, double *x, double *v);
/* The track restarted at `t` from its state there toward `target`, velocity kept (interruption). */
CmuxGooTrack cmux_goo_track_retarget(const CmuxGooTrack *track, double t, double target, CmuxGooSpring spring);
/* Seconds from start until |x-target| and |v| fall under epsilon. */
double cmux_goo_track_rest_time(const CmuxGooTrack *track, double epsilon);
/* The blob's outline at rest (equals TabCell.folderPath's shape to < 0.5 px). */
void cmux_goo_blob_outline(const CmuxGooBlob *blob, CmuxGooOutline *out);
/* An event's keyframes: the blob's edges from `left`/`right` tracks (plus lean and wobble from `tuning`), sampled
   at `hz` from max(left.start, right.start); writes at most `capacity` outlines and their key times (0...1), and
   returns the count and the duration in seconds. reduce_motion: 1 keyframe (the end) and duration 0. */
size_t cmux_goo_plan(CmuxGooEvent event, const CmuxGooBlob *rest_from, const CmuxGooBlob *rest_to,
                     const CmuxGooTrack *left, const CmuxGooTrack *right, const CmuxGooTuning *tuning, double hz,
                     bool reduce_motion, CmuxGooOutline *outlines, double *key_times, size_t capacity, double *duration);
/* The drag neck: `slot` is the dragged tab's blob in the strip, `tab_*` the lifted tab's rect (same coordinates).
   attached = whether the neck holds; outline = the slot's blob merged with the neck (or the slot alone, detached).
   `was_attached` gives the hysteresis (break_distance out, capture_distance back). */
void cmux_goo_drag_neck(const CmuxGooBlob *slot, double tab_x, double tab_y, double tab_w, double tab_h,
                        bool was_attached, const CmuxGooTuning *tuning, CmuxGooOutline *out, bool *attached);
/* A neighbour's smooth union with the blob (full only): the blob merged with a rounded rect within k. */
void cmux_goo_neck(const CmuxGooBlob *blob, double x, double y, double w, double h, double radius,
                   const CmuxGooTuning *tuning, CmuxGooOutline *out);
```

Swift names: `CCmuxMotionFFI` (the existing module). A Swift wrapper `GooPlan` (CmuxNextTabs) turns outlines into
`CGPath`s, with one `CGPath` per keyframe and nothing per frame.

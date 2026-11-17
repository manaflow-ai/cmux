# Live wallpapers

Leo, 2026-11-17, on a blog index whose covers look like prints:

> actually, now that i see more of these... we could make these. more than that, we can make these WITH
> MOTION. new: textures that move around in cmux! we have static wallpapers, we have moving wallpapers...
> now we have wallpapers that run under code! that you can interact with with your mouse! these are great
> samples to build out ourselves!

References: cmux-design-references, topic `blog-and-changelog-art` (7 screenshots, `apps/devin/web/blog-*`).

## What it is

A third kind of window backdrop, next to pictures (`.art`, `.system`, `.file`, `.desktop`) and moving
wallpapers (videos). A live wallpaper is a small program: one WGSL fragment function that the GPU runs
for each pixel of the backdrop. The host gives it time, the pointer and its velocity, the backdrop's
size and the theme's colors. Nothing else goes in or out. Nothing is replaced: pictures and videos keep
working as they do, and a live wallpaper is just one more choice in the same picker.

The same program also makes still images. A still is one frame at a fixed time and pointer, and that is
how a blog or changelog cover is made: the cover is a frame of a wallpaper with the title set over it.

## The program

A wallpaper is a folder:

```
grain-silk/
  wallpaper.json   the manifest
  wallpaper.wgsl   the program
```

`wallpaper.wgsl` defines one function and any helpers it needs:

```wgsl
fn wallpaper(px: vec2<f32>) -> vec4<f32>
```

`px` is the pixel's position in backing pixels, origin top left. It returns a premultiplied color in
linear light. The host adds the rest: the `Frame` uniform below, the entry points (a full-screen
triangle and `fs_main`, which calls `wallpaper`) and the color encoding. A program may not declare a
binding, an entry point, a texture, a sampler, a storage buffer, `var<workgroup>` or `var<private>`
state. Every frame is a pure function of `frame` and `px`.

```wgsl
struct Frame {
    time: vec4<f32>,      // x seconds since shown, y seconds since the last frame, z frame number, w still (1 in a still)
    size: vec4<f32>,      // x, y size in rendered pixels; z rendered pixels per point (screen backing scale x manifest scale: 1.0 on a 2x screen at scale 0.5); w seed (0..1, per window)
    pointer: vec4<f32>,   // xy position in backing pixels (top left origin); zw velocity in backing pixels per second, smoothed
    presence: vec4<f32>,  // x pointer inside the window (0 or 1, eased), y seconds since it last moved, z button down, w dark appearance (0 or 1)
    ink: vec4<f32>,       // theme text color, linear, a = 1
    paper: vec4<f32>,     // theme window background, linear, a = 1
    accent: vec4<f32>,    // theme accent, linear, a = 1
    params: array<vec4<f32>, 2>, // the manifest's params in order, up to 8 floats
}
var<uniform> frame: Frame;   // the host's binding; never declared by the program
```

Every field is a `vec4<f32>`, so the layout is the same in Metal, WGSL and GLSL std140: 144 bytes (nine `vec4<f32>`).

### Translation

cmux-wallpaper (Rust) parses the program with naga, checks it against the rules above, and writes
Metal Shading Language for the Mac and GLSL ES 3.00 for the gallery and the cover renderer. One source
makes the live wallpaper, the gallery and the still.

First-party programs are translated at build time: cmux-wallpaper's build script runs the check and
the translation on every `wallpapers/<id>/` program (a refused program fails the build) and embeds the
Metal next to the source. The app links no shader compiler: it reads the embedded Metal
(`cmux_wallpaper_first_party_msl`) and never compiles WGSL itself. The run-time check and translation
are cmux-wallpaper's `compile` feature (naga is about 1.8 MB of machine code), which no shipped binary
turns on.

Community wallpapers: a package's program is checked by author tooling built with cmux-app-manifest's
`wallpaper-programs` feature. Loading community wallpapers in the app is a later step: it needs a
decided place to translate them that keeps the compiler out of the app and daemon.

## The manifest

```json
{
  "id": "grain-silk",
  "name": "Grain and Silk",
  "description": "Film grain drifting over slow silk folds; the fold under the pointer lifts.",
  "shader": "wallpaper.wgsl",
  "fps": 30,
  "scale": 0.5,
  "interactive": true,
  "params": [
    { "name": "speed", "title": "Speed", "default": 0.4, "min": 0, "max": 2 }
  ],
  "still": { "time": 14.0, "pointer": [0.62, 0.42] }
}
```

- `fps`: the program's own cap, 1 to 60. The host takes the lower of it and Settings' cap.
- `scale`: the backing scale it renders at, 0.25 to 1. Grain and soft fields look the same at half
  scale for a quarter of the pixels.
- `interactive`: whether pointer motion wakes it (below).
- `params`: up to 8 floats, shown nowhere yet; a theme file or `cmux.json` may set them.
- `still`: the time and pointer (fractions of the size) a still uses when the caller gives none.
- `variants`: up to a few named looks (`name`, `accent` `#RRGGBB`, `params` by name, `themes`), each
  with an optional `still` of its own, since a fold or ridge that catches the pointer at one scale
  misses it at another.

A community wallpaper is an extension: its `cmux-app.json` lists it under `contributes.wallpapers`
(`{ "path": "wallpapers/grain-silk" }`), and cmux-app-manifest checks the folder: always its
`wallpaper.json` and the program's presence and size, and the program itself only when built with
`wallpaper-programs` (otherwise the report says `wallpaper.programNotChecked`). It needs no capability: a wallpaper cannot read files, the network, the screen or the
clipboard, and it gets only the `Frame` above.

## When it draws (cost)

The scheduler is pure Rust (`cmux_wallpaper_schedule`). The host asks it after every event that could
change the answer and on each frame; it answers `hold` or `run` at an interval.

- Hold, at zero GPU and CPU work (the display link is stopped, no timer runs), while the window is
  occluded or nearly all covered (`BackdropCoverage`), minimized, hidden with the app, on a sleeping
  screen or in an inactive session; in Low Power Mode; at serious thermal state; with Reduce Motion or
  animations off.
- Idle: when nothing has happened for 20 seconds (no pointer motion over the window, no key press in
  it, no change of size or theme), it holds on the frame it is on. Pointer motion over the window, a
  key press or a theme change wakes it, and it eases back in from the held frame (time continues from
  where it stopped, so there is no jump).
- Run at `min(manifest fps, Settings cap)`, 30 by default, with the display link's preferred frame rate
  set to it. The cap applies while the pointer moves too.
- A frame whose GPU time passes 4 ms three times in a row halves the scale; at 0.25 it holds and the
  picker marks the wallpaper as too heavy for this Mac.

The held frame is the last drawn one, so a held wallpaper looks like a picture. A window that opens
while held draws one frame and holds.

## Light

When Wallpaper Lighting is on (cmux#45022 and its step 2), a live wallpaper gives the light field one
still: a 256-pixel-wide frame at its `still` time, made once when the wallpaper is chosen or the theme
changes, read with `WallpaperLightField.read` and handed over with the step 2 setter. It is never fed
per frame: the field changes only per picture.

## Settings

- The picker (Settings > Appearance > Window Background) gets a "Live wallpapers" group after Moving
  wallpapers. Each thumbnail is the wallpaper's still. Choosing one sets `appearance.background` to
  `live:<id>` (first party) or `live:<extension>/<id>`.
- One row, `appearance.liveWallpaperFrameRate`, after Wallpaper Tint in the same group: 15, 30 (default)
  or 60 frames per second.

## The first-party set

Our own takes on the references, each one program:

1. Grain and Silk: drifting film grain over slow silk folds; the fold under the pointer lifts.
2. Particles: a dithered particle field that parts around the pointer and closes behind it.
3. Halftone: halftone waves whose dots swell where the pointer passes.
4. Orbits: fine orbit linework; the pointer bends the nearest orbit like a mass.
5. Metal: embossed brushed metal with light that follows the pointer.
6. Blueprint: a blueprint grid with dimension ticks; the pointer draws a crosshair and the grid breathes.

Each is mostly the theme's paper and ink with one accent.

## Code

| Part | Where |
|---|---|
| Manifest, validator, translation, scheduler, uniform packing | `cmux-tui/crates/cmux-wallpaper` (Rust) |
| C ABI (`cmux_wallpaper_*`, its own ABI version) | `cmux-tui/crates/cmux-app-ffi/src/wallpaper.rs` |
| First-party programs | `cmux-tui/crates/cmux-wallpaper/wallpapers/<id>/` |
| `contributes.wallpapers` | `cmux-app-host` schema v2 and `cmux-app-manifest` |
| Gallery and still renderer (WebGL2, the translated GLSL) | `design/live-wallpapers-gallery/` |
| The view (CAMetalLayer, display link, events into the scheduler) | `CmuxNextDesign/BackdropLiveView.swift` |
| `.live` selection, catalog group, Settings row | `BackdropSelection`, `BackdropCatalog`, `schemas/settings/source/appearance.json` |

Step 1 lands the Rust, the C ABI, the programs and the gallery. Step 2 lands the Swift once
app-ffi-release repins the binary with the `cmux_wallpaper_*` symbols, as cmux#45022 does.

## Measures

One harness (`scripts/cmux-next/wallpaper-cost.sh`, on one Mac) records the app's CPU (process time
per second), GPU (Metal GPU time per second from the view's command buffers, and `powermetrics` GPU
active residency) and RAM (phys_footprint) for 60 seconds each in: a picture backdrop (before), each
live wallpaper running, idle (no input), occluded, minimized and in Low Power Mode. Held states must
match the picture backdrop within noise.

# cmux-next liquid glass: one lens primitive for every web surface

Status: in progress (2026-10-20, lane `glass-lens`).

## Ask

Leo, 2026-10-20: iOS-style liquid glass refraction (lens / fisheye edge bending, a
specular rim) on as many cmux NEXT surfaces as possible, so the wallpaper shines
through. That means the composer, message bubbles, the queued-prompt card, menus and
popovers, hover cards, link cards, the Updated card, and the thinking dots. The look
comes first, but scrolling a long transcript on a laptop must not drop frames.
There are three modes: Plain glass (the default: blur only, the look before this
change), Lens and Spectrum (lens plus chromatic dispersion at the rim). Leo
(2026-10-21): the lens is a toggle to see and feel first, so it is a Debug choice
(DEV and NIGHTLY), not a setting. Toggle Liquid Glass Lens in the palette or the
Debug menu flips it live. When the lens is promoted it becomes a Settings >
Appearance control (and maybe the default).

## Why the lens can't be a backdrop filter

- **WebKit can't refract the backdrop.** WKWebView parses
  `backdrop-filter: url(#svg-filter)` but renders nothing for it. A probe on macOS 27
  with Playwright WebKit (2026-10-20) showed stripes behind the element untouched,
  where Chromium bent them. `filter: url(#svg-filter)` on the element itself works in
  both engines.
- **The wallpaper isn't in the page.** cmux draws it natively (`WindowMaterialView`,
  per pane `PaneContentView+Backdrop`) behind web views that have no background. A
  page has no pixels of it to bend.

So the host gives each page a still of the wallpaper as it is drawn, and the page
lenses its own copy of it.

## Design

### Host (Swift)

- **Mode.** The Debug Settings choice `glass.lens` (Glass and Overlays > Liquid
  Glass) is one of `plain` (the default), `lens` or `spectrum`, and lives in the
  build's debug-tunables.json, outside the settings schema. Release never activates
  Debug Settings, so it draws `plain`. The effective mode is `plain` under Reduce
  Transparency or Low Power Mode. `WebTheme` sends the effective mode, and the
  bootstrap sets it as `data-glass` on `<html>`. The theme is pushed again whenever
  the choice, Reduce Transparency or Low Power Mode changes.
- **Backdrop.** The bootstrap defines `window.cmuxTheme.backdrop(partial)`. It merges
  the payload into `window.cmuxBackdropState` and dispatches `cmux-backdrop` on
  `window`. The payload has these fields:

  | Field | Meaning |
  | --- | --- |
  | `image` | The art as drawn, before its blur, as a `data:image/jpeg` URL no wider than 1024 px. It is `null` when there is nothing still to refract: no art, a moving wallpaper, or the desktop through Clear Glass. |
  | `key` | Changes exactly when `image` changes. `image` is sent only then. |
  | `rect` | `{x, y, width, height}`: the art's aspect-filled rect in the page's CSS px, relative to the page viewport. It is sent again when the web view moves or resizes in the window. |
  | `blur` | The art's own blur radius, in CSS px. |
  | `tint` | The native wash over the art, as a CSS color with alpha, or `transparent`. |

### Web: `webviews/src/ui/glass/`

- **Tokens** on `:root`:
  - `--glass-tint`: the fill. It is a translucent mix of the theme's surface. It is
    never opaque and never the accent.
  - `--glass-blur`: the frost inside the glass.
  - `--glass-refraction`: how far the rim bends, in px.
  - `--glass-rim`: the specular highlight's strength.
  - `--glass-dispersion`: the chromatic split, which only Spectrum uses.
  - `--glass-opaque`: the surface's fill under Reduce Transparency. glass.css holds
    every `.ui-glass` opaque there with `!important`, whatever tokens the surface set.
  - `--glass-join`: `top`, `bottom` or `both`, the edges that continue into a
    neighbouring glass (the queued prompts on the composer). The lens carries the
    shape on past a joined edge, so it bends no rim at the seam, and clips the glass
    to the box.

  A surface can override any token on itself.
- **`.ui-glass`** is the only class a surface adds. It paints the tint, the
  backdrop blur and the thin top-lit specular rim (with color fringes under
  Spectrum). Under `data-glass="plain"`, Reduce Transparency, or before the host
  says anything, it is today's blur glass.
- **The lens.** One WebGL canvas per document sits behind all content (fixed, at
  z-index -1 in the root stacking context). For every visible `.ui-glass` it draws
  the host's wallpaper still, aligned to `rect` and composited under the same native
  tint and page surface color. Inside the glass's rounded rect, the image is
  displaced inward along the edge normal across a rim band, and blurred by
  `--glass-blur`. Spectrum samples R, G and B at different strengths.
  - Outside the glass, the copy continues for a margin and fades out. There it
    equals the native wallpaper, so a frame where scrolling runs ahead of the canvas
    shows no ghost shape.
  - Rects are read in a `requestAnimationFrame` loop that runs only after scroll,
    resize, DOM or animation events, and stops once the rects are stable. Each rect
    is clipped by its scrolling ancestors.
  - It does no work when the mode is `plain`, when there is no image, or when no
    glass is on screen.
- **Gallery.** A fixture wallpaper is painted as the page background and passed
  through the same `cmuxTheme.backdrop` call, so Linux gallery captures show the
  same code path the app runs.

## Surfaces

Each owning lane keeps its layout. Adoption swaps a surface's own fill, blur and rim
for `.ui-glass` and its tokens. Under Plain glass each keeps the look it had before
the lens.

| Surface | Adopted as |
| --- | --- |
| composer card | `.ui-glass` over art or a see-through window; the solid composer surface on an opaque one. Its ring stays the edge, the glass's specular rim sits inside it. |
| location strip | the card's glass tint and frost, no class of its own (the New Tab shares the strip) |
| queued prompts and their fold | `.ui-glass`, joined to the card (`--glass-join`); their fill is the card's glass tint |
| user bubbles | `.ui-glass` with the bubble's 12% text tint and no blur of its own |
| menus, context menus, popovers, pickers | `.ui-glass` on every `.ui-popup` (popupSurface.css) |
| hover cards, link cards, the Updated card | `.ui-glass` (`.ui-card.ui-glass`) |
| jump to latest | `.ui-glass` disc |
| thinking dots | unchanged: 3-4 px, the rim moved almost nothing and the tint would replace the accent |

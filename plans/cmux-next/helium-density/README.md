# Browser chrome density: Helium at Default, Chrome's sizes at Spacious

Lawrence, 2026-11-13: the browser pane's tab bar and omnibar match Helium pixel for pixel at Default; Compact is
the same design on 20 pt rows; Spacious keeps Helium's shapes, radii, icons and colours at Chrome's sizes and
paddings. Owner of this pass: a1169 (took over Lucas's #42393, #42717, #42793).

## What is here

| Path | What |
| --- | --- |
| [source-values.md](source-values.md) | Every value read from Helium's patches and Chromium 157's source, with links. The short table is in [design-tokens.md](../spec-proposals/visuals/design-tokens.md), "Browser chrome: Helium and Chrome source values". |
| `refs/` | 2x captures from cmux-lawrence-2 (Helium 0.21.3.1, Chrome 157), the window's top 200 px, light and dark: rest, inactive-tab hover, x hover (active and inactive tab), new-tab hover. |
| `user-shots/` | Lawrence's screenshots from the density thread (Chrome's many tabs, tab search, extensions, vertical tabs; the stray line under the docked Home). |
| `tools/ref-shots.sh`, `tools/hover-shots.sh` | Take the reference captures on cmux-lawrence-2 (cua daemon `get_window_state`, `mouse` posts the hover). |
| `tools/cmux-shots.py` | cmux's chrome at each density, light and dark, through a running build's socket (`debug.window_snapshot`). |
| `tools/sheet.py` | Stacks labelled crops into one comparison sheet. |
| `tools/fit_radius.py` | Fits a corner radius to a capture's anti-aliased edge. |

## The values per density

| Density | Row (tab, omnibar, buttons) | Gap (above, between, under) | Top chrome | Corner | x square / corner / ink / to tab end | Omnibar chip / text start |
| --- | --- | --- | --- | --- | --- | --- |
| Compact | 20 | 2 | 46 | 6 | 10 / 3 / 5.5 / 4.5 | 2 / 22 |
| Default | 28 (Helium) | 3 | 65 (Helium) | 8 | 14 / 4 / 8 / 6 (Helium) | 2 / 31 (Helium) |
| Comfortable | 31 | 4 | 74 | 9 | 15.5 / 4.5 / 9 / 6.5 | 2 / 34.5 |
| Spacious | 34 (Chrome) | 6 (Chrome) | 86 (Chrome) | 10 | 17 / 5 / 9.5 / 7.5 | Chrome's column |

At every density the x's hover is Helium's: the tab's most-contrasting ink at 16 % (14 % pressed), shown at once
with no fade, and the x keeps the title's color (Chromium's tab_close_button.cc, which Helium keeps).

Defaults live once in `BrowserChromeTuning` (CmuxNextDesign) and the density presets' `browserRowHeight` and
`browserRowGap` tokens.

## Density Overlay Playground

Command Palette "Debug: Density Overlay Playground" (DEV and NIGHTLY; the palette lists it after the app FFI re-pin
that carries `debug.densityOverlayPlayground`). Debug Settings > Browser Chrome tunes the same values until then.

1. Open a browser pane with its omnibar in a cmux window.
2. Open the playground. Pick a reference (`refs/` in a dev build of a checkout, or Choose Image).
3. Overlay (opacity), Difference (black where equal), Flip (click the canvas to swap), Side by Side; Zoom is a
   pixel loupe; the arrows move the reference a pixel; Tolerance ignores anti-aliasing.
4. Controls opens every density's values; a change redraws the chrome and the diff at once (Live). Copy Values
   exports them as Swift constants for the presets.

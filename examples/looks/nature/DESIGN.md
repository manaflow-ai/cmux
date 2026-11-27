# Nature: design notes

The wallpaper leads. Chrome is the clearest glass the Mac draws, so the picture is the look; the
colors only keep text readable on it and bring one leaf-green accent.

## References

| Reference | What Nature takes |
| --- | --- |
| The macOS 26 Liquid Glass material, clear variant | Glass belongs to the layer that floats over content; the clear variant shows the most of what is behind it. |
| [Aurora](../aurora) in this folder | The layer split: chrome on glass, content near solid, accent used sparingly, one theme file for light and dark. |
| Settings > Appearance, the Clear preset (0.35, `glass-clear`) | The material and the starting opacity. |
| Moss, lichen, bark | The palette: a green-black ground and lichen text in dark; a pale green-white ground and bark-green ink in light. |

## Decisions

| Setting | Value | Why |
| --- | --- | --- |
| `appearance.backgroundBlur` | `glass-clear` | The clearest material, so the picture shows. |
| `appearance.background` | `none` | No painting. |
| `appearance.wallpaperTint` | `true` | The glass leans toward the picture's hue. |
| `appearance.backgroundOpacity` | `0.5` | See the three variants below. |
| `appearance.surfaces.agentPane.opacity` | `0.86` | The content plane; the least that gives 10:1 text on the worst picture. |
| `browser.omnibar.glassTint` | `accent`, 0.1 | A faint leaf in the address bar. |

## Three window opacities compared

Primary text over the window tint at the opacity, over a pure black, a mid-gray and a pure white
picture (WCAG ratio, computed from the tint colors in `themes/nature.json`).

| Opacity | Dark text: black / gray / white picture | Light text: black / gray / white picture | Verdict |
| --- | --- | --- | --- |
| 0.35 (the Clear preset) | 17.5 / 5.9 / 1.9 | 2.2 / 6.9 / 15.6 | Passes only on mid-tones; the picture dominates the text. Too clear. |
| 0.50 | 17.1 / 7.5 / 3.0 | 3.8 / 8.3 / 15.4 | Kept: 7.5:1 and 8.3:1 on a mid-tone picture, the picture still leads. |
| 0.62 | 16.8 / 9.2 / 4.4 | 5.6 / 9.7 / 15.3 | Readable almost everywhere, but the chrome starts to read as tinted glass, not the picture. |

At 0.50, a pure white picture under the dark theme (3.0:1) or a pure black one under the light theme
(3.8:1) is below 4.5:1. That is the cost of letting the wallpaper lead; a person who runs such a
picture can raise the Opacity in Settings, or turn on Reduce Transparency, which paints the theme
background opaque.

The chat plane at 0.86 gives primary text 10.3:1 (dark over white) and 10.7:1 (light over black) at
worst. The terminal colors in each appearance (not slots 0 and 15 in the theme whose ground they are) hold 4.5:1 or more over that plane on both extremes
(the dim gray, slot 8, 3.9:1 or more).

## Measured and not measured

Measured: the contrast numbers above (computed). Not measured: a capture on a Mac. This folder was
written on a Linux VM with no GUI, so screenshots are not included; the test that installs the look
and the check on its stylesheet run in CI.

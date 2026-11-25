# Glass looks: what is native, what is CSS

Four opt-in looks, each one profile file. Each one only sets keys that exist on feat-cmux-next today,
and none needs a rebuild.

```sh
cmux customize use examples/customize-demo/glass/liquid.json   # on, live, nothing kept
cmux customize discard                                         # off again
```

| Look | What it shows |
| --- | --- |
| `liquid.json` | Clear Liquid Glass over Hokusai's wave. The painting bends through the sidebar, the tab bar and the floating panes, with no borders. A 55% dim sits under the chrome and 65% under text. |
| `chrome.json` | Liquid Glass on the controls only: the sidebar, its cards and group headers, the tab strip and the address bar, over Monet's water lilies. The terminal, chat and pages are solid cards. |
| `mica.json` | Mica: your own desktop picture, frosted to a wash of color under dense graphite. The content is one step lighter than the frame, with outlined cards and trays. |
| `tinted.json` | Liquid Glass over the live desktop, stained indigo. Workspace groups take aurora gradients on glass headers, and the cyan accent tints the address bar's glass. |

Edit a folder (`<look>/profile.json`, `<look>/themes/glass-<look>.json`, `<look>/agent-pane/theme.css`),
then run `python3 examples/customize-demo/glass/bundle.py`. `--check` exits 1 while a bundle is stale.

## Native (the app draws it, from the theme file)

The settings below drive the Mac's own materials. On macOS 26 and later that is Liquid Glass
(`NSGlassEffectView`). Before macOS 26 the glass styles fall back to a 20 pt frost, and Reduce
Transparency makes the window opaque.

| Key | Native effect | Used by |
| --- | --- | --- |
| `appearance.backgroundBlur` | `glass` (regular Liquid Glass), `glass-clear` (clear Liquid Glass), `frosted` (behind-window blur; over a picture it blurs the picture) | liquid `glass-clear`, chrome `glass`, tinted `glass`, mica `frosted` |
| `appearance.background` | the picture under the glass: a bundled painting, `desktop`, or `none` (the live desktop) | liquid `hokusai-great-wave`, chrome `monet-water-lilies`, mica `desktop`, tinted `none` |
| `appearance.backgroundOpacity` | how much theme tint covers the material | all |
| `appearance.glassTransparency` | takes part of that tint off again, so more shows through | all |
| `appearance.wallpaperTint` | the glass takes the desktop picture's colors | all |
| `appearance.sidebarSurface` + `appearance.surfaces.<surface>.color/.opacity` | a tint per surface over the one window glass. Below 1 the glass shows through. Surfaces used: sidebar, tabBar, terminal, agentPane, newTabPage, home, internalPage, markdown, browserChrome, splitDivider | all |
| `browser.omnibar.glass`, `.glassTint`, `.glassTintStrength` | the address bar's own glass (regular or clear) and its tint | all |
| `sidebar.groupHeader.background: glass`, `sidebar.groupPalette`, `sidebar.groupGradient` | group headers on the `chrome` glass level; group colors from glass, wallpaper or a gradient | all |
| `sidebar.sectionLook` (card, tray), `appearance.chromeStyle` (floating, card, card-outlined), `appearance.borders`, `sidebar.border/borderWidth`, `layout.paneCornerRadius`, `density.tokens` | the shape and edges the glass sits in | all |

## CSS (web pages, from `agent-pane/theme.css`)

Popovers, menus, the composer and hover cards in the agent pane are web glass (`webviews/src/ui/glass/glass.css`):
`backdrop-filter` blur plus a tint, tuned to match the native level. A look can retune that glass
only through CSS variables:

- `liquid/agent-pane/theme.css`: a tint floor (`--ds-glass-chrome-tint` 70%, `--ds-glass-popover-tint`
  74%, `--ds-glass-popover-art-tint` 70%, `--ds-glass-chip-tint` 72%) keeps text at 4.5:1 over a
  bright painting. It also sets `--glass-material-saturate: 2`.
- `tinted/agent-pane/theme.css`: a vivid frost (`--glass-material-saturate: 2.1`), a 72% popover tint,
  and links and the caret in the accent.

These are page-internal variables, not a published API, so a webviews change can rename them.
`chrome` and `mica` carry no CSS.

## Would look better with unmerged PRs

- **cmux#47206** (the carry of #46118, `.glass(level)` and the kit `Glass`): would let a customize view put
  native glass at the `chrome`/`popover`/`menu`/`chip` levels under its own pieces, for example glass widgets and
  cards in the sidebar or Session Info. It also adds `docs/cmux-next/glass.md`. Today only `Panel` sits on glass.
- **cmux#47161** (taste: inset glass sidebar): a sidebar floating as its own inset glass panel. Today
  `liquid` gets closest with `chromeStyle: floating` and a separate sidebar.
- **cmux#47172** (taste: glass toolbar groups): toolbar buttons grouped on glass capsules. No key exists for this today.
- Not in a PR yet:
  - The glass engine's lens (`lane/glass-engine-lens`, not yet a PR). It would give the web glass the same
    refraction as the native glass.
  - A true Mica window material (a desktop-tinted background with no live blur cost). The idea went to the
    glass-engine lane; `mica.json` imitates it today with `frosted` over `desktop` and a dense tint.
  - Any setting that picks a glass level for a surface, or a published glass-tint token for themes, so the
    CSS above becomes keys.

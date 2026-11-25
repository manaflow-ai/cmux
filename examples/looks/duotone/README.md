# Duotone

Duotone v0.2, a drop-in look. It changes no default; remove it and everything you had comes back.
The design system it sits beside is Instrument v0.1; Duotone is the two-tone variant of it: two
tones of one neutral gray and a neutral selection.

The window has two tones: the **chrome** (sidebar, toolbar, tab bar, docks) and the **work** (the
pane you are in). Nothing is separated by hue, and the selected row is drawn in the ink at low
strength, never in an accent colour.

## What the capture measures

Sampled from the look's golden capture (`bun run golden:looks --setup examples/looks/duotone`, the
test window, 1280 wide):

| | Work | Sidebar | Step | Selected row | Row against sidebar |
| --- | --- | --- | --- | --- | --- |
| Duotone (Light) | `#FFFFFF` | `#F5F5F5` | 1.090:1 (0.03 OKLCH L) | `#E7E7E7` | 1.13:1 |
| Duotone Dark | `#202020` | `#191919` | 1.079:1 (0.03 OKLCH L) | `#292929` | 1.21:1 |

- The light selected row is 1.13:1, under the 1.15:1 floor Instrument names. The test window draws
  a neutral selection as the ink at 6% (8% in Dark); a look has no setting for that strength.
- Ink on the selected row: 14.6:1 Light, 11.9:1 Dark. Unselected row text on the sidebar: 5.1:1
  Light, 6.9:1 Dark.
- In Dark the chrome is the darker tone. Instrument v0.1 makes the page the extreme in both
  schemes; Duotone keeps its own order here.

## What it does not set

- **The tab bar's tone in the test window.** The theme files set
  `appearance.surfaces.tabBar.color`, which the app reads; the test window reads only the sidebar
  and agent pane surfaces, so the capture draws the tab bar in the work tone.
- **The joined tab and the joined selected row.** v0.1 claimed the selected tab runs into the pane
  as one shape. No setting on main draws that (the tab shape waits on cmux#46780), there is no
  capture of it in the app, and this version does not claim it. `appearance.cornerFlush:
  flush-goo` is set and takes effect where a build supports it.
- **A curvature-continuous corner.** It needs a native change; today's fillet is a circular arc.
- **Radii per role, row insets and toolbar button sizes** (cmux#46861). They are comments in the
  theme files, naming the change they wait for.
- **`appearance.selection`** (cmux#46516, not on main). Until it lands the look gets its neutral
  selection from `appearance.accent: neutral`, which also makes focus and the Send button neutral.
  The only hue left is the terminal's cursor and text selection.
- **Text the look does not own.** The composer's effort label (2.9:1 Light, 3.7:1 Dark as sampled)
  and the sidebar's section label (3.4:1 Light, 4.6:1 Dark) are drawn by cmux's own styles. The
  look's own secondary inks are 72% and 62% of the ink (6.7:1 and 4.9:1 on the work, computed).
- **Glass.** Both theme files are opaque so the step is the same number over any wallpaper.

## Files

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Version 0.2.0. Picks the theme file; a 756 px reading column; theme colors for diffs and sidebar groups; an 8 px address field |
| `themes/duotone.json` | Default, Light. Work `#FFFFFF`; sidebar, tab bar and docks `#F5F5F5`; ink `#161616`; neutral accent; a `#D7D7D7` line between panes only |
| `themes/duotone-dark.json` | Dark. Work `#202020`; sidebar, tab bar and docks `#191919`; ink `#E8E8E8`; neutral accent; a `#333333` line between panes only |
| `agent-pane/theme.css` | Cards and your prompt one step toward the chrome tone with no ring, 8 px corners, secondary inks: `cmux.agentPane.style/1` tokens only |
| `markdown/theme.css` | Code a step toward the chrome with 8 px corners, headings with no rule: `--cmux-md-*` properties only |

Sizes follow one row height, H = 28: type 13, inset 6, strip and toolbar 40, sidebar 252, reading
column 756.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/duotone
cmux settings set appearance.themeFile duotone-dark    # duotone (Light) is the default
cmux setup remove manaflow-ai/duotone-look
```

Installing or removing it applies to open windows at once; no restart.

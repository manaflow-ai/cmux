# Duotone

Duotone v0.1, a design-system proposal shipped as a look. It changes no default.

The window has exactly two tones of one neutral gray: the **chrome** (sidebar, toolbar, tab strip)
and the **work** (the pane you are in). The selected tab takes the work tone and runs into the pane
as one continuous shape, so where you are is drawn, not highlighted. Nothing is separated by hue.

| | Work | Chrome | Step (OKLCH L) | Ink | Worst text contrast |
| --- | --- | --- | --- | --- | --- |
| Duotone (Light) | `#FFFFFF` | `#F5F5F5` | 0.03 | `#161616` | 4.89:1 (dim ink on the chrome) |
| Duotone Dark | `#202020` | `#191919` | 0.03 | `#E8E8E8` | 5.93:1 (dim ink on the work) |

The step is the same number in Light and Dark and does not change with what is behind the window,
because both theme files are opaque. The earlier two-tone default shaded the chrome with black at a
fixed alpha (0.28 dark, 0.045 light) over glass, so its step was 0.035 over a dark page and up to
0.09 over a bright wallpaper.

Every size is a fraction of one row height, H = 28: icon 16 (4/7 H), type 13, inset 6
((H - icon) / 2), corner 8 (2/7 H), strip and toolbar 40 (H + 2 insets), sidebar 252 (9 H),
reading column 756 (27 H, three sidebars).

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; a 756 px reading column; theme colors for diffs and sidebar groups; an 8 px address field |
| `themes/duotone.json` | Default, Light. Work `#FFFFFF`, chrome `#F5F5F5` (title area contrast 1.75 over an opaque ground), ink `#161616`, accent `#2F62D8`, a `#D7D7D7` line between panes only |
| `themes/duotone-dark.json` | Dark. Work `#202020`, chrome `#191919` (title area contrast 1.55), ink `#E8E8E8`, accent `#7AA7F7`, a `#333333` line between panes only |
| `agent-pane/theme.css` | Cards and your prompt one step toward the chrome tone with no ring, 8 px corners, secondary ink at 72% and 62% of the ink: `cmux.agentPane.style/1` tokens only |
| `markdown/theme.css` | Code a step toward the chrome with 8 px corners, headings with no rule: `--cmux-md-*` properties only |

What the look cannot set yet is written as comments in the files, each naming the change it waits
for: the tab shape and the selected sidebar row's join (cmux#46780), neutral selection
(cmux#46516), row insets and toolbar button sizes (cmux#46861). The curvature-continuous corner the
proposal specifies needs a native change; today's fillet is a circular arc.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/duotone
cmux settings set appearance.themeFile duotone-dark    # duotone (Light) is the default
cmux setup remove manaflow-ai/duotone-look
```

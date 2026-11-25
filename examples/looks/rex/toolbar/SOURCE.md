# Toolbar source evidence

Reviewed 2026-11-21 against cmux head
`f7230898ddfeed39c0f2b7a7c84869c92009b54d`.

## Vendor references

The [Mac settings catalog](https://www.superlogical.com/rex/docs/reference/mac-settings)
lists toolbar placement, tab behavior, icons and pane controls. The
[actions catalog](https://www.superlogical.com/rex/docs/reference/mac-actions)
lists split-right, split-down and zoom. The [source window](https://www.superlogical.com/rex-screenshot@2x.webp)
has SHA-256 `a7514745119404951bbc14651121640e2d802e2f96da93cb0548d4123f03ab8c`.

## Measured source pixels

These are approximate manual readings of the supplied **2114 × 1278 pixel**
raster, with origin at its upper-left. Bounds use an exclusive right/bottom edge;
anti-aliasing makes edge readings uncertain by roughly 2 pixels. The device scale
and source window's logical size are unknown. No pixel-to-point conversion or
SwiftUI metric is asserted.

| Region | Approximate pixel bounds or size | Proportion |
| --- | --- | --- |
| Space above pane cards | y = 0…92 | 7.20% of raster height |
| Upper-left pane card | x = 16…1145, y = 92…592 | 1129 × 500 px |
| Lower-left pane card | x = 16…1145, y = 607…1262 | 1129 × 655 px |
| Right pane card | x = 1161…2098, y = 92…1262 | 937 × 1170 px |
| Horizontal gap between cards | x = 1145…1161 | 16 px; 0.76% of raster width |
| Vertical gap between left cards | y = 592…607 | 15 px; 1.17% of raster height |
| Left/right outside inset | about 16 px each | 0.76% of raster width |
| Left share of content width, excluding gap | 1129 / (1129 + 937) | 54.65% |
| Upper share of left content height, excluding gap | 500 / (500 + 655) | 43.29% |
| Active top tab silhouette | x ≈ 405…847, y ≈ 15…79 | about 442 × 64 px |

The raster alone cannot establish the selected pane-style setting, hover state,
toolbar behavior setting, exact radii, material opacity, font metrics, or whether
the image was resized. No such values are recorded as measured facts.

## Chosen cmux preview values

The pack chooses 4 pt pane padding, 8 pt column gap, 12 pt corners, a 0.5 pt
border, and a 32 pt tab strip. These are schema-valid adaptation values, not
measured source points. They give inset surfaces and restrained controls using
the existing native chrome. The screenshot's 54.65/45.35 column ratio and
43.29/56.71 left-stack ratio are evidence only: the pack does not move or resize
the person's panes. It also does not infer a toolbar font size or titlebar height.

## cmux implementation references

All paths below are relative to the repository root:

- `schemas/settings/source/appearance.json`: Window Style, pane separation,
  pane padding, corner radius, border width, column gap, and borders.
- `schemas/settings/chrome-styles.json`: the `panes` style uses individual
  outlined panes and a sidebar edge line, without one enclosing main card.
- `schemas/settings/source/tabs.json`: `tabs.barPosition`,
  `tabs.toolbarButtons`, and `appearance.metrics.tabStripHeight`.
- `schemas/settings/source/general.json`: `window.titlebarButtons` and its
  sidebar-hidden scope.
- `cmux-tui/crates/cmux-action-catalog/src/catalog/pane.rs`: the three built-in
  action IDs, all with `targets: &["pane"]`.
- `Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Geometry/PaneChromeGeometry.swift`:
  actual gap composition and rounding below the hosted header.
- `cmux-tui/crates/cmux-customize/src/setup/reference.rs`: installation from a
  repository subdirectory with `@REF`.
- `examples/looks/basalt/cmux-setup.json`: setup/profile manifest precedent.

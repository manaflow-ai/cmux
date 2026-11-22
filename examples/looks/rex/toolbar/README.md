# Toolbar and pane chrome

An optional settings-only pack: inset rounded panes, a top tab bar, and native
Split Right, Split Down, and Pane Zoom buttons. It keeps the current color theme,
content, sidebar visibility, and workspace layout. It does not create the three
panes shown in the reference.

## Install or preview

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/rex/toolbar@lane/rex-feature-looks
```

To remove the installed layer, run `cmux setup remove manaflow-ai/rex-toolbar`.
To preview from the repository root, run the following commands, then choose
`cmux customize apply` or `cmux customize discard`.

```sh
cmux customize use examples/looks/rex/toolbar/profile.json
cmux customize check
```

## Mapping

| Source feature | cmux setting or action | Limit |
| --- | --- | --- |
| Toolbar above the panes | `tabs.barPosition: "top"` | cmux positions each pane's tabs, not one window-wide session strip. |
| Visible toolbar controls | `window.titlebarButtons: "always"` | This setting governs titlebar buttons while the sidebar is hidden; it does not change sidebar visibility or force hidden pane tab bars open. |
| Split right (`pane.split.right`) | `splitRight` in `tabs.toolbarButtons` | Acts on the current pane; uses cmux's existing split behavior. |
| Split down (`pane.split.down`) | `splitDown` in `tabs.toolbarButtons` | Acts on the current pane. |
| Zoom (`pane.zoom`) | `toggleSplitZoom` in `tabs.toolbarButtons` | Uses cmux's existing pane zoom. |
| Rounded outlined pane surfaces | `appearance.chromeStyle: "panes"`, `appearance.borders: "default"`, `layout.paneSeparation: "borders"` | cmux's content rounding excludes a reported tab header; it is not the source's whole-card contour. |
| Pane spacing | `layout.panePadding: 4`, `appearance.metrics.columnGap: 8` | cmux points chosen for preview, not source measurements. Columns use `max(columnGap, 2 * panePadding)`; split divider geometry can add space. |
| Pane corners and fine border | `layout.paneCornerRadius: 12`, `layout.paneBorderWidth: 0.5` | Chosen preview values. Corner radius also affects tabs, panels, popovers and cards according to the schema. |
| Compact header proportions | `appearance.metrics.tabStripHeight: 32` | Per-pane bar height; not a claimed source toolbar height. |

The source also offers Above/Below/Left/Right placement, toolbar auto-hide and
Hidden modes, pane-header hover behavior, equal-width tabs, and stacked pane
icons. This pack does not emulate these with new settings or custom actions.
The source's glass, background tint, icon artwork, window traffic lights, and
tab close behavior are outside this pack. Existing theme overrides or managed
settings may take precedence over the profile's settings.

## Evidence and verification

[SOURCE.md](SOURCE.md) separates image-pixel measurements from cmux preview
values and names the source and runtime references. All settings and the three
action IDs were checked against this checkout's schema and action catalog.

![Source window, with three terminal panes below the tab strip](../new-tab/screenshots/source-window.webp)

# Per-pane backgrounds (a245, user 2026-10-20)

Status: v1 BUILT on feat-cmux-next. Ask: "Make an option so that each pane can have its own
background instead of one background behind everything. Think of other edge cases like this
that people might want and implement it. Think from first principles."

## First principles

A background does three jobs, in this order:

1. **Legibility.** Text over it stays readable through the window's own opacity, blur and glass, applied the same way over every picture (Leo, 2026-10-20: no picture-dependent floor).
2. **Orientation.** It tells places apart at a glance: which window, which workspace, which pane
   (the agent's pane versus mine, prod versus dev, the pane I am typing in).
3. **Taste.** It makes the app the person's own.

Job 2 is why per-pane matters: one image behind everything says "this is cmux", not "this is the
prod shell". So a pane background is mainly a *marker*, and a marker must survive everything the
pane goes through (split, move, new window, restart), cost nothing when unused, and never cost
legibility.

## Model: one resolver, three levels

Precedence, most specific first: **pane > workspace > window (app)**. The window level is
`appearance.background`; the workspace level is the existing per-workspace pick (cx-t2x.5,
`WorkspaceBackgroundStore`); the pane level is new.

Each pane has its own `ThemeScope` (rooted at `PaneContentView`, under the workspace scope). It
pins nothing by default, so it inherits and nothing changes. A pane background pins the pane
scope (`ThemeScope.pinBackdrop`), so everything inside the pane (terminal hosts, pages, the
strip) sees the pane's art and stays see-through over it, the same way they already do over the
window's art. No owner reads a second source.

What the pane draws comes from one pure function, `PaneBackdropPlan.resolve` (CmuxNextDesign,
unit-tested): given the scope mode, whether the pane has its own background, its tint and the
backdrop of its scope, it returns `drawsArt`, the backdrop to draw, and the tint wash.

## The option the user asked for

`appearance.paneBackgrounds` (Settings > Appearance, CLI `cmux settings set`):

| value | meaning |
| --- | --- |
| `shared` (default) | One background behind the whole window, as today. |
| `perPane` | Every pane draws its own copy of the background, framed to the pane. Panes with their own pick show that. |

Default stays `shared` (R48 one-backdrop rule; nothing changes for anyone who does not opt in).

## Per-pane actions (one path; menu, palette, CLI, MCP)

| action | CLI | args | menu |
| --- | --- | --- | --- |
| `pane.setBackground` | `pane set-background` | `background`: `inherit`, `none`, `daily`, `desktop`, a painting id, `system:`/`file:` path | pane right-click > Pane Background (choices) |
| `pane.setTint` | `pane set-tint` | `color`: `none`, a named color (red, orange, yellow, green, teal, blue, purple, pink, gray) or `#RRGGBB` | pane right-click > Pane Tint (choices) |
| `pane.clearBackground` | `pane clear-background` | none | pane right-click |

All three target a pane (`--pane`, default the focused pane), so agents can mark their own pane
(`cmux pane set-tint --color purple`). MCP tools come from the same catalog.

## Edge cases (full list, ship now vs later)

| # | Case | Decision | Ship |
| --- | --- | --- | --- |
| 1 | Shared vs per-pane scope | `appearance.paneBackgrounds` `shared`/`perPane` | now |
| 2 | Per-workspace background | already shipped (cx-t2x.5) | done |
| 3 | Per-pane override image | `pane.setBackground` | now |
| 4 | Per-pane color tint (tell agent panes apart) | `pane.setTint`, a 12% wash over the pane, works in opaque windows too | now |
| 5 | Inherit rules | pane > workspace > window; `inherit` clears the pane level; `none` is plain glass even under art | now |
| 6 | Split | the new pane starts with no override (inherits). A split is a new place; copying a marker would make two "prod" panes | now (by construction) |
| 7 | Move a tab to another pane | the background belongs to the pane, not the tab; the tab takes its new pane's look | now (by construction) |
| 8 | Move a pane to another window or workspace | keyed by the pane's durable resource id, so it follows the pane | now |
| 9 | Close and restore / relaunch | app-local file `pane-backgrounds.json` (+ `pane-tints.json`) keyed `<session>/<pane resource id>`; daemon restore keeps resource ids | now |
| 10 | Panes without a durable id (old daemons) | no override offered (the action refuses with a reason) | now |
| 11 | Dim or blur inactive panes | already: Ghostty `unfocused-split-opacity` / `unfocused-split-fill` (ThemeBridge) | done |
| 12 | Legibility over busy images | the pane draws the window's tint and blur; Opacity and Material decide readability, never the picture | now |
| 13 | Window glass interplay | the pane copy draws art + tint only (no Liquid Glass view per pane); Window Glass keeps its art opacity | now |
| 14 | Light/dark variants | the shared art view picks the dynamic image's variant per appearance | now (reused) |
| 15 | Browser and Markdown panes | they are clear over art already (surface-backgrounds.md); they inherit the pane scope like terminals | now |
| 16 | Performance with 20+ panes | one decoded image per selection (`BackdropImageStore`); `CALayer.contents` shares it; no view at all in `shared` mode without an override | now |
| 17 | Reduce Transparency | the backdrop is opaque; the pane draws no art; the tint wash stays (it is a marker, not transparency) | now |
| 18 | Per-pane opacity slider | later: workspace has one; pane reuses its store shape | later |
| 19 | Settings UI picker per pane (tiles) | later: v1 uses the context-menu choices and CLI; the Settings picker gets a pane route like the workspace route | later |
| 20 | Daemon-synced pane backgrounds (other Macs, iOS) | later: move the entries into the daemon's pane record, like terminal themes moved | later |
| 21 | Per-tab background | rejected: a tab switch must not repaint the pane (tab-switch perf budget), and tabs already have themes | no |
| 22 | Video wallpapers per pane | allowed by reuse; many panes share one player per file (`BackdropVideoPlayers`) | now (reused) |
| 23 | Tint by agent automatically | later: agent panes could take the agent's cursor color; needs a12-style opt-in | later |

## Looks (gallery)

`design/pane-backgrounds-gallery.html`, opened as a Home right-pane tab. Four looks:

1. **Marker tint** (Recommended, the default for `pane.setTint`): shared art, each marked pane gets
   a 12% color wash. Legible, cheap, reads at a glance.
2. **Per-pane art**: `perPane`, each pane frames its own copy.
3. **Mixed**: shared art, one pane with its own painting (prod shell).
4. **Plain + tint**: no art; tints only (opaque windows).

## Tests

- `PaneBackdropPlanTests` (CmuxNextDesign): every mode x override x tint x Reduce Transparency.
- `PaneBackgroundsSettingTests` (CmuxNextSettings): parse, default, bad value diagnostic.
- `PaneBackgroundStoreTests` (app): key, set/clear, tint parse.

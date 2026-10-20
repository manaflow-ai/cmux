# Appearance scopes (a245, user 2026-10-20)

Status: DESIGN, phase 1 built (pane backgrounds, pane-backgrounds-DESIGN.md), phase 2 in progress.

Ask: "we need to be able to set theme/wallpaper per workspace and tab and pane etc… per window
etc.. think about first principles what people would like to customize and make it possible."

## First principles

People customize appearance for three reasons, in order of how often they matter:

1. **Orientation**: know where I am before I read anything. Prod vs dev, which repo, which
   agent, my pane vs the agent's, which window is the "work" window.
2. **Comfort**: read for hours. Font size for a pane on the projector, a lighter theme for
   one long-reading pane, less transparency where text is dense.
3. **Taste**: the app feels like mine. Wallpapers, themes.

So the system needs: every property settable at the level where the *meaning* lives (a repo, a
host, a pane, a window), a predictable inheritance, a way to see *why* something looks the way
it does, and a one-click way back to inherited.

## One cascade

Levels, least to most specific:

| level | what it is | key (persisted) | today |
| --- | --- | --- | --- |
| app | cmux.json `appearance.*` + Ghostty config | file | yes |
| window | a space (room); every window showing it | `space:<profile>` | theme yes (`space.setTheme`), others new |
| workspace | one workspace | `ws:<session>/<workspace key>` | theme yes, background + opacity yes (cx-t2x.5) |
| rule | `appearance.rules` match on cwd / git repo / ssh host / agent | file | new |
| pane | one pane (durable resource id) | `pane:<session>/<pane_…>` | background + tint (phase 1) |
| tab | one terminal or page | `tab:<terminal theme key>` | terminal theme yes (`terminal.setTheme`) |

A value set at a level wins over every less specific level. A **rule** sits between workspace
and pane: it describes *what is running* (repo, host, agent), which is more specific than the
workspace a person put it in, but a person's explicit pane or tab pick still beats it.

`reset` at a level removes that level's value, so the next level up shows again
("reset to inherited"). Nothing is ever copied down: changing the workspace theme changes every
pane that did not pick its own.

## Properties

| property | values | levels | applies through |
| --- | --- | --- | --- |
| `theme` | Ghostty theme name or `light:A,dark:B` | all | `ThemeScope.setOverride` (existing per-level scopes) |
| `background` | `appearance.background` vocabulary + `inherit` | app, window, workspace, rule, pane | `ThemeScope.pinBackdrop`; pane draws its own copy (phase 1) |
| `tint` | named color or `#RRGGBB` | window, workspace, rule, pane, tab | marker wash (`PaneBackdropPlan`); tab: strip chip color |
| `opacity` | 0...0.95 tint over art | app, window, workspace, pane | `pinBackdropTint`; a249 owns the app setting's behavior |
| `blur` | material choice | app, window | window-level only (one material per window, no glass per pane) |
| `fontSize` | points, 6...72 | app, workspace, rule, pane, tab | per-surface Ghostty config override line |
| `cursorStyle` | block, bar, underline, block_hollow | app, workspace, rule, pane, tab | per-surface Ghostty config override line |

Why not everything everywhere: blur is a window material (one glass view per window; per-pane
glass costs a GPU pass per pane and breaks the 20+-pane budget). Backgrounds per tab are
rejected: a tab switch must not repaint the pane (tab-switch latency budget), and a tab's own
look is its theme and tint.

## Rules (`appearance.rules`)

What people actually want to key on is not where a pane sits but what it is:

```json
"appearance": { "rules": [
  { "match": { "host": "*prod*" },           "set": { "tint": "red", "theme": "Rose Pine" } },
  { "match": { "repo": "manaflow-ai/cmux" }, "set": { "tint": "blue" } },
  { "match": { "cwd": "~/work/**" },          "set": { "background": "daily" } },
  { "match": { "agent": "claude" },          "set": { "tint": "purple" } }
] }
```

- `cwd`: glob on the terminal's working directory (`~` expands).
- `repo`: the git remote `owner/name` of the cwd's repo (already resolved for the sidebar).
- `host`: glob on the ssh/remote host of the terminal or workspace machine.
- `agent`: the agent harness of an agent tab (`claude`, `codex`, …).
- First matching rule per property wins (file order), so a specific rule goes first.
- A rule applies to a pane through its selected tab (the pane follows what it shows), and to a
  tab directly. Rules re-evaluate on cwd, host and agent change events only, never per frame.

## Showing where a value comes from

`cmux appearance show [--pane|--tab|--workspace|--window]` lists every property with its value and
source level (`pane`, `rule #2 (host *prod*)`, `workspace`, `app`). The same data drives:

- Settings > Appearance > "This Pane / Workspace / Window" section: each row shows the value
  and a source label ("From workspace"), with a reset button when set at that level.
- The right-click Appearance folder: a checkmark on the current value, and "Reset to Inherited"
  enabled only when that level has its own value.

## Actions (one path; menus, palette, CLI, MCP)

Generic, so every property and level shares one handler and one test matrix:

| action | CLI | args |
| --- | --- | --- |
| `appearance.set` | `appearance set` | `scope` (window, workspace, pane, tab), `property`, `value`, target |
| `appearance.reset` | `appearance reset` | `scope`, `property` (or `all`), target |
| `appearance.show` | `appearance show` | `scope`, target; returns value + source per property |

Plus the object-specific shortcuts that menus need (they call the same model):
`pane.setBackground`, `pane.setTint`, `pane.clearBackground` (phase 1), `workspace.setTheme`,
`space.setTheme`, `terminal.setTheme` (existing), and new `workspace.setTint`, `space.setTint`,
`tab.setTint`.

## Persistence

One app-local file per level kind is what exists today (workspace-backgrounds.json, terminal
themes, pane-backgrounds.json). Phase 2 adds `appearance-scopes.json`: `{ "<key>": { "<property>":
value } }` for the new properties (fontSize, cursorStyle, tint at window/workspace/tab), keyed as
in the table above. Existing stores keep their files (no migration risk); the cascade reads all
of them. Later the daemon's personal records take these fields so other Macs and iOS see them.

## Edge cases

- Split: the new pane has no own values (it inherits; markers are not copied).
- Move tab to another pane: tab values travel with the tab; pane values stay with the pane.
- Move pane/workspace to another window: keyed by durable ids, so values follow.
- Close + reopen closed tab/pane: the closed history keeps the resource id, so values return.
- Remote/ssh workspaces: keys include the session id, so two Macs never collide.
- Reduce Transparency: art and opacity drop; tints and themes stay (they are markers/colors).
- Light/dark: `theme` accepts `light:A,dark:B`; dynamic wallpapers pick their variant.
- Contrast: every tint is a 12% wash; theme choices keep the WCAG check of the app theme.
- Performance: values resolve on change events; no per-frame lookup; one decoded image per
  selection; per-surface Ghostty configs are cached by (theme, fontSize, cursorStyle).

## Phases

1. Pane background + tint, scope mode setting (BUILT).
2. Cascade model `AppearanceCascade` (pure, value + source), `appearance-scopes.json` store,
   `appearance.set|reset|show`, tint at window/workspace/tab. (in progress)
3. fontSize and cursorStyle per scope through per-surface Ghostty override lines.
4. `appearance.rules` (cwd, repo, host, agent).
5. Settings "This Pane / Workspace / Window" section with source labels.

Coordination: a249 owns the app-level opacity setting's behavior; a232 owns wallpaper captions;
both keep their keys, this system only reads them as the app level.

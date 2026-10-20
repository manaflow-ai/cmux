# Density, from first principles

Status: v1 landing on feat-cmux-next (Oct 20, Lawrence: "we need to rethink densities from first
principles like we need more options, and for font size to scale with it as well, i really like
how compact looks today though so let's not mess with that, make sure people can create their own
custom densities tho").

Same day, on the palette: "Sidebar Density: Compact" and "Use Compact Density" both showed for
"compact", and Enter did nothing. That is fixed here too.

## Problems today

1. **Two densities with the same names.** `appearance.density` (`Density`: compact, comfortable)
   sizes chrome tokens. `sidebar.density` (`SidebarDensity`: compact, comfortable, expanded) adds
   sidebar row height and insets on top. Both put "Compact" and "Comfortable" in the palette.
2. **Choosing the current value does nothing visible.** "Use Compact Density" while compact writes
   the same value. "Sidebar Density: Compact" returns early. To the user, Enter did nothing.
3. **Only two steps, and text does not follow.** `Metrics.pick(compact, comfortable)` is a
   switch. Typography has its own compact/comfortable pairs. Nothing between them, above them
   or below them.
4. **No custom densities.** The only path is `appearance.metrics.*` one key at a time, and the
   Settings page has no preview.

## Model: one token set, one level

A density is a **`DensityTokens`** value:

| field | meaning |
|---|---|
| `id` | stable key, `appearance.density` stores it (`compact`, `my-tight`) |
| `name` | display name (built-ins are localized; custom names are the user's) |
| `level` | where it sits on the compact→comfortable axis: 0 is Compact, 1 is Comfortable |
| `spacing` | multiplier for padding and insets (`Metrics.space1…6`), 1 is today |
| `fontSize` | chrome body size in points; nil means "follow the level" |
| `tokens` | optional exact values per metric (`sidebarRowHeight`, `tabStripHeight`, …) |

Every density metric already has a compact and a comfortable value (`MetricTunables`). A density
resolves each metric as `compact + (comfortable - compact) × level`, rounded to whole points (half
points for type). An explicit `tokens[name]` wins. Text sizes use the same rule on each
Typography style's compact/comfortable pair, then scale by `fontSize / bodyAtLevel` when a
custom `fontSize` is set. Line height follows from the font (we use font metrics, never fixed line
heights), so it scales with the font size.

Why one level and not an independent value per token: rows, tabs, radii, icons and text keep
their ratios at every density, so a density never looks broken. A custom density can still set
any token exactly.

### Presets

| preset | level | spacing | body text | sidebar row | tab strip |
|---|---|---|---|---|---|
| Ultra-compact | -0.5 | 0.75 | 11.5 | 20 | 24 |
| **Compact (default, today)** | 0 | 1 | 12 | 24 | 28 |
| Cozy | 0.5 | 1 | 12.5 | 28 | 32 |
| Comfortable (today's) | 1 | 1 | 13 | 32 | 36 |
| Spacious | 1.75 | 1.25 | 14 | 38 | 42 |

Compact is `level 0, spacing 1, no tokens`: every value is the literal compact value, bit for bit.
A guard test snapshots every Metrics and Typography value at Compact and fails on any change.
Comfortable is `level 1`: it is also unchanged.

`Density` (the old two-case enum) stays as the **family** (`level < 0.5` is compact, else
comfortable) for the few places that branch on it (Compact tabs, the page info bubble width), so
nothing else changes.

### Interaction with other settings

- `appearance.metrics.*` overrides still win per key. Interface Size
  (`appearance.metrics.chromeFontSize`) still wins over a density's text size. The order is
  Debug Settings > `appearance.metrics.*` > density `tokens` > the density level.
- `sidebar.density` stays as the sidebar's **row layout** (one line, taller one line, or expanded
  with a preview line). Its palette rows for compact/comfortable are removed because they read
  as duplicates. The sidebar's Options menu keeps them as "Compact Rows" and "Comfortable Rows".
  The sidebar row layout adds to the app density (`SidebarDensityTokens`). a288 owns the
  Comfortable overflow fix in the same tokens; this work reads `SidebarDensityTokens` and does not
  fork it.
- Interface Scale (`appearance.interfaceScale`) still multiplies everything after.

## Storage (cmux.json)

```json
{
  "appearance": {
    "density": "my-tight",
    "customDensities": [
      { "id": "my-tight", "name": "My Tight", "basedOn": "compact",
        "level": -0.25, "spacing": 0.9, "fontSize": 11.5,
        "tokens": { "sidebarRowHeight": 22, "itemCornerRadius": 5 } }
    ]
  }
}
```

- `appearance.density` takes a preset id or a custom id. An unknown id gives a diagnostic and
  falls back to Compact.
- Values are clamped: level −1…2.5, spacing 0.5…2, fontSize 9…20, and each token stays inside its
  tunable range.
- Export is the same JSON object (one density). Import accepts it, makes a unique id, and appends
  it. A custom density round-trips exactly: parse → serialize → parse gives the same value.

## Surfaces (one shared path)

All of them go through `DensityController` (the App): it resolves the id, applies it to
`DesignSettings` at once, writes cmux.json, and gives feedback.

- **Palette (Cmd+Shift+P):** one row per density, built-ins and customs, titled
  "Density: Compact". The active one shows "(current)" and a check. Enter applies it at once.
  Enter on the current one shows a toast ("Density is already Compact") so it is never silent.
  "Use Compact Density" / "Use Comfortable Density" are now these rows (same action IDs, new
  titles). The old CLI names still work as aliases.
- **CLI:** `cmux density list` (id, name, current), `cmux density set <id>`,
  `cmux density create --name N [--based-on compact] [--font-size 13] [--level 0.5]`,
  `cmux density export <id>`, `cmux density import <file|->`.
- **MCP:** the same catalog actions, so agents get `app_density_list`, `app_density_set`, and
  so on.
- **Settings > Appearance > Density:** a card with one tile per density (a small live drawing of
  a sidebar row, a tab and a text line at that density), Duplicate, an editor (name, level
  slider, spacing, font size, advanced per-token fields), Export and Import. The live preview
  draws with the same tokens the app resolves, and editing a custom density previews it in every
  window before it is saved (the same preview path as the background picker).

## Motion

A density change re-lays out at once, with no animation. If a later change animates the
re-layout, it must go through a274's motion gate (`plans/cmux-next/motion-DESIGN.md`) under the
panes/windows category and must work with all motion off.

## Tests (failing first)

1. Compact snapshot: every `MetricTunables` value, every `Typography` size and the sidebar tokens
   at Compact equal the recorded literals (the pre-change values).
2. Font scales with density: body text grows strictly from Ultra-compact to Spacious. A custom
   `fontSize` sets the body size, and the caption and header keep their ratio.
3. Custom round-trip: cmux.json `customDensities` parses, applies, serializes and parses back
   equal. An unknown id falls back to Compact with a diagnostic.
4. No overflow: at every preset, sidebar row frames from `SidebarLayout` stay inside the sidebar
   width with the shared inset and radius (a288's tokens).
5. Palette: running the density action changes `DesignSettings.densityTokens`. Running the current
   one gives feedback. Only one palette row matches "compact density".

## Gaps and next steps

- Tabs and Home read density through `Metrics` and `Typography`, so they follow. Menus are
  AppKit `NSMenu` and keep the system size. Web pages follow `--cmux-*` tokens and get the density
  level in a later change.
- Per-window or per-workspace density is out of scope (a245 owns per-scope appearance).

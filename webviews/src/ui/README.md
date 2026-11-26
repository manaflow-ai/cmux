# Shared web UI primitives

These components are the single interaction layer for cmux-next webviews. They use Base UI 1.8
for menu, focus, positioning, and dialog semantics. Base UI is already in the bundle and provides
the direction-aware keyboard and VoiceOver behavior used by the existing pages; React Aria can be
adopted behind these APIs later without changing callers.

Every export here is ready, experimental or deprecated; [STATUS.md](STATUS.md) says what each
promises and how an export is tagged.

## For agents

Run `bun run gen:component-manifest` to write `src/ui/llms.txt`, which lists every component with a
one-line summary and links to a page per component in `src/ui/docs/` (props, `data-*` attributes,
gallery entries, an example); `src/ui/components.generated.json` is the same data for tools. They are
read from the source, never committed (gitignored): generate them where you read them.
`bun run check:component-manifest` fails when the source no longer generates. Put `@status experimental`
(or `deprecated`) in a component's JSDoc to set its status.

## Menu

```tsx
<Menu>
  <MenuButton label="View">View</MenuButton>
  <MenuPopup>
    <MenuItem shortcut="⌘R" onSelect={refresh}>
      Refresh
    </MenuItem>
    <MenuSeparator />
    <Submenu label="Theme">
      <MenuItem onSelect={() => setTheme("dark")}>Dark</MenuItem>
      <MenuItem onSelect={() => setTheme("light")}>Light</MenuItem>
    </Submenu>
  </MenuPopup>
</Menu>
```

Menus open on the primary pointer press. While that pointer remains down, moving over rows
highlights them; releasing on a row selects it and closes the menu. Releasing on the trigger leaves
the menu open. A small four-pixel movement slop avoids selecting a row from an accidental tremor.
Keyboard arrows, Home/End, type-ahead, Return/Space, Escape, focus return, direction-aware arrows,
and Base UI's VoiceOver roles remain available. Submenus use Base UI's hover intent and the shared
safe-triangle bridge.

## Select

```tsx
<Select
  label="Color scheme"
  value={scheme}
  options={[
    { value: "system", label: "System" },
    { value: "dark", label: "Dark", shortcut: "⌘D" },
  ]}
  onChange={setScheme}
/>
```

`Select` is a single-choice `Menu` with a stable `SelectOption` data shape. It inherits the same
press-drag-release, keyboard, Escape, focus-return, and VoiceOver behavior. Use `labelledBy` when a
visible field label already exists.

## Submenus and context menus

Use `Submenu` inside `Menu` for a nested menu. A surface that has no trigger element can use the
standalone point-anchored context menu:

```tsx
<ContextMenu items={[{ id: "copy", label: "Copy", onSelect: copy }]}>
  <div className="file-row">...</div>
</ContextMenu>
```

`ContextMenu` owns the right-click gesture and keyboard dismissal. It intentionally does not share
the trigger-based `Menu` because its anchor is the pointer location; normal menus and selects must
use the shared `Menu`/`Select` layer.

Composer controls should import these same primitives. Leo's composer lane should leave its current
files unchanged until it rebases, then replace local menu/select implementations with the examples
above so there is one press-drag-release implementation.

## Menu tokens a look sets

A look (its `agent-pane/theme.css`, on `:root`) styles every page-drawn menu and popover with these
custom properties. Each is read with today's value as its fallback, so a page with none set draws
exactly what it drew, and the app's watcher applies a changed stylesheet to open panes with no
reload. Colors should be made from the theme's own (`color-mix()` over `var(--agent-text)` and
`var(--agent-page-bg)`), never a literal. The gallery's `ui.menu-looks` draws cmux, Claude, Codex
and Studio with the values in `MenuLooks.gallery.tsx`.

| Token                         | Type        | What it sets                                                                                  | Unset                                              |
| ----------------------------- | ----------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `--menu-radius`               | length      | the panel's corner (the App's host glass follows it)                                          | `--ds-radius-popup` (8 px)                         |
| `--menu-padding`              | length      | the panel's inner padding, which is also the hover fill's inset from its edges                | the menu grid's 5 px                               |
| `--menu-fill`                 | color       | the panel's fill, on the page's glass and on the App's                                        | the transient glass tint                           |
| `--menu-border`               | color       | the panel's hairline edge (`appearance.borders: none` still clears it)                        | the theme's text at 12%                            |
| `--menu-shadow`               | box-shadow  | the panel's drop shadow                                                                       | `--elevation-2`                                    |
| `--menu-row-height`           | length      | a row's height                                                                                | `--ds-control-row`                                 |
| `--menu-hover-fill`           | color       | the highlighted row's fill                                                                    | each surface's own wash                            |
| `--menu-hover-radius`         | length      | the highlighted row's corner                                                                  | the grid's 5 px                                    |
| `--menu-separator`            | color       | a separator's line                                                                            | each surface's own line                            |
| `--menu-separator-inset`      | length      | a separator's distance from the panel's edges                                                 | the grid's 15 px                                   |
| `--menu-label-color`          | color       | a section label ("Open in")                                                                   | the row ink at 55%                                 |
| `--menu-label-weight`         | font-weight | a section label's weight                                                                      | `--weight-emphasis`                                |
| `--menu-label-size`           | length      | a section label's size                                                                        | `--text-caption`                                   |
| `--menu-shortcut-color`       | color       | the shortcut column                                                                           | the row's own muted ink                            |
| `--menu-subtitle-color`       | color       | a row's second line (`MenuItem` `subtitle`)                                                   | the row ink at 55%                                 |
| `--menu-destructive`          | color       | a destructive row (`ui-menu-item-destructive`: Delete)                                        | `--cmux-app-danger`                                |
| `--menu-disabled-opacity`     | number      | a disabled row's strength                                                                     | 0.45 (ui.css hosts), the surface's own in the pane |
| `--menu-submenu-offset`       | length (px) | a submenu's distance from its row; negative overlaps the menu                                 | 6 px (`UI_ANCHOR_GAP`)                             |
| `--menu-submenu-align-offset` | length (px) | a submenu's shift along its row (negative: up, so its first row meets the row that opened it) | 0                                                  |

The tokens style menus the page draws (`Menu`, `Submenu`, `Popover`, `Select`, the composer's
pickers). Right-click menus the App draws (`ContextMenu` in a host, the sidebar's, a tab's and a
pane's) are AppKit's `NSMenu`, which these do not reach.

## Overlays

`Popover`, `Tooltip`, `Dialog`, and `Sheet` all portal into the `UiProvider` container, return focus
to their trigger, close on Escape, and use Ghostty theme tokens. Tooltips wait 500 ms on the first
hover and move immediately to a neighbor. Menus and popovers (Menu, Popover, Select, Combobox,
ContextMenu, and every `.ui-popup`) open in one frame with no fade, scale or slide, and fade only as
they close (Leo 2026-10-24: "When you open it up, no animation. When you close it, animation for
closing... No fade in ever for any of these."). `test/popover-instant-open.test.ts` holds this.

## Layers and transparency

One z-index scale for every page and the agent pane, defined in `pages/shared/desktop.css` (loaded
first everywhere). Use the token, never a number: `z-index: var(--layer-dropdown)` in CSS,
`z-(--layer-dropdown)` in Tailwind.

| token              | value      | for                                                                                                          |
| ------------------ | ---------- | ------------------------------------------------------------------------------------------------------------ |
| `--layer-backdrop` | -1         | the liquid glass lens's one canvas (`ui/glass/lens.ts`), behind all content and over the page color          |
| `--layer-base`     | 0          | normal flow                                                                                                  |
| `--layer-raised`   | 1          | a part lifted above its siblings inside one component (a hover card edge, a selected row's outline)          |
| `--layer-sticky`   | 10         | sticky headers, docked bars inside a scroller                                                                |
| `--layer-overlay`  | 30         | scrims and dimming layers; a field's suggestions (New Tab), so the menus its composer opens cover them       |
| `--layer-modal`    | 40         | dialogs and sheets                                                                                           |
| `--layer-dropdown` | 50         | menus, popovers, pickers, comboboxes (the shared positioner); above modals so a picker inside a dialog shows |
| `--layer-toast`    | 900        | transient notices                                                                                            |
| `--layer-tooltip`  | 1000       | tooltips, including the title tooltip                                                                        |
| `--layer-debug`    | 2147483000 | dev-only overlays (gallery error panel)                                                                      |

Rules:

- Popups, menus, pickers and tooltips render in the portal container (`usePortalContainer`), never
  inside a component, so no parent's stacking context (`transform`, `filter`, `opacity`, `isolation`)
  or `overflow` traps or clips them. Inside a component use only base, raised and sticky.
- Menus, popovers, pickers and context menus are glass, never opaque: the popup adds `.ui-glass`
  (`Menu`, `Popover`, `ContextMenu` and `Combobox` do) and paints no fill or shadow of its own;
  `ui/popupSurface.css` gives it the popup's one hairline as the glass edge and the popup drop
  (`--ui-popup-drop`). Plain glass is glass too (the surface at 60% under the frost); only Reduce
  Transparency makes it the popup surface `var(--surface-popup)` (desktop.css: the host's
  `--cmux-popup-surface`, the native overlays' `Palette.popupSurface`), opaque (`--glass-opaque`).
  A popup never inherits the tint of the surface it opens from (`.ui-popup.ui-glass`, glass.css). Tooltips keep the tooltip surface (`--tooltip-*`). Any other translucent
  surface that carries text keeps at least `--surface-text-min` of its fill:
  `color-mix(in srgb, <fill> var(--surface-text-min), transparent)`.
- A blur uses `backdrop-filter: var(--surface-blur)`, or the file has its own
  `@media (prefers-reduced-transparency: reduce)` rule that makes the surface opaque. Both tokens turn
  opaque under Reduce Transparency (`prefers-reduced-transparency`, or `data-reduce-transparency` on
  the root, which the host may set from the app setting).
- `scripts/cmux-next/check-layers.py` (run by `bun run check`) fails on a new raw z-index or a new
  bare `backdrop-filter`; the old ones sit in `scripts/cmux-next/layers-baseline.tsv`, which may only
  go down. Each component moves to the tokens in its UI-tournament round.
- The gallery stage checks every play step: an open popup must be the top element at its corners and
  center, and nothing may clip it (`judgePopups` in `gallery/play.ts`). It warns by default; an entry
  gates it with `checks.popupLayer = { value: true, reason }`.

## Liquid glass

A glass surface adds `.ui-glass`; its
tint, blur and rim come from `ui/glass/glass.css`, which `pages/shared/desktop.ts` loads on every page
and the agent pane. Override a token on the surface itself, never the fill. Reduce Transparency holds
every `.ui-glass` opaque whatever tokens it sets (`!important` in glass.css), with `--glass-opaque` as
its fill:

| token                | default                  | for                                                                                                   |
| -------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------- |
| `--glass-tint`       | the theme surface at 40% | the fill: never opaque, never the accent                                                              |
| `--glass-blur`       | 2px                      | the frost inside the glass                                                                            |
| `--glass-refraction` | 22px                     | how far the rim bends the wallpaper                                                                   |
| `--glass-rim`        | 1                        | the specular rim's strength (0 to 1)                                                                  |
| `--glass-dispersion` | 0 (0.35 under Spectrum)  | the per-channel split of the bend                                                                     |
| `--glass-elevation`  | none                     | the surface's own drop shadow, from the elevation scale                                               |
| `--glass-opaque`     | the theme surface        | the opaque fill under Reduce Transparency                                                             |
| `--glass-join`       | none                     | `top`, `bottom` or `both`: edges that continue into a neighbouring glass, where the lens bends no rim |

The host sets `data-glass` (`lens`, `plain`, `spectrum`) on `<html>` and sends a still of the
wallpaper through `window.cmuxTheme.backdrop(...)`. `ui/glass/lens.ts` then draws it on one WebGL
canvas behind all content (`--layer-backdrop`), bent at each glass's rounded rim
(plans/cmux-next/glass-lens-DESIGN.md). Plain glass, Reduce Transparency, no still or no glass on the
page leave it with no canvas and no listeners but the mode watchers; Reduce Transparency makes the
surface opaque.

## Type scale

One set of font sizes and two weights for every page, the agent pane and the native app. The source is
`schemas/type-scale/type-scale.json`; `scripts/cmux-next/gen-type-scale.py` writes it into
`pages/shared/desktop.css` (loaded first everywhere) and the app's `TypeScale` (CmuxNextDesign). Use the
token, never a size or weight: `font-size: var(--text-body)` (and `line-height: var(--text-body--line-height)`)
and `font-weight: var(--weight-emphasis)` in CSS, `text-body` in Tailwind (sets both).

| token            | size                               | line height        | for                                                                      |
| ---------------- | ---------------------------------- | ------------------ | ------------------------------------------------------------------------ |
| `--text-caption` | 11px                               | 14px               | keyboard shortcuts, group labels, badges, counters, tooltips             |
| `--text-detail`  | 12px                               | 16px               | descriptions, secondary lines, metadata, section headers, footer rows    |
| `--text-body`    | 13px                               | 18px               | chrome text: labels, rows, menus, controls, settings (macOS system font) |
| `--text-control` | the body step                      | the body step's    | menu and picker rows, composer controls (`NSFont.menuFont` is 13)        |
| `--text-title`   | 15px                               | 20px               | card and panel titles, search fields, glyph buttons                      |
| `--text-heading` | 20px                               | 26px               | page headings                                                            |
| `--text-content` | the user's `--cv-font-size` (14px) | `--cv-line-height` | reading content: transcript, markdown, composer prompt                   |

| token               | weight | for                                                     |
| ------------------- | ------ | ------------------------------------------------------- |
| `--weight-regular`  | 400    | everything by default                                   |
| `--weight-emphasis` | 600    | titles, headings, selected or unread rows, group labels |

Rules:

- Chrome uses the UI steps (caption to heading); it does not grow with the user's content size, as
  macOS chrome does not. Reading content uses `--text-content`, so the agent pane font setting
  (theme.css / AgentPaneTheme) changes the transcript and prompt, not the menus.
- The steps follow macOS (measured on macOS 26 with AppKit, 2026-10-09): `--text-body` is
  `NSFont.systemFontSize` (13); `--text-control` is `NSFont.menuFont(ofSize: 0)` (13), so web menus,
  popover lists and picker rows match the native NSMenus next to them; `--text-caption` is
  `NSFont.smallSystemFontSize` and `NSFont.toolTipsFont(ofSize: 0)` (11), so tooltips match native ones.
- Relative sizes (`em`, `%`) are fine for parts that scale with their parent (a superscript).
- `scripts/cmux-next/check-type-scale.py` (run by `bun run check`) fails on a new literal size
  (`font-size: 12px`, a `font:` shorthand with a size, `fontSize: 12`, Tailwind `text-[12px]`); the old
  ones sit in `scripts/cmux-next/type-scale-baseline.tsv`, which may only go down. Each component moves
  to the tokens in its UI-tournament round.
- The app's Swift has the same ratchet: `scripts/cmux-next/check-swift-type-scale.py` (cmux-next checks)
  fails on a new literal font size or a weight other than `TypeScale.regular` and `TypeScale.emphasis`.
  `scripts/cmux-next/type-inventory.py` prints each surface's sizes and weights, native and web.

## Design scale and Tailwind

One token source: `schemas/design-scale/design-scale.json` (spacing, control heights, icon sizes,
radii, glass levels, elevation, colour roles) with `schemas/type-scale` and `schemas/motion-scale`.
`webviews/scripts/pages/gen-design-scale.mjs` writes the `--ds-*` and `--elevation-*` variables into
`pages/shared/desktop.css`, the Tailwind theme `ui/theme.generated.css` that every Tailwind entry
imports, and `ui/designTokens.generated.ts` for the token sheet (gallery `ui.token-sheet`). The last
two are build output (gitignored): `bun install`, every build and the test preload write them through
`gen-strings.mjs`. Run it after editing the schema; `--check` (in `bun run check`) fails when
desktop.css's block drifted. Tailwind then resolves to
our tokens: `p-3` is 3 grid units, `rounded-md` is `--ds-radius-md`, `text-body` is the type step,
`bg-hover` / `text-muted` are the colour roles the host derives from the terminal theme, and
`shadow-elevation-2`, `duration-quick` and `ease-standard` are the shadow and motion steps. Glass
levels are variables only (`--ds-glass-<level>-tint` and `-blur`). Settings keeps rem spacing and
radii off its own root until it migrates (`pages/settings/tailwind.css`).

## Controls

`Button` (ghost, subtle (default), solid; sm 24, md 28, lg 32; `icon`, `danger`), `Switch` (sm, md
(default), lg), `Input` (filled (default), outline, plain) and `Tabs` / `TabsList` / `TabsTrigger` /
`TabsContent` (pill (default), underline, segmented) wrap Base UI in shadcn's shape and draw only
with the design scale (`controls.css`). A button that opens a popup stays lit while it is open
(`data-popup-open`), fills cover the control only, and Reduce Motion makes every change instant.

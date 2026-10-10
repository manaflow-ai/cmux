# Shared web UI primitives

These components are the single interaction layer for cmux-next webviews. They use Base UI 1.8
for menu, focus, positioning, and dialog semantics. Base UI is already in the bundle and provides
the direction-aware keyboard and VoiceOver behavior used by the existing pages; React Aria can be
adopted behind these APIs later without changing callers.

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

## Overlays

`Popover`, `Tooltip`, `Dialog`, and `Sheet` all portal into the `UiProvider` container, return focus
to their trigger, close on Escape, and use Ghostty theme tokens. Tooltips wait 500 ms on the first
hover and move immediately to a neighbor. Menus have no fade-in; overlays only use a short fade-out.

## Layers and transparency

One z-index scale for every page and the agent pane, defined in `pages/shared/desktop.css` (loaded
first everywhere). Use the token, never a number: `z-index: var(--layer-dropdown)` in CSS,
`z-(--layer-dropdown)` in Tailwind.

| token              | value      | for                                                                                                          |
| ------------------ | ---------- | ------------------------------------------------------------------------------------------------------------ |
| `--layer-base`     | 0          | normal flow                                                                                                  |
| `--layer-raised`   | 1          | a part lifted above its siblings inside one component (a hover card edge, a selected row's outline)          |
| `--layer-sticky`   | 10         | sticky headers, docked bars inside a scroller                                                                |
| `--layer-overlay`  | 30         | scrims and dimming layers                                                                                    |
| `--layer-modal`    | 40         | dialogs and sheets                                                                                           |
| `--layer-dropdown` | 50         | menus, popovers, pickers, comboboxes (the shared positioner); above modals so a picker inside a dialog shows |
| `--layer-toast`    | 900        | transient notices                                                                                            |
| `--layer-tooltip`  | 1000       | tooltips, including the title tooltip                                                                        |
| `--layer-debug`    | 2147483000 | dev-only overlays (gallery error panel)                                                                      |

Rules:

- Popups, menus, pickers and tooltips render in the portal container (`usePortalContainer`), never
  inside a component, so no parent's stacking context (`transform`, `filter`, `opacity`, `isolation`)
  or `overflow` traps or clips them. Inside a component use only base, raised and sticky.
- Menus, popovers and tooltips are opaque. A translucent surface that carries text keeps at least
  `--surface-text-min` of its fill: `color-mix(in srgb, <fill> var(--surface-text-min), transparent)`.
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

## Type scale

One set of font sizes for every page and the agent pane, defined in `pages/shared/desktop.css` (loaded
first everywhere). Use the token, never a size: `font-size: var(--text-body)` (and
`line-height: var(--text-body--line-height)`) in CSS, `text-body` in Tailwind (sets both).

| token            | size                               | line height        | for                                                                                              |
| ---------------- | ---------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------ |
| `--text-caption` | 11px                               | 14px               | keyboard shortcuts, group labels, badges, tiny counters, tooltips (NSFont.toolTipsFont is 11 pt) |
| `--text-detail`  | 12px                               | 16px               | descriptions, secondary lines, metadata, section headers                                         |
| `--text-body`    | 13px                               | 18px               | chrome text: labels, settings rows, page text (macOS system font)                                |
| `--text-control` | 13px                               | 18px               | menu and picker rows, menu search fields, composer controls                                      |
| `--text-title`   | 15px                               | 20px               | card and panel titles, glyph buttons                                                             |
| `--text-heading` | 17px                               | 22px               | page headings                                                                                    |
| `--text-content` | the user's `--cv-font-size` (14px) | `--cv-line-height` | reading content: transcript, markdown, composer prompt                                           |

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

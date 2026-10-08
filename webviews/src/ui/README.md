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

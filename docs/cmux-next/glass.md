# Glass in your own UI

cmux draws its chrome on the Mac's own glass: Liquid Glass (`NSGlassEffectView`) on macOS 26 and
later, the vibrancy material (`NSVisualEffectView`) before, and an opaque surface when Reduce
Transparency is on. A look, a theme file or a view of your own can use the same glass. This page
says where, and what each way costs.

## Four levels

Every glass in cmux is one of four levels, so glass you add matches the glass around it:

| Level | What uses it in cmux |
| --- | --- |
| `chrome` | Glass docked on the window: the sidebar's cards and group headers, the tab strip |
| `popover` | Floating surfaces over content: hover cards, the palette, find bars, popovers |
| `menu` | Menus cmux draws |
| `chip` | Small one-line glass: tooltips, shortcut hints |

You pick a level, never a blur, a tint or an opacity: the level carries those, and they follow the
theme, light and dark, and Reduce Transparency.

## The window's glass: a theme file

The sidebar, the titlebar and the panes sit on the window's glass. A theme file sets how much of it
shows ([theme-recipes.md](theme-recipes.md)):

| Key | What it does |
| --- | --- |
| `appearance.background` | A wallpaper behind the glass, or `none` |
| `appearance.backgroundBlur` | How the window's material frosts what is behind it |
| `appearance.glassTransparency` | How see-through the glass is |
| `appearance.sidebarSurface`, `appearance.surfaces.sidebar.opacity`, `appearance.surfaces.agentPane.opacity` | Below 1, the window's glass shows through that surface |

`cmux settings list` shows each key's values. The recipe `cmux customize use
~/.local/state/cmux/customize/recipes/glass.json` turns the glass on in one step.

## Glass behind a piece of your view: `.glass(level)`

A view of your own (a sidebar section, a hover card, Session Info, an app pane:
[sidebar-customization.md](sidebar-customization.md)) can put the app's glass under any piece:

```js
function renderCard(ctx) {
  return VStack({ spacing: 4 }, [
    HStack([Text(ctx.card.title).bold(), Spacer()])
      .padding(8)
      .cornerRadius(10)
      .glass("chip"),
    Text(ctx.card.status ?? "").secondary(),
  ])
}
```

- The app draws it natively, in the same view as the piece: there is no second layer to keep in
  step, so it scrolls, resizes and zooms with the piece.
- It is paint only. The piece's size and its children's places are the same with glass and without
  it, so adding, switching or removing glass never moves anything.
- It replaces `.background`. `.cornerRadius` rounds it. `.glass(null)` removes it; an unknown level
  draws no glass.
- An app from before this prop has no `.glass` method. A view that must run there guards it:
  `const glass = (n, level) => (typeof n.glass === "function" ? n.glass(level) : n)`.
- `Panel` already sits on the `chrome` glass; use `.glass` for anything else.

Where a scene is drawn in a web page instead (the web renderer), the same prop draws the page's
glass at the same level.

## Glass in a web page: the kit's `Glass`

A web page built on the kit ([webviews/src/kit](../../webviews/src/kit/README.md)) puts a region on
glass with `Glass`:

```tsx
import { Glass } from "../kit";

<Glass level="popover" radius={12}>
  …
</Glass>;
```

It is the page's glass at that level (`ui/glass/glass.css`): the shared blur and tint, tuned to the
app's material at the same level, or the lens when the Liquid Glass lens is on, and the opaque
surface under Reduce Transparency. Like `.glass`, it is paint only.

A web page cannot have the app's native glass drawn under one of its regions: the app would draw it
from boxes the page sends, and under a pinch zoom or a fast scroll the two drifted apart, so cmux
stopped doing that for its own popovers and menus. The page's glass is the matched material instead.

## A whole look

A look add-on ([examples/looks](../../examples/looks)) sets the window's glass in its theme file and
puts `.glass` on the pieces of its `customize/` views where glass fits. The looks there are
written only on these public surfaces.

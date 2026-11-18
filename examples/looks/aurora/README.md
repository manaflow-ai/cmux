# Aurora

A glass-forward look for cmux NEXT. The titlebar, tab strip and sidebar are the Mac's own clear glass
over your desktop. The chat stays nearly solid, so it reads on any wallpaper. A cool northern-lights
accent, teal at its base and violet at its edge, shows in only a few places. Light and dark both come
from one theme file and follow your Mac's appearance. With Reduce Transparency on, it becomes a calm
two-tone look with the same accent.

<!-- media -->

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's font, size and width, the sidebar's density, and the aurora gradient for group colors |
| `themes/aurora.json` | The window's glass, the light and dark colors (`appearance.theme` names a light and a dark theme, `appearance.themeEdits` colors each), and the chat's opacity |
| `agent-pane/theme.css` | A teal prompt bubble with a violet hairline and neutral cards, with `cmux.agentPane.style/1` tokens only |
| `customize/` | A hover card whose status sits on a small chip of the app's glass (`.glass("chip")`) |
| `DESIGN.md` | The references, the decisions, the contrast numbers in light and dark, and the Reduce Transparency check |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/aurora@feat-cmux-next
cmux setup remove manaflow-ai/aurora-look
```

The goo corner (the selected tab flowing into the content card) is a Debug Settings choice a setup
cannot make; Aurora keeps the stock chrome so the plain flush corner draws.

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

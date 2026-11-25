# Nature

A wallpaper-led look for cmux NEXT. The titlebar, tab strip and sidebar are the Mac's clearest glass
(Liquid Glass, clear) with half a tint, so your own wallpaper is what shows through, and the glass
leans toward its hue. Nothing is painted over the picture. The chat is a plane at 86% that reads on
a mid-tone picture. Moss, bark and a leaf-green accent; light (morning moss) and dark (forest floor)
come from one theme file and follow your Mac's appearance. With Reduce Transparency on, it becomes a
calm two-tone look with the same accent.

It differs from [Aurora](../aurora) in the material and the lead: Aurora is regular glass at 72% with a
polar palette; Nature is clear glass at 50% and lets the picture carry the color.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's font, size and width and the sidebar's density |
| `themes/nature.json` | The window's clear glass, the light and dark colors, and the chat's opacity |
| `agent-pane/theme.css` | A leaf prompt bubble with a leaf hairline and neutral cards, with `cmux.agentPane.style/1` tokens only |
| `customize/` | A hover card whose status sits on a small chip of the app's glass (`.glass("chip")`) |
| `DESIGN.md` | The decisions, the three opacities compared, and the contrast numbers |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/nature@feat-cmux-next
cmux setup remove manaflow-ai/nature-look
```

It is opt-in: nothing changes until you install it, and removing it puts back what you had.

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

# Astrolabe

A calm, ceremonial look for agent chats in cmux: deep navy, ivory text, old-gold hairline frames
around the prompt and every card with small, nearly square corners, airy serif replies and Markdown,
and folders as titled sections in the sidebar. The thinking line glows slowly with a wide soft band,
and work in progress is a thin gold arc.

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's and the Markdown viewer's serif type, airy line height and reading width, a slow thinking glow and a sectioned sidebar |
| `themes/astrolabe.json` | Astrolabe, dark (the default): colors, terminal palette, hairline chrome, proportions, the gold arc |
| `themes/astrolabe-dawn.json` | Astrolabe Dawn: ivory parchment, navy ink and a bronze accent deep enough to read on it |
| `agent-pane/theme.css` | Gold hairline frames on the prompt and cards, warm secondary text, with `cmux.agentPane.style/1` tokens only |
| `customize/` | A titled hover card with the task in full, and calm rows with a thin arc |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/astrolabe@feat-cmux-next
cmux settings set appearance.themeFile astrolabe-dawn   # astrolabe (dark) is the default
cmux setup remove manaflow-ai/astrolabe-look
```

Remove puts back every setting and file you had before. The look's `customize/` replaces your own
`local/customize` app while it is on.

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

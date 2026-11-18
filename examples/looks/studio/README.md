# Studio

A dense, near-black workbench for agent chats in cmux: quiet neutral chrome, a hairline between the
sidebar and the chat, compact rows, and a boxed prompt with square-ish corners.

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's font, size and width and the sidebar's density and row facts |
| `themes/studio.json` | The colors, surfaces, borders and density |
| `agent-pane/theme.css` | The prompt bubble and cards, with `cmux.agentPane.style/1` tokens only |
| `customize/` | A terse hover card and plain sidebar rows with a dot while work runs |

```sh
cmux setup install github.com/manaflow-ai/cmux-studio-look
cmux setup remove manaflow-ai/studio-look
```

Studio's source is its own repo, [manaflow-ai/cmux-studio-look](https://github.com/manaflow-ai/cmux-studio-look): install from it and change it there.
This folder is a copy that cmux's tests check: its setup, theme, stylesheet and view are the repo's.

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

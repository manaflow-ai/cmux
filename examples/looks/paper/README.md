# Paper

A warm, roomy reading look for agent chats in cmux: serif replies on off-white paper, ink-brown text,
a sepia accent, and soft rounded prompts.

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's serif font, size, line height and width and the sidebar's density |
| `themes/paper.json` | The colors, surfaces and density |
| `agent-pane/theme.css` | The prompt bubble and cards, with `cmux.agentPane.style/1` tokens only |
| `customize/` | A reading hover card with the task in full, and calm sidebar rows |

```sh
cmux setup install github.com/manaflow-ai/cmux-paper-look
cmux setup remove manaflow-ai/paper-look
```

Paper's source is its own repo, [manaflow-ai/cmux-paper-look](https://github.com/manaflow-ai/cmux-paper-look): install from it and change it there.
This folder is a copy that cmux's tests check: its setup, theme, stylesheet and view are the repo's.

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

# Overdrive

A loud, fast look for agent chats in cmux: hot pink and electric cyan on near-black, floating round
panes, chunky round prompts and cards, a tight bold chat face, and every motion at full speed. The
thinking line sweeps quickly with a narrow band of light, and work in progress is a heavy cyan dot.

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's tight face, size, line height and width, a fast thinking shimmer, big sidebar rows and a quick hover card |
| `themes/overdrive.json` | Overdrive, dark (the default): colors, terminal palette, floating panes, proportions, the cyan dot, a 90 ms spring for color changes |
| `themes/overdrive-daylight.json` | Overdrive Daylight: the same on cool white, with a deep magenta and cyan dark enough to read on it |
| `agent-pane/theme.css` | The prompt as a big round pill with an accent rim, cards as rounded tiles with an accent ring, with `cmux.agentPane.style/1` tokens only |
| `customize/` | A hover card that leads with the status, and rows with heavy names and a pulsing dot |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/overdrive@feat-cmux-next
cmux settings set appearance.themeFile overdrive-daylight   # overdrive (dark) is the default
cmux setup remove manaflow-ai/overdrive-look
```

Remove puts back every setting and file you had before. The look's `customize/` replaces your own
`local/customize` app while it is on.

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

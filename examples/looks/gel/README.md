# Gel

A soft, gooey look for cmux: every surface is a tone of one sea-glass seed color, in light and dark;
cards and the prompt are filled tonal containers with large soft corners and no hairlines; the
window and sidebar float on glass while the chat stays opaque; and the selected tab flows into the
content card like two drops of water meeting.

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets Roboto in the chat, its size and width, comfortable rows, and tonal unfocused tabs |
| `themes/gel.json` | The tonal palette for light and dark (a light/dark theme pair with its own tones), glass behind the chrome, no borders, the flush corner, the arc |
| `agent-pane/theme.css` | The prompt bubble, cards, text and links as `cmux.agentPane.style/1` tokens, each a `light-dark()` pair |
| `customize/` | A hover card with a headline, a state chip on glass and place chips, and sidebar rows with the arc while work runs |
| `DESIGN.md` | The references, the palette, the decisions and the contrast numbers |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/gel@feat-cmux-next
cmux setup remove manaflow-ai/gel-look
```

## Turn on the goo

The fillets where the selected tab meets the card are a Debug Settings choice that a setup cannot
set yet: open Debug Settings, Corner flush, and pick "Flush, goo". Without it, Gel keeps the flush
corner (the selected tab runs straight into the card) with no fillets. On a chat tab the fillets do
not show yet either: see DESIGN.md, "Open: the goo against an opaque chat".

## The hover card

A workspace's hover card opens collapsed, with its tabs; Gel's card (the headline, the state chip and
the place chips) shows after you click Show details on it.

## Screenshots

The chat with Gel's tokens, drawn by the look-addons browser test (Linux, so the page color is the
gallery's, not the theme's; captures from the macOS app follow):

| Light | Dark |
| --- | --- |
| prompt bubble in the secondary-container tone, no edge | the same in the dark tone |

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

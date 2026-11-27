# Grove

A forest look for cmux NEXT: ink on unbleached paper by day, a deep fern dark by night, a moss
accent, and frosted morning air in the sidebar over a painted grove. Replies read in a book serif;
the chat's controls use a humanist sans. Colors come from moss, lichen, bark, fog and earth pigments,
and every text color passes 4.5:1 in both appearances ([DESIGN.md](DESIGN.md)).

Screenshots and a demo video come with the look's pull request.

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's serif and humanist sans, size, line height and width, the card corner, and the sidebar's density and row facts |
| `themes/grove.json` | Each appearance's colors and terminal palette, a painting per appearance behind frosted glass, the window style, and calm motion |
| `agent-pane/theme.css` | The prompt bubble, cards, text and links, light and dark, with `cmux.agentPane.style/1` tokens only |
| `customize/` | A field-note hover card with a frosted header, and calm sidebar rows with the arc while work runs |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/grove@feat-cmux-next
cmux setup remove manaflow-ai/grove-look
```

Light and dark follow the system appearance. How looks like this one are written:
[docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

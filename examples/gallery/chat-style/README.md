# Starter Chat Style

A reading column for the agent chat and the Markdown viewer. It has no theme file of its own, so it
goes over any theme.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Sets the chat at 15 px with a 1.6 line height, code at 0.92, a 720 px column and no minimap. Sets the Markdown viewer at 15 px with a 1.6 line height and an 88-character column |
| `agent-pane/theme.css` | `cmux.agentPane.style/1` tokens: a borderless prompt block with 14 px corners, quiet cards, softer secondary text, and links one step toward the text color |
| `markdown/theme.css` | `--cmux-md-*` tokens: code on a faint fill with 10 px corners, headings with no rule, and quotes on a 3 px line |

Both stylesheets mix every color from the theme's own (`--agent-text`, `--agent-accent`,
`--page-text`).

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/gallery/chat-style@feat-cmux-next
cmux setup remove manaflow-ai/starter-chat-style
```

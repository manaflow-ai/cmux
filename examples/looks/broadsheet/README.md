# Broadsheet

A design-system proposal (Broadsheet v0.1) as a drop-in look. What agents produce is writing, so
the hierarchy is built from type, measure and rhythm, not from boxes.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat in the system face at 16 px on a 24 px line in a 560 px column (35 em, 72 characters a line as measured), code at 13 px; plain sidebar sections; a small flat address field |
| `themes/broadsheet.json` | Default, Light. Page `#FAF8F3`, ink `#111110`, margin (sidebar, tab strip, docks) `#F3F0E9`, rule `#DEDAD0`, link `#2A4B9B`; a 40 pt title bar, 36 pt tab strip, 28 pt rows, 13 pt chrome text, 240 pt sidebar, 6 pt pane corners |
| `themes/broadsheet-dark.json` | Dark. Page `#161615`, ink `#E9E6DF`, margin `#1F1E1C`, rule `#34322E`, link `#A3BBF5` |
| `agent-pane/theme.css` | Your prompt on a 5% wash with 2 px corners and no edge; cards with no fill and a hairline; secondary ink at 72% and 66%. `cmux.agentPane.style/1` tokens only |
| `markdown/theme.css` | The Markdown viewer: hairline rules, no filled table header, 2 px code corners. `--cmux-md-*` properties only |

It changes no default. Remove it and everything you had comes back.

```sh
cmux settings set appearance.themeFile broadsheet-dark   # broadsheet (Light) is the default
```

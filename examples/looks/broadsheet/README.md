# Broadsheet

Broadsheet v0.2 (`0.2.0`), the reading preset, as a drop-in look. What agents produce is writing, so
the hierarchy is built from type, measure and rhythm, not from boxes. It started as a design-system
proposal (RFD 0037); the system that was chosen is another, and this stays as a look.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat in the system face at 16 px on a 24 px line in a 560 px column (35 em, 72 characters a line as measured), code at 13 px; plain sidebar sections; a small flat address field |
| `themes/broadsheet.json` | Default, Light. Page `#FAF8F3`, ink `#111110`, margin (sidebar, tab strip, docks) `#F3F0E9`, rule `#DEDAD0`, link `#2A4B9B`; a 40 pt title bar, 36 pt tab strip, 28 pt rows, 13 pt chrome text, 240 pt sidebar, 6 pt pane corners |
| `themes/broadsheet-dark.json` | Dark. Page `#161615`, ink `#E9E6DF`, margin `#1F1E1C`, rule `#34322E`, link `#A3BBF5` |
| `agent-pane/theme.css` | Your prompt on a 5% wash with 2 px corners and no edge; cards with no fill and a hairline; secondary ink at 72% and 66%. `cmux.agentPane.style/1` tokens only |
| `markdown/theme.css` | The Markdown viewer: hairline rules, no filled table header, 2 px code corners. `--cmux-md-*` properties only |

It changes no default. Remove it and everything you had comes back.

```sh
cmux setup install examples/looks/broadsheet
cmux settings set appearance.themeFile broadsheet-dark   # broadsheet (Light) is the default
```

## What the captures measure

From `screenshots/broadsheet-light.png` and `broadsheet-dark.png` (the test window, 1280 px wide):

| | Light | Dark |
| --- | --- | --- |
| Reading text | 16 px on 24 px, 72 characters a line (63 to 79) | the same |
| Margin against page | 1.07:1, with a hairline | 1.09:1, with a hairline |
| Tool rows against page | 4.54:1 | 5.55:1 |
| Sidebar section header | 5.27:1 | 6.59:1 |

## What this look does not set

A look reaches settings, theme files and eleven chat paint tokens. These are outside it, so the look
does not claim them:

- **The measure holds code too.** The 560 px column is one width for reading text, code blocks and
  diffs. A long diff line wraps where the default's 800 px column would not, and a code line fades
  at the column edge. Giving code its own wider column needs a change in the chat's own styles.
- **Inline code can break across lines.** A token such as `Retry-After` can split at its hyphen at
  the end of a line. That is the chat's own wrapping rule, the same with or without this look; the
  narrow column makes it show more often.
- **Tool rows are the reading size.** Tool rows draw at 16 px on a 20 px line, not smaller than the
  reading text: every chat size follows the one font size.
- **Not on the 4 px line grid:** code lines (21.67 px) and headings (27.43 and 25.14 px).
- **Card and composer corners** draw at the default's 8 px. The 2 px corner applies to your prompt.
- **The session panel.** In a 1280 px window the narrow column leaves room for the session panel, so
  it opens beside the chat, as the Light and Dark captures show.
- **Type in the chrome:** the sidebar's, tab strip's and Settings' fonts, sizes and tracking.
- **Not checked in the Mac app:** every number above is from the test window, which does not draw
  the neutral selection or the margin tone behind the tab strip.
- 59 of 252 text runs in the Light capture and 46 in Dark are under 4.5:1 (the lowest 2.65:1, the
  "Waiting for you" label); they are the default's own and this look does not repaint them.

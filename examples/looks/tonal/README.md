# Tonal

A calm, opaque redesign of the whole window in which every color grows from one seed. The seed
gives five tonal palettes (primary, secondary, tertiary, neutral, neutral-variant), each a ramp of
tones from 0 (black) to 100 (white) at one hue and chroma, and every surface and ink picks a tone
from one of them. Surfaces are told apart by tone, not by shadows, blur or hairlines: the page is
`surface`, the sidebar and tab strip a few tone steps off it, settings and pages one step more.
Nothing is glass. The work sits in one rounded card set into the tonal chrome, the selected tab is
a pill, and the primary color does selection, focus, links and a filled Send.

It ships three seeds, each in Light and Dark:

| Theme file | Seed | Character | Primary | Page | Sidebar |
| --- | --- | --- | --- | --- | --- |
| `tonal` (the default) | `#5b8c7a` sage-teal | Airy: comfortable rows, a 260 pt sidebar, 16 pt card corners | `#0e6b53` | `#f4fbf8` | `#e9efed` |
| `tonal-dark` | same | | `#85d6b9` | `#101412` | `#1c211f` |
| `tonal-ink` | `#6750d8` indigo-violet | Vivid: lavender-cast neutrals, saturated containers, 20 pt corners, card sections in the sidebar | `#5e48c9` | `#f9f9ff` | `#e7e7f3` |
| `tonal-ink-dark` | same | | `#c2c1fc` | `#13131b` | `#292932` |
| `tonal-clay` | `#b5573a` terracotta | Dense and warm: compact rows, 12 pt corners, a 4 pt gap, a quiet status dot | `#a23e1e` | `#fff8f6` | `#f9ebe7` |
| `tonal-clay-dark` | same | | `#ffb59e` | `#1a110f` | `#271d1a` |

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks `tonal`; the Markdown viewer in the system face at 15 px; theme-colored diffs with change bars; the chat in a 760 px column with no minimap; comfortable sidebar rows; a capsule command bar with no shadow |
| `themes/*.json` | The six theme files: colors, the terminal's sixteen colors, opaque surfaces, the card layout, corners, proportions, type and motion |
| `agent-pane/theme.css` | The chat in the same language: `cmux.agentPane.style/1` tokens for tonal message containers, a 28 px composer, a filled primary Send, state layers on hover and press |
| `markdown/theme.css` | The Markdown viewer's paint, `--cmux-md-*` tokens mixed from the page's own colors |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/tonal@feat-cmux-next
cmux settings set appearance.themeFile tonal-ink    # or tonal-dark, tonal-clay, tonal-clay-dark, tonal-ink-dark
cmux setup remove manaflow-ai/tonal-look
```

## How the colors are made

Each theme file was generated from its seed: the seed's OKLCH hue is held, each palette gets its
own chroma, and a palette's tone T is the color at that hue whose CIELAB lightness is T, cut back
in chroma until it fits sRGB. So tone 40 is equally light on every palette, and a role is a
(palette, tone) pair:

| Role | Light | Dark | Used for |
| --- | --- | --- | --- |
| primary | primary 40 | primary 80 | accent, cursor, Send, links |
| on-primary | primary 100 | primary 20 | the Send glyph |
| primary-container | primary 90 | primary 30 | selection |
| surface | neutral 98 | neutral 6 | the page: chat, terminal, editor, diffs, Markdown |
| surface-container-low | neutral 96 | neutral 10 | settings, pages, new tab, docks |
| surface-container | neutral 94 | neutral 12 | sidebar, tab strip |
| surface-container-high | neutral 92 | neutral 17 | Tonal Ink's sidebar and tab strip |
| on-surface | neutral 10 | neutral 90 | text |
| outline-variant | neutral-variant 80 | neutral-variant 30 | the rare line tone cannot replace |

The terminal's colors 1 to 6 and 9 to 14 are the six ANSI hues at one chroma, each with its tone
solved over the page to WCAG AA (4.5:1 in Light; in Dark 4.5:1 and the bright ones 7:1); 7 is a
4.5:1 gray, 8 a 3.5:1 (Light) or 3:1 (Dark) dim gray. On-primary over primary is at least 6.4:1
and text over the page at least 14:1 in every file.

## Not yet possible

| Part | Why |
| --- | --- |
| A 28 pt card or sheet corner on the content card | `layout.paneCornerRadius` stops at 20 |
| The toast's shape and fill (`notifications.toast.style: "flat"`) | Pending cmux#49661 |
| The sidebar row's corner radius and inset, a full-width pill on the selected row | No public key (pending cmux#46861) |
| A neutral, tonal selected row instead of the accent fill | Pending cmux#46516 |
| Pill-shaped tabs throughout | Pending cmux#46780 |
| Menu and popover radius and fill | The chat stylesheet's menu tokens only (pending cmux#46846) |

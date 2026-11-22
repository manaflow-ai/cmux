# Halo v1

A minimal look for agent chats in cmux, after a minimal chat assistant desktop app: near-monochrome
(white or near-black), airy spacing in a centered column, prompts in soft gray bubbles, a pill
message box, a header that shows its tools only on hover, and a sidebar of plain titles.

![Halo's chat](screenshots/halo-chat.png)
![Halo Dark's chat](screenshots/halo-dark-chat.png)

## Design intent

Halo v1 optimizes for calm and focus: nothing on screen but the conversation, no color but the content's, generous space around every line. Density is spacious (36 pt sidebar rows, spacious chrome). Type is the system face at 15 px with a 1.65 line height in a centered 720 px column. It sets all three chat layout keys: `agentPane.display.layout.messages` `bubbles`, `.composer` `pill`, `.header` `quiet`.

## What it reshapes

| Part | How |
| --- | --- |
| Chat layout | `agentPane.display.layout.messages` `bubbles`, `.composer` `pill`, `.header` `quiet` |
| Chat type | `agentPane.display.font.preset` `system` at 15 px with a 1.65 line height, `width` 720, no minimap |
| Sidebar | `sidebar.density` `comfortable`, no grouping, no timestamps, no icon, branch, folder, status, pull request or notification on a row, `groupPalette` `grayscale`, `controlsOnHover` |
| Chrome | `appearance.chromeStyle` `flat`, no borders, `density` `spacious`, a 260 pt sidebar of 36 pt rows (theme files) |
| Color | `themes/halo.json` (white, near-black ink, no accent color) and `themes/halo-dark.json` (near-black, off-white ink); pick the dark one with `appearance.themeFile` `halo-dark` |
| The chat's paint | `agent-pane/theme.css`: a soft gray bubble with no outline and 22 px corners, barely-there cards, links in the text's own color |
| Sidebar view | `customize/`: a hover card of the title and the last reply only; regular rows with a small dot |

With cmux#45843 also set `agentPane.composerLook` and `agentPane.emptyChatComposerPosition` (the
message box centered in an empty chat); they are not keys yet, so this look leaves them out.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/halo@feat-cmux-next
cmux setup remove manaflow-ai/halo-look
```

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

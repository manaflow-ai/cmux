# Hearth

A warm reading look for agent chats in cmux, after a warm chat assistant desktop app: serif prose
on cream paper (or a warm brown dark), your prompts as soft outlined cards on the leading edge with
the reply flowing under them, a rounded message box and a header that shows its tools only on hover.

![Hearth's chat](screenshots/hearth-chat.png)
![Hearth Dark's chat](screenshots/hearth-dark-chat.png)

## What it reshapes

| Part | How |
| --- | --- |
| Chat layout | `agentPane.display.layout.messages` `card`, `.composer` `rounded`, `.header` `quiet` |
| Chat type | `agentPane.display.font.preset` `serif` at 16 px with a 1.7 line height, `font.ui` `source-sans`, `code.scale` 0.85, `width` 760, no minimap |
| Sidebar | `sidebar.density` `comfortable`, `groupBy` `recents` under section headers, no icon, branch, folder or age on a row, `controlsOnHover` |
| Chrome | `appearance.chromeStyle` `flat`, no borders, `density` `comfortable`, a 272 pt sidebar of 32 pt rows (theme files) |
| Color | `themes/hearth.json` (cream paper, warm ink, terracotta) and `themes/hearth-dark.json` (warm brown-black, lifted terracotta); pick the dark one with `appearance.themeFile` `hearth-dark` |
| The chat's paint | `agent-pane/theme.css`: a warm-tinted prompt card with a gentle outline, ruled-page cards, warm secondary text |
| Markdown | `markdown.font.preset` `serif` at 16 px, a 72-character measure |
| Sidebar view | `customize/`: a reading hover card with the conversation in full; medium rows with a soft arc |

With cmux#45843 also set `agentPane.composerLook` and `agentPane.emptyChatComposerPosition` (the
message box centered in an empty chat); they are not keys yet, so this look leaves them out.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/hearth@feat-cmux-next
cmux setup remove manaflow-ai/hearth-look
```

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

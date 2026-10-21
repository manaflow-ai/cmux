# Chat display settings (agent chat + Markdown viewer)

User ask (2026-10-20): "make almost everything configurable in markdown viewer to be configurable in
the trajectory thing like the acp chat thing. like in 3 dots. like max width, fonts, we need to make
code fonts configurable separately too somehow?"

## Inventory: what the Markdown viewer can change today

Settings > Appearance > Markdown Viewer and the viewer's Aa popover (ReadingSettings.tsx), keys in
`markdown.*` (MarkdownViewerSettingsSchema.swift, webviews/src/pages/markdown/settings.ts):

| Markdown key | What | Carries to chat? |
| --- | --- | --- |
| `markdown.layout.width` (30–1000 ch) | text column width | yes, as `agentPane.display.width` (points: the chat lays rows out in px before paint) |
| `markdown.layout.fullWidth` | column fills the pane | yes, `agentPane.display.fullWidth` |
| `markdown.font.size` | body size | yes, `agentPane.display.font.size` (own default 14; inheriting 16 would change every chat) |
| `markdown.font.preset` (system/serif/mono) | body font | yes, `agentPane.display.font.preset`; default "markdown" follows the viewer |
| `markdown.font.lineHeight` | line height | yes, `agentPane.display.font.lineHeight` (own default 1.625, today's 22.75/14) |
| `markdown.code.scale` | code size as share of text | yes, `agentPane.display.code.scale`; unset follows the viewer |
| `markdown.code.family` | code font (cmux.json only until now) | yes, `agentPane.display.code.family`; unset follows the viewer, then the terminal font. New Settings row for the viewer too |
| `markdown.spacing.paragraph` | paragraph gap | no (v1): the chat's row estimator assumes a fixed block gap |
| `markdown.tables` (scroll/wrap) | wide tables | no: chat tables always scroll in their card |
| `markdown.theme` (app/light/dark) | page paper | no: the chat follows the terminal theme by design |
| `markdown.code.blockSize` | legacy | no |
| a169 Obsidian parity, a216 omnibar | viewer-only features | no |

## Model

One resolver, two views. The chat's value for a look key is: its own `agentPane.display.*` key when
set, else the Markdown viewer's key for the inherited ones (font preset, code family, code scale),
else the default. Sizes and width never inherit: the two views have different defaults and an
upgrade must not move anyone's chat.

Code font defaults to the terminal font in both views (the pages already get it as
`--cmux-diff-code-font-family`).

## Plumbing

- Swift `AgentPaneDisplaySetting` (CmuxNextSettings): reads the accepted values of the chat keys and
  the inherited Markdown keys from cmux.json into one flat `{dotted key: value}` map. Rows are
  `AgentPaneDisplaySettingsSchema` (Settings > Appearance > Agent Chat), agent-settable (looks only),
  so `cmux settings set`, MCP settings tools, Settings search and Cmd+Shift+P settings search all see them.
- `AgentPanePageSettings` follows the map and pushes the `display` page event; a new page gets it
  on subscribe.
- The page (`chatDisplay.ts`) resolves inheritance and ranges, sets `--cv-font-size`,
  `--cv-line-height`, `--cv-font`, `--cv-mono`, `--cv-code-scale`, `--cv-column`, and gives the row
  estimator (model.ts) the same metrics, so measured heights follow the font.
- Writes: the popover sends `pane.setDisplay {key, value|null}`; the host refuses any key outside
  `agentPane.display.*` and writes through `SettingsController.setSetting` (null removes the key).

## UI

The chat's ··· menu gets "Text & Width…", which opens a popover: width (with Full Width), font,
size, line height, code font, code size, Reset. Gallery `chat-display-menu` shows three layouts:
A popover (Recommended, matches the Markdown viewer's Aa popover), B submenu of presets, C inline
steppers in the menu. A ships.

## Motion

The popover opens through the shared `Popover` (its fade uses `--agent-motion-*`, which the motion
gate and Reduce Motion set); nothing new animates.

## Tests (failing first)

- Swift: `AgentPaneDisplaySettingTests` — inheritance map, refused values dropped, writable keys.
- Web: `chatDisplay.test.ts` — resolution order, clamping, CSS variables, estimator line height
  follows the font size.

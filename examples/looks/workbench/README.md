# Workbench

A dense, code-first look for agent threads in cmux, after a code-first agent app with a thread
sidebar: a cool neutral dark, compact rows grouped by project with each chat's sub-sessions as a
tree, a monospace-leaning chat in a wide column, prompts as flat rows marked by an accent rule, and a
square docked message box.

![Workbench's chat](screenshots/workbench-chat.png)

## What it reshapes

| Part | How |
| --- | --- |
| Chat layout | `agentPane.display.layout.messages` `flat`, `.composer` `square`, `.header` `full` |
| Chat type | `agentPane.display.font.preset` `mono` at 13 px, `font.ui` `system-ui-tight`, `code.scale` 0.95, `width` 960, `minimap` `compact`, `harnessPlacement` `compact` |
| Sidebar | `sidebar.density` `compact`, `groupBy` `folder`, `sessionTree` on, timestamps, branch and last activity on the row, `controlsOnHover`, `groupHeader.background` `sections` with member counts |
| Chrome | `appearance.chromeStyle` `flat-sidebar-line`, `density` `compact`, a 232 pt sidebar of 24 pt rows, 12 pt chrome text, a 30 pt tab strip (theme file) |
| Color | `themes/workbench.json`: blue-gray near-black, a darker sidebar, one calm blue |
| The chat's paint | `agent-pane/theme.css`: small corners, crisp card hairlines, links in the accent |
| Sidebar view | `customize/`: a terse hover card that leads with the folder and agent; regular rows with a braille spinner |

With cmux#45843 also set `agentPane.composerLook` and `agentPane.emptyChatComposerPosition`; they
are not keys yet, so this look leaves them out.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/workbench@feat-cmux-next
cmux setup remove manaflow-ai/workbench-look
```

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

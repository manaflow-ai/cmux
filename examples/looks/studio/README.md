# Studio

A quiet black workbench for agent threads, drawn after a desktop agent studio app: a pure black
sidebar that opens with New thread and Search rows, then your threads by project as cards (project
and age on top, the title under it, the agent's status and PR), with the chats you have read folded
into Settled at the end; a near-black chat in a 736 px column with filled 16 px prompt bubbles; and
one rounded composer whose model, effort and access chips sit in a row under the prompt, with a round
accent send button. It ships in three color variants: Studio (dark, the default), Studio Light and
Studio Ember.

It is built only from public surfaces, so you can copy any part of it.

## What each part draws

| Part | Drawn by |
| --- | --- |
| Sidebar top: New thread and Search rows, plain icon and label, no fill at rest | `sidebar.nav` (`palette.newAgentChat`, `search.chats`) |
| Threads by project, each a card: project and age on the first line, the title under it, the agent's status and the PR at the right | `sidebar.groupBy: folder`, `sidebar.density: comfortable`, `sidebar.showTimestamps`, `sidebar.workspaceRow.*` (directory, PR and agent status on; icon, branch and last activity off), and `customize/` (regular-weight titles, a dot while a thread works) |
| Chats you have read fold into a "Settled (N)" row at the end of their list until their next turn | `sidebar.settleFinished` |
| The selected thread a gray card, while Send and links stay blue | `"appearance.selection": "neutral"` in each theme file |
| Right-click and more-button menus in the theme's colors | `sidebar.drawnMenus` |
| A hover card per thread: project and age, title, approval, branch, PR | `customize/` (`cmux.hovercard/1`) |
| The composer: one rounded card, the prompt over a row of model, effort and access chips, the attach clip and a round accent send button at the right, the branch and checkout in a tray under it | `agentPane.composerLook: studio` |
| A new, empty chat: the composer in the middle of the pane under its heading | `agentPane.emptyChatComposerPosition: center` |
| The chat: system font, 14 px type in a 736 px column, no minimap, "Thinking" as the status verb | `agentPane.display.*` |
| The filled, borderless 16 px prompt bubble, faint cards, muted secondary text, accent links | `agent-pane/theme.css` (`cmux.agentPane.style/1` tokens, every color mixed from the theme's own) |
| Colors: black sidebar, near-black chat, white-at-8% hairlines, one bright blue | `themes/studio.json` (default), `themes/studio-light.json`, `themes/studio-ember.json` |

```sh
cmux setup install github.com/manaflow-ai/cmux-studio-look
cmux settings set appearance.themeFile studio-light    # or studio-ember; studio is the default
cmux setup remove manaflow-ai/studio-look
```

Studio's source is its own repo, [manaflow-ai/cmux-studio-look](https://github.com/manaflow-ai/cmux-studio-look): install from it and change it there.
This folder is a copy that cmux's tests check: its setup, themes, stylesheet and view are the repo's.

`cmux setup install` refuses a setup with a key the running build does not know, so the keys still in
review sit in this folder as comments naming their pull request: `sidebar.nav` (cmux#46508),
`appearance.selection` (cmux#46516), `agentPane.composerLook` and
`agentPane.emptyChatComposerPosition` (cmux#46738) and `sidebar.drawnMenus` (cmux#46879). Uncomment
each once its pull request lands. `sidebar.settleFinished` (cmux#46872) has landed and is on.

## Variants

| Variant | Switch to it |
| --- | --- |
| Studio (default) | `cmux settings set appearance.themeFile studio` |
| Studio Light | `cmux settings set appearance.themeFile studio-light` |
| Studio Ember | `cmux settings set appearance.themeFile studio-ember` |

The stylesheet makes every color from the theme's text and accent, so it reads over all three (and
over any theme of your own).

## Not yet possible

What the look reaches for and the public surface cannot set yet:

| Part | Why |
| --- | --- |
| A project badge (two letters on a colored tile) before each thread's project name | A row decoration can set title, weight, icon, indicator and badge, but not a tile before the folder line |
| Project, new folder and new thread buttons at the right of the Search row | A `sidebar.nav` row is one action; it has no trailing buttons |
| Settings, pull requests and usage buttons in the sidebar's bottom bar | The sidebar's footer is not a public surface |
| An approval strip in amber above the composer | Approval cards have no paint tokens; their colors come from the host |
| Sidebar rows with the project on the first line and the title under it, as two separate lines | `sidebar.workspaceRow.lines` validates but is not drawn; the folder line sits under the title |
| A breadcrumb title bar (project / thread) with panel toggles on the right | The title bar's content is not a public surface |
| A tab strip with no tabs: only the breadcrumb title over the chat | The workspace tab strip always draws; no setting hides it for a one-chat workspace |
| Inline code chips with a hairline and a small file-type badge | Inline code has no paint token; it keeps the chat's own filled chip |
| The "Worked for" divider line | It has no token |
| Panel animation duration in ms and a contrast slider | `ui.animationSpeed` offers fast, normal and off only; no contrast setting |
| Interface font size apart from the chat's | Only `agentPane.display.font.size` and the sidebar's text size presets are settable |
| The sidebar's row decorations alongside your own `customize/` | A look's `customize/` files replace yours (only `local/customize` may decorate rows) |

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

# Studio

A quiet black workbench for agent threads: a pure black sidebar with a hairline edge, threads grouped
by project with the age at the right of each title, a near-black chat in a comfortable 736 px column,
filled borderless prompt bubbles with soft 16 px corners, muted "Worked for" and tool rows, and one
bright blue for links and the send button. It ships in three color variants: Studio (dark, the
default), Studio Light and Studio Ember.

It is built only from public surfaces, so you can copy any part of it:

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Picks the theme file; sets the chat's system font, 14 px type and 736 px width (the line height stays at cmux's default, 1.625), a 255 px sidebar, the minimap off, and the sidebar: rows grouped by project folder (`sidebar.groupBy`), the folder, PR and agent status on each row, and the age at the right end of the title line (`sidebar.showTimestamps`) |
| `themes/studio.json` | Default. Black sidebar, near-black chat, white-at-8% hairlines, bright blue |
| `themes/studio-light.json` | Off-white chat, pale zinc sidebar, zinc hairlines, deep blue |
| `themes/studio-ember.json` | The dark layout warmed through: brown-black sidebar, warm charcoal chat, copper accent |
| `agent-pane/theme.css` | The filled 16 px prompt bubble, faint cards, muted secondary text, accent links: `cmux.agentPane.style/1` tokens only, every color mixed from the theme's own |
| `customize/` | A thread hover card (folder and age, title, approval, branch, PR) and plain rows with a dot while work runs |

```sh
cmux setup install github.com/manaflow-ai/cmux-studio-look
cmux settings set appearance.themeFile studio-light    # or studio-ember; studio is the default
cmux setup remove manaflow-ai/studio-look
```

Studio's source is its own repo, [manaflow-ai/cmux-studio-look](https://github.com/manaflow-ai/cmux-studio-look): install from it and change it there.
This folder is a copy that cmux's tests check: its setup, themes, stylesheet and view are the repo's.

## Variants

| Variant | Switch to it |
| --- | --- |
| Studio (default) | `cmux settings set appearance.themeFile studio` |
| Studio Light | `cmux settings set appearance.themeFile studio-light` |
| Studio Ember | `cmux settings set appearance.themeFile studio-ember` |

The stylesheet makes every color from the theme's text and accent, so it reads over all three (and
over any theme of your own).

## With a newer cmux

The setup carries only settings every current cmux NEXT build has, because `cmux setup install`
refuses a setup with a key the running build does not know. These surfaces are off by default and in
review; once your build has them, add them yourself for the rest of the look:

| Part | Add | Needs |
| --- | --- | --- |
| A Search row at the top of the sidebar | `cmux settings set sidebar.nav '["search.chats \| Search \| magnifyingglass"]'` | cmux #46508 |
| A chat row's age at the right of its title (folder rows have it today) | nothing: `sidebar.showTimestamps` is already on | cmux #46506 |
| A neutral gray card for the selected row while Send and links stay blue | `"appearance.selection": "neutral"` in your copy of the theme file | cmux #46516 |
| The composer: a rounded card with the model, effort and access chips in one bottom row and a round accent send button | `cmux settings set agentPane.composerLook studio` | the composer look setting (lane/composer-look-setting) and its `studio` look |
| The prompt bubble at about 80% of the column | `cmux settings set agentPane.display.transcriptTokens '{"userMessage.maxWidth": 0.8}'`, or the whole preset with `agentPane.display.transcriptLook studio` | cmux #46047, #46258 |

## Not yet possible

What the look reaches for and the public surface cannot set yet:

| Part | Why |
| --- | --- |
| An approval strip in amber above the composer | Approval cards have no paint tokens; their colors come from the host |
| A centered heading over the composer in an empty thread | The empty chat's layout is built in; no setting or token moves it |
| Sidebar rows with the project on the first line and the title under it | `sidebar.workspaceRow.lines` validates but is not drawn; a row decoration can set title, weight, icon, indicator and badge, not reorder lines |
| A breadcrumb title bar (project / thread) with panel toggles on the right | The title bar's content is not a public surface |
| A tab strip with no tabs: only the breadcrumb title over the chat | The workspace tab strip always draws; no setting hides it for a one-chat workspace |
| Inline code chips with a hairline and a small file-type badge | Inline code has no paint token; it keeps the chat's own filled chip |
| The "Worked for" divider line | It has no token |
| Panel animation duration in ms and a contrast slider | `ui.animationSpeed` offers fast, normal and off only; no contrast setting |
| Interface font size apart from the chat's | Only `agentPane.display.font.size` and the sidebar's text size presets are settable |
| The sidebar's row decorations alongside your own `customize/` | A look's `customize/` files replace yours (only `local/customize` may decorate rows) |

How looks like this one are written: [docs/cmux-next/look-addons.md](../../../docs/cmux-next/look-addons.md).

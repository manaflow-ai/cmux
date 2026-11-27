# Web coding app profile

A cmux profile that looks and works like a light web coding agent: a white page on a light-gray frame,
a one-line session list grouped by folder, a centered chat column with your prompt in a gray bubble,
unified diffs, and the keys that app's users reach for.

It is built only from public surfaces (`docs/cmux-next/look-addons.md`, `cmux setup`), so every row
below that is not matched names the cmux change it waits on.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/web-coding-app/profile@feat-cmux-next
cmux setup check examples/looks/web-coding-app/profile   # offline check of this folder
```

| File | What it sets |
| --- | --- |
| `cmux-setup.json` | sidebar, tabs, chat column, diff and attention settings, the motion switches |
| `themes/web-coding-app.json` | page and frame colors, plus requested native hover timings |
| `agent-pane/theme.css` | the chat’s text and prompt colors, hover and fold durations |
| `keybindings.json` | new chat, step sessions, reopen, unread, model, effort, mode, shortcut search |

Remove it with `cmux setup remove manaflow-ai/web-coding-app-profile`; everything you had comes back.

## Feature checklist

46 features of the reference, graded against cmux with this profile on: 22 matched, 20 partial, 4 missing.
The first grading, before this profile's keys, read 20, 20 and 6: Command-1 to 9 and jump-to-unread now walk sessions,
reopen has a key, and the mode menu has one.

### Keyboard

| Feature | Status | How, or what is missing |
| --- | --- | --- |
| New chat with one key | matched | `cmd+n` runs `palette.newAgentChat` |
| Walk session tabs by key | matched | `cmd+shift+[` / `]` step sessions, `cmd+1`..`9` pick one (`tabs.commandDigits`), `cmd+shift+u` jumps to unread |
| Reopen a closed session tab | matched | `cmd+shift+t` runs `reopenClosedWorkspace` (a session is a workspace here) |
| Command palette | matched | the Command Palette |
| Searchable shortcut list and rebinding | partial | `cmd+/` searches shortcuts; rebinding is `keybindings.json`, not a Shortcuts page in Settings |
| Leader-key chords | missing | cmux binds single chords only; a terminal-client convention, low value in the GUI |
| Escape interrupts the turn | partial | cmux stops on Esc Esc within 1.6 s; the reference stops on one Esc. No setting for a single Esc |

### Panels

| Feature | Status | How, or what is missing |
| --- | --- | --- |
| Session list sidebar | partial | one line per session, grouped by folder; no projects rail beside a per-project list with search |
| Sidebar toggle | matched | the titlebar sidebar button |
| Embedded terminal panel | partial | terminal tabs and splits, not a drawer under the chat |
| In-app browser preview | matched | the browser panel and browser tabs |
| Changed-files tree / review panel | matched | the edited-files card, folded (`agentPane.editedFiles.show`) |

### Diff review

| Feature | Status | How, or what is missing |
| --- | --- | --- |
| Per-turn file diff card with +N -M | matched | the edited-files card per turn |
| Unified diff layout | matched | `diff.layout: unified` |
| Comment on a diff line and send it to the agent | partial | diff comments exist; not yet verified that a line comment becomes the next prompt |
| Mark file reviewed | matched | the diff viewer's Viewed toggle |
| Hunk and file navigation keys | partial | the diff viewer has `diffViewerNextHunk` / `diffViewerNextFile`; the profile keeps cmux's keys for them |

### Agents and plan mode

| Feature | Status | How, or what is missing |
| --- | --- | --- |
| Plan vs build agent | matched | the composer's Plan toggle and `/plan` |
| Cycle agents with shift+tab | partial | `ctrl+shift+a` opens the mode menu (`agentPane.setMode`); no one-key cycle action, and shift+tab stays the composer's |
| Agent chip in the composer | partial | mode and harness chips; no named custom-agent chip |
| Subagent child sessions | matched | subagent rows open a read-only child view |

### Slash commands and attachments

| Feature | Status | How, or what is missing |
| --- | --- | --- |
| Slash command menu | matched | `/` lists cmux's commands and the harness's own |
| Custom markdown commands | partial | the harness's own custom commands show; no cmux command folder with `$ARGUMENTS` |
| Undo / redo a turn | partial | rewind to before a turn; no redo |
| Compact the context | matched | `/compact` |
| Shell mode with a leading ! | matched | `!` in the composer |
| Side question that stays out of the chat | partial | option-return sends a side message; not verified it stays out of the transcript |
| @ file mention with fuzzy search | matched | `@` file search |
| Paste images and files | matched | paste attaches |
| Composer placeholder naming / and @ | partial | no setting for the placeholder text |

### Status and progress

| Feature | Status | How, or what is missing |
| --- | --- | --- |
| Word-by-word streaming with a fading tail | partial | cmux reveals by characters with a 120 ms fade; waits on `agentPane.display.streaming` |
| Queued prompts while busy | matched | `cmd+return` queues |
| Permission prompt: once / always / reject | matched | the permission card |
| Todo list from the agent | matched | the task strip |
| Context usage / cost | partial | the context ring; cost not shown |
| Busy spinner in the session header | matched | the chat status indicator |

### Pickers and settings

| Feature | Status | How, or what is missing |
| --- | --- | --- |
| Model picker with search and favorites | matched | `ctrl+shift+m` |
| Effort submenu beside each model | partial | a separate effort menu (`ctrl+shift+e`), not a submenu off the hovered model |
| Cycle recent models by key | missing | no model-cycle action |
| Provider connect / disconnect page | partial | accounts connect from the composer's account card; no Providers list in Settings |
| Choose which models appear in the picker | missing | favorites only |
| Settings as a modal over the app | missing | Settings is a page |

### Sessions, sharing and theme

| Feature | Status | How, or what is missing |
| --- | --- | --- |
| Rename / delete session | partial | rename and delete; pin not verified |
| Session share link | partial | copy chat link and machine share; no public share page |
| Light theme, white page on a light-gray frame | partial | the theme file paints it; cmux's own toolbar chrome stays |
| Centered narrow chat column, prompts in gray bubbles | partial | `agentPane.display.width: 760`, `presentation: messages`, the stylesheet's bubble; not yet seen in a capture with a sent prompt |

## Motion checklist

| Motion | Reference | cmux with this profile | Status |
| --- | --- | --- | --- |
| Streaming text reveal | word by word, each word fades in over about 200-300 ms | characters, 120 ms fade | partial: waits on `agentPane.display.streaming` |
| Diff / file card enter | within one frame | uses the shared card transition | partial: enter timing unverified |
| Collapsible row hover | background 150 ms ease | 150 ms for chat controls using the quick transition | partial: row timing unverified |
| Collapsible chevron rotate | 150 ms ease | 150 ms shared transcript fold duration | partial: curve and rendered timing unverified |
| List header / icon fade | opacity 150 ms ease | control-specific fades can cap the shared duration | partial: individual controls unverified |
| Popover / model picker open | no transition | no transition | matched |
| Spinner | dot grid, still under reduced motion | status spinner, still under reduced motion | partial: shape differs |
| Reduced motion | animations off | follows the system setting, plus `ui.animations.enabled` | matched |
| Message send, dialog open, button press | not measured | control-specific durations | unmeasured |

The chat stylesheet sets `--cmux-motion-quick` and `--cmux-motion-settle` to 150 ms. The native theme also requests 0.15 seconds for `motion.fades.hover` and `motion.fades.hoverOut`. See `docs/cmux-next/extensions/behavior-motion-gaps.md` for the available profile controls.

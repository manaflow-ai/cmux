# Customize recipes

Thirteen ready-made changes to cmux. Press **Run** on a recipe's command to try it: cmux changes at
once, as a preview. Nothing is kept until you apply it.

- Keep it: `cmux customize apply`
- Put back what you had: `cmux customize discard`
- Change your mind later: `cmux customize rollback` (every apply is numbered, and nothing is lost)

Want it a little different? Ask instead, in your own words, and an agent changes it while you
watch: `cmux customize 'make the sidebar compact'`. Each recipe below gives a wish to start from.

Reading this outside cmux? Run `cmux customize recipes --open` once. It puts the recipe files in
`~/.local/state/cmux/customize/recipes` and opens this page in cmux, where each command has a
Run button.

## Look

### A tiling window manager look

Hard pane borders, small gaps, a rail sidebar, no motion.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/tiling-look.json
```

Or ask: "make it look like a tiling window manager"

### Calm: no motion

Nothing slides, pulses or blinks, and status is quieter.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/calm.json
```

Or ask: "turn off the animations and make it calm"

### Glass

See-through glass behind the window, with a lighter sidebar.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/glass.json
```

Or ask: "make the window see-through glass"

## Layout

### A compact sidebar

A narrower sidebar with shorter rows. Its buttons show when you point at it.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/compact-sidebar.json
```

Or ask: "make the sidebar compact"

### Vertical tabs

Tabs in a column beside the panes instead of a strip above them.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/vertical-tabs.json
```

Or ask: "put my tabs in a vertical list"

## Type

### A different font

Geist in the chats, Menlo in the terminal and the editor, a serif for Markdown pages.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/different-font.json
```

Or ask: "use Geist in the chats and Menlo for code"

### Larger text

Bigger text in the sidebar, the chats, the terminal and Markdown pages.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/larger-text.json
```

Or ask: "make the text bigger everywhere"

## Widgets

A widget recipe is your views app (`~/.config/cmux/customize`). While it previews, it takes the
place of a views app you already have; Discard brings yours back.

### Your pull requests in the sidebar

Your open pull requests and the reviews you owe, live in the sidebar. It reads GitHub through
your connected account, or asks for your login.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/pr-widget.json
```

Or ask: "add a PR widget to the sidebar"

### The time and the weather

The time and the weather where you are, at the bottom of the sidebar.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/clock-weather.json
```

Or ask: "show the time and the weather in the sidebar"

## Keys

### Move between panes with H J K L

Control-Command-H, J, K and L move to the pane on the left, below, above and on the right, like
Vim. While it previews, it takes the place of your own `keybindings.json`; if you have one, ask
instead and the agent adds these keys to yours.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/pane-keys.json
```

Or ask: "let me move between panes with ctrl-cmd-h, j, k and l"

## App looks

Each of these makes cmux look and work like an agent app: the colors, the sidebar, the chat and
the composer, and also the app's keys, its panels and how a new chat starts. Each turns on a
theme file of its own and a chat stylesheet, so to make one your own, edit
`~/.config/cmux/themes/NAME.json` and `~/.config/cmux/agent-pane/theme.css` after you apply it.

Only what a recipe names changes. Its keys go into your `keybindings.json` beside your own, and
each key it takes from cmux stays in the Command Palette. Each table says how the recipe gives
one of the app's features, and what cmux can't do yet.

### Like the Codex app

A gray sidebar of your chats by project with how long ago each ran, a white page, your prompts
in gray pills, and a large rounded composer. Shift-Command-O starts a Codex chat, a button on
the tab bar opens the diff, and a chat whose turn ended rings until you look at it.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/codex-app.json
```

Or ask: "make cmux look and work like the Codex app"

| Feature | How the recipe does it | Gap |
| --- | --- | --- |
| Threads by project | `sidebar.groupBy` `folder`, `sidebar.showTimestamps` | No Pinned and Recents sections above the projects |
| Threads home | `tabs.newTabTemplate` `threads`: New Tab lists your chats | |
| New thread | Shift-Command-O: New Agent Chat with Codex (`palette.newAgentChat`, `harness: codex`) | It opens as a tab in this workspace, not as its own sidebar row. Shift-Command-O was Restore Previous App Launch |
| Composer: Return sends, attachments | Return sends already; `agentPane.attachmentView` `strip` | |
| Model and reasoning picker | Control-Shift-M: Switch Model; effort with Set Agent Chat Effort in the palette | No effort picker in the composer |
| Approval modes | The mode menu (Set Agent Chat Mode) per chat | A recipe can't set `agents.defaultPermissionMode` (only you can), nor the Codex approval mode in its own config |
| Local, worktree or cloud thread | Local by default; New Git Worktree and New Cloud Chat in the palette | No "new chat in its own worktree" choice |
| Review pane | Control-Shift-G and a tab bar button open the diff (`tabs.toolbarButtons`), `diff.layout` `unified`; commit and push from the palette | No staged and unstaged scopes, no per-hunk stage or revert, no review comments sent to the agent |
| Terminal | Control-backtick opens a terminal tab already | No terminal panel that one key shows and hides |
| Files | Shift-Command-E shows the files beside the chat | |
| Switch threads | Shift-Command-[ and ] step through the sidebar; Command-1 to 9 already | |
| Done notice | `notifications.attention.agentChats` `ring` | |
| Keyboard shortcuts list | Command-/ searches the shortcuts | |
| Automations | Automations in the palette | A recipe can't carry automations or actions |
| Skills | Your skills in `~/.config/cmux/skills` reach every chat already | No skills browser |

### True black, chats by project

True black, a dense sidebar of chats by project with the branch under each name, a narrow chat
column and an indigo accent. A Threads section in the sidebar puts the chats that need you
first, with running ones on a shelf below. Shift-Command-O starts a Codex chat, Shift-Command-M
picks the model, and a button on the tab bar opens the diff. The Threads section is a views app:
while it previews, it takes the place of one you already have, and Discard brings yours back.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/true-black.json
```

Or ask: "make cmux true black with a dense sidebar of chats by project"

| Feature | How the recipe does it | Gap |
| --- | --- | --- |
| Threads per project, the ones that need you first | `sidebar.groupBy` `folder`, `sidebar.groupHeader.unreadCount`, and the Threads section (your views app) | Threads can't be settled or snoozed |
| What waits on you | `agentPane.needsYou.enabled`: a count in the chat header | |
| New thread | Shift-Command-O: New Agent Chat with Codex | It opens as a tab in this workspace. Shift-Command-O was Restore Previous App Launch |
| Worktree per thread | New Git Worktree in the palette, then a chat in it | No setting starts every new chat in its own worktree |
| Git panel | A tab bar button opens the diff; commit and push from the palette | No one step that commits, pushes and opens a pull request |
| Model picker | Shift-Command-M: Switch Model (was Copy Mode) | |
| Full access or supervised | The mode menu per chat | A recipe can't set `agents.defaultPermissionMode` (only you can), nor the agent's own mode in its config |
| Terminal drawer | Control-backtick opens a terminal tab | No drawer that one key shows and hides (Command-J starts cmux's key sequences) |
| Split terminal | Command-D and Shift-Command-D already | |
| Switch threads | Shift-Command-[ and ] step through the sidebar; Command-1 to 9 already | |
| Default model for new threads | | No cmux setting picks the agent or model of a new chat, and a recipe does not edit the agent's own config |

### Like the Claude Code desktop app

A warm dark page, your sessions by project in the sidebar with their branch and pull request,
the clay accent, and tool rows that show each file and its line counts. Command-N starts a
Claude chat, Shift-Command-M opens the mode menu (plan mode is in it), and new panes open beside
the chat.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/claude-code-app.json
```

Or ask: "make cmux look and work like the Claude Code desktop app"

| Feature | How the recipe does it | Gap |
| --- | --- | --- |
| Sessions by project | `sidebar.groupBy` `folder`, `sidebar.workspaceRow.branch`, `sidebar.workspaceRow.pullRequest` | |
| New session | Command-N: New Agent Chat with Claude (`harness: claude`) | It opens as a tab in this workspace. Command-N was New Workspace |
| Permission modes, plan mode | Shift-Command-M: the mode menu, with plan mode (was Copy Mode) | A recipe can't set `agents.defaultPermissionMode` (only you can), nor the default mode in Claude Code's own settings. No Accept edits or Auto mode of cmux's own |
| Model and effort | Shift-Command-I: Switch Model; Shift-Command-E: Set Effort | |
| Type / for commands | The composer's / menu already | |
| Return sends, Shift-Return a new line | Already | |
| Preview | Shift-Command-B shows the preview beside the chat (was the bookmarks bar) | |
| Terminal, tasks and changes panels | `layout.newPanePlacement` `split`; `agentPane.display.sessionInfo.placement` `push`; a tab bar button opens the diff; `agentPane.editedFiles.scope` `session` | No terminal panel that one key shows and hides |
| Next and previous session | Shift-Command-[ and ] | |
| Close a pane | Command-\ | |
| Keyboard shortcuts | Command-/ opens them | |
| Worktree per session | New Git Worktree in the palette | No "work in a worktree" switch under the composer |
| Side chat, cycle the view | | No side chat action and no action that cycles `agentPane.display.transcriptView` |

## For agents and scripts

- `cmux customize recipes --json` lists every recipe: its name, title, group, wish, what it
  changes and the path of its file. The MCP tool `customize_recipes` returns the same.
- Try one with `cmux customize use PATH` (MCP `customize_use {profile: PATH}`). It is checked
  whole before anything is written, so a recipe that does not fit this cmux changes nothing.
- Apply and discard are the person's call.
- A recipe is a profile file, the format `cmux customize save NAME` writes. Save your own setup
  the same way to share it.

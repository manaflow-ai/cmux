# Customize recipes

Ready-made changes to cmux. Press **Run** on a recipe's command to try it: cmux changes at
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

To put glass behind a piece of a view of your own, see [glass.md](glass.md).

### Hairline: flat and neutral

Opaque gray surfaces on one-pixel lines, one corner radius for panes, tabs, cards and the
composer, a 2 px ring for focus, and no glass or shadows. The chat uses a dense 14 px Inter, the
Markdown viewer the system font at the same size, and links are underlined text. It carries three palettes, each dark and light:
`hairline` (zinc, 8 px corners), `hairline-slate` (6 px) and `hairline-stone` (10 px); switch with
`cmux settings set appearance.themeFile hairline-slate`. The same look installs from
`examples/looks/hairline`.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/hairline.json
```

Or ask: "make cmux flat and neutral: gray surfaces, one-pixel lines, one corner radius, a focus ring and no glass"

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

Each of these changes the whole window at once: the colors, the sidebar, the chat and the
composer. Each turns on a theme file of its own and a chat stylesheet, so to make one your own,
edit `~/.config/cmux/themes/NAME.json` and `~/.config/cmux/agent-pane/theme.css` after you apply it.

### Like the Codex app

A gray sidebar of your chats by project with how long ago each ran, a white page, your prompts
in gray pills, and a large rounded composer.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/codex-app.json
```

Or ask: "make cmux look and work like the Codex app"

### Like the Claude desktop app

The Claude desktop app's Code tab, dark, with colors measured from the real app: a #191919 page,
a warm #282524 sidebar with a 1 pt line at its edge, sessions under their project with sub-sessions
nested under the session that started them, title-only rows, a one-line #303030 composer with a
1 pt edge and 12 pt corners, and your prompt in a #252525 pill. It ships its theme file
(`themes/claude-code-app.json`) and chat stylesheet (`agent-pane/theme.css`), so you can copy and
change either.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/claude-code-app.json
```

Or ask: "make cmux look and work like the Claude desktop app's Code tab"

### Claude Code notification levels

Show banners for permission requests, badges for questions, and turn task-complete alerts off.
The profile maps Claude Code’s `permission_request`, `question`, and `task_complete` events
to `notifications.delivery.permissionRequest`, `.question`, and `.taskComplete`.
Source: Claude Code 6.28899.6, `app.asar`, `index.chunk-CknhaMei.js`, bytes 294195–294880.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/claude-code-notification-levels.json
```

Or ask: "show permission banners and question badges, with task-complete alerts off"

## For agents and scripts

- `cmux customize recipes --json` lists every recipe: its name, title, group, wish, what it
  changes and the path of its file. The MCP tool `customize_recipes` returns the same.
- Try one with `cmux customize use PATH` (MCP `customize_use {profile: PATH}`). It is checked
  whole before anything is written, so a recipe that does not fit this cmux changes nothing.
- Apply and discard are the person's call.
- A recipe is a profile file, the format `cmux customize save NAME` writes. Save your own setup
  the same way to share it.

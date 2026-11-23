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

## For agents and scripts

- `cmux customize recipes --json` lists every recipe: its name, title, group, wish, what it
  changes and the path of its file. The MCP tool `customize_recipes` returns the same.
- Try one with `cmux customize use PATH` (MCP `customize_use {profile: PATH}`). It is checked
  whole before anything is written, so a recipe that does not fit this cmux changes nothing.
- Apply and discard are the person's call.
- A recipe is a profile file, the format `cmux customize save NAME` writes. Save your own setup
  the same way to share it.

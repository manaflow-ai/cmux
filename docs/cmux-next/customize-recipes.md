# Customize recipes

Sixteen ready-made changes to cmux. Press **Run** on a recipe's command to try it: cmux changes at
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

### True black, chats by project

True black, a dense sidebar of chats by project with the branch under each name, a narrow chat
column and an indigo accent.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/true-black.json
```

Or ask: "make cmux true black with a dense sidebar of chats by project"

### Like the Claude Code desktop app

A warm dark page, your chats by project in the sidebar, the clay accent, and tool rows that show
each file and its line counts.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/claude-code-app.json
```

Or ask: "make cmux look and work like the Claude Code desktop app"

## Rices

A rice is a whole themed look, the way people theme a Linux desktop: every terminal color, the
sidebar, glass, borders, motion, a wallpaper, the chat, the composer and the fonts, all in one
palette. Each turns on a theme file of its own and a chat stylesheet; to make one yours, edit
`~/.config/cmux/themes/NAME.json` and `~/.config/cmux/agent-pane/theme.css` after you apply it.

### Sakura: cherry blossom

A hanami night: plum glass over Van Gogh's Almond Blossom, petal pink for whatever is active, cherry
for errors, a mint counterpoint from the painting's sky. Floating panes, a petal-shaped prompt
bubble and a pink-rimmed composer, Hanken Grotesk in the chat and PT Mono in the terminal.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/sakura.json
```

Or ask: "rice cmux with a cherry blossom theme, pink and plum everywhere"

### Two-Tone: ink and amber

Two inks and nothing else. A curved ink pane on a deeper ink sidebar, amber only for what matters
(the cursor, a running agent, a link, the send button), and a terminal whose colors are tints of
amber and cream. Klimt's gold glows faintly behind the sidebar. Geist in the chat, Monaco in the
terminal.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/two-tone.json
```

Or ask: "rice cmux in two tones, ink and amber only"

### Great Wave: Hokusai and Kanagawa

Hokusai's Great Wave behind sumi-ink glass, with the Kanagawa palette in every terminal color:
rice-paper text, wave blue, carp ochre headings and a sakura-pink quote bar. IBM Plex Sans in the
chat and Menlo in the terminal.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/great-wave.json
```

Or ask: "rice cmux with the Great Wave and the Kanagawa colors"

What a rice can't carry yet: a font file (the terminal font must be one the Mac has, and the chat
font one cmux bundles) and a picture of its own (the wallpaper is one of the paintings cmux ships).

## For agents and scripts

- `cmux customize recipes --json` lists every recipe: its name, title, group, wish, what it
  changes and the path of its file. The MCP tool `customize_recipes` returns the same.
- Try one with `cmux customize use PATH` (MCP `customize_use {profile: PATH}`). It is checked
  whole before anything is written, so a recipe that does not fit this cmux changes nothing.
- Apply and discard are the person's call.
- A recipe is a profile file, the format `cmux customize save NAME` writes. Save your own setup
  the same way to share it.

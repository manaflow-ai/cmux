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

### Lamina

A layered, translucent desktop look in four variants, each dark and light. Pick one; each turns on a theme file and a chat stylesheet of its own (`themes/NAME.json`, `agent-pane/theme.css`). Each variant is also a whole look, `examples/looks/lamina`, `lamina-mist`, `lamina-slate` and `lamina-tide` (`cmux setup install github.com/manaflow-ai/cmux/examples/looks/NAME@feat-cmux-next`); their READMEs list what each surface gets.

#### Lamina

Layered, translucent and compact: a frosted sidebar under squarer content cards, 4 point controls, 8 point panes and cards, one-point strokes, an accent mark on the selected row, and a toast that is an 8 point card instead of a pill.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/lamina.json
```

Or ask: "make cmux look like Lamina, compact and balanced"

#### Lamina light

Layered, translucent and compact: a frosted sidebar under squarer content cards, 4 point controls, 8 point panes and cards, one-point strokes, an accent mark on the selected row, and a toast that is an 8 point card instead of a pill. Light.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/lamina-light.json
```

Or ask: "make cmux look like Lamina, compact and balanced, light"

#### Lamina Mist

Lamina, cooler and more see-through: a blue-gray tint, clear glass behind the window, a card sidebar and a looser density.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/lamina-mist.json
```

Or ask: "make cmux look like Lamina Mist, cool and more translucent"

#### Lamina Mist light

Lamina, cooler and more see-through: a blue-gray tint, clear glass behind the window, a card sidebar and a looser density. Light.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/lamina-mist-light.json
```

Or ask: "make cmux look like Lamina Mist, cool and more translucent, light"

#### Lamina Slate

Lamina, neutral, flatter and denser: no glass, solid layers, tighter rows and a line between the panes.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/lamina-slate.json
```

Or ask: "make cmux look like Lamina Slate, neutral, flatter and denser"

#### Lamina Slate light

Lamina, neutral, flatter and denser: no glass, solid layers, tighter rows and a line between the panes. Light.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/lamina-slate-light.json
```

Or ask: "make cmux look like Lamina Slate, neutral, flatter and denser, light"

#### Lamina Tide

Lamina with the accent forward: teal marks, carded sidebar sections and a thicker status ring.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/lamina-tide.json
```

Or ask: "make cmux look like Lamina Tide, accent-forward teal"

#### Lamina Tide light

Lamina with the accent forward: teal marks, carded sidebar sections and a thicker status ring. Light.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/lamina-tide-light.json
```

Or ask: "make cmux look like Lamina Tide, accent-forward teal, light"

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

### Ukiyo-e: the Great Wave

Hokusai's Great Wave behind frosted washi paper, Prussian-blue ink, a two-tone window and serif pages. It ships its theme file (`themes/ukiyo-e.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/ukiyo-e.json
```

Or ask: "make it look like a Japanese woodblock print"

### Hiroshige at dusk

Hiroshige's coast at Hota behind dark glass, warm paper ink and a vermilion accent, floating panes. It ships its theme file (`themes/hiroshige-dusk.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/hiroshige-dusk.json
```

Or ask: "make it look like a Hiroshige print at dusk"

### Fuji in mist

Hokusai's Umezawa Manor and Mount Fuji behind pale frosted glass, sea-green ink, a two-tone window. It ships its theme file (`themes/fuji-mist.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/fuji-mist.json
```

Or ask: "make it pale and misty like a Hokusai Fuji view"

### Nio guardian

Kano Hogai's Nio guardian behind dark glass, umber panes and a gold-leaf accent on cards. It ships its theme file (`themes/nio-guardian.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/nio-guardian.json
```

Or ask: "make it dark and warm like a Kano school painting"

### Sumi ink

Black ink on rice paper and one seal-red mark: no picture, a hairline sidebar, serif pages. It ships its theme file (`themes/sumi-ink.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/sumi-ink.json
```

Or ask: "make it black ink on rice paper"

### Water lilies

Monet's water lilies behind frosted glass, pond greens and blues, a two-tone window. It ships its theme file (`themes/water-lilies.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/water-lilies.json
```

Or ask: "make it look like Monet's water lilies"

### Starry night

Van Gogh's Starry Night behind dark glass, night blue and a star-yellow accent, floating panes. It ships its theme file (`themes/starry-night.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/starry-night.json
```

Or ask: "make it look like The Starry Night"

### Gilded

Klimt's The Kiss behind dark glass, gold-leaf accent on cards, serif pages. It ships its theme file (`themes/gilded.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/gilded.json
```

Or ask: "make it gold like a Klimt painting"

### Moonrise

Friedrich's Two Men Contemplating the Moon behind frosted glass, moss and moonlight, a flat window. It ships its theme file (`themes/moonrise.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/moonrise.json
```

Or ask: "make it quiet and moonlit like Friedrich"

### Engraving

A Dore engraving behind dark glass, pure grays, separate panes and serif pages. It ships its theme file (`themes/engraving.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/engraving.json
```

Or ask: "make it black and white like a Dore engraving"

### Aurora

The living Aurora wallpaper behind clear glass, polar night blue and a green-teal accent, floating panes. It ships its theme file (`themes/aurora-night.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/aurora-night.json
```

Or ask: "put a moving aurora behind the window"

### Still water

The living Ripples wallpaper behind glass, deep teal and a pale cyan accent on cards. It ships its theme file (`themes/still-water.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/still-water.json
```

Or ask: "put moving ripples behind the window"

### Deep currents

The living Currents wallpaper behind glass, ocean blue and a bright blue accent, floating panes. It ships its theme file (`themes/deep-currents.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/deep-currents.json
```

Or ask: "put moving ocean currents behind the window"

### Dot grid

The living Dot Field wallpaper behind frosted glass, black and white only, block panes and Geist type. It ships its theme file (`themes/dot-grid.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/dot-grid.json
```

Or ask: "put a moving dot grid behind a black and white window"

### Aero sky

The living Aero wallpaper behind light glass, sky blue and a bright blue accent, floating panes. It ships its theme file (`themes/aero-sky.json`).

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/aero-sky.json
```

Or ask: "put a glossy moving sky behind a light window"

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

### A review desk

The chat stays the main pane and every diff, file and link it opens lands in a column on its
right; new terminals split instead of stacking as tabs; the edited-files card stays open; the tab
bar gets Split Right, Split Down, Open Diff Viewer and Zoom. Shift-Command-D opens the diff, and in
the diff `] F`, `[ F`, `N`, `Shift-N` and `G G` step files and hunks. Two palette actions show the
branch against main and start Claude to review it. It brings its own `keybindings.json`, so while
it previews it takes the place of yours.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/review-desk.json
```

Or ask: "set up a review layout with the chat, the diff and a terminal side by side"

### Every bar at the bottom

The tab bars, the browser and Markdown address bars, the sidebar's spaces, the Chief and docked
columns all move to the bottom edge.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/bottom-deck.json
```

Or ask: "move the tab bar, the address bars and the docks to the bottom"

### Workspaces like browser tabs

Each workspace is one line, groups get a colored rail like a browser's tab groups, Command-1 to 9
picks a workspace, and you drag a workspace onto a pane's edge to show it beside yours.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/workspace-tabs.json
```

Or ask: "make my workspaces work like browser tabs"

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

### Editorial type

IBM Plex for the interface, a serif for the chats and Markdown pages, roomier lines.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/editorial-type.json
```

Or ask: "use a serif for the chats and the pages"

### Readable type

Atkinson Hyperlegible for the interface and chats, a little larger with open lines.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/readable-type.json
```

Or ask: "use the most readable font everywhere"

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

### A keyboard mode on Command-J

Press Command-J, let go, then one key: V or minus splits, Z zooms, E evens the splits, O floats
the pane, C opens a terminal tab, A a chat beside you, D the diff, B hides the sidebar, X closes
the tab, ] and [ step workspaces. Command-J W, R or M, then H, J, K or L, moves focus, resizes or
moves the tab. Command-J is cmux's own leader, so no key a terminal or a chat types is taken. Like
the pane keys, it takes the place of your own `keybindings.json` while it previews.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/leader.json
```

Or ask: "give me leader keys to split, zoom, resize and move panes"

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

### Like the Codex app, dark

A near-black page, a quiet sidebar of chats by project, white ink and grays with no color accent,
and a rounded composer. It ships its theme file (`themes/codex-app-dark.json`) and chat stylesheet
(`agent-pane/theme.css`); the colors are matched by eye, not measured.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/codex-app-dark.json
```

Or ask: "make cmux look like the Codex app, in dark"

### A violet coding app

A violet-black page, threads by project in a separate sidebar, lavender ink, a pink accent and card
panes. It ships its theme file (`themes/violet-app.json`) and chat stylesheet
(`agent-pane/theme.css`); the colors are matched by eye, not measured.

```sh
cmux customize use ~/.local/state/cmux/customize/recipes/violet-app.json
```

Or ask: "make cmux look like a violet desktop coding app"

## For agents and scripts

- `cmux customize recipes --json` lists every recipe: its name, title, group, wish, what it
  changes and the path of its file. The MCP tool `customize_recipes` returns the same.
- Try one with `cmux customize use PATH` (MCP `customize_use {profile: PATH}`). It is checked
  whole before anything is written, so a recipe that does not fit this cmux changes nothing.
- Apply and discard are the person's call.
- A recipe is a profile file, the format `cmux customize save NAME` writes. Save your own setup
  the same way to share it.

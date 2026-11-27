# Make cmux look like anything, without breaking it

A whole look for cmux NEXT (colors, the sidebar, glass, borders, motion, fonts, the wallpaper) is one
file: `~/.config/cmux/themes/<name>.json`. You don't need a build or a restart, and a mistake can't
break the app. This page gives the steps, the shipped looks to start from, and how to undo a look.
Ready-made changes you try with one click: [customize recipes](customize-recipes.md).
The full key list is in [the cmux-customization skill](../../skills/cmux-customization/SKILL.md#rice-cmux).

## Five steps

1. Pick the shipped look closest to what you want (below) and copy it:
   `cp ~/Applications/"cmux NEXT DEV.app"/Contents/Resources/theme-files/phosphor.json ~/.config/cmux/themes/mine.json`
   (or copy it from `Resources/theme-files/` in a checkout).
2. Turn it on: `cmux settings set appearance.themeFile mine`. In the palette, the Theme File row
   previews each file on the whole app as you move over it.
3. Edit `mine.json` and save it. The running app repaints at once.
4. If a key or value is wrong, cmux drops only that key and shows a toast naming the file and the
   key. Fix the key and save again.
5. To go back, run `cmux settings reset appearance.themeFile`. Your cmux-next.json is never changed
   by a theme file.

## Shipped looks

Each one is in the Theme File list by name. Your own file with the same name wins.

| Name | The look | The keys that make it |
|---|---|---|
| `harbor` | Harbor-blue glass over a painting | `appearance.background`, `appearance.surfaces.*`, `terminal.fontFamily` |
| `classic-desktop` | A 90s desktop: gray chrome, hard edges, navy selection, no motion | `appearance.chromeStyle: "blocks"`, `sidebar.borderWidth`, `ui.animationSpeed: "off"`, `appearance.backgroundBlur: "none"` |
| `phosphor` | A green-screen terminal | `appearance.theme: "Green Phosphor CRT"`, `appearance.chromeStyle: "bare"`, `appearance.borders: "none"`, `appearance.statusIndicator.style: "braille"` |
| `claude-desktop` | Warm paper and clay | `appearance.theme: "Claude Light"`, a clay `colors.accent`, a beige `appearance.surfaces.sidebar.color` |
| `charcoal` | A quiet dark chat app | a charcoal `colors.background`, a near-black sidebar, `appearance.accent: "neutral"` |
| `moss` | A forest floor: deep green blocks with no lines, a lichen accent | `appearance.chromeStyle: "blocks"`, `appearance.theme: "Everforest Dark Hard"`, a darker `appearance.surfaces.sidebar.color` |
| `meadow` | Moss in daylight: sage and cream blocks, a fern-green accent | `appearance.chromeStyle: "blocks"`, `appearance.theme: "Everforest Light Med"`, a sage `appearance.surfaces.sidebar.color` |
| `lily-pond` | See-through teal blocks over Monet's water lilies, a lily-pink accent | `appearance.chromeStyle: "blocks"`, `appearance.background: "monet-water-lilies"`, `appearance.backgroundBlur: "glass"`, `appearance.surfaces.*.opacity` |
| `miku` | Miku teal on sea-green glass, a teal cursor and pink accents, five public-domain teal paintings through the day; shuffles your own pictures once you name their folder | `colors.cursor`, `appearance.background: "schedule"`, `appearance.backgroundSchedule`, `appearance.backgroundBlur: "glass"` |
| `minimal-sessions` | Only the sidebar: one line per session, its status first, then its name; your colors stay | `sidebar.workspaceRow.statusPlacement: "leading"`, `appearance.statusIndicator.iconSet`, `sidebar.detailedStatusIcons`, every `sidebar.workspaceRow.*` element off but `working` and `progress` (the spinners), `sidebar.showColors: false` |

## One look for light and dark

Name a light and a dark terminal theme in `appearance.theme`, then give `colors` a `"light"` and a
`"dark"` half. The plain colors paint both sides, and each half paints only its own side, over them:

```jsonc
{
  "appearance.theme": "light:Rose Pine Dawn,dark:Rose Pine",
  "colors": {
    "accent": "#907aa9",                                  // both sides
    "light": { "background": "#faf4ed", "foreground": "#575279" },
    "dark": { "background": "#191724", "foreground": "#e0def4" }
  }
}
```

A half takes the same colors as `colors` (`background`, `foreground`, `cursor`, `selection`, `accent`,
`0` to `15`, `palette`). With one theme for both appearances (`"appearance.theme": "Nord"`) there are
no sides, so cmux drops the halves, names them, and applies the plain colors. A cmux from before
this change drops `colors.light` and `colors.dark` the same way, naming each, and shows the plain
colors on both sides, so keep the colors the two sides share outside the halves.

## What a theme file can and can't change

A theme file is a pit of success: it can only set how cmux looks, never what it does.

- It takes look settings only: `appearance.*`, `ui.animation*`, `ui.calm`, the terminal font, the
  sidebar's shape, how its rows draw (density, text size, status icons and where they sit, which
  row elements show, the row layout) and its grouping. A key that does something (a shortcut, a command, an agent setting) is refused
  with "a theme file sets only look settings".
- Each value gets the same check as `cmux settings set`. A bad one is dropped and the rest still
  applies.
- Unreadable text is ignored. If you save the file halfway through an edit, the last good version
  stays in place.
- Text can't become unreadable. A `foreground` under 4.5:1 contrast with its `background` is drawn
  in the app theme's text color instead, and Settings says so.
- A managed (team or MDM) value wins over the file.

### Layout and proportions

A look can also take the source app's proportions. Each one is an `appearance.metrics.*` number with
a bounded range. If you leave it unset, it keeps the density's value, so a look without these keys draws cmux's
own layout. Each value applies as soon as you save.

| Proportion | Key | Range |
| --- | --- | --- |
| Title bar (header) height | `appearance.metrics.titlebarHeight` | 24-56 pt |
| Default sidebar width | `appearance.metrics.sidebarWidth` | 160-420 pt |
| Sidebar row height | `appearance.metrics.sidebarRowHeight` | 20-48 pt |
| Sidebar row fill to sidebar edge | `appearance.metrics.sidebarRowInset` | 0-24 pt |
| Sidebar row fill to its content | `appearance.metrics.sidebarRowPadding` | 0-24 pt |
| Gap between sidebar rows | `appearance.metrics.sidebarRowGap` | 0-12 pt |
| A row with a detail line (a two-line card) | `appearance.metrics.sidebarRowHeightWithSubtitle` | 28-96 pt |
| Tab bar height (the tabs follow it) | `appearance.metrics.tabStripHeight` | 22-44 pt |
| Toolbar icon button size (header chips take it too) | `appearance.metrics.toolbarButtonSize` | 16-40 pt |
| Gap between toolbar buttons (pitch less size) | `appearance.metrics.toolbarButtonGap` | 0-16 pt |
| Toolbar button fill corner (hover, pressed, active) | `appearance.metrics.toolbarButtonCornerRadius` | 0-20 pt |
| Fill under a toolbar button that is on, a share of the text color | `appearance.metrics.toolbarButtonActiveFill` | 0-0.4 |
| Hairline under the header and tab row, 0 for none | `appearance.metrics.headerDivider` | 0-1 |
| Chat composer side padding | `appearance.metrics.composerPadding` | 0-24 pt |
| Chat composer one-line height | `appearance.metrics.composerMinHeight` | 32-160 pt |
| Spacing grid (padding and gaps), a multiplier | `appearance.metrics.spacingScale` | 0.5-2 |
| Gap between panes | `appearance.metrics.columnGap` | 0-24 pt |

```jsonc
// themes/claude-dark.json: Claude's header buttons, 21.5 pt on a 24.5 pt pitch, the one that is on over a 5 pt
// rounded square at 14% of the text color, a hairline under the header
{
  "appearance.metrics": {
    "titlebarHeight": 40, "sidebarWidth": 288, "sidebarRowHeight": 26,
    "toolbarButtonSize": 21.5, "toolbarButtonGap": 3, "toolbarButtonCornerRadius": 5,
    "toolbarButtonActiveFill": 0.14, "headerDivider": 1
  }
}
```

For more than a look, write a view of your own: a sidebar or Session Info section (the skill's "Make
a view"). A view whose script fails shows its error in its own place with a Reload button, and the
rest of the app keeps working. If a code change of your own breaks the app, go back a build from the
palette with **Roll Back to Previous Version**, or run `cmux settings rollback-update --confirm`.

## Install a theme from a repository

A theme someone shared lives in a git repository: a `cmux-theme.json` at its root and theme files
under `themes/`. One command installs it and puts it on, wallpapers included:

```sh
cmux theme install github.com/teamleaderleo/teal-twin-theme
```

cmux shows one line (what it is, where it comes from, that no code runs) and asks first; an agent
passes `--yes` after asking you. The look changes at once, and the output names the theme now in
use. `cmux apps install github.com/OWNER/REPO` (the line cmux.com's install page shows) and
`cmux theme import github.com/OWNER/REPO` do the same for a theme or snippet repository.
`cmux theme remove OWNER/REPO` (or `cmux customize rollback`) puts back the look you had, and
`cmux theme update` follows new releases. A snippet (look settings and surface stylesheets, such
as a set of fonts) installs the same way with `cmux snippet install`.

`cmux theme import FILE` only copies one theme file into the themes folder; add `--use` to put it
on, or run the `cmux theme use NAME` it prints.

`cmux theme import FILE` also takes a terminal color scheme: base16 YAML, iTerm2 `.itermcolors`,
Windows Terminal JSON, a Ghostty theme, or a VS Code color theme (the `.json` an editor theme
extension ships; comments and trailing commas are fine). A VS Code theme's `terminal.ansi*`
colors become the 16 terminal colors; one without them gets each from its nearest syntax color.
It installs as a terminal theme; `cmux theme set appearance.theme "<its name>"` puts it on.

## Share a theme so people find it

1. Make a repository: `cmux theme export --save NAME` writes your look as `themes/NAME.json`; add a
   `cmux-theme.json` beside `themes/` (`"cmuxTheme": 1`, an `id` starting with your GitHub name, a
   `name`, a `description`, a `version`, and `"use"` naming the theme file to put on).
   [Teal Twin](https://github.com/teamleaderleo/teal-twin-theme) is a full example.
2. `cmux theme check .` in the folder reports anything cmux would not load.
3. Tag a release with the version (`1.0.0`).
4. Add the topics. cmux.com lists repositories with the topic `cmux-extension` as candidates; add
   `cmux-theme` (or `cmux-snippet`) and `cmux` too, so people searching GitHub find it. On the
   repository page, click the gear beside **About**, type each topic under **Topics**, and save. From
   a terminal signed in to GitHub:
   `gh repo edit OWNER/REPO --add-topic cmux-extension --add-topic cmux-theme --add-topic cmux`.
5. To list it on cmux.com and in the App Store's Community source, open a pull request adding it to
   `themes.json` (a snippet: `snippets.json`) in
   [manaflow-ai/cmux-extensions](https://github.com/manaflow-ai/cmux-extensions); a merge there is
   the review.

## Theme packs

A theme pack is a folder with a `cmux-pack.json` and an `assets/` folder for its own pictures and
videos. It sets a whole look at once, undoes and redoes as one step, and can be edited live with
`cmux pack use DIR --watch`. It compiles to a theme file, so everything on this page still applies.
See [theme-packs.md](theme-packs.md); `examples/theme-packs/sakura` is a finished one.

## Ship fonts with a community theme

A community theme repository (one with `cmux-theme.json`, installed with `cmux theme install`) can
carry font files for the agent chat in a `fonts/` folder beside `themes/`, the way it carries
`wallpapers/`. Declare the fonts' license in `cmux-theme.json` and include its text:

```json
{ "cmuxTheme": 1, "id": "you/pack", "name": "Pack", "version": "1.0.0",
  "fontLicense": "OFL-1.1" }
```

```text
cmux-theme.json
themes/pack.json
fonts/PackSans.woff2
fonts/PackSerif-Italic.woff2
fonts/OFL.txt            (or fonts/LICENSE*)
```

Then name the faces in the theme file. A `file:` path is relative to the themes folder, as a
backdrop picture is:

```json
{ "agentPane.display.font.uiFamily": "Pack Sans, system-ui",
  "agentPane.display.font.proseFamily": "Pack Serif",
  "agentPane.display.font.faces": {
    "Pack Sans": "file:../fonts/PackSans.woff2",
    "Pack Serif:italic": "file:../fonts/PackSerif-Italic.woff2" } }
```

- Only openly licensed fonts: `"fontLicense"` is `OFL-1.1`, `Apache-2.0` or `MIT`, and the license
  text ships as `fonts/OFL.txt` or `fonts/LICENSE*`. A theme with font files and no license is
  refused.
- At most 8 font files, each at most 2 MiB, `.woff2`, `.woff`, `.ttf` or `.otf`, and the extension
  must match the file's bytes.
- A face key is one family name, optionally suffixed `:italic`. Its value is one of the theme's own
  files, `file:../fonts/NAME`.
- `font.uiFamily` wins over `font.ui`, and `font.proseFamily` wins over `font.preset`. A theme
  file may also set `agentPane.display.code.family` and `agentPane.display.code.scale`, to match
  inline code to the pack.
- Install copies the fonts and the license text to `~/.config/cmux/fonts/<entry>/` and points the
  theme file there; `cmux theme remove` deletes them.
- `cmux theme check DIR` on the repository folder reports a missing license, a bad font file and a
  bad face before you publish.
- A setup repo (`cmux-setup.json`, installed with `cmux setup install`) carries fonts the same way:
  `fonts/` beside `themes/`, `"fontLicense"` in `cmux-setup.json`, the same license and size rules.
  Install copies them to `~/.config/cmux/fonts/setup-OWNER-NAME/` and points the setup's theme files
  there; `cmux setup remove` deletes them. One repo can be both a theme and a setup, as
  [manaflow-ai/cmux-quillet-look](https://github.com/manaflow-ai/cmux-quillet-look) is.

## Keep it fast

A theme file costs nothing per frame: it's read once on each save. Code you add to the app is a
different matter. [modding-kit.md](modding-kit.md) lists the rules the dev server checks on save and
the primitives that keep a mod fast.

## The thinking look (settings a look sets)

A look's setup can set how the running line and Jump to latest move while an agent works. All of them
are agent-settable settings (`cmux settings set`, the palette, MCP `settings_set`); each default
draws what cmux draws without a look, and a change applies at once:

| Key | Values | Default | What it does |
| --- | --- | --- | --- |
| `agentPane.display.thinking.shimmer` | `cadenced`, `continuous` | `cadenced` | `continuous`: the light band crosses the running line's words and running tool rows pass after pass, eased in and out, as Claude's desktop app draws it. `cadenced` is one one-second pass every four seconds |
| `agentPane.display.thinking.shimmerPeriod` | 600 to 4000 ms | 1250 | One continuous pass |
| `agentPane.display.thinking.shimmerBand` | 0 to 240 px | 0 | The band's lit width on any line; 0 keeps the band half the line wide |
| `agentPane.display.thinking.jumpButton` | `arrow`, `dots`, `glyph` | `arrow` | `dots`: while the agent works, Jump to latest shows three dots in the theme accent that trade size between the middle and the ends; `glyph`: it plays the look's thinking glyph instead (below). The arrow shows on hover and once the agent stops |
| `agentPane.display.thinking.glyph` | a `cmux.particles/1` document | none | The look's own thinking dots, played before the running line's words while the agent works, each activity with the document's trigger for it (`read`, `execute`, `sendMessage`, `thinking`, ...; any other plays `cycle`). The document format is [ABI.md "Particles choreography"](../../cmux-tui/crates/cmux-app-host/js/ABI.md); cmux refuses an invalid one and says where it goes wrong |
| `agentPane.display.thinking.glyphSize` | 0 to 16 pt | 0 | The dot size Jump to latest plays the glyph at; 0 keeps the document's `particle.size`. The running line and sidebar rows always use the document's size |

A look keeps the glyph as a file of its folder and names it in `cmux-setup.json`; installing the look
or `cmux customize try PATH/cmux-setup.json` reads the file into the setting:

```json
"settings": {
  "agentPane.display.thinking.glyph": { "$file": "thinking-glyph.json" },
  "agentPane.display.thinking.glyphSize": 2.4,
  "agentPane.display.thinking.jumpButton": "glyph"
}
```

`{"$file": PATH}` works for any setting: PATH is relative, inside the look's folder, a plain file
(no link) under 64 KB of JSON or JSONC. The look's own sidebar rows (`cmux.sidebar.rows/1`) can
play the same glyph while a row works with `indicator: "glyph"` (or `{"choreography": "glyph",
"trigger": "execute"}`), or a document of their own with `{"choreography": {...}, "trigger": ...}`.

Reduce Motion, static status indicators and animations off hold all of them still. The Claude look
sets `continuous`, 1250, 80 and `dots`.

## Surface tokens (shape, edge and shadow)

A look restyles a surface's corner, edge and shadow in two ways: settings, for the surfaces the app
draws natively, and CSS variables, for the web surfaces a look's stylesheet reaches
(`agent-pane/theme.css`, `markdown/theme.css`, `diff/theme.css`, `picker/theme.css`,
`fileViewer/theme.css`; a recipe ships them beside its settings). Every token's default draws what cmux
draws without a look.

Every button and text field on those pages (`ui/controls.css`):

| Variable | Default | What it sets |
| --- | --- | --- |
| `--cmux-button-radius` | the control radius (`--ds-radius-control`) | every button's corner, all sizes |
| `--cmux-button-border` | `0` | every button's border (a `border` value: `1px solid #0001`) |
| `--cmux-button-shadow` | `none` | every button's shadow at rest: a paired light and dark drop shadow, say |
| `--cmux-input-radius` | the field radius (`--ds-radius-sm`, `-md`, `-lg` by size) | every text field's corner, all sizes |
| `--cmux-input-border` | `0` | every text field's border |
| `--cmux-input-shadow` | `none` | every text field's shadow: an inset well, say |

A shadow token loses to a variant's own edge (the outline field's hairline) and to every focus ring,
so focus stays visible in any look.

```css
:root {
  --cmux-button-radius: 14px;
  --cmux-button-shadow: -3px -3px 6px rgb(255 255 255 / 70%), 3px 3px 6px rgb(0 0 0 / 14%);
  --cmux-input-shadow: inset 2px 2px 4px rgb(0 0 0 / 12%), inset -2px -2px 4px rgb(255 255 255 / 70%);
}
```

The native surfaces take settings a theme file sets:

| Surface | Settings |
| --- | --- |
| Every edge at once | `appearance.borders` (`none` clears them), `appearance.chromeStyle` |
| Glass, window wide | `appearance.backgroundBlur` (`none` turns it off), `appearance.glassTransparency` |
| Panes | `layout.paneCornerRadius`, `layout.cornerPadding`, `layout.paneBorder`, `layout.paneBorderWidth`, `layout.paneBorderColor`, `appearance.cornerFlush` |
| Split dividers | `appearance.surfaces.splitDivider.color` and `.opacity`, `appearance.metrics.dividerThickness` |
| Sidebar | `sidebar.border`, `sidebar.borderWidth`, `sidebar.sectionLook`, `appearance.surfaces.sidebar.*` |
| Omnibar | `browser.omnibar.cornerRadius`, `browser.omnibar.shadow`, `browser.omnibar.glass` |

## Not in a theme file yet

These parts of a look are still built into the app:

- the thinking indicator's look in the agent pane (a Debug setting today, `StatusWorkingLook`)
- the motion of the jump to latest button, beyond `agentPane.display.thinking.jumpButton` above
- a shadow on any native surface (sidebar rows and sections, panes, split dividers, the tab bar and
  titlebar buttons), and a corner radius or border for the sidebar's rows and sections apart from
  the settings above
- glass on or off for one native surface rather than the whole window

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

## What a theme file can and can't change

A theme file is a pit of success: it can only set how cmux looks, never what it does.

- It takes look settings only: `appearance.*`, `ui.animation*`, `ui.calm`, the terminal font and the
  sidebar's shape. A key that does something (a shortcut, a command, an agent setting) is refused
  with "a theme file sets only look settings".
- Each value gets the same check as `cmux settings set`. A bad one is dropped and the rest still
  applies.
- Unreadable text is ignored. If you save the file halfway through an edit, the last good version
  stays in place.
- Text can't become unreadable. A `foreground` under 4.5:1 contrast with its `background` is drawn
  in the app theme's text color instead, and Settings says so.
- A managed (team or MDM) value wins over the file.

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

## Keep it fast

A theme file costs nothing per frame: it's read once on each save. Code you add to the app is a
different matter. [modding-kit.md](modding-kit.md) lists the rules the dev server checks on save and
the primitives that keep a mod fast.

## Not in a theme file yet

These parts of a look are still built into the app:

- the thinking indicator's look in the agent pane (a Debug setting today, `StatusWorkingLook`)
- the motion of the jump to latest button

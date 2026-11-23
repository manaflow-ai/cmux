# Theme packs

A theme pack is a whole look for cmux NEXT as one folder. It swaps in at once, undoes and redoes as one
step, and you can edit it while it's on. A pack has no code: it sets look settings and nothing else.
It builds on [theme files](theme-recipes.md), which are one file of look keys. A pack adds a manifest,
declared capabilities, its own pictures and videos, and history across the whole look.

```
sakura/
  cmux-pack.json
  assets/
    petals.jpg
```

Two examples are in `examples/theme-packs/`: `sakura` (a finished look) and `garbage` (a pack broken on
purpose, every failure in one file).

## Try one

```sh
cmux pack check examples/theme-packs/sakura       # report what cmux would drop; applies nothing
cmux pack use examples/theme-packs/sakura --watch # apply it, and re-apply on every save
cmux pack undo                                    # back to the look you had
```

## The manifest

`cmux-pack.json` is JSON with comments, at most 512 KB.

| Field | Meaning |
|---|---|
| `cmuxPack` | Required. The format, `1`. Without it the folder isn't a pack. A higher number still loads, and applies what this cmux knows. |
| `id` | `owner/name`: each part 1 to 64 of `a-z 0-9 - . _`, not starting with a dot. If it's missing or wrong, the id becomes `local/` plus the folder name. |
| `name` | Text up to 200 characters. Defaults to the id. |
| `version` | Text up to 64 characters. |
| `description` | Text up to 2000 characters. |
| `capabilities` | A list of capability names. With none, the pack can change nothing. |
| `look` | An object of settings, as dotted keys (`"appearance.accent": "theme"`) or nested objects. |
| `colors` | The terminal theme's colors: `background`, `foreground`, `cursor`, `selection`, `accent`, `0` to `15`, `palette`. Each is `"#RRGGBB"`. |
| `slots` | Slot id to variant id (`"chat.thinkingIndicator": "pulse"`). Ids and variants are in `schemas/theme/slots.json`. |
| `$schema` | Allowed, ignored. |

Any other top-level key is skipped with a message. At most 4096 values are read from `look`.

`colors` edit the terminal theme the pack names in `appearance.theme`, so set that too. A `foreground`
under 4.5:1 contrast with its `background` is replaced by the app theme's text color, as in a theme
file.

## Capabilities

A pack lists what it changes. A value whose capability the pack didn't list is dropped, and the
rest still applies.

| Capability | Covers |
|---|---|
| `tokens` | Every look key no other capability covers: `appearance.theme`, `appearance.accent`, `appearance.chromeStyle`, surfaces, glass, density, borders, status indicator. |
| `colors` | The `colors` section. |
| `backgrounds` | `appearance.background*`, `appearance.paneBackgrounds`, `appearance.wallpaper*`, `ui.reducedBackgrounds`: wallpapers, their tint, opacity and rotation, including pictures and videos from `assets/`. |
| `motion` | `ui.animation*` (speed and the per-area switches), `ui.paneAnimations`, `ui.calm`. |
| `tabs` | `appearance.tabShape`, `appearance.metrics.tab*`. |
| `fonts` | `terminal.fontFamily`, `terminal.fontSize`, `appearance.font*`, `appearance.metrics.chromeFont*`. |
| `components` | `sidebar.*` and the `slots` section. |

A key matches by prefix, so `appearance.backgroundOpacity` is `backgrounds`. The code is
`cmux-tui/crates/cmux-theme-pack/src/capability.rs`.

## What happens to a bad pack

A pack is refused whole only when there is nothing to read. Then the look in use stays:

- no `cmux-pack.json` in the folder
- the manifest can't be read, isn't a file, or is over 512 KB
- it isn't a JSON object, or has no `"cmuxPack"` number

Everything else falls back one piece at a time, with a message that names the section and key. The
rest of the pack still applies.

| Problem | What is dropped |
|---|---|
| A key whose capability isn't declared | That key (or `colors`, or `slots`, as a section) |
| An unknown key, a wrong type, a number out of range, an unknown choice | That key. The check is the one `cmux settings set` makes. |
| A bad color (not `#RRGGBB`) | That color |
| A `file:` or `folder:` value that leaves `assets/` (`../`, an absolute path, a link out), points at a missing file, or is too big or the wrong kind | That key |
| An unknown slot, or a variant the slot doesn't have | That slot. It keeps its default. |
| An unknown top-level key | Skipped |
| A bad `id` | Replaced by `local/FOLDER` |
| A `capabilities` entry that isn't a capability name, or a `capabilities` that isn't a list | That entry, or the list (so the pack changes nothing) |
| A bug in reading one section | That section. The app keeps running. |

`examples/theme-packs/garbage` has one of each, with a comment on every line saying what should happen.
`cmux pack check` lists these messages without applying anything.

## The sandbox

A pack can't run anything, read anything outside itself, or change what cmux does.

- No code. There's no script field, and a pack never loads a file as code.
- Look settings only: `appearance.*`, `ui.animation*`, `ui.calm`, the terminal font, the sidebar's
  shape. The theme file reader refuses any other key, the same as for a theme file.
- Files only from the pack's own `assets/` folder, written as `file:assets/NAME` or
  `folder:assets/NAME`. Paths are resolved first, so a `../` or a link that leaves `assets/` is
  refused.
- A picture or video: `png`, `jpg`, `jpeg`, `heic`, `webp`, `gif`, `tiff`, `mp4`, `mov`, `m4v`.
  Each file is at most 256 MB.
- A managed (team or MDM) value still wins over the pack.

## Commands

| Command | What it does |
|---|---|
| `cmux pack check DIR` | Reads the pack and prints what it would apply and every message above. Changes nothing. |
| `cmux pack use DIR\|NAME` | Applies a pack. `NAME` is a folder in `packs/` beside `cmux-next.json`. |
| `cmux pack use DIR --watch` | Applies it, then re-applies each time you save a file in it. |
| `cmux pack edit KEY VALUE` | Sets one look value over the applied pack, as one undo step. It passes the same capability and schema checks. |
| `cmux pack undo` / `cmux pack redo` | One step back or forward through the history. |
| `cmux pack off` | Takes every pack off and goes back to the theme file you had before. |
| `cmux pack history` | Lists the generations and which one is applied. |
| `cmux pack bench DIR...` | Times how long each pack takes to read and compile. |

## Undo and redo

Each pack you apply, and each `edit`, is one generation: the whole compiled look. Undo and redo move
a cursor over the generations and write that look back, so a step always restores a whole pack, never
half of one. The step before the first generation is the theme file you had picked before any pack.

- `use` adds a generation after the current one and drops anything you had undone.
- `use --watch` replaces the applied generation when it's the same pack. Saving twenty times is one
  undo step, not twenty.
- `edit` adds a generation each time.
- `off` goes back to the look before any pack, and is itself one step, so `undo` brings the pack back.
- 64 generations are kept; the oldest go first.
- If you pick another theme file yourself (`cmux theme use`, or undoing `appearance.themeFile` in the
  settings), the next pack command starts the history over from that file: `off` and `undo` go back
  to it, never to an older look over yours. A theme of your own is never taken for a pack's, whatever
  its name.
- The history moves only once the setting does: if `cmux settings` fails to pick the step's theme
  file, the history stays where it was.

The history is `packs/.history.json` beside `cmux-next.json`. If it doesn't parse, it starts over;
any name in it that isn't a plain theme file name (or, for a pack's file, doesn't start with
`pack-`) is dropped. Each command holds `packs/.history.lock` while it reads and writes the history,
so `use --watch` and an `undo` in another terminal never lose each other's step.

## How a pack applies

cmux compiles a pack to a theme file, `themes/pack-OWNER-NAME-HASH.json` (`cmux/sakura` becomes
`pack-cmux-sakura-` plus a hash of the compiled look), and sets `appearance.themeFile` to it. Each
generation has its own file, so undoing `appearance.themeFile` in the settings history brings back the
look that name had. A live edit rewrites the current file in place. The theme files cmux wrote are
kept, so that undo keeps working, up to the 256 most recently written; beyond that the oldest are
removed, never the one `appearance.themeFile` picks, the one you had before any pack, or one a kept
generation names. A theme file of your own is never removed. The running app already reloads theme
files live, so a pack needs nothing new in the app, and it writes your `cmux-next.json` no more than a theme
file does. The compiled file holds every value that passed, plus `colors` and `slots`.

`slots` are accepted and carried in the compiled file, but they don't paint yet. They will once the
app forwards them in its theme push, which it doesn't today. Everything else in a pack paints now.

See [theme files](theme-recipes.md) for the single-file form, the shipped looks and how to share one.

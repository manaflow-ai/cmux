# cmux NEXT dotfiles

cmux NEXT keeps its settings in plain JSONC files you can check into a dotfiles
repo, edit by hand, or change from a script or an agent. The app reloads them
when you save, and Settings writes back to the same file without dropping your
comments or reordering your keys.

## The files

| File | What it holds |
| --- | --- |
| `~/.config/cmux/cmux-next.json` | App settings: theme, glass and colors, fonts, sidebar, tabs, panes, notifications, browser |
| `~/.config/cmux/keybindings.json` | Key bindings, in the common editor format |
| `~/.config/ghostty/config` | Terminal rendering that Ghostty owns (cursor, shaders, padding) |

Set `CMUX_NEXT_CONFIG_FILE` to use another settings file. `keybindings.json`
moves with it. On its first launch, cmux NEXT copies classic cmux's
`~/.config/cmux/cmux.json` to `cmux-next.json` once; after that the two files
are separate.

A symlinked file works: writes go through the link to the file in your repo,
so the link stays a link.

## What happens when you save

- Saving `cmux-next.json` applies the change to every open window. You don't
  need to reload.
- A value cmux refuses (a misspelled choice, or a number out of range) falls
  back to its default and is listed with the reason in Settings. The other
  keys still apply.
- A file that isn't valid JSONC keeps the last good settings in effect until
  you fix it.
- Comments, trailing commas and keys cmux doesn't know about are kept. When
  you change something in Settings, only that value is rewritten.

## Editor completion

Write the JSON Schema next to your settings and point the file at it:

```bash
cmux settings schema > ~/.config/cmux/cmux-next.schema.json
```

```jsonc
{
  "$schema": "./cmux-next.schema.json"
}
```

The schema comes from the installed build, so rerun the command after an
update to pick up new keys. Each key has its title, help text, default,
choices and range. Theme, font and sound names are checked by the app, so
the schema only asks for a string there.

## Example `cmux-next.json`

```jsonc
{
  "$schema": "./cmux-next.schema.json",

  // Colors: one theme for light mode and one for dark.
  "appearance": {
    "theme": "light:Rose Pine Dawn,dark:Rose Pine",
    "accent": "theme",
    // Your own colors over the theme; remove an entry to reset it.
    "themeEdits": { "Rose Pine/background": "#1f1d2e" },

    // Glass: how much of the desktop shows through, and the blur.
    "glassTransparency": 0.35,
    "backgroundBlur": "glass",
    "chromeStyle": "floating",

    "metrics": { "chromeFontSize": 12, "sidebarWidth": 240 },
  },

  "terminal": { "fontFamily": "Berkeley Mono", "fontSize": 13 },

  "sidebar": {
    "side": "right",
    "density": "comfortable",
    "groupBy": "folder",
    "showSpaces": false,
  },

  "layout": { "panePadding": 6, "paneCornerRadius": 10 },
}
```

`cmux settings list` shows every key with the value that applies now and its
default. Add `--section appearance` for one section, or `--keys` for just the
names.

## Example `keybindings.json`

```jsonc
[
  { "key": "cmd+k cmd+p", "command": "palette.open" },
  { "key": "cmd+alt+right", "command": "toggleRightSidebar" },
  // A leading "-" removes a default binding.
  { "key": "cmd+shift+p", "command": "-palette.open" },
]
```

`cmux keybinding list` shows the action ids and what is bound now.

## Agent defaults

Set the permission mode every new agent chat starts in, including chats an
agent starts through acpmux:

```jsonc
{
  "agents": {
    // fullAccess (the default), standard (the harness's own mode) or ask.
    "defaultPermissionMode": "ask",
  },
}
```

It's also Settings > Agents > Agent Chat > Permission Mode for New Chats, and
`cmux config set agents.defaultPermissionMode ask --confirm`. Agents can't
change it without you confirming. A mode you pick in a chat applies to that
chat only; new chats keep starting in this setting's mode. When your
organization manages this setting (MDM or a team policy), its value applies
to new chats; a value it forces that cmux doesn't know starts chats in the
agent's own mode.
A harness profile or preset that sets its own mode still uses that mode.

The model and reasoning effort a new chat starts with aren't in
`cmux-next.json` yet. `acpmux defaults <harness> model=<id> effort=<level>`
saves them (for example `acpmux defaults claude model=claude-opus-5-5
effort=high`), and the last pick you make in a chat becomes the default too.

## Changing settings from a script or an agent

`cmux config` and `cmux settings` are the same command.

```bash
cmux config get sidebar.side
cmux config set appearance.glassTransparency 0.4
cmux config set appearance.theme "light:Rose Pine Dawn,dark:Rose Pine"
cmux config reset appearance.glassTransparency
cmux config list --section appearance --json
cmux config validate ~/dotfiles/cmux/cmux-next.json
```

- `set` parses the value as JSON when it can and otherwise uses it as a
  string, so `0.4`, `true` and `["a","b"]` keep their types.
- `set` and `reset` go through the running app, which checks the value against
  the schema and edits the file in place. A refused value changes nothing and
  exits 1 with the accepted values.
- `validate` needs no running app. It reports the problems cmux would show for
  a file, with what each refused key accepts, and exits 1 if there are any, so
  you can run it in a dotfiles repo's CI before you sync. Without a FILE it
  checks your settings file; a missing one is valid (every key has its
  default).
- A few keys (privacy, permissions and quitting) can't be changed through the
  CLI or the socket alone: add `--confirm`, and cmux asks you on screen first.
  The schema marks these keys with `"x-cmux-agent-settable": false`.

An agent inside cmux can do the same over the app's control socket with
`settings.get`, `settings.set {path, value}` and `settings.reset {path}`. The
CLI is a thin client for those methods.

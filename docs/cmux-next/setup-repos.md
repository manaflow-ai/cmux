# Setup repos

A setup repo is a whole cmux customization in one git repo, like dotfiles: a theme, settings,
shortcuts, views, stylesheets, actions and extensions. Anyone installs it from its URL, and
removing it puts back what they had.

## Install one

```sh
cmux setup install github.com/OWNER/REPO        # or HOST/OWNER/REPO[@REF]
```

cmux fetches the repo at one commit and shows a card with everything it changes before it writes
anything. `--yes` answers the card for you (needed with `--json` or without a terminal).

- `cmux setup install ./DIR` installs a setup folder on this machine the same way, with the same
  card, so you can try a look before you publish it. It's kept under its id, marked local. Use
  `--as OWNER/NAME` to try it under an id of your own (for a look that names another owner, or
  one you haven't named yet); only a folder takes `--as`.
- `cmux setup installed` lists what is installed.
- `cmux setup update [REPO]` moves one to the newest commit of the ref it came from (a local one:
  to what its folder holds now).
- `cmux setup remove [REPO]` takes it off: its layer, its actions, and the extensions it installed.

## Make one

```sh
cmux setup export ~/my-setup --id OWNER/NAME
```

writes what you have now as a setup repo, with a README. The repo holds:

| File | What it is |
| --- | --- |
| `cmux-setup.json` | The header (`cmuxSetup: 1`, `id`, `name`, `description`, `engines.cmux`, `extensions`), `settings` by dotted key, and `actions` |
| `themes/NAME.json` | Theme files; select one with the `appearance.themeFile` setting |
| `keybindings.json` | Shortcuts, added to the person's own |
| `customize/cmux-app.json` and its script | Views: sidebar sections, hover cards, rows |
| `agent-pane/theme.css` (and other `SURFACE/theme.css`) | Stylesheets |

The `id` is `OWNER/NAME` in lowercase, and OWNER is the repo's owner on its host.

## Check one before you push it

```sh
cmux setup check ~/my-setup
```

reads the folder and nothing else: no running cmux, no network, and not your own customization.
It runs every check `cmux setup install` runs, and reports every problem at once where install
stops at the first. It also reads each `themes/*.json` with the theme reader and
`customize/cmux-app.json` with the app manifest validator.

```text
error[setting.unknown] cmux-setup.json (appearance.densty): the setting appearance.densty is not one this cmux has
  fix: did you mean appearance.density?
error[theme.value] themes/night.json:3 (appearance.nope): appearance.nope: ...
leo/night: 2 errors, 0 warnings. cmux setup install would refuse it.
```

An error is something install refuses, or a part cmux leaves out when it loads the setup (a theme
key the theme reader refuses, a theme file that isn't there). A warning is something that installs
and loads but won't do quite what it says (a theme color the contrast guard changes, an
`engines.cmux` no cmux reads).

Settings change over time. A key cmux retired (`schemas/settings/retired-keys.json`) gets a
`setting.deprecated` warning, and when a setting took its place, the fix names it
(`set remote.ultra instead`). Install still refuses a key this cmux doesn't read, so the same key
also has a `setting.unknown` error carrying the same fix.

| Flag | Effect |
| --- | --- |
| `--json` | One JSON object (below) |
| `--strict` | Warnings fail too |
| `--owner OWNER` | The repo's owner for the id rule. Default: the owner `repository` names, else the id's own |

It exits 0 with no errors, 1 with errors (or warnings under `--strict`), and 2 on wrong
arguments, so it fits a CI step:

```sh
cmux setup check . --strict --json
```

```json
{
  "schema_version": 1,
  "setup_id": "leo/night",
  "ok": false,
  "findings": [
    {
      "severity": "error",
      "code": "setting.unknown",
      "path": "cmux-setup.json",
      "key": "appearance.densty",
      "message": "the setting appearance.densty is not one this cmux has",
      "fix": "did you mean appearance.density?"
    }
  ],
  "skipped": [{ "check": "agent-pane.tokens", "why": "..." }]
}
```

`key`, `line` and `fix` appear when there is one to give. Match on `code`, never `message`. The
codes are `setup.unreadable`, `setup.format`, `setup.id`, `setup.engines`, `setup.extension`,
`text.hidden`, `file.unreadable`, `file.place`, `file.invalid`, `setting.unknown`,
`setting.private`, `setting.value`, `setting.deprecated`, `manifest.warning`,
`theme.unreadable`, `theme.value`, `theme.corrected`, `theme.missing`, `action.invalid` and
`secret.found`. A message never quotes a refused value, since it may be a credential under the
wrong key.

`skipped` names a check this cmux can't run. Today that's the stylesheet tokens: there is no
list of agent pane style tokens yet, so `agent-pane/theme.css` is checked only for hidden
characters and secrets.

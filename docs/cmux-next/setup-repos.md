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
  card, so you can try a look before you publish it. Its receipt names the folder as its source.
  Use `--as OWNER/NAME` to try it under an id of your own (for a look that names another owner, one
  you haven't named yet, or one whose id is installed already); only a folder takes `--as`.
- `cmux setup installed` lists what is installed, top layer first, each on or off.
- `cmux setup update [REPO|ID|DIR]` moves one to the newest commit of the ref it came from (a
  folder: to what it holds now). It keeps its place in the order, and stays off if it was off.
- `cmux setup remove [REPO|ID|DIR]` takes off its layer and only its layer: its settings, views,
  actions, and the extensions it installed.
- `cmux setup off ID` turns its settings, theme, shortcuts, stylesheets and views off and keeps it
  installed in its place (its actions and extensions stay); `cmux setup on ID`
  turns it back on.
- `cmux setup order ID [ID]...` puts the setups in that order, top first.

## Setups stack, like dotfiles

Every setup is a layer of its own. Install two looks and both are there: the newer one on top.

- **Your own customization is never written by a setup.** Your views app,
  `~/.config/cmux/customize` (`local/customize`), stays yours. A setup's `customize/` files go to
  a folder of its own, `~/.config/cmux/setups/setup-OWNER-NAME/`, and load as the app
  `local/setup-OWNER-NAME` (its `cmux-app.json` is written with that id; the repo keeps
  `local/customize`). It installs with its read scopes and the sandbox, as your own views app
  does; more waits for you.
- **What you change after installing stays above it.** A setting you change, a shortcut, a theme
  you pick: each is a layer of its own above the setups (the library, `cmux customize library`).
  Updating a setup puts its new version back in its old place, below them.
- **A key two setups set takes the higher one's value.** `cmux setup order` changes which is
  higher; `cmux setup off` lets the one below show.
- **Removing one touches nothing else.** The other setups' settings, themes and views, and your
  own, stay byte for byte. An action you changed since stays yours. An action another installed
  setup also sets stays that setup's (the topmost one's, when several do), even when both set the
  same value; only when no installed setup sets it any more does it go back to what was there
  before the setups.

On disk:

```text
~/.config/cmux/setups/layers.json          the layers that are on, top first (cmux reads it)
~/.config/cmux/setups/setup-OWNER-NAME/    one setup's views
~/.local/state/cmux/customize/setups.json  the receipts: source (repo or folder), id, order, on/off
```

`layers.json` is `{"cmuxSetupLayers": 1, "layers": [{"id", "app", "dir"}]}`. cmux loads only the
folders it names, in its order; an app id starting `local/setup-` anywhere else is refused.
`setups.json` (`"cmuxSetups": 2`) keeps one receipt per id with its `source`
(`{"kind": "repo", "reference": ...}` or `{"kind": "folder", "path": ...}`); a file from before
(a `reference`, and `local` for a folder) reads the same.

The sidebar's row decorations (`cmux.sidebar.rows/1`) and the hover card (`cmux.hovercard/1`)
are drawn from your own `local/customize` app only for now; a setup's views layer draws its
sections, panels and pages.

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

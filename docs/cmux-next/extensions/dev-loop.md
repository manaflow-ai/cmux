# The extension dev loop

An extension is a cmux app you write: a sidebar section today (more places as their interfaces
land). Write it against the public SDK, `cmux-extension-sdk`
([`cmux-tui/crates/cmux-extension-sdk`](../../../cmux-tui/crates/cmux-extension-sdk/README.md): TypeScript
for the extension, Rust for tools around it); `examples/extensions/activity` is a working one. `cmux ext dev` loads your folder into the cmux you are running and reloads it on every
save, so cmux changes as you work. `cmux apps ...` keeps working; `ext` is the author's noun.

## For a person

```sh
cmux ext new my-prs          # ./my-prs: cmux-app.json, src/main.ts, dist/main.js, sdk/, README.md, cmux-app.d.ts
                             # --kind sidebar (default), session-info, pane, newtab or command
cd my-prs
cmux ext dev                 # validate, build, load; then one line per save
```

The first run asks you to install it (a card in cmux; confirm once). Until then it loads as a
preview. Edit `src/main.ts`, save, and read the line `ext dev` prints:

```text
reloaded in 180 ms (build 95 ms)
load failed (the last good version stays live):
  dist/main.js:14:9: SyntaxError: unexpected token
```

The extension's log lines print as they come. Ctrl-C stops; the extension stays installed
(`--remove-on-exit` removes it, `cmux ext remove local/my-prs` later does too).
`cmux ext list` shows the extensions loaded this way.

## For an agent

Run one reload per edit and read the JSON:

```sh
cmux ext dev --once --json
```

```json
{"ok":false,"phase":"load","exitCode":1,"app":"local/my-prs",
 "errors":[{"file":"dist/main.js","line":14,"column":9,"field":null,"message":"SyntaxError: unexpected token"}],
 "reloadMs":null,"buildMs":95,"changed":true,"installed":true,
 "placed":[{"interface":"cmux.section/1","where":"sidebar, bottom region","shown":true}],
 "probe":"cmux.section/1","logs":[],"installedAt":"<state>/apps/local/my-prs","next":null}
```

| Exit | `phase` | Means |
|---|---|---|
| 0 | `done` | loaded and rendered (`reloadMs`: copy to first frame) |
| 1 | `load` / `reload` | the script does not load (file:line in `errors`), or cmux did not reload it |
| 3 | `daemon` | no cmux to load into |
| 4 | `manifest` | `cmux-app.json` is invalid (`file` and `field` in `errors`) |
| 5 | `build` | the build failed (file:line when the tool printed one) |

Fix what `errors` names and run it again. When `installed` is false, `next` says how the person
installs it; the load check runs as a preview meanwhile.

## See what it rendered

`cmux ext shot` reloads once, as `ext dev --once` does, and then shows what the view rendered in
two ways:

```sh
cmux ext shot                   # in the extension's folder
cmux ext shot --out shot.png    # the picture goes here (default: a temporary file)
cmux ext shot --json
```

```text
reloaded in 180 ms
rendered cmux.section/1:
  VStack
    Text text="My PRs" font=headline
    Button title="Refresh" icon=arrow.clockwise tint=accent
picture of the window (2880x1800): /tmp/shot.png; the extension is in the sidebar, bottom region
```

- **The outline** is the view's first scene, one node per line from the root, with the words
  each node shows and its `icon`, `tint` and `font`. It comes from the load check's own mount, so it
  needs no window and works for a preview too. `ext dev --once --json` carries it as well, as `scene`.
- **The picture** is a PNG of the cmux window that shows the extension. It is taken by `cmux window
  screenshot`: cmux's own capture, so there is no Screen Recording grant and no change of focus.
  The window comes out as an agent sees it, with browser pages and chats masked in gray. The
  extension's own view is not masked.

`--json` adds `shot` to the `ext dev --once` fields: `{"path", "width", "height"}`, or
`{"error"}` when there is no picture.

| Exit | Means |
|---|---|
| 0 | loaded, rendered, and the picture was written |
| 1, 3, 4, 5 | as `ext dev --once`: there is nothing to picture yet |
| 6 | loaded and rendered, but no picture was taken (`phase` is `shot`). Either it is not installed, so no window shows a preview, or the window capture failed (`shot.error` says why) |

An agent's loop is: edit, `cmux ext shot --json`, read `errors` and `scene`, look at `shot.path`,
and repeat until both look right.

## What happens on a save

1. A change in the folder (dot files, `node_modules` and editor backups ignored) wakes the
   watch; 120 ms of quiet later one reload starts. A save that leaves the folder's contents as
   they were reloads nothing.
2. The manifest is validated by the validator cmux itself runs (`cmux-app-manifest`). When step 3
   will build, the main script it writes (`runtime.main`, `dist/main.js`) need not exist yet, so a
   fresh clone (examples gitignore `dist/`) builds; the full check, the main script included,
   runs again after the build. With nothing to build, a missing main script ends the reload at
   phase manifest.
3. Build: `--build CMD` when given; else, with `src/main.ts` and `bun` on PATH, the packer every
   sample uses (`cmux-app-host/tools/pack.ts`, built into the CLI) writes `dist/main.js`; a plain
   `dist/main.js` needs no build. `cmux-extension-sdk` resolves to the folder's own copy
   (`node_modules`, or `tsconfig.json` `paths`) when it has one, else to the SDK built into the
   CLI, so a folder needs no install. A build may run 120 s (`--build-timeout SECS` changes it);
   past that it and what it started are stopped, and the reload ends at phase build.
4. The files cmux loads (the manifest and its `files`) are copied into the local apps folder
   cmux watches (`<state>/apps/local/<name>`, which `apps-list` names as `local_dir`). cmux
   reloads only that app; a script that does not load while its view is open is refused and the
   last good one stays on screen.
5. `ext dev` mounts the app's view once to see the new script render, then unmounts it.

Only the folder's own files are copied: a file that is a symbolic link, or a `files` path that
leads out of the folder, is refused by name.

`ext dev` refuses a folder in the local apps folder that it did not make, and an id that is not
`local/NAME` (`local/customize` is `~/.config/cmux/customize`, which reloads on save already).

An app under its own id (a fork of a first-party app renamed so it does not collide with the
shipped one, or an extension with a publisher) can run
from your checkout without `ext dev`: start cmux with `CMUX_APPS_DIRS` naming the folder that holds
the app's folder. Every `CMUX_APPS_DIRS` folder is watched like the local apps folder, so a save of
an app there (its built `dist/main.js` or its manifest) reloads it and remounts its open views.
These apps keep no rollback copy: they are your files.

## Reload on request

A save reloads by itself. To reload when you choose (a file written where the watch did not see it, a
folder on a network volume, a script you want to start over), ask for it with one command:

```sh
cmux ext reload my-prs        # local/my-prs: read its folder again and rerun it
cmux ext reload               # every extension in a local folder, the customize folder too
cmux ext reload --json        # {"reloaded": [...], "refused": [{"app", "reason"}], "removed": [...]}
cmux reload-config            # cmux-next.json and the Ghostty config, then every local extension
```

The daemon reads the folder again and restarts the app whether or not its files changed; its open
views draw again in place (a sidebar section keeps its place, its region and its row). A script
that does not load keeps the last good view on screen, and the command names the file and line and
exits 1. In the app the same reload is **Reload Custom Views** in the command palette (`cmux apps
reload`), and **Reload Configuration** (Cmd-Shift-,) reads the settings and Ghostty files.

A reload never places a section: a section you removed from the sidebar stays removed until you
place it again (`cmux apps place local/my-prs#cmux.section/1 --region bottom`, or the sidebar's edit
mode). To take one back out, remove the section in the sidebar's edit mode, turn the extension off in
Settings > Apps, or `cmux ext remove local/my-prs`.

## Kinds

| `--kind` | What it adds | Interface |
|---|---|---|
| `sidebar` (default; `section` too) | a sidebar section | `cmux.section/1` |
| `session-info` | a section in an agent chat's Session Info panel; its context is that chat's session | `cmux.session.info.section/1` |
| `pane` | a view in a tab, opened from the command palette by its title | `cmux.pane/1` |
| `newtab` | a whole New Tab page, shown once picked: `cmux settings set tabs.newTabApp local/NAME` | `cmux.newtab/1` |
| `command` | a command in the palette, `cmux NAME hello` in a terminal, and a tool for agents | `catalog.json` |
| `menu` | refused until cmux has context-menu contributions (`cmux.context_menu/1`); the error says what to make meanwhile | |

Each kind loads as written, and a save to its `src/main.ts` is on screen within a second
(`cmux-tui` test `every_kind_is_new_loads_then_shows_an_edit_within_a_second`, which runs
the watch, the debounce, the bun build and the reload against a daemon that renders with the
real app host).

## The SDK in a new extension

`cmux ext new` writes `sdk/`: `cmux-extension-sdk` as the `cmux` that ran it was built with it
(its TypeScript source and the runtime's event and scope tables, embedded in the binary).
`tsconfig.json` points `import … from "cmux-extension-sdk"` there and `package.json` names it as
`file:./sdk`, so a new extension builds with no npm account, no registry and no network, and its
`API_VERSION` is that cmux's. `cmux ext new` in a newer cmux gives a newer copy.

## Share it from a git repository

An extension folder is a git repository with the manifest and `README.md` at its root.
`cmux ext new NAME --repo OWNER/REPO` (or `cmux ext new NAME --dir .` in a clone of a new,
empty GitHub repository, whose `origin` names it) writes:

- the id `owner/NAME` (the GitHub owner, lowercased) and `"repository": "https://github.com/OWNER/REPO"`;
- a README with the badge and the install line:

  ```markdown
  [![Get it on cmux](https://cmux.com/extensions/badge.svg)](https://cmux.com/extensions/OWNER/REPO)
  ```

  ```sh
  cmux apps install github.com/OWNER/REPO
  ```

- a `.gitignore`, and `git init` (branch `main`) when the folder is in no repository.

With no repository, the id stays `local/NAME` and the README carries a marked `OWNER/REPO`
placeholder. `cmux ext dev` loads an `owner/NAME` folder as `local/NAME` (its copy in the local
apps folder says `local/`; the folder keeps its own id).

`cmux ext publish [DIR] [--repo OWNER/REPO] [--write-badge] [--json]` writes nothing to the
network. It checks the manifest validates, the id starts with the owner, the `repository` field,
the README badge (`--write-badge` adds it or fills the placeholder), and an image `icon` or
`screenshots`; then prints the steps: push to GitHub, add the topic `cmux-extension` (cmux.com
lists repositories with it once reviewed), or submit at https://cmux.com/extensions. Exit 0 when
ready, 1 when something is left (each `todo` line says what), 2 for a bad `--repo` or folder.
Commit `dist/main.js`: cmux installs the repository as it is, with no build.

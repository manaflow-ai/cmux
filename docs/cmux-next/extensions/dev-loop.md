# The extension dev loop

An extension is a cmux app you write: a sidebar section today (more places as their interfaces
land). Write it against the public SDK, `cmux-extension-sdk`
([`cmux-tui/crates/cmux-extension-sdk`](../../../cmux-tui/crates/cmux-extension-sdk/README.md): TypeScript
for the extension, Rust for tools around it); `examples/extensions/activity` is a working one. `cmux ext dev` loads your folder into the cmux you are running and reloads it on every
save, so cmux changes as you work. `cmux apps ...` keeps working; `ext` is the author's noun.

## For a person

```sh
cmux ext new my-prs          # ./my-prs: cmux-app.json, src/main.ts, dist/main.js, sdk/, README.md, cmux-app.d.ts
                             # --kind section (default), pane or command
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
2. The manifest is validated by the validator cmux itself runs (`cmux-app-manifest`).
3. Build: `--build CMD` when given; else, with `src/main.ts` and `bun` on PATH, the packer every
   sample uses (`cmux-app-host/tools/pack.ts`, built into the CLI) writes `dist/main.js`; a plain
   `dist/main.js` needs no build. A build may run 120 s (`--build-timeout SECS` changes it);
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

## The SDK in a new extension

`cmux ext new` writes `sdk/`: `cmux-extension-sdk` as the `cmux` that ran it was built with it
(its TypeScript source and the runtime's event and scope tables, embedded in the binary).
`tsconfig.json` points `import … from "cmux-extension-sdk"` there and `package.json` names it as
`file:./sdk`, so a new extension builds with no npm account, no registry and no network, and its
`API_VERSION` is that cmux's. `cmux ext new` in a newer cmux gives a newer copy.

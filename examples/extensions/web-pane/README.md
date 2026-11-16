# Web pane: an extension whose pane is its own page

`local/web-pane` imports nothing but `cmux-extension-sdk/web`. Its pane (`cmux.pane/1`) is an
HTML page it ships (`render: web`), not a scene:

- **Its own files only.** `runtime.web.root` is `web/`; cmux serves the page from that folder on
  the page's own origin and nothing else. The page's policy is strict: no network, no frames, no
  file outside the root.
- **The same scopes as a script.** `call("workspace.list")` goes through the door an
  extension's script uses: cmux checks it against the scopes the person granted
  (`workspace:read`, `storage:local` here). Every call is answered later, at most 256 KiB each
  and 200 a second. The "Try to rename a workspace" button asks for `workspace.rename`, which
  needs `workspace:write`; the extension never asked for it, so cmux answers `scope.missing`.
- **cmux's look.** The page reads cmux's theme through CSS variables (`--cmux-text`,
  `--cmux-accent`, ...), which follow light, dark and custom colors.
- **Hot reload.** Save a file and the open pane reloads in place; nothing restarts.

## Run it

```sh
cd examples/extensions/web-pane
cmux ext dev            # loads it into the running cmux; every save reloads the open pane
cmux ext dev --once --json   # one check: the manifest, the files, and the page cmux will host
```

Install it from the card cmux shows, then open "Web pane" from the command palette. Edit
`web/index.html` or `web/page.css` and save: the pane reloads. `src/page.ts` builds to
`web/page.js` with `bun run build` (or `cmux ext dev --build "bun run build"`).

Outside this repository, copy the folder, run `npm install` (the dependency is
`cmux-extension-sdk`) and remove `paths` from `tsconfig.json`.

## Files

- `cmux-app.json`: the manifest: `runtime.web.root`, and `implements["cmux.pane/1"].web`.
- `web/`: what cmux serves: `index.html`, `page.css`, and `page.js` (built from `src/page.ts`).
- Tests: `cmux-tui/crates/cmux-tui/src/cli/ext/tests.rs` (`once_loads_the_web_pane_example`)
  runs `ext dev --once` on it; `cmux-tui-core` `apps::supervisor_tests::page_calls` checks the
  scopes.

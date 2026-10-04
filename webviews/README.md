# cmux Webviews

This is the source-owned React bundle for embedded cmux webviews. It currently ships the `cmux diff` viewer and is structured to host more React-backed webviews.

Build it with:

```sh
./scripts/build-webviews-app.sh
```

The build output is committed under `Resources/markdown-viewer/webviews-app` because the macOS app serves local static files from its bundled resources. Keep source changes in this directory, then regenerate the bundled asset with the script above.

The same build emits `diff-page.html`, the diff viewer of the cmux-next shared page host (`cmux-page://cmux.diff/`, whose root is this output directory). It embeds no config and no CSP meta: it calls `cmux.diff.config` over the cmuxPage bridge (`src/diff/page.ts` lists the ops and streams), and the scheme handler sends the CSP.

It also emits `markdown-page.html`, the markdown editor (`cmux-page://cmux.markdown/`, `src/pages/markdown`). It runs under the strict PageCSP and talks to its host only over the cmuxPage bridge; `src/pages/markdown/host.ts` lists the ops (`cmux.markdown.config`, `.save`, `.openLink`, the `cmux.markdown.changes` stream, the `save` page command) and the resources the host serves (`assetBase` images, `libBase` diagram libraries). Saving is a minimal-change write (`src/pages/markdown/sourceMap.ts`): blocks the user did not edit are written back byte for byte, which `test/markdown-roundtrip.test.ts` checks on a corpus of real repo files. The classic viewer (`Resources/markdown-viewer/shell.html`) is unchanged.

React Compiler is enabled in `vite.config.ts` with the React 19 runtime target. Verify the compiled bundle guard with:

```sh
./scripts/check-webviews-react-compiler.mjs
```

## Dev server

`bun run dev` serves every surface from one Vite+ server with hot reload; `http://127.0.0.1:4200/` lists them (`CMUX_WEBVIEWS_DEV_PORT` moves it):

- `/diff/`: the diff viewer against the real `cmux-diff-sidecar` (`$CMUX_DIFF_SIDECAR`, else the newest one in a built app), on this repo. Query: `?source=branch&base=HEAD~5` (default), `?source=unstaged|staged`, `&layout=unified`.
- `/markdown?file=<path>`: the markdown editor on a markdown file under the repo (saves write the file; Cmd-S saves at once). Files under `CMUX_MARKDOWN_DEV_READONLY_ROOTS` (colon-separated) open read only.
- `/markdown/viewer?file=<path>`: the classic markdown viewer shell (`Resources/markdown-viewer/shell.html`). Saving the file or a shell stylesheet updates the page in place.
- `/agent-pane/` (and `/agent-pane/prototype.html`): the agent pane, `?mock` for the in-page daemon. See [its README](src/agent-session/acpmux/README.md#dev-server); `bun run dev:agent-pane` still serves the pane alone on 4176.

The hosts are `apply: "serve"` plugins in `dev-server/`, so `vp build` output does not change; `test/dev-server.test.ts` covers their path and request checks. `scripts/agent-pane/dev-slot.sh up N` runs this server on port 4180+N next to a standalone acpmux daemon and prints one URL per surface (sidecar from `$CMUX_DIFF_SIDECAR_BIN`, else the newest built app).

Static checks run through Vite+ (`vp check`: Oxlint, Oxfmt and a TypeScript Go type check). The rules and formatting live in `config/vite-plus/check.ts`, shared with `cmux-tui/frontends/web`:

```sh
bun run check      # what CI runs
bun run check:fix  # format and apply lint fixes
```

Large public stress samples are available through:

```sh
./scripts/open-diff-viewer-stress-samples.sh bun-rust
./scripts/open-diff-viewer-stress-samples.sh all
```

The sample opener caches local clones under `/tmp/cmux-diff-viewer-stress`, checks out the sample refs, then runs `cmux diff --base <ref>` from inside the repository so the stress path matches normal local git diffs.

## Diff viewer languages

The diff viewer highlights every language Shiki ships; each grammar is its own lazily loaded chunk, and highlighting runs in the `@pierre/diffs` worker pool (`src/worker-pool.ts`). `src/diff-languages/detect.ts` picks a file's language from user overrides, user grammars, known file names (`Dockerfile`, `Makefile`, `.zshrc`, ...), the extension and then the `#!` line, and falls back to plain text. Syntax colors come from the terminal theme's ANSI palette (`appearance.themes.*.palette`, `src/syntax-colors.ts`).

Users add languages in `diff/languages/` next to `cmux.json` (`~/.config/cmux/diff/languages/`; `CMUX_NEXT_CONFIG_FILE` moves it): a `<name>.language.json` manifest (`id`, `grammar`, `scopeName`, `extensions`, `filenames`, `aliases`, `embeddedLanguages`) beside a TextMate `<name>.tmLanguage.json`, and `overrides.json` (`{"extensions": {"h": "c"}, "filenames": {"BUILD": "python"}}`). The host sends the folder's JSON files as text, unparsed, in `payload.languages` and on change through `window.cmuxDiffViewerLanguages.apply({files})`; the page validates them, skips an invalid file with a warning and applies the rest. A changed grammar the page already loaded returns `reloadRequired`, and the host reloads the page. `src/diff-languages/pack.ts` documents the format; the dev server reads the folder and hot-applies edits.

# Acpmux React pane

Swift is the WKWebView host only. On `ready`, the versioned host bridge returns the authenticated loopback WebSocket endpoint, a per-launch token, and the selected session id. The React client connects directly to acpmux, initializes, watches sessions, attaches with `{eventStream: true}`, pages older records with `beforeSeq`, and folds the event stream into its view model. Acpmux owns session state and business logic; the bridge carries only host configuration and native-only actions.

TanStack Query (`catalog.ts`) caches acpmux server state that the pane requests on demand: today the harness and model catalog, fetched after connect instead of before attach, refetched for each new client and on focus once a minute old. Use it for request/response reads like that (model lists, a future session browser). Do not put the transcript, session list, queue or permission in it: acpmux streams those over the watch/attach subscription and the direct client folds them in order, so they stay in the client snapshot. Older history pages merge into the same rows and stay there too.

Rows are measured before paint with [Pretext](https://github.com/chenglou/pretext) using the named `Helvetica Neue` font. Prepared markdown blocks are cached by row id, content version, and text. Layout stores exact tops and heights in typed arrays and finds the visible range with binary search. React mounts only that range; row components are memoized by id and content version, so a streaming update replaces one row.

User customization files live in `~/.config/cmux/agent-pane/`: `theme.css`, `layout.json`, and `registry.js`. Registry components must provide a static `measure(row, width)` function returning a Pretext-based height. Components without it use post-mount measurement and scroll anchoring. `registry.js` can register or replace message, tool, edited-files, permission, and composer-chip components. cmux-next watches the directory (next to `cmux.json`, so `CMUX_NEXT_CONFIG_FILE` moves it) and pushes changes to open panes: it evaluates `registry.js` as host script, separately so a broken registry cannot stop the theme, then calls `applyCustomization({themeCSS, layout})`, which replaces the user stylesheet (an empty one after `theme.css` is deleted) and hands `layout.json` to the registry's `configure`. A file that is missing or invalid is skipped and the others still apply. `registry.js` runs inside its own function scope and is replayed on every page load, handshake and file change, so keep it idempotent: register renderers, don't add listeners or timers at top level. Deleting it takes effect on the next pane load.

Dictation: the mic next to Send (or Toggle Dictation, Ctrl-Cmd-V by default; hold it to talk) runs Apple's on-device speech in Swift (`CmuxNextDictation`). Swift pushes each change through `cmuxAcpmuxBridge.dictation(update)` with the session's whole text, and `dictationText.ts` splices it at the prompt's cursor: typed text around it stays, a revised hypothesis replaces itself in place, and Esc (`dictation.cancel`) removes the session's words. Words the user edits mid-session become theirs; later words continue after them, and a revision of words they took over only adds what is new. Nothing is sent unless `layout.json` opts in with `{"dictation": {"autoSend": true}}`, and then only when the session placed words. Dictation reads the prompt's plain text and writes each change as one undoable edit of the span that changed (`MarkdownFieldHandle.text` / `writeText`), so formatting around it stays; macOS dictation (Fn Fn) and third-party input methods keep working in the editor, and an update that arrives mid-composition waits for it to end. While idle no timer or key listener runs.

The virtualized DOM cannot provide selection or find across rows that are unmounted. The v1 pane keeps cmux find in the host, which can ask the direct client to page and mount a matching row in a future action. The preview harness is the iteration path: `cd webviews && bun run preview:dev` for Vite hot reload, or `bun run preview:build`, which writes static files to `webviews/dist/acpmux-agent-session-preview/`.

## Dev server

To iterate on the real pane inside a running cmux-next with hot reload:

1. `cd webviews && bun run dev:agent-pane` serves this directory with Vite at `http://127.0.0.1:4176/`.
2. Launch a tagged build with the pane pointed at it: `CMUX_NEXT_AGENT_PANE_DEV_URL=http://127.0.0.1:4176/ ./scripts/reload.sh --tag <tag>`. `reload.sh` forwards the variable to the app.
3. Open New Agent Chat and edit the TypeScript or CSS here; Vite hot-reloads the pane in about a second. Swift still answers the handshake, so the page talks to the real acpmux daemon and its sessions.
4. Before committing, rebuild the shipped page with `./scripts/cmux-next/build-agent-pane-web.sh`; CI runs it with `--check`.

Only Debug and tagged builds read the variable; Release always loads the bundled page. The URL must be `http` on `127.0.0.1` or `localhost` with an explicit port, and anything else falls back to the bundled page. The pane only trusts that exact origin, but whatever process listens on that port receives the daemon token, so point it only at your own dev server. The dev page's CSP (`index.html`) allows same-origin scripts for Vite; the bundled page keeps its inline-only CSP.

## Merging feat-cmux-next

The shipped page and the webviews app bundle are committed build output, so two branches that each rebuilt them always collide. With the clone's merge drivers registered (`./scripts/install-git-hooks.sh`, run by `setup.sh`), `git merge origin/feat-cmux-next` keeps this branch's copies instead of stopping on them. Resolve any source conflicts, then run `./scripts/cmux-next/regenerate-web-bundles.sh`, which syncs `node_modules` to the merged lockfile, rebuilds both bundles and stages them. CI's `--check` steps fail until it has run. GitHub ignores merge drivers, so the PR page still reports the conflict until the merge is pushed. Rebase, cherry-pick and `git stash pop` use the driver too, and in a rebase "ours" is the upstream, so each replayed commit loses its bundle change: run the script and commit after those as well.

## Comparing against reference captures

`bun run compare:agent-pane [scenario]` renders the pane in a headless Chromium with the bridge stubbed to mock mode, replays a recorded turn (`scripts/agent-pane/<scenario fixture>.json`) through the in-page daemon and the production client, applies the default dark terminal theme the way Swift does (`scripts/agent-pane/theme.mjs`), and scores the transcript against a reference capture with pixelmatch, as the reference prototype's `compare-region.mjs` does. It prints the mismatch and writes `$TMPDIR/cmux-agent-pane-compare/<scenario>/{ref,actual,diff,side}.png` (or `--out DIR`). The captures live in the private reference prototype checkout: pass `--reference DIR` or set `CMUX_AGENT_PANE_REFERENCE` (required, no default). Scenarios, with the reference's content rectangle and scroll anchor, are listed in `scripts/agent-pane/compare.mjs`.

For showcase captures rather than scores, `worked-turn` has no reference: it replays a coding turn with every transcript part (the "Worked for" fold, tool rows with output, two edits, a code block and the edited-files card) and writes `actual.png`. Captures go on Catppuccin Mocha so they show the transcript follows the terminal theme:

```sh
bun run compare:agent-pane worked-turn --theme "Catppuccin Mocha" --open
```

`workspace` opens the mock daemon's seeded workspace as it is (`mockFixture.ts`: the populated sidebar and its worked session) in a 1440×900 window, with no recorded script or prompt. Use it for whole-window captures:

```sh
bun run compare:agent-pane workspace --theme "Catppuccin Mocha" --open
```

`--theme NAME` reads a Ghostty theme from `Resources/ghostty/themes`, `--anchor TEXT` scrolls to other text, and `--open` opens the turn's fold. Code blocks color their syntax from the theme's ANSI colors (`palette`, as `--agent-ansi-0` to `--agent-ansi-15`), falling back to the built-in dark colors when a host sends none.

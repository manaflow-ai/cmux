# Code editor page

The cmux-next file viewer and editor (`cmux-page://cmux.editor/`, entry `webviews/editor-page.html`) opens any text file in [Monaco](https://github.com/microsoft/monaco-editor). Dev: `bun run dev`, then `/editor?file=<absolute path>` (`/editor` alone shows the empty state). The host contract is in `plans/cmux-next/diff-host.md`, "Editor page"; `host.ts` has the types.

## What loads

`editor-page.mjs` (the page, the empty state; 67 KB) loads first. Monaco loads when a file opens: `chunks/view.mjs` (the core API and every editor contribution, 3.6 MB), `assets/view.css`, the codicon font and the editor worker (`chunks/editor-worker.mjs`, a same-origin module worker). No Monarch tokenizers and no language services (TypeScript, JSON, CSS and HTML workers) ship. Monaco's UI strings load in the page's language where Monaco has them. Nothing of Monaco is in the diff, markdown or agent pages' first load (`test/editor-csp.test.ts`, `scripts/check-webviews-diff-budget.mjs`).

CSP: the strict PageCSP plus `'wasm-unsafe-eval'` (the diff page's policy without its `connect-src`). Nothing needs `'unsafe-eval'`. Without `'wasm-unsafe-eval'` the page still works on Shiki's JavaScript regex engine, only slower in WebKit.

## Highlighting

One system for the diff viewer, the markdown page and the editor: Shiki with the same grammars (one lazy chunk per language), the same theme (the terminal palette, or the shared `appearance.syntaxTheme`), the same user languages (`<config dir>/diff/languages/`, delivered in the config and the look stream) and the same detector (`diff-languages/detect.ts` with Pierre's extension map). The regex engine is the diff viewer's Oniguruma (the shared `shiki-wasm` chunk); a 1 MB TypeScript file tokenizes in 1.1 s in WebKit with it and in 17.4 s with the JavaScript engine. `@shikijs/monaco` feeds Monaco; `view.ts` wraps its tokenizer states so Monaco stops re-tokenizing at the first line whose state did not change.

Language configurations (comments, brackets, auto-closing pairs, indentation and on-enter rules) come from Monaco's own language definitions, loaded per language; a language Monaco does not define gets brackets, quotes and its line comment.

## Saving never rewrites what you did not edit

The host sends the file decoded as UTF-8 with nothing removed. Monaco holds the text without the BOM and with one line ending; `textCodec.ts` keeps what Monaco would lose: the BOM, and, for a file with mixed endings or lone CRs, every line's own ending (updated from Monaco's change events, so an untouched line keeps its ending and a new line break gets the file's most common one). A missing final newline stays missing. A file the user did not edit, or whose edits were undone, is never written; the host also skips a save whose bytes equal the file's. Non-UTF-8 and binary files open read only. `test/editor-page.test.ts` checks the bytes in Chromium and WebKit.

Saving: the `save` page command (Cmd-S), after a pause (`editor.autoSave` `"afterDelay"`, `editor.autoSaveDelay` ms), on page hide, and when the host calls `cmux.editor.flush`. A save whose base hash is stale is refused; the banner offers Reload and Keep My Changes. A clean file follows a change on disk in place.

## Large files

From `editor.largeFileThreshold` bytes (default 8 MiB) the file opens as plain text with the minimap, folding, bracket pair colors, sticky scroll, occurrence and selection highlights, links and word suggestions off, and a note says so. Monaco itself stops tokenizing above 20 MiB or 300,000 lines, stops syncing the model to its worker above 50 MiB and refuses heap operations above 256M characters. Measured from the built bundle (headless, M-series Mac), a 50 MB file paints in 0.46 s (WebKit) and 0.40 s (Chromium) after navigation, and typing takes 6 ms median, 15 ms p95 per key (WebKit). Under the threshold with highlighting, a 1 MB TypeScript file types at 7 ms median in WebKit.

## Customizing

Settings are the `editor` section of the settings store, with Monaco's and VS Code's names (the shape existing `cmux.json` files use). The host passes the section in the config and re-sends it on `cmux.editor.look`; the toolbar toggles write keys through `cmux.editor.setPreference`, never page storage. Fonts follow the terminal: without `fontFamily` and `fontSize` the editor uses the terminal font and size from the host's appearance.

| Key                                                                         | Default                                                                         |                                                                                      |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `editor.fontFamily`                                                         | the terminal font                                                               |                                                                                      |
| `editor.fontSize`                                                           | the terminal size                                                               |                                                                                      |
| `editor.fontWeight`, `editor.fontLigatures`, `editor.lineHeight`            | `"normal"`, `false`, `0` (from the font size)                                   |                                                                                      |
| `editor.tabSize`, `editor.insertSpaces`, `editor.detectIndentation`         | `4`, `true`, `true`                                                             | per language too                                                                     |
| `editor.wordWrap`, `editor.wordWrapColumn`                                  | `"off"`, `80`                                                                   | toolbar toggle; per language too                                                     |
| `editor.minimap.enabled`                                                    | `false`                                                                         | toolbar toggle; `editor.minimap: bool` works too                                     |
| `editor.lineNumbers`                                                        | `"on"`                                                                          | `"off"`, `"relative"`, `"interval"`                                                  |
| `editor.rulers`                                                             | `[]`                                                                            | per language too                                                                     |
| `editor.renderWhitespace`                                                   | `"selection"`                                                                   |                                                                                      |
| `editor.cursorStyle`, `editor.cursorBlinking`                               | `"line"`, `"blink"`                                                             |                                                                                      |
| `editor.smoothScrolling`                                                    | `false`                                                                         |                                                                                      |
| `editor.bracketPairColorization.enabled`                                    | `true`                                                                          |                                                                                      |
| `editor.stickyScroll.enabled`                                               | `true`                                                                          |                                                                                      |
| `editor.folding`, `editor.guides.indentation`, `editor.renderLineHighlight` | `true`, `true`, `"line"`                                                        |                                                                                      |
| `editor.scrollBeyondLastLine`, `editor.autoClosingBrackets`                 | `false`, `true`                                                                 |                                                                                      |
| `editor.formatOnSave`                                                       | `false`                                                                         | runs a registered formatter; none ship yet                                           |
| `editor.autoSave`, `editor.autoSaveDelay`                                   | `"afterDelay"`, `1000`                                                          | `"off"`: Cmd-S and the host's flush only                                             |
| `editor.largeFileThreshold`                                                 | `8388608`                                                                       | `0` turns it off                                                                     |
| `editor.accessibilitySupport`                                               | `"auto"`                                                                        | `"auto"` follows the host's `screenReader`                                           |
| `editor.toolbar`, `editor.statusBar`                                        | `true`, `true`                                                                  |                                                                                      |
| `editor.languages.<id>`                                                     | built-in: tabs for `make`, `go`; wrap for `markdown`; ruler 72 for `git-commit` | `tabSize`, `insertSpaces`, `detectIndentation`, `wordWrap`, `rulers`, `formatOnSave` |

Look: `--cmux-editor-*` custom properties (`settings.ts` `EDITOR_STYLE_DEFAULTS`, the same defaults in `styles.css`), then `<config dir>/editor/theme.css` last. The editor's colors are Monaco theme colors resolved from these properties, so theme.css restyles Monaco in place: `--cmux-editor-background`, `-foreground`, `-line-highlight`, `-selection`, `-cursor`, `-line-number`, `-line-number-active`, `-indent-guide`, `-whitespace`, `-ruler`, `-scrollbar`, `-scrollbar-hover`, `-widget-background`, `-widget-border`; chrome only: `-chrome-font-size`, `-toolbar-height`, `-status-height`, `-banner-background`, `-error-color`. Any Monaco `--vscode-*` color can also be set on `.monaco-editor`.

## Keys

Monaco handles typing, navigation and its editing chords inside the editor. The app's key dispatcher resolves every chord first, so a chord the app binds without a context never reaches Monaco. App actions reach the page as page commands (`keys.ts`): `save`, `find`, `findNext`, `findPrevious`, `useSelectionForFind`, `hideFind`, `replace`, `gotoLine`, `zoomIn`, `zoomOut`, `zoomReset`, and `editorAction` with a Monaco action id from `EDITOR_ACTIONS`, so an editor-scoped binding can run any of them without a page change.

The editor page sets `codeEditorFocused` (the focused page is `cmux.editor`). While it has the keyboard, the default bindings of the actions in `KeyBindingDefaults.yieldsToCodeEditor` step aside, so their keys reach Monaco (R127); a user binding keeps its own `when`. App-global chords (Cmd-T, Cmd-W, Cmd-N, Cmd-1…9, Ctrl-1…9, Shift-Cmd-P, Cmd-Q, Cmd-comma, Shift-Cmd-T) stay the app's. Cmd-S, word wrap and the editor actions below need `codeEditorFocused`.

| Key                        | App action (default)                             | In the editor                                                  |
| -------------------------- | ------------------------------------------------ | -------------------------------------------------------------- |
| Cmd-S                      | `saveFilePreview`                                | the `save` page command                                        |
| Cmd-F, Cmd-G, Cmd-E        | `find`, `findNext`, `useSelectionForFind`        | the same through page commands                                 |
| Opt-Cmd-G                  | `findPrevious`                                   | the same through a page command                                |
| Ctrl-G                     | `fileEditorGotoLine`                             | the `gotoLine` page command                                    |
| Cmd-=, Cmd--, Cmd-0        | `fileEditorZoomIn`, `ZoomOut`, `ZoomReset`       | the zoom page commands                                         |
| Shift-Cmd-G                | `groupSelectedWorkspaces` (yields)               | Monaco: previous match                                         |
| Cmd-D                      | `splitRight` (yields)                            | Monaco: add selection to next match                            |
| Shift-Cmd-L                | `openBrowser` (yields)                           | Monaco: select all occurrences                                 |
| Opt-Cmd-Up, Opt-Cmd-Down   | `focusUp`, `focusDown` (yield)                   | Monaco: add cursor above, below                                |
| Shift-Opt-Cmd-arrows       | `moveSurfaceToPane*` (yield)                     | Monaco: column selection                                       |
| Opt-Cmd-[, Opt-Cmd-]       | `space.previous`, `space.next` (yield)           | Monaco: fold, unfold                                           |
| Opt-Cmd-F                  | `globalSearch` (yields)                          | Monaco: replace                                                |
| Cmd-I                      | `palette.newAgentChat` (yields)                  | Monaco: trigger suggest                                        |
| Cmd-L                      | `focusLocation` (yields)                         | Monaco: expand line selection                                  |
| Shift-Cmd-I                | `feed.show`                                      | the app's (Monaco binds nothing there)                         |
| Cmd-Enter, Shift-Cmd-Enter | `toggleChecklistItemComplete`, `toggleSplitZoom` | the app's; Monaco's insert line below/above via `editorAction` |
| Shift-Cmd-O, Shift-Cmd-,   | `reopenPreviousSession`, `reloadConfiguration`   | the app's (no symbol providers in the editor)                  |

Chords bound only under other contexts (Cmd-[ and Cmd-] for `browserFocused`, the Cmd-K chords for `agentPaneFocused`, Ctrl-D/N/P for the diff viewer and palette, Shift-Cmd-K for the terminal) stay Monaco's in the editor. The dev server's dispatcher (`devKeys.ts`) takes the same chords.

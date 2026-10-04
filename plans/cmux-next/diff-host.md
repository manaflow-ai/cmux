# cmux-next diff and markdown host (R60 pages)

Owner: cmuxterm-hq-48 (also owns Native/DiffSidecar). Status: plan, slices S1-S3 in progress.

Blockers found on feat-cmux-next:
- The bundled diff sidecar calls `bin/cmux __diff-viewer-refs` / `__diff-viewer-branch` (Native/DiffSidecar/src/server.rs:728, :1705, :1764). They were Swift CLI commands, deleted in 90b48fa188d. bin/cmux is cmux-tui now, so the branch picker and branch change are broken.
- PageSchemeHandler has ONE fixed CSP: no connect-src (patch fetches fail) and no 'wasm-unsafe-eval' (the shiki wasm highlighter fails).
- PageWebView.applyTheme builds WebTheme without surface: (PageWebView.swift:205).
- BrowserHandlers.swift:144-149 marks openDiffViewer, palette.openDirectoryDiffViewer and 11 diffViewer* actions unavailable. No store exists for comments, viewed files or viewer prefs.

Decisions:
(a) Diff backend: the bundled Rust sidecar behind a page-protocol adapter. The page calls cmux.diff.* over the cmuxPage bridge, and a Swift DiffPageProvider runs the sidecar over stdio (pool of 4, as classic). cmux.git.diff cannot carry the viewer (counts plus one patch string: no sessions, branches, streaming). Later the sidecar becomes a pane-protocol provider (provider.kind process) and the page does not change. Objection: a second Rust git engine stays next to the daemon's git_ops, and the Swift spawn code stays for now.
(b) Markdown stays shell.html, packaged as page resources: a build step fills the placeholders, and a shim maps cmuxLib onto cmuxPage. A React rewrite is not part of the host change.
(c) Handshake: the engine-neutral cmuxPage bridge. The page gets its config with an async cmux.diff.config (no injected script, so CEF needs no injection). A new PageDiffTransport carries calls, and events come as a cmux.diff.events subscription. Patches are served at cmux-page://cmux.diff/__patch/<token>/... through a dynamic scheme-handler hook.

Slices, in landing order:
S1 Pages module (React UIs lead reviews): cmux.diff and cmux.markdown in firstParty, a CSP per descriptor, a dynamic-resource hook, PageWebView(surface:) passed to WebTheme, and per-descriptor commands. Tests: CmuxNextPagesTests via cmux-ci.
S2 Rust sidecar: DiffTransportKind::Page; refs and branch implemented natively (no bin/cmux). cargo test on a testbox.
S3 webviews: PageDiffTransport, async config boot, comments over the page bridge (hidden until S5), a pages/diff multi-file bundle. bun test plus bundle checks.
S4 Swift host: DiffPageProvider (pool, session root, token/manifest), bind the open actions, map the navigation actions to page commands. Unit tests with a fake sidecar; live check on cmux-lawrence-2 (Ctrl-Shift-Cmd-G; appearance.surfaces.diff changes the background).
S5 Comment, viewed-files and prefs store (Rust daemon ops through DaemonPageRelay).
S6 Markdown page (build script, MarkdownPageProvider, local images limited to the markdown file's folder, zoom actions).
S7 CLI `cmux diff [--staged|--base]` in cmux-tui.
S8 CEF hosting, after 84f75b5e961 and the cmux.16 scheme registration.

Empty state (host work in S4 for diff, S6 for markdown; page side in webviews/src/viewer-empty, ops.ts has the types):
- When: `cmux.diff.config` answers `{pick: true}` (or a payload with neither `repoRoot` nor `sessionSource`); `cmux.markdown.config` answers `{pick: true}` (or no `path`). The pick answer may carry `payload.appearance` (diff) or `appearance`/`settings`/`themeCSS` (markdown) so the empty state is themed.
- `cmux.diff.recents {}` and `cmux.markdown.recents {}` -> `{home?: string, items: [{path, name?, openedAt, source?, branch?}]}`. `path` is absolute (repo top level, or the .md file); `openedAt` is ms since epoch; the page sorts newest first and shows about 8. Diff only: `source` is the last source kind (`"branch" | "uncommitted" | "staged" | "unstaged"`), preselected in the source step; `branch` is the current branch. The host records an item on every open (empty state, CLI, palette), not only from the empty state.
- `cmux.diff.chooseFolder {start?: string}` and `cmux.markdown.chooseFile {start?: string}` -> `{path}` or `null` (cancel). The host shows the shared palette folder and file picker, starting at `start` (the newest recent's folder). Its interaction is the in-page fallback picker's (webviews/src/viewer-empty/PathPicker.tsx, pickerModel.ts): one level, recent folders first, git repos marked, fuzzy filter of the level, a leading "." lists hidden entries, Tab or Right enters, Left or Backspace on an empty query goes up, Enter chooses (file mode: enters folders, chooses .md files), `~` home, `/` root, `name/` enters, a breadcrumb.
- `cmux.diff.open {path, source: DiffSource}` -> the config `cmux.diff.config` would now answer for that repo (the page renders it in place, no reload). The host resolves `path` to its git top level, authorizes it for the session token and records the recent. `source` is the sidecar `DiffSource`: `{kind: "branch", repoRoot, baseRef?}` (no `baseRef`: the host's default base; `baseRef: "HEAD"` is Uncommitted), `{kind: "staged" | "unstaged", repoRoot}`. Errors: `cmux.diff.not_a_repo`.
- `cmux.markdown.open {path}` -> the `MarkdownConfig` of that file (as `cmux.markdown.config`); the page's file is that file from then on (save, changes, openLink use it). Errors: `cmux.markdown.not_markdown`, `cmux.markdown.not_found`.
- Drops: the page opens drops that carry a path as text (`text/uri-list` file URLs, an absolute path in `text/plain`). WebKit hides Finder file paths from the page, so the native web view must accept file-URL drags on an empty-state page itself and call the same open path (diff: show the source step, or open with `branch`; markdown: `cmux.markdown.open`). Not built yet.
- `cmux.picker.list {path: string | null | "~", mode: "folder" | "file", hidden}` -> `{path, parent, home, entries: [{name, path, kind: "dir" | "file", git?}]}` is the fallback picker's data source; the dev server serves it (home folder only, privacy-guarded home folders never probed). The app needs it only to use the in-page picker.

Markdown page contract for S6 (page side webviews/src/pages/markdown; host.ts has the types, README.md the behavior):
- `cmux.markdown.config {}` -> `{path, text, hash (SHA-256 hex of the bytes), readOnly?, appearance?, assetBase?, libBase?, settings?, themeCSS?}`. `readOnly` for a file outside every workspace root or not valid UTF-8. `settings` is the cmux.json `markdown` section (keys in README.md, for CmuxNextSettings); `themeCSS` is `<cmux.json dir>/markdown/theme.css`.
- `cmux.markdown.save {path, text, baseHash}` -> `{hash}`; refused with `cmux.markdown.conflict` `{hash, text}` or `{deleted: true}` when the file's hash is not `baseHash` (null: create only when absent), `cmux.markdown.read_only` for a read-only file.
- Streams: `cmux.markdown.changes` `{path, hash, text?, deleted?}` on a disk change of the page's file (its own saves included); `cmux.markdown.look` `{settings?, themeCSS?, appearance?}` when one changes (applied in place).
- Links: `cmux.markdown.open {path}` (above) also opens a markdown file the user followed a link to; the page keeps its own link history. `cmux.markdown.openLink {path, href, kind, target?}`: kind `external` (http(s): a cmux browser tab), `file` (another file; `target` its resolved path: the file viewer), `mail` (mailto:/tel:: the system handler). `cmux.markdown.resolveLinks {from, paths}` -> `{links: {[path]: {exists, path?, kind?: "markdown" | "file" | "directory"}}}` for relative targets (decoded, no fragment) of the file `from`, inside the workspace roots; the page batches per tick and caches per file. `cmux.markdown.listFiles {from, prefix}` -> `{entries: string[]}`, paths relative to the file's folder starting with `prefix` (folders end in "/"), for link completion.
- Page commands through the key dispatcher, while a markdown page has the keyboard: `save` (Cmd-S), `back` (Cmd-[), `forward` (Cmd-]), `link` (Cmd-K; Cmd-K is otherwise only agentPane.searchChats, scoped to agentPaneFocused, so a markdown-scoped binding does not conflict).
- Resources from the page origin (strict PageCSP): `<assetBase><path>` images from the file's folder only; `<libBase>mermaid.js` (mermaid.min.js) and `<libBase>vega.js` (vega.min.js then vega-lite.min.js).

Coordinator decisions (2026-10-04):
- Q1: the sidecar becomes a pane-protocol provider (one Rust engine for the viewer), but it is NOT a second git implementation: it uses the same git crate and code as the daemon's git ops (P7 gitwrite and gitui). Agents and the CLI keep using the daemon's git.* ops.
- Q2: comments keep the classic on-disk format (compatibility), unless that blocks something.
- Q3: remote PR patches are later, not v1.
- Q4: the diff opens as a pane TAB in the workspace, not as an app screen.
- Q5: CSP per descriptor, strict by default. First-party pages that need it (diff) may add 'wasm-unsafe-eval' and a connect-src limited to the page's own provider. The React UIs lead reviews it.

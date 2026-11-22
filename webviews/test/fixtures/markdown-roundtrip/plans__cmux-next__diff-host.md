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

Coordinator decisions (2026-10-04):
- Q1: the sidecar becomes a pane-protocol provider (one Rust engine for the viewer), but it is NOT a second git implementation: it uses the same git crate and code as the daemon's git ops (P7 gitwrite and gitui). Agents and the CLI keep using the daemon's git.* ops.
- Q2: comments keep the classic on-disk format (compatibility), unless that blocks something.
- Q3: remote PR patches are later, not v1.
- Q4: the diff opens as a pane TAB in the workspace, not as an app screen.
- Q5: CSP per descriptor, strict by default. First-party pages that need it (diff) may add 'wasm-unsafe-eval' and a connect-src limited to the page's own provider. The React UIs lead reviews it.

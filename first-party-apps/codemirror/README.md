# CodeMirror (`cmux/codemirror`)

A light code editor for files and documents in cmux, built on [CodeMirror 6](https://codemirror.net/) (MIT). It implements `cmux.editor/1` as a web pane: edit a document handle, dirty dot, Save (Cmd-S in the editor and the palette command), external changes, conflicts with Compare / Keep Mine / Use Disk Version, read-only mode, language from the document type, and a diff mode (side by side and inline) for the Diffs app. It is the default editor that Diffs embeds.

The Monaco prototype that shared this design retired; cmux-next's file viewer and editor is the Monaco editor page (webviews/src/pages/editor).

Status: prototype. Web panes, documents and the bridge are proposed (app platform critique C2, C6; plan section 12 V3, V7). Manifest v2: `cmux-app.v2.json` and `catalog/` (section Manifest v2).

## How it works

- `web-src/` is bundled with bun into `web/` (`bun first-party-apps/codemirror/build-web.ts`): `index.html`, `main.js` (ES module), `main.css`, `THIRD_PARTY_NOTICES.txt`. No CDN, no network; CSP `default-src 'self'; style-src 'self' 'unsafe-inline'` (CodeMirror injects its styles at runtime; scripts stay `'self'`).
- The page talks to the host through the proposed bridge (`src/interfaces/web-bridge.ts`): `window.webkit.messageHandlers.cmux.postMessage(json)` out, `window.__cmuxBridgeReceive(message)` in. Messages: `init` (props, terminal theme, settings, locale), `props`, `theme`, `settings`, `command`, `visibility` from the host; `call`, `subscribe`, `emit` (interface events), `commandDone`, `log` from the page.
- `src/shared/doc-session.ts` is the document state machine (loading, ready clean/dirty, saving, conflict, error, closed). One edit is in flight at a time: the single replacement from the confirmed text to the view text, sent with its base revision. A stale base resyncs and rebases; remote edits merge; a clean buffer reloads on a disk change.
- Theme: the host's terminal theme (background, foreground, cursor, selection, 16-color palette, font). Syntax colors map to palette entries and never use the blue ones (4, 12); selection, cursor, matches and focus use host colors, never a library default.
- `src/main.ts` is the app script: `open`, `save`, `revert`, `toggleReadOnly`, `cycleVariant` for the palette, CLI and MCP. With a `doc` handle they act on the document owner; without one they run in the focused editor pane (proposed `app.pane.command`).

## Contributions and scopes

| Kind | Id | What |
| --- | --- | --- |
| Pane kind (web) | `editor` | `web/index.html`, `x-cmux-implements: cmux.editor/1` (capabilities `diff`, `readOnly`, `multiCursor`), pane commands `save`, `revert`, `toggleReadOnly`, `focus` |
| Commands | `open` (CLI/MCP), `save` (palette, proposed `x-cmux-keybinding: cmd+s` when an editor pane is focused), `revert`, `toggleReadOnly`, `cycleVariant` (DEV) | |
| MCP | `codemirrorTools` | the commands |

Scopes: `document:write` (edit and save documents you open with it), `workspace:write` (open an editor pane).

Settings: `variant` (DEV), `fontFamily` (empty: terminal font), `fontSize` (0: terminal size), `wordWrap`, `lineNumbers`, `tabSize`. CodeMirror has no minimap.

## Variants (DEV/NIGHTLY setting `variant`, palette "Next CodeMirror Variant")

| Variant | Design |
| --- | --- |
| `statusLine` (recommended) | a 22 pt status line under the editor: dirty dot, name, notice (Saved, Reloaded from disk, Read only), Ln/Col, language, encoding |
| `header` | a header above the editor: dirty dot, name, Save button; no status line |
| `bare` | the editor only; a banner appears for conflicts, errors and a read-only reason |

Recommendation: `statusLine`. Strongest objection: the status line duplicates information the cmux tab title and sidebar could show (name, dirty dot), so in a split with many panes it is chrome repeated per pane; `bare` with the dirty state in the tab title is cleaner once the tab title API exists. Embeds (Diffs) always get `chrome: "none"`.

## Bundle

`web/` total 0.79 MB (main.js 755 KB minified, main.css 2 KB, notices 36 KB): CodeMirror core, merge view, search, autocomplete (brackets only), JavaScript/TypeScript, JSON, Markdown, Python, Rust, CSS, HTML.

## Proposed operations

| Op | Params | Result | Owner | Risk | Scope | Events | Why |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `document.open` | `{doc \| uri}` | `{info: DocInfo, text}` | document host | read | `document:read` | `document.changed`, `document.conflict` (filter `{doc}`) | no document primitive (C2/V3) |
| `document.edit` | `{doc, base_revision, edits}` | `{revision, dirty}` (stale: `document.revision_mismatch`) | document host | mutate-shared | `document:write` | `document.changed` | one buffer, many views |
| `document.save` | `{doc, revision, overwrite_disk?}` | `{revision}` (`document.conflict` with `details.disk_revision`) | document host | mutate-shared | `document:write` | | atomic save with conflict check |
| `document.revert` | `{doc}` | `{info, text}` | document host | mutate-shared | `document:write` | | Use Disk Version |
| `document.read` | `{doc, revision}` | `{text}` | document host | read | `document:read` | | diff side at a revision |
| `diff.file.read` | `{diff, path, side}` | `{text}` | diff producer | read | `diff:read` | | diff mode inside Diffs |
| `ui.open` | `{interface: cmux.diff.renderer/1, props}` | | shell | mutate-own, gesture | | | Compare during a conflict |
| `app.pane.open` | `{kind, props}` | `{pane}` | shell | mutate-own, gesture | `workspace:write` | | Open File |
| `app.pane.command` | `{kind, command, args}` | command result | shell -> focused pane | per command | | | palette Save reaches the focused web pane |
| `app.settings.set` | `{key, value}` | | config layer | mutate-own | | settings push to panes | persist the variant |

## Manifest v2

`cmux-app.v2.json` is the manifest v2 that the daemon's app supervisor loads; it passes the one validator (`cmux-tui/crates/cmux-app-manifest`). It declares the same app as `cmux-app.json`: `runtime.main` `dist/main.js`, `cmux.editor/1` as a web implementation (`web/index.html` under `runtime.web.root` `web/`, with the CSP of v1), and the catalog fragment `catalog/codemirror-catalog.json`. Every v1 command is one catalog op of family `codemirror` (owner `app:cmux/codemirror`, `export` names the JS function, CLI `apps run cmux/codemirror <verb>`, palette title only for palette commands, MCP as v1 exposed it). The DEV/NIGHTLY `variant` setting is the `variants` block. `cmux-app.json` stays for today's in-app runtime.

The v2 schema cannot hold these parts of the app, so the manifest leaves them out:

1. Keyboard surface: the catalog op format has no keyboard field, so `Cmd-S` for `codemirror.save` and the `when: paneFocused:editor` condition stay in `cmux-app.json` only.
2. `openWith` (ask to become the default editor for a type): no manifest field. The handled types are on the `cmux.editor/1` implementation (`types`).
3. `options.capabilities` and `options.paneCommands` are free-form: the `cmux.editor/1` interface file defines no options yet.

Platform gaps found by the earlier v2 sketch (still open):

- The web pane bridge message shape is not specified in V7 (interfaces/web-bridge.ts proposes one).
- No pane-routed commands: Save from the palette or Cmd-S must reach the focused web pane (`options.paneCommands` lists them).
- V7 CSP: both editor libraries inject styles at runtime and need style-src 'unsafe-inline'; scripts stay 'self'.
- No terminal theme in the pane init (background, foreground, cursor, selection, 16-color palette, font): the editors must not fall back to library colors.
- document.read {doc, revision} for an older revision (conflict compare) is not in V3's op list.
- No locale in the web pane init; cmux.t(key) is defined for the script VM only.
- No pane visibility event to pause work in hidden panes.

Update (2026-10-03): the manifest v2 extensions (app-platform.md 12.5) now hold the items above that this app needed; `cmux-app.v2.json` and its catalog declare them (scopes, handles, keyboard, gestures, presets, requires, lifecycle, documents, openWith, notices, drag/drop and `consumes` as applicable). Items that depend on missing runtime support (embed node, pane-routed commands, native servers) stay open.

## Platform gaps (most important first)

1. Web panes: the manifest accepts `web` but nothing hosts it; the bridge (message shape, transport, grant checks, origin stamping) is unspecified.
2. Documents (open, edit, save, revert, conflict, external change, unsaved journal, open-with) do not exist.
3. No interfaces in the manifest (`x-cmux-implements` stands in) and no open-with per type.
4. No pane commands and no command key bindings: Cmd-S works inside the editor, the palette Save needs `app.pane.command`; `x-cmux-keybinding` and `x-cmux-when` are proposals.
5. No terminal theme or font for apps; the init message proposes one (`EditorTheme`).
6. CSP: the editor needs `style-src 'unsafe-inline'`.
7. No locale and no visibility event for web panes (the bridge proposes both).
8. `app.settings.set`, `x-cmux-devOnly`, app l10n.

## Checks

```bash
cd first-party-apps/codemirror && bun install    # pinned, minimum release age 7 days (bunfig.toml)
bun build-web.ts [--check]                        # web/
bun notices.ts [--check]                          # THIRD_PARTY_NOTICES from node_modules
cd ../.. && bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/codemirror
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/codemirror
bun test first-party-apps/codemirror/test
```

`preview/*.json` are web pane fixtures (`init`, `ops`, `events`) for an offscreen screenshot harness; `preview/make-fixtures.ts` regenerates them. Licenses of bundled code: `THIRD_PARTY_NOTICES`.

# Finder (`cmux/finder`)

Browse folders on this Mac, cmux servers, Cloud VMs, the team VM and plain SSH hosts. Copy, move, rename and trash with progress, conflicts and undo; preview text, markdown, images and PDF; send files to the focused terminal or agent.

Built as a third-party app would be: it uses only the public `cmux` global and scene views, and it holds only handles the user gave it (`root_…` folders, `conn_…` connections). It never sees an absolute path, a host name it was not given, or a credential. Every file operation runs in the owner of the bytes. The platform proposal behind it is `plans/cmux-next/finder.md`.

## Contributions

| Kind | Id | What |
| --- | --- | --- |
| Sidebar section | `files` | Favorites (roots), Hosts (connections, with state and path), Add Folder, Connect to Host, Recent |
| Pane kind | `finder` | the browser (variant below), preview, jobs |
| Commands | `openFinder`, `addFolder`, `connectHost`, `cycleVariant` (DEV) | palette and section context |
| Settings | `variant` (DEV/NIGHTLY), `showPreview` | |

## Scopes

| Scope | Why |
| --- | --- |
| `fs:read` | list and preview files in the folders and hosts you give the app |
| `host:read` | show the hosts you connected the app to and whether they are online |
| `fs:write` (optional) | create, rename, copy, move and trash when you ask, only in folders you gave write access to |
| `host:control` (optional) | open the cmux connect sheet when you click Connect; you choose host and credential |
| `terminal:input` (optional) | Insert Path in Terminal |
| `agent:write` (optional) | Attach to Agent |

## Variants

| Variant | Design |
| --- | --- |
| `listPreview` (default, recommended) | path bar, sortable list with Name / Date Modified / Size / Kind, preview on the right, jobs strip below |
| `columns` | column view: every folder opens a column to the right, the last selection previews on the right |
| `dualPane` | two lists side by side (this Mac and a remote host by default) with Copy → / Move → between them |

Switch with the DEV setting `variant` or the palette command "Next Finder Variant".

## Proposed operations

None of these exist yet; the app calls them with `cmux.call` and shows what is missing when the host answers `operation.unsupported` or `scope.missing`. Details, errors and limits: `plans/cmux-next/finder.md`.

| Op | Owner | Risk | Scope | Invalidated by |
| --- | --- | --- | --- | --- |
| `host.list` | `cmux link` (transport) | read | `host:read` | `host.watch` |
| `host.connect` (host-owned sheet), `host.disconnect` | `cmux link` | mutate-own | `host:control` | `host.watch` |
| `fs.roots.list`, `fs.root.pick` (host panel) | app supervisor + host panel | read / mutate-own | `fs:read` | `fs.roots.watch` |
| `fs.list` (cursor batches, owner-side sort and filter) | file system owner (session host; `cmux link` for SSH) | read | `fs:read` + root | `fs.watch` |
| `fs.watch` (stream with revisions) | file system owner | read | `fs:read` + root | none |
| `fs.read`, `fs.thumbnail` | file system owner | read | `fs:read` + root | `fs.watch` |
| `fs.mkdir`, `fs.rename`, `fs.copy`, `fs.move`, `fs.trash`, `fs.undo` | destination file system owner | mutate-shared / destructive | `fs:write` + read-write root | `fs.job`, `fs.watch` |
| `fs.job.list`, `fs.job.cancel`, `fs.job.resolve` | destination file system owner | read / mutate-own | `fs:read` / `fs:write` | `fs.job` |
| `document.open` | document host (session host) | mutate-own | `fs:read` + root | none |
| `terminal.drop` | session host of the terminal | mutate-shared | `terminal:input` | none |
| `agent.attach` | ACP session owner | mutate-shared | `agent:write` | none |
| `app.pane.open` | app supervisor / Mac app | mutate-own | none | none |

## Manifest v2

`cmux-app.v2.json` is the manifest v2 that the daemon's app supervisor loads; it passes the one validator (`cmux-tui/crates/cmux-app-manifest`). It declares the same app as `cmux-app.json`: `runtime.main` `dist/main.js`, `cmux.section/1` (`renderFiles`) and `cmux.pane/1` (`renderFinder`), handles `root` and `host`, and the catalog fragment `catalog/finder-catalog.json`. Every v1 command is one catalog op of family `finder` (owner `app:cmux/finder`, `export` names the JS function, CLI `apps run cmux/finder <verb>`, palette title only for palette commands, MCP as v1 exposed it). The DEV/NIGHTLY `variant` setting is the `variants` block. `cmux-app.json` stays for today's in-app runtime.

The v2 schema cannot hold these parts of the app, so the manifest leaves them out:

1. Scopes `host:control` (open the connect sheet) and `terminal:input` (insert a path into the focused terminal): not in the v2 scope grammar. Connect to Host and Send to Terminal need grammar entries before the supervisor can grant them.
2. Handle limits (`max`, `rights`, host kinds): `handles` holds a reason only.
3. `cmux.opener/1` and `cmux.search.provider/1`: the app has no `openLocation` or `searchNames` export yet, so it does not claim them.
4. Drag sources and drop targets (`drag.provides`, `drop.accepts`): no manifest field.

Platform gaps found by the earlier v2 sketch (still open):

- No ScrollView, visible-range events, keyboard selection or Table in the v2 scene vocabulary list beyond the names in V7.
- No scene props for drag sources and drop targets (12.4 names the payload, not the scene contract).
- Image cannot render an img_… handle from fs.thumbnail.
- No ent_… handle for one dropped file; the 12.4 payload passes the dragger's handle.
- No fs.search op named in cmux.fs.provider/1 (needed for the search provider without a crawl).

Update (2026-10-03): the manifest v2 extensions (app-platform.md 12.5) now hold the items above that this app needed; `cmux-app.v2.json` and its catalog declare them (scopes, handles, keyboard, gestures, presets, requires, lifecycle, documents, openWith, notices, drag/drop and `consumes` as applicable). Items that depend on missing runtime support (embed node, pane-routed commands, native servers) stay open.

## Platform gaps

1. No scroll container and no visible-range events: lists page 22 rows at a time.
2. No keyboard selection, focus or key commands in lists.
3. No modifier keys or double-click on tap: tap selects, a second tap opens; no multi-select.
4. No `Table` node: columns are hand-built, not resizable.
5. No drag source or drop target props: drag to terminals and agents is reachable only through the context menu.
6. `Image` loads bundle files only: thumbnails (`img_…` handles) show a placeholder.
7. No embed node: the preview is built in instead of the user's `cmux.viewer/1` app.
8. No pane size and no pane input in the mount context; no `app.pane.open`.
9. The preview harness runtime lacks the global `onCleanup` and `cmux.gesture`; `src/runtime.ts` feature-checks both.
10. Manifest: `storage:local` cannot be declared, no `files` category, `x-cmux-devOnly` is not honored on commands.
11. `untrack` exists at runtime but not in `cmux-app.d.ts`.
12. No search or bordered style for a toolbar `TextField`.

## Layout

`src/model/` holds the pure, tested model: handles and root-relative paths (`handles.ts`), entries and the shared comparator (`entries.ts`), the listing reducer for cursor batches and watch events (`listing.ts`), the job state machine (`jobs.ts`) and drag payloads and drop plans (`drag.ts`). `src/browser.ts` is one directory browser; `src/views/` builds the scene. Strings: `strings/en.json`, `strings/ja.json` via `t()` in `src/l10n.ts`.

Build: `bun first-party-apps/build.ts finder`. Test: `bun test first-party-apps/finder/test`. Fixtures: `bun first-party-apps/finder/preview/make-fixtures.ts`.

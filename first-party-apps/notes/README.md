# Notes (`cmux/notes`)

Plain-text and markdown notes inside cmux. Global notes, one scratchpad per workspace that follows the workspace, quick capture, pins, search, markdown export, and the same commands as MCP tools so an agent can keep notes for you. Agent writes go through commands: they never move focus or selection, and they show a sparkles mark when the host reports an agent actor.

Prototype on the public app API only (`cmux` global and view builders). Everything the API lacks is a proposed operation called through `cmux.call` with a fallback, or a gap listed below.

## Contributions

| Kind | Id | What |
| --- | --- | --- |
| sidebar section | `notes` (`renderNotes`) | the main surface; design picked by the `variant` setting |
| pane kind | `notesPane` (`renderNotesPane`) | list and editor side by side. The platform does not mount pane kinds yet; the preview harness renders it |
| command | `newNote` | palette and section menu: an empty note, selected in the app's surfaces. Not an MCP tool |
| command | `capture {text, workspace?}` | quick capture: a new note from text, first line = title. Palette and MCP |
| command | `list {query?, workspace?, limit?}` | titles, previews, pin, workspace, revision; never bodies |
| command | `read {id}` | one full note |
| command | `create {title?, body?, workspace?, pinned?}` | a new note |
| command | `append {id or workspace, text}` | adds lines; with `workspace` appends to its scratchpad and creates it on first use |
| command | `pin {id, pinned?}` | pin or unpin |
| command | `search {query, limit?}` | the search-provider answer (below) |
| command | `export {id?}` | `{files: [{id, name, text}]}` markdown per note |
| command | `open {id}` | shows a note in the app's surfaces (target of search results). Not an MCP tool |
| command | `cycleVariant` | "Next Notes Variant" (palette). Not an MCP tool |
| MCP server | `notesTools` (`tools: "commands"`) | the commands above as tools |

`workspace` arguments take an id, a workspace name, or `"current"` (the focused workspace). Errors carry stable codes: `invalid_params`, `note.not_found`, `note.too_large`, `notes.full`, `workspace.not_found`.

Settings: `variant` (`scratchpad` default, `list`, `split`; DEV/NIGHTLY only via `x-cmux-devOnly`), `sort` (`updated`, `created`, `title`), `bodyLines` (lines shown before Show More, default 12).

## Scopes

| Scope | Why |
| --- | --- |
| `workspace:read` | find the current workspace for its scratchpad; label notes with live workspace names; resolve `workspace` arguments |
| `mcp:expose` | offer the note commands to agents as MCP tools |

Local storage (`app.storage.*`, scope `storage:local`) is always granted by the host and cannot be declared in a manifest (the schema's scope pattern has no `local` level).

## Variants (pick after dogfood)

| Variant | Design |
| --- | --- |
| `scratchpad` (default, recommended) | The current workspace's scratchpad is open at the top with one field to add a line; below it, search and every other note, the selected one open inline. |
| `list` | Search, then all notes (pinned first); tapping a row opens its lines inline under it with an add-line field. |
| `split` | In the sidebar: the list, and after a tap the note replaces it (title field, meta line, lines, add-line field, back chevron). As a pane: list and editor in two columns. |

Recommendation: `scratchpad`. It is the only design that uses what cmux has and other notes tools do not: the workspace. Jotting into the workspace you are in takes no clicks, and an agent's `append {workspace: "current"}` lands in the same place you are looking.

Strongest objection: "current workspace" is a guess. The API has only a session-wide `focused` flag, so with two windows the scratchpad can show the other window's workspace, and with no focused workspace the top half is a label and nothing else. It also spends vertical space on a scratchpad that may be empty, which `list` does not.

## Storage: document store or a folder of `.md` files

Today the app stores every note in one `cmux.storage` key (`notes.v1`, a versioned document). It works now, but it is local to one machine, rewrites the whole set on each save (bounded by the 5 MiB quota; the app refuses writes past 4.5 MB), and synced KV (256 KiB) is far too small for notes.

| | A. Document store primitive (proposed `document.*`) | B. User-chosen folder of `.md` files (`fs` scope) |
| --- | --- | --- |
| Owner | app supervisor (local SQLite, per app) with sync owned by `UserDO`; one record per document | the file system; the app is one of many writers |
| Quota | per app, for example 64 MiB local and 16 MiB synced, plus per-document 1 MiB | the disk |
| Sync | built in (records replicate through `UserDO`, iOS and web read the same records) | none, unless the folder lives in a sync service; never on iOS or the web |
| Conflict rule | per document: last writer wins ordered by revision; a write carries `base_revision` and gets `revision.conflict` with the current copy; the app replays its op (append is safe to replay) | none: external editors overwrite; needs file watching and a merge story |
| Search | the owner can index documents for the search app without running the app | the search app would scan files |
| Interop | export (below) | other markdown editors and git work directly |
| Risk | new owner surface | `fs` read/write scope on a user folder; path escapes; watching without polling needs FSEvents through the host |

Recommendation: A, with export to `.md` files as a user action. Notes must reach the phone and the web, follow workspaces across machines, and be searchable without waking the app; only A gives that with a single writer per note. B is the right second step as one-way export or an opt-in mirror, not as the store.

The store module already speaks A: on start it calls `document.list {collection: "notes"}`; when the op is missing (`operation.unsupported`, `scope.missing`) it falls back to `cmux.storage`. Writes use `document.put` with `base_revision` and replay on `revision.conflict`; it subscribes to `document.changed`. Tests cover the conflict replay. When `document.*` lands, add `"documents:write"` (or the name the platform picks) to `optionalScopes` and a one-time migration from `notes.v1`.

## Proposed operations

| Name | Params | Result | Owner | Risk | Scope | Invalidated by | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `document.list` | `{collection, cursor?, limit?}` | `{documents: [{id, revision, data, updated_at}], cursor}` | app supervisor (local), `UserDO` (synced) | read | `documents:write` (own data; one scope for the app's own store) | `document.changed` | `cmux.storage` is one flat KV: 5 MiB, local only, no revisions, no per-record conflict rule |
| `document.get` | `{collection, id}` | `{id, revision, data} \| null` | same | read | same | `document.changed` | same |
| `document.put` | `{collection, id, data, base_revision}` | `{revision}`; error `revision.conflict {current}` | same | mutate-own | same | emits `document.changed` | same; needs optimistic concurrency so an agent's append and a phone edit both survive |
| `document.delete` | `{collection, id, base_revision}` | `{}` | same | mutate-own | same | emits `document.changed {deleted: true}` | same |
| event `document.changed` | filter `{collection}` | `{collection, id, revision, deleted?}` | same | read | same | | other devices and other app instances write the same notes |
| `app.settings.set` | `{key, value}` | `{}` | config layer | mutate-own (origin `user` only) | none (own settings) | `__cmuxAppSetSettings` | `cycleVariant` cannot persist; today it keeps a session override |
| `client.current` | `{}` | `{workspace, screen, pane, tab}` of the client that mounted the surface | the client (projection of the workspace store) | read | `workspace:read` | event `client.current.changed` | `workspace.list` has one session-wide `focused` flag; two windows can show different workspaces |
| `fs.write` (export) | `{handle, name, text}` where `handle` comes from a user folder pick | `{path}` | native service (file access broker) | mutate-shared | `fs:write` per picked folder | | export can only return text today; nothing can write a file |
| `fs.pick` | `{kind: "folder", purpose}` (origin `user` only) | `{handle, display_name}` (opaque; no raw path in the VM) | native service | read | none (user gesture) | | export target and a future mirror need a user-chosen folder without giving the app the file system |
| `asset.put` / `asset.url` | `{collection, owner_id, name, bytes_base64, mime}` / `{asset}` | `{asset}` / `{url}` (host-served, short-lived) | app supervisor + `UserDO` blob store | mutate-own / read | `documents:write` | `document.changed` | images in notes (paste, drop) need blob storage and a way to show them; there is no binary store and `Image` reads only bundle paths |

## Search provider (proposed `contributes.searchProviders`)

The manifest schema rejects unknown `contributes` keys, so this is a proposal. Shape:

```jsonc
"searchProviders": [{ "id": "notes", "title": {"en": "Notes"}, "run": "search", "prefix": "n", "symbol": "note.text" }]
```

The search app calls `run({query, limit})` and gets:

```jsonc
{ "results": [{ "id": "note_…", "title": "Deploy runbook", "subtitle": "api", "snippet": "freeze merges", "score": 23, "symbol": "note.text", "updated_at": 1790000000000, "open": { "command": "cmux/notes#open", "args": { "id": "note_…" } } }] }
```

`open` runs with origin `user` because the user picked the result. The `search` command already returns this shape (also an MCP tool). With the document store, the owner could index note text so the search app does not wake this app.

## Proposed scene nodes

The renderer has single-line `TextField` and `Text`. The app shows bodies line by line with markdown-lite styling done in app code (headings, bullets, numbers, checkboxes you can tap, quotes, code), edits one line at a time (right-click > Edit Line), and appends through a field. Real editing needs:

- `TextEditor {text, revision, placeholder, markdown: "lite" | "plain", minLines, maxLines, onChange, onCommit}`: multi-line, client-owned text. The client owns the text, selection, IME composition and undo stack; it sends `change {text, base_revision}` debounced and `commit` on blur. The app answers with `revision`; a prop update applies only when its revision is newer than the client's base, so an agent's append never resets what the user is typing (today a controlled `TextField` would echo stale text). Markdown-lite styling (heading sizes, bold, italic, code spans, checkbox glyphs) is drawn by the client, so no per-keystroke round trip. Undo is client-local; an app-side write clears it only for the lines it touched.
- `Markdown {text, onLink, onToggleCheck}`: read-only rendering (CommonMark subset plus task lists, no HTML, no remote images; images through `asset.url`). `onToggleCheck {line}` lets the app toggle a task without parsing positions itself.
- `TextField` `clearOnSubmit: true`: the app rebuilds the field to clear it (the renderer keeps typed text when the `text` prop does not change).

## Platform gaps (most important first)

1. No document store: one local KV key; no sync, no per-note conflict rule, 5 MiB (see Storage).
2. No multi-line editor and no markdown node (see Proposed scene nodes); editing is line by line.
3. Command context has only `{app}`: no `actor`, `origin` or `locale`. The app cannot tell an agent's write from the palette's, so the agent mark depends on a proposed `ctx.actor`, and "select the new note" is limited to commands that are not MCP tools.
4. No per-client current workspace (`client.current` or a `workspace` field in the mount context); the scratchpad uses the session-wide `focused` flag.
5. No way to mark a command as "not an MCP tool": the manifest uses `"x-cmux-mcp": false` on `newNote`, `open` and `cycleVariant`, which the platform does not honor yet.
6. Palette commands cannot prompt for arguments: `capture` needs `text`; the palette should prompt from the command's `arguments` schema.
7. `searchProviders` is not in the manifest schema.
8. No file write or folder pick: export returns markdown text only.
9. No attachments or images: no blob store, and `Image` reads bundle files only.
10. Apps cannot write their own settings (`app.settings.set`); `cycleVariant` keeps a session override.
11. `x-cmux-devOnly` is not honored: the `variant` setting shows in every build.
12. No app i18n API and no locale in the mount context: `src/l10n.ts` holds English and Japanese, and the language comes from `Intl` when the engine has it.
13. No surface visibility signal: relative ages ("5m") refresh only when the note changes, since timers must pause while hidden and the app cannot know.
14. Typings: `CmuxError` is declared without its `(code, message)` constructor (the app casts in `src/errors.ts`), and `untrack` is a runtime global missing from `cmux-app.d.ts`.
15. `storage:local` is needed by `app.storage.*` but cannot be declared (the scope pattern has no `local` level); it is granted implicitly.
16. No way to reveal an app section or open a pane kind from a command (`open` selects the note in mounted surfaces but cannot scroll the sidebar to it).

## Layout and checks

`src/model.ts` (types, pure reducers, title, preview, search, sort, export), `src/markdown.ts` (line classes), `src/store.ts` (signal, ordered writes, document and local backends), `src/commands.ts`, `src/views/*` (one file per variant plus shared pieces), `src/l10n.ts`.

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/notes        # build dist/main.js
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/notes
bun test first-party-apps/notes/test
```

`preview/*.json` are fixtures for the preview harness: `scratchpad`, `list`, `split` (same invented notes), `empty`, `error`, and `documents` (the proposed document store answering).

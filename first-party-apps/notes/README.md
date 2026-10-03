# Notes (`cmux/notes`)

Markdown notes inside cmux: a scratchpad per workspace, quick capture, pins, search, Markdown import and export, and tools so an agent can keep notes for you.

Notes are documents owned by the notes server: `server {kind: native, binary: cmux-notes, args: [serve], instances: user, data: durable}`. One instance per user keeps every note (text, revision, title, pin, workspace), derives titles and previews, searches, stamps who wrote last (user, agent, app, automation, from the caller's principal), and streams typed changes on `note.watch`. It is also the document host of each note's document (`doc_…`): body edits are `document.edit {doc, base_revision, edits}`, a stale base is refused with `revision.conflict` and the current text, and the editor rebases. Its ops are the catalog fragment `catalog/notes-catalog.json` (family `note`, owner `app:cmux/notes`). The text is edited in a native editor pane; this app keeps the sidebar section as scene trees. Nothing implements the server or the pane yet: on today's runtime the section shows "Notes are not available yet".

This app keeps no copy of the notes and no storage of its own: it renders the server's summaries (`note.list`, then `note.watch`) and fetches the bodies a surface shows (`note.get`, again when a newer revision arrives). The earlier single-key local store and its fallback are removed.

Build: `bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/notes`. Validate: `bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/notes`. Test: `bun test first-party-apps/notes/test` (FakeHost with the mock notes server and file broker in `test/mock-server.ts`). Preview fixtures: `bun first-party-apps/notes/test/fixtures.ts --write`. `cmux-app.v2.json` is the manifest v2 sketch.

## Contributions

| Kind | Id | What |
| --- | --- | --- |
| sidebar section | `notes` (`renderNotes`) | the main surface; design picked by the `variant` setting |
| native pane (v2 sketch) | `editor` | the note's text, edited natively (contract below) |
| commands, agent tools | `list {query?, workspace?, limit?}`, `read {id}`, `create {title?, body?, workspace?, pinned?}`, `append {id \| workspace, text}`, `capture {text, workspace?}`, `search {query, limit?}` | forward to `note.list`, `note.get`, `note.create`, `note.append`, `note.capture`, `note.search`. On manifest v2 these are the catalog ops themselves (MCP `default`) and the wrappers go away |
| commands, palette only | `newNote`, `open {id}`, `exportNotes {id?}`, `importNotes`, `cycleVariant` | not MCP tools (`x-cmux-mcp: false`) |
| MCP server | `notesTools` (`tools: "commands"`) | the agent tools above on today's runtime |

`workspace` arguments are selectors (an id, a name, or `"current"`), passed through to the server; the op router resolves them like any selector, so `"current"` is the caller's own workspace (an agent's terminal), not a guess.

Agent writes never move focus: commands call no focus op and never touch a surface's selection; their result reaches mounted surfaces through `note.watch`, and the editor pane applies them as remote edits without moving the caret. Only `newNote` and `open` (user commands) select a note.

## Scopes

| Scope | Why |
| --- | --- |
| `workspace:read` | the current workspace for its scratchpad; live workspace names |
| `mcp:expose` | the agent tools (today's runtime) |
| `fs:read` (optional) | import: read the files the user picked, through the picked handle |
| `fs:write` (optional) | export: write `.md` files into the folder the user picked, through the picked handle |

The app's own catalog ops need no scope. `fs:read` and `fs:write` are not in the generated scope table yet (the validator warns).

## Variants (pick after dogfood)

| Variant | Design |
| --- | --- |
| `scratchpad` (default, recommended) | The current workspace's scratchpad open on top with one field to add a line; below it, search and every other note, the selected one shown inline. |
| `list` | Search, then all notes (pinned first); a click shows the note's lines inline with an add-line field. |
| `editor` | Rows only; a click opens the note in the native editor pane. |

Inline bodies are read-only markdown-lite (headings, bullets, numbers, quotes, code); checkboxes toggle with one `document.edit`, and every inline body has an "Open in Editor" button.

Recommendation: `scratchpad`. Jotting into the workspace you are in takes no clicks, and an agent's `append {workspace: "current"}` lands where you look. Strongest objection: "current workspace" in a sidebar is a guess (the API has only a session-wide `focused` flag, gap 4), and the top half spends space on a scratchpad that may be empty.

## The editor pane (native, first-party)

The only native pane for now. Contract:

- Input: `{doc}`, the note's document handle. No text passes through the app VM. Opened by `app.pane.open {contribution: "cmux/notes#editor", input: {doc}, placement}` with the gesture token of a tap (it moves focus); open-with maps the `note` document type to it.
- Owner: the notes server as document host. The pane reads `document.open {doc}` -> `{text, revision}`, follows `document.watch {doc}` (remote edits with revisions), and sends `document.edit {doc, base_revision, edits}` from an intent log; on `revision.conflict` it rebases its pending edits on the current text. The host keeps the unsaved-buffer journal, so a crash or a closed window loses nothing.
- Client view state: selection, caret, scroll, IME composition, undo stack (client-local; a remote edit clears undo only for the ranges it touched). Remote edits (an agent's append, another device) never move the caret, selection or focus.
- Rendering: markdown-lite styling drawn natively (heading sizes, emphasis, code spans, checkbox glyphs that toggle), find, Dynamic Type, Reduce Motion, VoiceOver.
- Title: derived by the server from the text unless set explicitly; the pane shows it and edits it with `note.update {title}`.

## Markdown export and import

Export (section menu "Export All Notes as Markdown…", a row's "Export as Markdown…", palette "Export Notes as Markdown…"):
1. `fs.pick {mode: "folder", purpose: "export", create: true}` with the tap's gesture: the system panel; the result is an opaque root handle `{root: "root_…", name}`. Cancel is `fs.cancelled`.
2. For each note (oldest first, or the one note): `note.get`, then `fs.write {root, path: "<slug>.md", text, exists: "unique"}` with an idempotency key per note revision. Names are unique slugs of the title; the host never overwrites, it picks a free name. An explicit title becomes a leading `# Title`.

Import (section menu "Import Markdown Files…", palette "Import Markdown Files as Notes…"):
1. `fs.pick {mode: "files", purpose: "import", accept: [".md", ".markdown", ".txt"], multiple: true}` -> `{root, entries: [{path, name, size}]}`.
2. For each entry up to 1 MB: `fs.read {root, path, max_bytes}` -> `{text}`, then `note.create {title?, body}` with idempotency key `import:<root>:<path>` (a retried import creates each note once). A leading `# Title` becomes the title (the inverse of export).

The app never sees or sends an absolute path; a handle reaches only what the user picked.

## Proposed operations

The note ops are in `catalog/notes-catalog.json`: `note.list`, `note.get`, `note.search`, `note.watch` (stream), `note.create`, `note.capture`, `note.append`, `note.update`, `note.delete`. Summary:

| Name | Params | Result | Owner | Risk | Scope | MCP |
| --- | --- | --- | --- | --- | --- | --- |
| `note.list` | `{query?, workspace?, sort?, limit?, after?}` | `{notes: [NoteSummary], next}` | notes server | read | own | default |
| `note.get` | `{note}` | `{note}` with body | notes server | read | own | default |
| `note.search` | `{query, limit?}` | `{results}` (search-provider shape) | notes server | read | own | default |
| `note.watch` | `{after_seq?}` | stream of `{seq, kind: created\|updated\|deleted, note}` | notes server | read | own | never |
| `note.create` | `{title?, body?, workspace?, pinned?, scratchpad?}` | `{note}` | notes server | mutate-own | own | default |
| `note.capture` | `{text, workspace?}` | `{note}` | notes server | mutate-own | own | default |
| `note.append` | `{note \| workspace, text}` | `{note}` (no base revision: appends commute) | notes server | mutate-own | own | default |
| `note.update` | `{note, title?, pinned?, workspace?}` | `{note}` | notes server | mutate-own | own | never |
| `note.delete` | `{note}` | `{}` | notes server | mutate-own | own | never |
| `document.edit` | `{doc, base_revision, edits: [{start, end, text}]}` | `{revision}`; `revision.conflict {current: {revision, text}}` | document host (the notes server for notes) | mutate-own | own | never |
| `fs.pick` | `{mode: folder\|files, purpose, accept?, multiple?, create?}`, gesture required | `{root: "root_…", name, entries?}` | native file broker (the client) | read (user grant) | `fs:read` / `fs:write` | never |
| `fs.write` | `{root, path, text, exists: unique\|replace\|fail}` | `{path}` (relative to root) | native file broker | mutate-shared | `fs:write` | never |
| `fs.read` | `{root, path, max_bytes}` | `{text}` | native file broker | read | `fs:read` | never |
| `app.pane.open` | `{contribution, input?, placement?}`, gesture required | `{tab_id}` | workspace store | mutate-own (focuses) | `workspace:write` | never |
| `client.current` | `{}` | `{workspace, screen, pane, tab}` of the mounting client | the client | read | `workspace:read` | never |

## Platform gaps (most important first)

1. No notes server, no `document.*` host and no native pane host: the app has nothing to read on today's runtime.
2. No `fs.pick`/`fs.read`/`fs.write` or root handles (V6); export and import are refused.
3. Palette commands carry no gesture token, so the palette's Export and Import (which open the system panel) fail with `gesture.required`; the section menu works because a tap carries one.
4. No per-client current workspace (`client.current` or a `workspace` field in the mount context); the scratchpad uses the session-wide `focused` flag.
5. No per-command MCP exposure flag: the manifest uses `"x-cmux-mcp": false`, which the platform does not honor yet. Manifest v2 moves the tools into the catalog fragment, where `mcp.expose` exists.
6. A pull-down `Menu` takes only a text title, so the section's import/export menu hangs off an icon button's right-click.
7. `TextField` has no clear-on-submit; the append field is rebuilt after each submit.
8. Palette commands cannot prompt for arguments (`capture` needs `text`).
9. `searchProviders` / `cmux.search.provider/1` is not in the v1 manifest schema.
10. Today's Swift prototype engine passes neither `locale` nor `strings`; the app's `t()` falls back to its bundled tables by `cmux.app.locale`.
11. `x-cmux-devOnly` is not honored by today's Settings UI.
12. The typings declare `CmuxError` without its `(code, message)` constructor (`src/errors.ts` casts).
13. The preview engine's bundled scope table predates these ops; preview fixtures name their scopes.

## Layout

`src/notes.ts` (wire types, op calls), `src/store.ts` (projection of the server: summaries, bodies, the stream, writes, checkbox toggles with rebase), `src/files.ts` (export and import through handles), `src/model.ts` (pure line edits and Markdown files), `src/markdown.ts` (line classes), `src/commands.ts`, `src/views/*` (one file per variant plus shared pieces), `src/l10n.ts` with `strings/en.json` and `strings/ja.json`. `preview/*.json` are fixtures for the preview harness: `scratchpad`, `list`, `editor`, `empty`, `unavailable`.

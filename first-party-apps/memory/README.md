# Agent Memory (`cmux/memory`)

Browse, search, edit and delete what your agents remember, on every machine and project: `CLAUDE.md`, `CLAUDE.local.md`, Claude project memory (`MEMORY.md` and its topic files), `AGENTS.md` at any depth, `AGENTS.override.md`, `GEMINI.md`, the Copilot instructions file and Cursor rules. Each file shows which agents read it and what kind it is (instructions, personal, override, memory index, memory, rules). Every write shows a diff first; delete moves the file to the Trash. Files reach the app only through root and document handles, never as paths it could open itself.

Status: prototype on today's app runtime (preview harness and bun FakeHost). The memory, document and trash ops are proposed (below). Manifest v2: `cmux-app.v2.json` and `catalog/`; the proposed host ops the app calls are in `proposed/host-catalog.json`, not in its catalog.

## Contributions

| Kind | Id | What |
| --- | --- | --- |
| Sidebar section | `memory` | This machine's memory files (current project first), one native row each; tap opens the pane at the file. |
| Pane kind | `memoryHub` | The browser (three designs, below) with "Search memory", the open file as entries (Edit… and Delete Line… on each, "Add a line to this file…", Move to Trash…), and the review card. |
| Commands | `openMemory`, `reload` (palette, section menu), `cycleVariant` (palette, DEV/NIGHTLY) | |

The memory file table is `src/model/kinds.ts`: one rule per (root kind, path pattern) with the agents that read it and its kind, so adding an agent is one row. Files under a root that match no rule are not shown.

## Scopes

| Scope | Why |
| --- | --- |
| `machine:read` | list machines |
| `memory:read` | list and search memory files under the memory roots; the owner never lists other files |
| `document:read` | read the file you open |
| `document:write` (optional) | save a reviewed edit from a tap (origin user) |
| `fs:write` (optional) | move a reviewed file to the Trash from a tap (origin user) |

## How a write works

Edits are intents (`append`, `remove` and `replace` an entry by its text, `trash` the file), applied to the document's current text to make the "after" text. The review card shows the line diff with two context lines. Save sends `document.edit {doc, base_revision, edits}` with minimal line edits and the tap's gesture. If an agent wrote the file in between, the document host answers `document.stale`; the app reads the file again, applies the same intent once more, and shows the new diff with a note ("This is your edit on the new text"). If the entry is gone, it says so and changes nothing. Move to Trash reviews the whole file as removed lines and sends `fs.trash {root, paths, expected_revisions}`. "Open in Diffs" turns the same edits into a diff resource (`document.propose`) and opens it with the user's `cmux.diff.renderer/1`.

## Variants (DEV/NIGHTLY setting `variant`, palette "Next Agent Memory Variant")

| Variant | Design |
| --- | --- |
| `files` (recommended) | files grouped by project and machine ("api-server · MacBook Pro", "build-server · everywhere") with agents and kind per row; the selected file below as entries; the review above |
| `entries` | every entry of every memory file in one list under file headers, filtered as you type; Delete Line… and Show File on each entry |
| `split` | file list on the left, the selected file and the review on the right |

Recommendation: `files`. Memory is per file and per agent ("which agents read this, is it shared or personal"), and the same stacked layout works at sidebar width and in a pane. Strongest objection: with many Claude project memory files the open document sits under a long list, and with no scroll view in the scene it can fall below the pane; `split` avoids that at pane widths, and `entries` is the fastest way to find and delete one stale fact.

## Proposed operations

Owner: the session host of the machine that has the files (V3 document host), with the `agent_cli.*`, `skill.*` and `mcp_server.*` ops of the sibling apps. The operation-catalog form is `proposed/host-catalog.json`.

| Op | Params | Result | Owner | Risk | Scope | Events | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `memory.roots` | `{machine?}` | `{machine, roots: [{root: root_…, kind: user\|project, label, workspace?}]}` | session host | read | `memory:read` | `workspace.changed` | a user root that exposes only memory paths is narrower than any file root; the app never names a path it was not given |
| `memory.list` | `{root}` | `{files: [{path, size, modified, revision, project_label?}]}` | session host | read | `memory:read` | `memory.watch` | `fs.list` would be a recursive crawl of the home folder |
| `memory.search` | `{roots, query, limit?}` | `{hits: [{root, path, line, text}]}` | session host | read | `memory:read` | | search runs where the files are; the app falls back to names and texts it already read |
| `memory.watch` (stream) | `{root}` | `{root, path, revision}` | session host | read | `memory:read` | | agents write memory; no polling |
| `document.open`, `document.read` | `{root, path}`, `{doc}` | `{doc: doc_…, revision}`, `{text, revision}` | document host (session host) | read | `document:read` | `document.watch` | V3 documents |
| `document.edit` | `{doc, base_revision, edits}` | `{revision}` or `document.stale` | document host | mutate-shared, origin user | `document:write` | `document.watch` | V3 |
| `document.propose` | `{doc, base_revision, edits}` | `{diff: diff_…}` | document host (diff producer) | mutate-own | `document:read` | `diff.changed` | a pending edit as a V5 diff resource, so the Diffs app can show and accept it |
| `fs.trash` | `{root, paths, expected_revisions?}` | `{trashed}` | session host | destructive, origin user | `fs:write` | `memory.watch` | delete must go to the Trash and refuse a changed file |
| `ui.open` | `{interface, props}` | | shell | mutate-own, gesture | | | open in the user's diff renderer |

## Platform gaps (most important first)

1. No documents (V3) on the session host: no handles, revisions, `document.edit` with `base_revision`, `document.watch`, or `document.propose` as a diff resource.
2. No narrow root kind: a "memory root" over the home folder that exposes only the provider table's paths (the permissions model has workspace folders and user-picked bookmarks only).
3. No `fs.trash` with expected revisions, and no confirmation primitive (the review card doubles as the confirmation).
4. Scene: no multi-line text editor (edits are one line at a time: add, change, delete), no ScrollView, no markdown rendering, no inline diff component (the review is built from Text rows).
5. `machine.list` lists only the local machine (see `cmux/agents`); remote memory needs per-machine owners.
6. The context menu must sit on the text node because tools that target a node by text (the preview harness) do not walk up to the row; a row-level menu API would be cleaner.
7. The scope grammar does not know `memory:*` and `document:*` (validator warnings).
8. Claude project memory folders are named by a path slug; the owner must map them to a project label.

## Layout and checks

`src/model/` (memory file table and classification, markdown entries, edit intents and minimal line edits, the review state machine, line diff), `src/store.ts`, `src/actions.ts`, `src/views/` (section, variants, shared parts), `src/l10n.ts` + `strings/`. No third-party code.

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/memory
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/memory
bun test first-party-apps/memory/test
```

`preview/*.json` are preview-harness fixtures (invented machines, projects and memory text); `preview/make-fixtures.ts` regenerates them.

# Built-in Memory Inspector (native, editable)

User ask (2026-10-20): "make sure people can open memory inspector, and it is a built in thing
not a web server thing, and people can selectively edit and delete the memory".

The old inspector (optchat-inspector.md) is a React page served by `optchat-chief` on
`127.0.0.1:<port>` behind a token and a ticket. It closes at once for some users (a243) and it
is read-only. This design replaces it with a native SwiftUI pane in cmux-next that reads and
changes a Chief's memory through the app's own daemon connection.

## Open paths

One action, `chief.openMemoryInspector`, in every build (it was DEV and nightly only):

- Command palette: Cmd+Shift+P, "Memory Inspector".
- The Chief's menu (the Chief settings sidebar's "Show Memory" button and the main menu, Window).
- CLI: `cmux chief memory-inspector [--chief ID]` (the action's CLI name); MCP: the action's
  generated tool.

It opens a pane tab (internal page `chief-memory`) in the Home right column (the column beside
the Chief's chat), one tab per Chief: opening it again for the same Chief selects that tab.
No localhost server, no port, no token, no web view.

## Data path

```
SwiftUI view -> ChiefMemoryClient -> DaemonConnection `chief-inspect` -> daemon (owner check)
  -> brain tools socket {"tool":"inspect","method":GET|POST,"path","query"} -> optchat-chief
```

- Reads reuse the seven read paths (`/api/status`, `/api/node`, `/api/level`, `/api/search`,
  `/api/date`, ...). The app talks to the local daemon for a local Chief and to the paired
  server's daemon for a remote one (Cloud Chief), one code path. The daemon answers only the
  owner's trusted connection (local Unix client or the link's owner_session splice).
- Writes are four new paths, method POST: `/api/memory/edit`, `/api/memory/delete`,
  `/api/memory/undo`, `/api/memory/changes` (the last is a read of the change journal). The
  daemon forwards POST only for those paths; daemons that do advertise `chief-memory-edit-v1`.
- Each Chief: the reserved query key `chief` names a Chief; the daemon sends the request to that
  Chief's brain socket (`chief_brains::tools_socket`), as `chief.engine.*` does. Absent: the
  default Chief. No schema change to the `chief-inspect` command (params stay `path` + `query`).
- At the brain, a write is refused for a caller that is one of the Chief's own turn or subagent
  sessions (`turn_caller::Role`): the Chief and its agents cannot rewrite their own memory
  through this path. The daemon forwards as `Role::Other`.
- Cloud Chief's placeholder inspector (a235) calls the same `chief-inspect` paths.

## What can change

The memory is an append-only log of messages (kinds user, talk, tool, echo, note, work) and a
binary tree of summary nodes `id+n` over it. A tree address must never move, so:

- **Edit a message or a note**: its text is replaced in place (same id, same kind, same date).
- **Delete a message or a note**: its text becomes the tombstone `(deleted by the user)`. The id
  stays, so every node name and `zoom` path stays valid.
- **Edit a summary line**: its text is replaced in place (at most `NODE` bytes).
- **Delete a summary line**: its text becomes the tombstone. It is not built again from its
  children (the user removed it on purpose; a rebuild would bring the content back).

### Summaries after a change (default picked: mark stale, then re-summarize)

After a change to message `m` (or to node `x`), every built ancestor above it still holds the old
content. They are marked **stale** at once (state key `memory.stale`, shown with a badge in the
view) and rebuilt bottom-up by the Chief's own compactor (`compact_request` + `run_node`, the
same prompt and size loop as a normal build). A node whose source fits in `NODE` bytes is
rebuilt at once without a model call (the "free" text: a short message verbatim, or its two
children joined). The rebuilt text replaces the stored text in place; the core's size book
(`Memory::resize`) keeps the view's byte count right. The stale list survives a restart: the
host rebuilds what is left when it starts.

Why this default: editing the ancestors in place by text substitution would miss paraphrased
content (a summary never quotes the message), and leaving them alone would keep a deleted secret
in the Chief's view. A rebuild costs one compactor call per level (about `log2(T)` calls).

Cost of the change to the prompt cache: the view bytes change from the first stale line on, so
the next turn writes its cache from there once. Past turns' "exact bytes" badge in the trace
view turns to "not exact" for turns that showed a changed line; that is correct.

## Safety

- **Backup before any change**: before the first change of a host process, a full copy of the
  database (`VACUUM INTO optchat/backups/memory-<UTC stamp>.sqlite3`, 0600) is written from a
  separate read connection. Every change then appends its record to
  `optchat/memory-edits.jsonl` (0600, fsynced before the database write): change id, time,
  target, old text, new text, and later each rebuilt ancestor's old text.
- **Confirm**: Delete asks first (a sheet with the text it removes). Edit saves on an explicit
  Save button.
- **Undo**: every change can be undone from the change list (and Cmd+Z right after it): the
  target and every ancestor it rebuilt get their old texts back, exactly. An undo is itself a
  journal record. A change whose rows a later change also wrote is undone only after that later
  change (the view says which).

## The view

Three columns, native SwiftUI, in the pane tab:

- **Top bar**: Chief name, message and node counts, settle state, stale count, search field.
- **Tree**: the current view's lines (one per node, newest last) and a breadcrumb; clicking a
  line zooms (the two children, down to one message), the same path as the agent's `zoom`.
  Level strip toggle. Search jumps to the hit's node or message.
- **Detail**: the selected message or line in full: kind, id, date, text; Edit, Delete; stale
  badge on stale lines; the change list (with Undo) at the bottom.

## Old web inspector

The HTTP server now starts only with `OPTCHAT_INSPECTOR_WEB=1` (fallback flag). The app's action
opens the native view; the web page and its ticket path stay in the tree for the fallback and
are removed once the native view has shipped in a nightly without a regression.

## Tests (failing first)

- optchat-core: `Memory::resize` keeps `view_size` and `compact_size` right.
- optchat-host: `edit_message`, `edit_node`, `rebuild_node` change the stored text and the FTS
  index, keep ids, and the core stays consistent (a later append and pump still work).
- optchat-chief (`tests/memory_edit.rs`): over the tools socket: edit, delete (tombstone),
  undo restores exact text, backup file and journal written before the change, ancestors marked
  stale then rebuilt with the fake model, a turn/subagent caller is refused, GET cannot write.
- cmux-tui: `chief-inspect` forwards POST only for the memory paths, refuses non-owners, routes
  `chief` to that Chief's socket.
- CmuxNext (Swift Testing): the action opens one `chief-memory` tab per Chief from the palette,
  the Chief menu and the CLI; edit, delete (after confirm), undo through a fake client.

# Chief memory import (incremental, merge, side lane)

Status: design + first build (a634). Ask: "apply all my memories from the Mac Chief to the Cloud Chief",
modelled on VictorTaelin/UniiChat (`Import.ts`, `Memory.ts`, HEAD 0500bf6).

## What UniiChat does (the parts we copy)
- Imported sessions join the same summary tree as a separate **side**. It builds in the background and
  never blocks a live turn.
- Two passes over the source: **heads** first (count + cost estimate, priced per compaction node), then
  the picked sessions as JSON lines (a note naming the session, then messages oldest first, never thinking).
- An `import_key` per session: a re-import brings only the NEW messages (incremental, idempotent).
- A pause/hold; only credit stops it.
- Sources: Claude Code + Codex folders; claude.ai / ChatGPT export zips.

## What exists in Chief today
| piece | does | limit |
|---|---|---|
| `memory export --text` / `memory import DIR` | JSONL day files, `main/` (messages) `tree/` (summary nodes) | import only into an EMPTY memory, host stopped |
| `move --to cloud` (`migrate_cloud.rs`) | one-shot copy, `PUT /v1/chiefs/<id>/memory` batches | server refuses once state is `done`/`live` (`memory-import.ts`) |
| `import-claude-code` (`claude_import.rs`) | transcripts -> items, drops tool output/thinking | local only, empty memory unless `--append-after-live` |
| `agent_memory/` | index over `~/.claude/projects/*/memory`, `~/.codex/memories`, notes | read-only search index |

The Cloud Chief's memory lives in the **ChiefBrainDO** (`backend/apps/api/src/chief-brain/`), one object per
`agent/main-conversation`: `oc_message(i, kind, text, size, date)` append-only log, `oc_node(l, i, text)`
summary tree built by the compactor (`compactor.pump()`), plus `oc_import(state)`. The Oct 19 copy (a184)
filled it and set `state = done`; the Cloud Chief has appended its own messages since (`live`).

## Design

### Item
`{key, kind, text, date, source}`. `key = sha256(kind \0 date_ms \0 text)` (hex). The same formula runs on
the client (new items) and on the server (existing messages, lazily hashed). So the Oct 19 copy is
**deduped without any record of it**: a Mac message already in the cloud has the same key. Identical text at
a different second is a different message (so "ok" repeats are kept).

### Sources (`optchat-chief memory import-from <source>`)
| source | items |
|---|---|
| `chief` (default `--mux-home`) | the Mac Chief's own messages (`memory export` main/ lines). Summary nodes are NOT copied in merge mode: the target builds its own tree for the side (cheaper to trust than splice at foreign offsets). |
| `claude-memory` | each `~/.claude/projects/*/memory/*.md` file as one `note` (dated by file mtime) |
| `claude-code` | transcripts through `claude_import::convert_projects` |
| `codex` | `~/.codex/memories` entries |
| `zip:FILE` | claude.ai export (`conversations.json`: `chat_messages[].sender/text/created_at`) or ChatGPT export (`conversations.json`: `mapping` tree, `author.role`, `content.parts`, `create_time`); read with `unzip -p`; never thinking/tool parts |
| `dir:DIR` | an old JSONL home / export (`main/`) |

### Plan (dry-run)
`dry-run` prints, per source: items, bytes, new vs already-there (dedupe), dropped as secrets, date range,
and a cost estimate: tokens = chars/4, compaction priced per node (leaf pair -> level 1 ... : about 1.0x the
input as input tokens plus 0.15x as output, Haiku-class default `$1/M in, $5/M out`, override with
`--price-in/--price-out`). The write refuses above `--max-cost` (default $20).
Against a cloud target the dry run asks the server (`dry_run: true`), which answers new/duplicate counts.

### Merge into a NON-empty memory ("side lane")
- Local target: backup (`memory.sqlite3` copy to `memory.sqlite3.import-backup-<ts>`), then
  `chat.append_imported` per item (host stopped, as `browse::import`). Keys of what was imported are
  appended to `<root>/import-keys.txt`; existing messages are hashed from the export, so a re-run adds nothing.
- Cloud target: new server mode of `PUT /v1/chiefs/<id>/memory`: `{mode:"append", items, dry_run}`.
  Allowed in any state (empty/done/live), needs no brain-off, but refuses with `brain_busy` while a turn
  runs (client retries). Each accepted item is appended as a **`note`** (never `user`/`talk`: an old user
  line at the end of the log must not look like a live request) with a one-line header
  `[imported from <source> · <kind> · <date>]`, so it is clearly a side. Keys go to `oc_import_key`.
  `compactor.pump()` then builds the tree **in the background** (the normal alarm path); turns never wait.
  Position: appended at the log end (the log is append-only; node ids are positional), carrying its true date in the header.
- Pause/hold: `import-from ... write --max-items N` stops after N, the next run continues (keys). A
  credits stop is the compactor's own existing behaviour (`creditsCanStart`).

### Safety
- **Secrets never copied**: `agent_memory::notes::looks_secret` on every item text (GitHub, sk-, Slack,
  AWS, Google, glpat, PEM). A hit drops the item and counts it ("N dropped as secrets", never the text).
  The server re-checks the same shapes (second wall) and rejects the item.
- **Backup before writing**: local = db copy; cloud = a download of the cloud log (`GET ...memory?from=N`)
  into `~/.cmux/chief/import-backups/<ts>-cloud.jsonl` before the first write.
- **Undo**: local = restore the backup file (host stopped). Cloud: the log is append-only, so undo is a
  tail truncation of the batch, allowed only while no summary node covers it (NOT built in this commit;
  the backup file + `oc_import_key` batch ids are the base for it).
- Never prints the session token; token from `CMUX_CLOUD_SESSION_TOKEN` / 0600 file as `move` does.

### UI
`Chief menu > Import memories…` (Cmd+Shift+P palette entry "Import memories") runs the dry run and shows the
plan table with a Write button. Not built in the first commit (see report); the CLI prints the same plan as `--json`.

## Tests (failing first)
1. Incremental: running the same import twice adds 0 the second time.
2. Merge: importing into a memory that already has messages keeps every existing message and node.
3. Secrets: an item holding `ghp_…` is dropped and counted; a normal item passes.
4. Server: `append` into a `done`/`live` memory adds notes, dedupes by key and by an existing message's hash,
   refuses with a turn running; `dry_run` writes nothing.

# Search everything (Cmd+Shift+A)

Status: design, 2026-10-20. Owners: engine (Rust, cmux-tui daemon) = "Search-everything index
engine" agent; UI (mocks, Swift window) = "Search-everything UI" agent. The engine sections (1-9)
are written first; the UI agent owns section 10 and later.

User ask (Lawrence, 2026-10-20): Cmd+Shift+A and Cmd+P become the same thing; full-text search
through literally everything; a proper index, efficient from first principles; benchmark it and
make it 100x faster than ripgrep; good ordering (VS Code / Raycast file search); decide where
state lives (TUI vs Swift); search ACP chats, old scrollback, full-screen TUI scrollback, chat
sessions and all Chief data.

Change (2026-10-20, later): Cmd+P and Cmd+Shift+A split again. Cmd+P lists only what is open in
the workspaces now (workspaces, groups, panes, tabs); browser history, agent chat history and the
rest of history made it noisy. Cmd+Shift+A is the search-everything window, with no chip.

## 1. Decisions (defaults picked by Chief, the user can override)

- One search window. Cmd+Shift+A opens it with no scope chip; the sidebar's Search button opens
  the same. Cmd+P is not this window: it is the Workspaces scope, the open items only.
- The index lives in the cmux-tui daemon (Rust). The daemon already sees every PTY byte, every
  ACP/acpmux session and the workspace model, and it outlives app restarts and updates. Swift
  holds no index: it sends a query over the socket and renders hits. The app keeps only UI
  state (query text, selection, scope chip).
- App-only rows (palette actions, settings rows) stay ranked in the app by the existing palette
  ranker (palette-ranking.md). The window merges two lists: app rows (instant, in-process) and
  daemon hits (streamed). Merge rule in section 7.4.
- The existing SQLite FTS5 index (`cmux-history::SearchIndex`, `history-search-v1`) is replaced,
  not extended. It was never installed (`install_history_search` has no caller), so nothing
  migrates. Reasons in section 3.

## 2. Sources (what "everything" means)

| source | kind | owner of the data | unit indexed | jump target |
| --- | --- | --- | --- | --- |
| terminal scrollback (normal screen) | `scrollback` | daemon (ghostty-vt per terminal) | a line as it leaves the screen into history; the visible screen on demand | terminal + absolute line |
| full-screen TUI frames (alt screen) | `screen` | daemon | a snapshot of the alt screen on exit, on a 2 s idle after a redraw, and on terminal close; deduped by content hash | terminal + frame time |
| finished shell commands (OSC 133) | `command` | daemon | command line + cwd + exit code | terminal + line |
| ACP / agent chats (Claude, Codex, acpmux, every harness in cmux-chat-index) | `chat` | daemon (acpmux sessions) + read-only harness stores | one message (user, assistant, tool call title and output) | session + turn |
| Chief chats and memory (optchat) | `chief` | Chief brain store | one message; one memory entry | Chief id + message / memory key |
| workspaces, tabs, panes | `workspace`, `tab`, `pane` | daemon model | name, cwd, title | object id |
| files in open workspaces' folders | `file` | filesystem (walked by the daemon, .gitignore respected) | path (fuzzy) and, for text files under 1 MB, content | path + line |
| browser history and open tabs | `page` | cmux-history visit store | title + URL | URL / tab id |
| settings, commands (actions) | `setting`, `action` | app catalog | ranked in the app (section 1) | action / settings row |

Privacy: everything stays on this Mac in the user's data directory. Private-mode terminals and
incognito browser tabs are never indexed. A purged chat or closed-and-cleared terminal removes
its docs (tombstones, section 4.4). Secrets: lines that look like `KEY=...` with a high-entropy
value are indexed with the value masked (follow-up; noted as a gap).

## 3. Why not FTS5, why not "just run ripgrep"

- ripgrep reads every byte per query: at ~5-10 GB/s warm, 10 GB costs 1-2 s per keystroke, and
  far more cold. 100x faster means a p50 of 10-20 ms on 10 GB, so a query must touch a small
  fraction of the bytes. Only an index does that.
- FTS5 trigram stores one posting per (trigram, row, position): about 3x the text on disk, and
  a common trigram over 10 GB has hundreds of millions of positions. Writes go through B-trees
  and a WAL, and every scrollback line is a row. Newest-first with a LIMIT still merges whole
  posting lists. We measured nothing on it because it was never fed; the bench harness keeps an
  FTS5 column so the choice is proven, not assumed (section 8).
- What we build is the Code Search / zoekt shape, tuned for "newest first, stop at the limit":
  trigram -> block postings, then verify candidates with a fast substring scan.

## 4. Index structure

### 4.1 Docs and blocks

- A doc is one unit from section 2 (a line, a message, a frame, a name). Docs are appended to a
  per-source-class log in arrival order, so doc order is time order.
- Docs are packed into blocks of about 16 KiB of text (a block never splits a doc; a doc over
  16 KiB gets a block of its own, capped at 1 MiB, the rest is cut). A block id (u32) is the
  posting unit: 4 billion blocks x 16 KiB is far beyond any Mac.
- Text is folded once at write time for matching: Unicode lowercase plus diacritic removal
  (NFKD, drop combining marks), with a byte map back to the original for snippets. ANSI escape
  sequences never reach the index (the daemon indexes rendered cells, not raw PTY bytes).

### 4.2 Postings

- Trigram key: three folded bytes packed into a u32 (byte trigrams, so UTF-8 text works with no
  tokenizer; CJK gets 3-byte trigrams that still filter well).
- For each trigram, the sorted list of block ids that contain it, delta + varint encoded
  (sealed segments) or a growable `Vec<u32>` (the live segment).
- Query plan: take the query's distinct trigrams, order them by posting length (rarest first),
  intersect with galloping search, stop after the rarest 4-6 lists when the candidate set is
  already small. Then verify each candidate block, newest first, with a SIMD substring scan
  (`memchr::memmem`) on the folded text, and stop when the limit is full. A 2-character query
  uses a separate bigram table over names only (workspaces, tabs, files, Chiefs); a 1-character
  query searches names only by prefix.
- Multi-word queries: every word must match in the same doc (AND); each word adds its trigrams
  to the intersection.
- Fuzzy (VS Code / fzf style) applies to names and paths only (section 7.2); content search is
  exact substring after folding. Typo tolerance on content: no (it destroys precision on 10 GB).

### 4.3 Segments, append and compaction

- Live segment: in memory, takes appends, owns the newest blocks. Sealed when it reaches 64 MiB
  of text or 30 s idle, written as an immutable segment file and mmap'd:
  `<data>/search/v1/seg-<first-block>.idx` (postings, trigram table sorted by key for binary
  search) and `seg-<first-block>.txt` (folded block text + doc headers; compressed with zstd per
  block in a later step if size requires).
- Queries walk segments newest to oldest and stop when the limit is full, so a recent hit never
  waits on old data.
- Compaction (background, low QoS): merge small sealed segments into 1 GiB ones and drop
  tombstoned docs. Never runs while the user types (it yields when a query is in flight).
- Crash safety: a segment file is written to a temp name, fsync'd, renamed; the manifest
  (`manifest.json`: list of segments + per-source cursors) is replaced atomically after. On start
  the daemon reopens the manifest; anything newer than the manifest is re-read from the sources
  from their cursors.

### 4.4 Updates and deletes

- Renames (tabs, workspaces) and edits (Chief memory) are upserts: the doc key gets a new
  version; older versions are tombstoned in a per-segment deleted-doc bitset checked during
  verify.
- Removing a source (purged chat, cleared terminal) tombstones all its docs at once (per-source
  doc id ranges).

### 4.5 Retention and budgets

- Default cap: index text plus postings at most 4 GiB or 10% of free disk, oldest scrollback
  first; chats, Chief and names are never evicted. Configurable (`search.maxIndexBytes`).
- RAM: live segment (at most 64 MiB) + trigram tables of sealed segments are mmap'd, so the
  resident set follows what queries touch.
- Idle CPU: zero. No timers when nothing is appended. Indexing is driven by appends; a scrollback
  line costs one fold + trigram insert (target: under 1 microsecond per line on M-series).

## 5. Capture points in the daemon

- Scrollback: hook where ghostty-vt pushes a row from the active screen into history; index the
  rendered row text (soft-wrapped rows joined into one logical line). Lines are batched per
  terminal and appended every 250 ms or 64 KiB.
- Alt screen: on enter, remember; on redraw, debounce 2 s of quiet, snapshot the screen text, hash
  it, skip if the hash equals the terminal's last frame hash or the frame has under 3 changed
  lines from the last indexed frame; on exit and on close, snapshot again. This is how full-screen
  TUIs (vim, htop, Claude Code, Codex) become searchable "old scrollback".
- OSC 133: command line, cwd, exit code at command finish.
- ACP: every acpmux session event that carries text (user prompt, agent message chunks merged
  per message, tool call title and text output). Harness stores outside acpmux (Claude Code
  `~/.claude/projects`, Codex `~/.codex/sessions`, the others in cmux-chat-index) are backfilled
  by read-only feeds with cursors (byte offset per file), like `SearchFeed` today.
- Chief: optchat messages and memory entries, read through the Chief store's change feed.
- Model: workspace/tab/pane create, rename and close events.
- Files: on workspace open, walk its folders with `ignore` (gitignore aware, skip binaries and
  files over 1 MiB, skip `node_modules`, `target`, `DerivedData`), and watch with FSEvents for
  changes. Paths always; content only for text files.

## 6. Where state lives

| state | lives in | why |
| --- | --- | --- |
| index (segments, manifest, cursors) | daemon, `<data>/search/v1` | sees all data, survives app restarts and updates |
| capture hooks | daemon | PTY and ACP bytes arrive there |
| frecency of opened hits | daemon (`search/v1/frecency.json`) | one history for CLI, MCP, app, every dogfood build (palette-ranking.md finding 5) |
| app catalog rows (actions, settings) | app | the app owns the catalog |
| query text, selection, scope chip, window | app | UI only |

## 7. Query API and ranking

### 7.1 Wire

Socket command `search.query` (capability `search-v1`, trusted local connections only):

```json
{"query": "cargo test", "scopes": ["chat", "chief"], "limit": 50, "cursor": null,
 "since_ms": null, "workspace": null}
```

Reply: `{"hits": [...], "took_us": 812, "partial": false, "cursor": "..."}`. A hit:
`key, kind, source, target, position, title, subtitle, snippet, highlights (UTF-16 ranges),
at_ms, score`. `partial: true` means the time budget (default 30 ms) ran out before older
segments were scanned; the app shows hits and asks again with `cursor` for more. The app cancels
the previous query on each keystroke (`search.cancel` with the request id).

Scopes: `chat` (ACP + harness chats), `chief`, `scrollback` (incl. `screen` frames and
`command`), `file`, `workspace` (workspaces, tabs, panes), `page`. Cmd+Shift+A sends
`["chat", "chief"]`.

CLI: `cmux search QUERY [--scope chat,chief] [--limit N] [--json]`. MCP: tool `search_query`
with the same fields. `cmux search --stats --json` prints index size, doc and block counts,
segments, backlog and last append time per source.

`search.opened {key}` records that the user opened a hit (frecency).

### 7.2 Name matching (fuzzy)

Names and paths (workspaces, tabs, panes, Chiefs, files, page titles) use an fzf/VS Code style
scorer: query characters must appear in order; bonus for a match at a word start, a camelCase
hump, after `/` `_` `-` `.` or space, for consecutive runs, and for matching the file's basename;
penalty for gaps and for path depth. The basename of `Sources/App/ContentView.swift` wins for
"cv" and "contview". Candidates come from an in-memory name table (all names fit in RAM: 1
million paths ~ 60 MiB), prefiltered by a 64-bit "letters present" mask per name, so fuzzy over a
million names is a linear pass of mask checks plus scoring the survivors (target under 5 ms).

### 7.3 Ranking: one list across all sources

The engine returns one list, names and content together, best first (section 10.3). Every hit
gets a match tier on one shared scale, so a terminal error can beat a file name:

| tier | content hit (scrollback, chat, Chief, file text, ...) | name hit (workspace, tab, file path, page) |
| --- | --- | --- |
| 5 | a doc line is the whole query | the name (or a path's basename) is the query |
| 4 | the query as a phrase, every word a whole word | the name or basename starts with the query |
| 3 | every word starts a word (`migrat` in `migration failed`) | the query is contiguous at a word start (`migrat` in `db-migrations-DESIGN.md`) |
| 2 | the query as a phrase anywhere | the query is contiguous anywhere |
| 1 | every word somewhere in the doc | fuzzy: letters in order (fzf style, quality 0..99 breaks ties) |

Score = tier x 1000 + (kind weight - 1) x 500 + 400 x recency + frecency (at most 300) + name
quality (0..99). Kind weights: `chief` 1.2, `chat` 1.15, `command` 1.1, names 1.1, `scrollback`
and `file` 1.0, `page` 0.95, `screen` 0.9. Recency = `exp(-age / 7 days)` (a name's age is its last
use; a file's is its mtime). Frecency: +1 per open of the hit's target, half-life 3 days, keyed by
target (Raycast/Alfred), 100 points per unit up to 300.

Example ("migrat"): the 2-minute-old scrollback line `error: migration 0042 failed` and the file
`db-migrations-DESIGN.md` (edited yesterday) are both tier 3 with weight 1.0, so recency puts the
error first. A tier never crosses another (recency + frecency + weight stay under 1000).

Collection: the engine collects up to 4x `limit` content candidates newest first and every name
candidate that passes the letter mask, scores them all, and returns the top `limit`.

### 7.4 What the window shows

One ranked list (section 10.2): the first hit is the "Best match", the rest follow in score order,
not grouped by source. App rows (actions, settings) merge into it with the same tiers (10.3).
In a scope (Cmd+Shift+A, a source chip) the list holds only those kinds. Visuals: UI agent
(section 10).

## 8. Benchmark and the 100x goal

Harness: `cmux-tui/crates/cmux-search/benches/vs_ripgrep` (a binary, run on a Mac mini through
the fleet; never on the user's Mac).

- Corpora: (a) real: a copy of the user's scrollback logs, Claude/Codex transcripts and Chief
  data, built on the Mac mini from an export the user approves (default: synthetic only until
  then); (b) synthetic 10 GB: terminal-like lines (build logs, compiler errors, JSON, paths, UUIDs,
  English chat text) from a fixed seed, so every run is identical.
- Queries: 200 drawn from the corpus: rare tokens (UUID pieces), mid-frequency words, common
  words ("error", "the"), 2-word phrases, misses, and 3-character prefixes as typed.
- Ripgrep baseline: `rg -F -i --max-count 1 -c` style per query over the same files, warm page
  cache (the best case for rg), and `rg -F -i -m 50` for "first 50 hits".
- Reported: p50 and p99 query latency (engine and rg), speedup at p50, index build time, index
  size / corpus size, peak RSS while building, RSS while serving, CPU while idle (should be 0),
  CPU per MB appended.
- Perf guard test: a 50 MB synthetic corpus in the test suite; fails if p50 query exceeds 2 ms
  or index size exceeds 0.6x of the text, so a regression is caught on every hosted run.

Goal: p50 >= 100x faster than warm rg on the 10 GB corpus, p99 under 50 ms.

## 9. Engine plan and status

1. This doc (engine sections).
2. Crate `cmux-tui/crates/cmux-search`: fold, trigram postings, live + sealed segments, query,
   fuzzy name table, ranking. Failing-first tests (red commit), then implementation (green).
3. Bench harness + perf guard; first numbers on a Mac mini.
4. Daemon wiring: `search.query`, `search.opened`, `search.stats`, capability `search-v1`;
   capture hooks (scrollback, alt-screen frames, OSC 133, model names) first, then ACP, Chief,
   files, pages.
5. CLI `cmux search` and MCP tool `search_query`.
6. Remove `cmux-history::SearchIndex` and `history_search` once `search-v1` serves.

Coordination: a247 (sidebar search button opens the palette in Search mode: that mode becomes
this window), a182/a97 (Cmd+Shift+P palette speed: actions stay in-app), a268 (daemon tab write
slowness: search capture must never block the daemon's main loop; it runs on its own thread with
a bounded channel and drops to backfill when full), a257 (Memory Inspector: Chief memory is a
`chief` source here, read-only).

## 10. UI (owned by the Search-everything UI agent)

Mocks: `plans/cmux-next/search-everything-gallery/index.html` (5 live looks, light and dark,
type in any of them). Recommended: look A.

### 10.1 One window, built on the palette's `search` scope

- The window is the palette panel on the `search` scope (a247, plans/cmux-next/sidebar-search.md).
  No second panel, field or ranker. Cmd+Shift+A (`search.chats`, titled Search Everything; the id
  stays for user key files) opens the `search` scope, whose open action it is; its empty query lists
  the workspaces, and typed it adds history and agent chats (tests `CmdShiftASearchesEverythingTests`).
  The sidebar button opens it anchored. Cmd+P (`goToWorkspace` with no workspace) opens the
  `workspaces` scope: workspaces, then their groups, panes and tabs, and no history
  (tests `CmdPListsOpenItemsTests`). Cmd+Shift+P stays the command list; `palette.goToTab` /
  `tab.search` stay as aliases for scripts.
- The "Chats & agents" scope (daemon scopes `["chat", "chief"]`) stays in the scope list; no key
  opens it.

### 10.2 Layout (look A)

- Field row: scope chip (if any), query, a small "ms" readout in DEBUG builds only.
- Source chips row under the field: All, Terminal, Chats & agents, Chief, Files, Tabs, Web,
  Settings, Commands, each with its live hit count. Tab / Shift+Tab move between them, Cmd+1..9
  pick one. A chip is the same thing as a scope (it sets the daemon `scopes` and filters app rows).
- Left: one list ranked across all sources (the engine's "Top hit" row first, under "Best match",
  then "More"). Not grouped: grouping (look B) lets a weak section sit above the best hit, and
  section order jumps while typing. Inside a single source chip the list is flat.
- Row: source icon (colored tile), title with highlights, place (workspace, terminal, line
  number, harness), and one snippet line with the matched words marked (`highlights` UTF-16
  ranges from the hit). Right edge: age, or the shortcut for a command.
- Right: preview of the selected row (`listWithDetail`, palette-scopes 3.3), loaded lazily:
  - scrollback / command: about 6 lines around the hit with line numbers, the hit line marked;
    Return jumps the terminal to that line and flashes it.
  - screen (old full-screen TUI frame): the saved frame text, monospaced, words marked; Return
    opens the frame read-only, Cmd+Return goes to the live terminal.
  - chat / chief: the message as a bubble with the one before and after; Return opens the chat
    scrolled to that message.
  - file: lines around the hit; Return opens it at the line.
  - setting, command, tab, page: key/value rows and the row's actions.
- Footer: key hints (arrows, Return, Cmd+Return split, Tab source, Cmd+K actions) and the count.

### 10.3 Ordering in the merged list

App rows (actions, settings, workspaces, tabs; palette ranker, instant) and daemon hits
(streamed) are merged by a normalized score: each list's scores are mapped to 0..1 by match class
(exact title > word-start title > title anywhere > content word-start > content anywhere), then
recency and frecency (engine 7.3) break ties. Rule that stops the list jumping: rows already shown
above the selected row never move when a later daemon batch arrives; new hits insert below it.

### 10.4 Empty state

Recent searches (last 5 queries, from the daemon frecency file) and Recent places (palette
frecency over all kinds), plus one hint line with the prefixes: `>` commands, `@` chats and agents,
`#` files, `/` settings, `!` terminal output.

### 10.5 Speed and motion

- Every keystroke paints app rows from the in-memory snapshot in under 16 ms (palette ranker, off
  main); daemon hits arrive in later batches. The query is cancelled on each keystroke
  (`search.cancel`).
- Until the daemon serves `search-v1`, the app uses a stub source (no rows, no error) so the
  window ships on its own.
- Reduce Motion: no fades or slides; selection and preview change instantly.

### 10.6 UI plan

1. Mocks and this section (done).
2. Daemon search source in the palette (`PaletteQueryProvider`, a247 phase 2): async,
   generation-tagged, cancelled per keystroke, stubbed until `search.query` exists.
3. Cmd+Shift+A opens the `search` scope; Cmd+P opens `workspaces` (open items only).
4. Source chips row and the preview pane.
5. Strings in all 21 locales; failing-first tests for each step on the Mac minis.

# cmux-next OptChat: every agent is one endless chat whose memory is the chat

Status: proposal, 2026-10-03 (chief lane, branch feat-cmux-next-chief). Source: Taelin's OptChat
spec (his post, pasted by Lawrence 2026-10-03; not copied into this public repo).
Lawrence's goals (2026-10-03): each agent is an OptChat; memory is decoupled from the agent and
the UI, and the user picks where it lives: (1) on the same MacBook, (2) on a Mac mini the user owns,
(3) hosted by us (Durable Objects, PlanetScale, maybe Freestyle).

## 1. What changes from today

Both Chiefs use OptMem-style memory today (the P1 Rust core `cmux-chief/src/memory.rs`, the
TypeScript `mux/packages/brain`, and this experiment's `src/memory`): short notes, a wake cover
recomputed per read, blocks of 16 compressed from raw notes. OptChat replaces all three parts:

| | OptMem (today) | OptChat (target) |
| --- | --- | --- |
| log | notes the agent chooses to write | every message: user, talk, tool, echo, note; verbatim, fsync |
| tree | blocks of up to 16 from raw notes, then halves | purely binary; level 0 = one message; free nodes when the source fits 512 B |
| view | cover recomputed per read (cache misses every turn) | incremental fold: append, then merge the most-due built pair; never split |
| compactor | the agent naps on prompt | background worker, cheap model, view as context, SCALE line, size retries, strict order |
| turn | session with hooks | fresh call per message: system + view + new message, tools zoom and date |
| caching | none designed | byte-stable system and tools, view breakpoints at 50k/80k/100k chars |

The OptMem conformance work in this branch is reusable only as a pattern (oracle-driven vectors);
its algorithm is replaced.

## 2. Three layers plus memory

```
UI (Aziz: CmuxHomeCore/Render + hosts)  -- HomeSource -->  conversation owner (Rust daemon | ConversationDO)
                                                                   ^  agent ops
                                                                   |
                                         harness (Claude Code, Codex, pi, ...): one turn = fresh call
                                                                   |  memory ops
                                                                   v
                                         OptChat memory service (placement chosen by the user)
```

- The conversation owner keeps what people see (user and talk messages, work cards).
- The memory service keeps the agent's whole log (also tool and echo), the tree and the view,
  and runs the compactor. It is the single writer of one agent's memory.
- The harness asks the memory service for the settled view, logs each entry as it streams, and
  offers `zoom` and `date` (served by the memory service as MCP or as its own ops).

## 3. Memory service: one protocol, three placements

Ops (typed, idempotency keys on writes): `memory.append {kind, text, key}`, `memory.settle`
(wait until every view line is built), `memory.view` (rendered `<chat>` text plus the cache marks),
`memory.zoom {id, n}`, `memory.date {id}`, `memory.import {notes[]}`, `memory.export`
(the browse page), `memory.status` (compactor queue, sizes).

| Placement | Where the service runs | Storage | Compactor model calls |
| --- | --- | --- | --- |
| Same MacBook | the cmux Rust daemon on the laptop | `chat/main/*.jsonl`, `chat/tree/*.jsonl` (spec section 2) | from the laptop |
| User's Mac mini | the same Rust daemon on the mini, reached over the overlay (D3) | same files on the mini | from the mini |
| Hosted | a MemoryDO per agent | DO SQLite (log, tree), PlanetScale projection for search and the browse page | from the Worker |

A client (harness, CLI, UI browser page) talks to whichever placement the agent record names.
Moving between placements is `memory.export` then `memory.import` of the log; the tree is rebuilt
or copied.

## 4. One core

The fold, the pump order, node addressing, zoom, the size loop and the request layout are pure
logic. Write them once as a sans-I/O Rust crate (`optchat-core`: `step(state, input) -> effects`,
the shape P1 already uses) and run it:

- natively in the Rust daemon (placements 1 and 2), with the file store, fsync and the socket lock;
- as WebAssembly inside the MemoryDO (placement 3), with DO SQLite as the store through host calls.

Alternative: a Rust core plus a TypeScript twin for the DO, kept equal by a shared corpus (the
cmux-conversation and home-core pattern). Cost: two implementations of the subtle parts (fold,
pump rule 3, size retries).

## 5. Harnesses

A harness turn follows spec section 7: settle, render the view before logging the new message,
one fresh model call with tools (the vendor's own plus zoom and date, plus spawn and tell when it
has subagents), log every talk, tool and echo entry as it streams (tool results capped at 30,000
characters), never log thoughts. Each harness keeps the system prompt and tools byte-identical
across calls. The Chief is one such harness; a subagent's report comes back as a user entry
"[id] report".

## 5a. Cache-stable turn input (cmux rule, 2026-10-15; hq-1f, hq-6d, hq-ec agreed)

Goal: a warm turn reads >= 90 % of its prompt from the provider's prompt cache (Lawrence: parity
with the reference client). Both brains (the local optchat-chief and the Cloud ChiefBrainDO) follow
this rule, through `optchat-core` (`turn_input`), not through host code.

Cloud Chief (2026-10-19, hq-1f, UNII-PARITY section 7 rows 9 and 22): a turn first waits for the
summaries of every message before its new ones (the reference client's `Memory.settle`, at most 5 s and
only while the compactor is healthy), then renders the view again (`turn_input` with no frozen view): the
view shows every earlier message as built lines and the delta holds only the new messages, as the
reference client builds each call. The frozen view below is its fallback when the compactor is behind.
Cache marks there come from `chief-brain/cache-prefix.ts`: the view's last whole block (written for the
next turn) and the longest piece prefix an earlier request wrote (read; Bedrock has no look-back), kept
in the brain object across evictions. The Rust Chief keeps the frozen rule below.

A turn's input is: the system prompt and tools (byte-identical across calls), then the FROZEN VIEW,
then the DELTA, in that order. Nothing before the delta's end changes between two turns unless a
re-render happens.

1. Frozen view. The rendered `<chat>` view (5.1) is frozen at a render: the host keeps the parts it
   showed (`RenderedView.parts`) and the log index it covers (the front: the newest log entry any
   shown part covers). Later turns send the same bytes again (`render_parts`), with the same cache
   marks (section 8 cuts). A fold of the compactor after the render does not change the frozen
   view by itself.
2. Delta ("memory changes since view"). Every log entry after the front, oldest first, one line
   each in the view's line form (`<id>|<text>`, newlines as spaces; a tool result capped as in
   spec 7). Tool writes, edits and deletes of memory are log entries too, so no change after the
   render is invisible. The delta is cut into blocks at each change between the kind `user` and the
   other kinds, so the new messages of a turn are one block and that turn's work (talk, tool, echo)
   the next block. A block, once sent, is sent again byte for byte; a turn adds blocks only at the
   end. The cache marks: one at the request's end, and one where the previous turn's request ended
   (its newest user block: the second to last user block of the delta), or at the frozen view's end
   when there is none. Bedrock reads a cache entry only at a mark (no look-back; measured on staging
   2026-10-16: reads stopped at the view's end until this mark), so the previous end needs its own mark.
   An entry that edits, retracts or deletes something a line of the frozen view already shows names
   that line's id: `<id>|edit of <target-id>: <new text>`, `<id>|retracted <target-id>`,
   `<id>|deleted <target-id>`. The system prompt says: "A line after </chat> that names an earlier
   line id (edit of, retracted, deleted) replaces what that line says." The next re-render folds the
   change into the view. Conformance case `delta-edit` (brain corpus, both brains): edit a line that
   the frozen view shows, run a turn, and the model's input carries the edit entry naming the line;
   with the scripted model, the reply quotes the edited text, not the old one.
3. Anchoring (spec 7). The new messages are logged before the turn's input is built and appear only
   in the delta (never also in the view); the turn answers the newest woken message as before. A
   message delivered mid-run is logged and goes to the model as a user message, as before.
4. Re-render (one cache write of the view). The delta bytes counted here are the entries before
   this turn's new messages (a turn's own long message never forces a re-render), and imported
   messages are never delta lines (their build state changes later; the view shows them after a
   re-render). A turn re-renders, freezing a new view and an empty
   delta, when (a) the delta is over DELTA_MAX = 8,000 bytes (about 2,000 tokens) and the
   compactor has built nodes past the front (the re-rendered view is then shorter than view +
   delta), or (b) the delta is over DELTA_HARD = 32,000 bytes (the growth cap between folds:
   re-render even if the compactor is behind; unbuilt lines show as in 5.1), or (c) there is no
   frozen view yet. A re-render waits for settle like any turn (spec 7).
5. Measure: each run records its usage (input, output, cache_read, cache_write); cache hit =
   cache_read / (input + cache_read + cache_write).

## 6. Steps

1. `optchat-core` crate with the spec's fold, pump and zoom; a conformance corpus written from the
   spec's rules and replayed real logs (no oracle exists: Taelin's code is unpublished).
2. Native host in the daemon behind a capability, with the file store (placements 1 and 2).
3. MemoryDO host (placement 3).
4. Compactor with the COMPACT prompt, SCALE, retries, JOBS = 8.
5. Harness adapter for the Chief on top, then for other harnesses.
6. Import: OptMem `LOG.txt` notes and old agent sessions as kind `note`.

## 7. Decisions (Lawrence, 2026-10-03)

- O1: one Rust core (`optchat-core`), native in the daemon and WebAssembly in the MemoryDO. No
  TypeScript twin.
- O2: one OptChat per agent (each Chief and each agent has its own log and tree).
- O3: the default placement for a new user is hosted by us (MemoryDO, PlanetScale); the user can
  move to the same MacBook or a Mac mini later (`export` then `import`).
- O4 (coordinator): the production Chief (P1) moves to OptChat memory once `optchat-core` passes its
  corpus and a native daemon test; until then its OptMem memory is frozen (bug fixes only).
- Compactor prompt: selectable per memory. `taelin` (default): the OptChat spec's prompt, verbatim
  apart from the agent's name, credited to Victor Taelin. `cmux`: our own version that tries to
  improve on it. `custom`: a prompt the user supplies.

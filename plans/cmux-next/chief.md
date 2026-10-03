# cmux-next Chief: a manager whose memory is its whole context (isolated experiment)

Status: isolated experiment, revision 2, 2026-10-02 (chief lane, session cmuxterm-hq-e0). Lives on
branch `feat-cmux-next-chief` in `experiments/chief-optmem/` and is never merged into
`feat-cmux-next` without a new decision. Decisions (Lawrence via the coordinator, 2026-10-02): no
spec changes; production Home objects (MuxDO, ConversationDO, OwnerDO), home-core and other
feat-cmux-next code are not touched; the loop uses Cloudflare `agents` pi-on-DO (`PiHarness`), beta
and its own transcript schema accepted inside the experiment; one memory per chief; cloud first,
staging only, own Worker name and DO namespaces, own wrangler config; Home data is read only
through public routes if at all; a minimal UI inside the experiment.

References: https://github.com/VictorTaelin/OptMem at 1fb164cf (Python `memo`, read in full; the
repository has no license, so the experiment reimplements the behavior and uses the script only as
a test oracle, never copies it), Taelin's post of 2026-09-29 ("a harness that replaces the chat by
optmem ... it IS the chat history ... no tools other than spawn"), `agents` 0.26.0 and
`@earendil-works/pi-durable` 1.0.0.

## 1. The product

Chief is one manager agent per person that you talk to forever. It has no chat transcript and no
compaction. Each turn its whole context is rebuilt from its memory: a fixed budget of lines where
recent events are verbatim and older ones are progressively coarser summaries (OptMem's cover).
Everything that happens (your messages, its replies, results from workers) is appended to memory.
The chief does no work itself: its only tool is `spawn`, which starts or steers a worker agent that
has the real tools. Worker results come back as events, which become memory, which wake the chief.

Properties to prove: the chief never forgets (append-only log, `recall` finds any line); a turn
costs the same on day 1 and day 1000 (context bounded by `WAKE_LINES`); the model can change between
two turns (nothing lives in a provider session).

## 2. Words

- Memory: an append-only log of entries plus a binary tree of one-line summaries (OptMem).
- Entry `#n`: one line of at most 280 bytes with a date.
- Block `#lo-hi`: an aligned power-of-two range; its summary is one line.
- Cover: the blocks a turn sees, `cover(T, WAKE_LINES)`.
- Nap: writing the next pending summary. Blocks are built in order, smallest first.
- Worker: an agent the chief spawned. A worker never writes memory (OptMem's subagent rule).

## 3. Layout (experiments/chief-optmem/)

```
src/memory/      pure OptMem: cover, pending, nap prompts, wake/zoom/recall views, memo-format text
src/memory-do.ts MemoryDO: one per chief, DO SQLite tables entry(n, date, text) and node(size, k, text)
src/chief-do.ts  ChiefDO: Agent + PiHarness; the turn loop and the spawn tool
src/worker.ts    routes: chief create, send, stream, memory views; bearer token (staging secret)
web/             minimal UI: the conversation and a memory view
conformance/     generator that runs the Python memo on seeded op sequences -> vectors JSON
test/            vitest: pure memory vs vectors; DO tests with the workers pool
wrangler.jsonc   Worker `cmux-chief-optmem-staging` (and a local env), its own DO classes
```

## 4. Memory

The behavior is OptMem's, checked byte for byte against the Python script by the conformance
vectors (wake, note, nap, zoom, recall, forget, config and their messages, with the tool name fixed
to `memo`). Storage differences:

- Fixed-width records exist in OptMem for O(1) seeks; `entry.n` and `node(size, k)` give the same
  lookups in SQLite.
- `forget` truncates the dense prefix count of each level (`built[size]`) instead of deleting rows;
  rows past the prefix are dead and are overwritten when the block is rebuilt. Forgetting a low
  block of a large memory is O(levels), not O(blocks).
- Every write carries an idempotency key, so a retried turn appends once (OptMem has no such guard;
  the DO is the lock).
- Dates come from the chief's time zone (config `TZ`), not the server clock's.
- Search (`recall`) is ripgrep style (Lawrence, 2026-10-02): a plain scan of the log, no index,
  no ranking, smart case and rg's `-i -s -F -w -A -B -C` with rg's meanings (checked against the
  real `rg` binary). Without flags the output is memo's; the newest output that fits one part is
  kept, with memo's "Newest k of N matches" footer.

MemoryDO RPC: `note(entries, key)`, `nap(block, text)`, `forget(block)`, `config(knobs)`,
`import(entries)`, `wake(part?, T?)`, `recall(rg args)`, `zoom(block)`, `state()`.

## 5. The turn

ChiefDO is an `Agent` with a `PiHarness`. One turn at a time (pi's busy session + `whenBusy:
"followUp"` queues later events).

1. Event in: a human message (`POST /chiefs/:id/messages`) or a worker event.
2. Ingest: append one entry per event (`<name>: <text>`; a longer message stores its first 280
   bytes plus `[msg <id>]`, and the full text is kept in ChiefDO's message table for this turn and
   for the UI).
3. Nap: while the cover needs a summary, compress it with one plain pi-ai completion on the
   chief's model (the chief compresses its own memory, as in OptMem); spare naps after the turn,
   at most 4 per turn.
4. Context: the turn resets pi's root session (`session.reset()`), then submits one prompt: the
   cover + the new events in full. The system section (identity, the spawn tool, how to read `#n`
   and `#a-b`) is a pi extension section. pi keeps its own transcript; after the reset the model
   sees only this prompt and its own tool round.
5. Reply: the assistant text is shown in the conversation and appended to memory as `chief: ...`
   (the first 280 bytes; the chief is told to put what matters first).
6. `spawn {name, prompt}` starts a worker, or steers it when the name is reused. Phase 1 worker:
   a pi session in a WorkerDO with a read-only `fetch_url` tool, so the loop runs end to end on
   Cloudflare. Phase 2: a coding agent on a Freestyle VM (the cmux Cloud provider). The worker's
   final answer comes back as a `worker <name>: ...` event and wakes the chief.

Memory is shown to the model only through the cover; `recall` and `zoom` are not chief tools in
phase 1 (Taelin: spawn only). If turns show the chief needs older detail, phase 2 adds
`recall`/`zoom` as read tools and we measure the difference.

## 6. UI

Lawrence (2026-10-02): a native client built from MessagesLab appkit-native, in the Home section of
the app, at the top left. Placement agreed with the coordinator: no new tab or pane kind and no
edits to the Home files other lanes own. The item "Chief (experiment)" is injected on the client at
index 0 of the sidebar's Home section (`sec_top`), only when `~/.config/cmux/chief-experiment.json`
exists, and only in builds of this branch. A click opens an internal page tab (one per window)
whose view is `CmuxNextChief.ChiefView`: the shared `HomeStore` fed by `ChiefHomeSource` (a
`HomeSource` over the Worker's long poll), rendered by lane 16's `HomeNativeTranscriptView` through
`HomeStoreBinding`. The view reuses the appkit-native port; it copies nothing.

Mapping: one conversation `conv_chief_<id>`; participants me, Chief, and one agent per worker
name; the conversation revision is the newest message seq (the Worker keeps seqs dense); read
cursors stay on the Mac; search and contacts are not supported.

## 7. Steps

1. Done (adfb0e9858f, 8ee88c0ed34): pure memory, conformance vectors from the Python memo,
   ripgrep-style recall checked against the real `rg`.
2. Done (bb4815e5222): MemoryDO on DO SQLite, the experiment Worker, verified in wrangler dev.
3. Done in part: the turn engine `src/chief/turn.ts` (ingest, ordered naps, cover-only context,
   reply and spawn entries, keyed retries) behind model and memory ports, tested with a fake model.
   Done (bfc57ee74b0): ChiefDO with PiHarness, WorkerDO, staging Worker
   https://cmux-chief-optmem-staging.debussy.workers.dev (token in ~/.secrets/cmux-chief-optmem.env).
   Model: Workers AI `@cf/moonshotai/kimi-k2.7-code` until a Claude route is chosen (AI Gateway
   billing or BYOK, a direct key, or coderouter: Lawrence's decision).
4. Done: WorkerDO (pi session, `fetch_url`) and spawn.
5. Native UI in Home (416320062f3, 3e032168fbe): `CmuxNextChief` target, sidebar item, `chief.show`
   action (palette, CLI `cmux chief show`). Tagged build `chief2` verified: `chief.show` runs, the
   view long-polls staging and follows new messages (after=0 -> 1 -> 2). UNVERIFIED: the drawn
   view and sending from the composer (Computer Use onboarding is not finished on this Mac).
6. Freestyle worker.

## 8. Open

- How long a chief reply may be before it is stored as first line + ref (start: 280 bytes).
- Whether the nap runs on the chief's model or a cheaper one (start: the chief's model).
</content>
</invoke>
<invoke name="Bash">
<parameter name="command">cd /tmp/optmem-src && sed -n 1,80p test.py
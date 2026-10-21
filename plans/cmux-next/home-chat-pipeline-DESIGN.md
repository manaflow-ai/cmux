# Home chat pipeline: one ordered timeline from the owner to the bubbles

Status: landed (Oct 20, 2026): model, B1-B5 fixes, tests. Owner of the model: the "Home chat rebuild" agent.
Agents on Home chat (a197 streaming lag, a102 bubbles, a287 group chats/replies/reactions,
a231 long-press, a227 first message) build on this model and do not add new ordering or
stream paths of their own.

User (Oct 20): "we have lots of race conditions and UI issues with imessage stuff, you need to
fix all from first principles. like while streaming, i send message, and ordering gets messed up."

## 1. What the pipeline is today

```
owner (cmux-tui conversation store / Cloud)          seq per conversation, idempotency keys
  └─ HomeSource events ──► HomeStore (@MainActor, serial)
        mirror: TranscriptWindow per conversation     committed messages by seq (gap ⇒ refetch)
        log:    IntentLog                            my ops by idempotency key until the echo
        liveBook: HomeLiveBook                        chief-live-v1 deltas (seq per step, resync)
        draftBook: HomeDraftBook                      legacy conversation-draft-v1 deltas
           │
           ├─ transcript(for:)  → [TranscriptItem]   committed by seq, then my pending sends
           └─ liveRun(in:) / drafts[id] → ONE running reply per conversation  ◄── problem
                 │
  HomeProjection (one per open view) ── ProjectionCore + HomeDiff ──► vendored MessagesLab
        reducer actions: .receive / .send / .status / .prependPage / .streamBegin/Set/End
        `.receive` and `.streamEnd(replacedBy:)` APPEND             ◄── problem
```

Most of the "from scratch" design is already here and correct: the owner assigns a monotonic
`seq`; every send carries a client id (its idempotency key) from the moment it is made; the
pending row and its echo share that id, so the row morphs instead of being replaced; the
transcript never sorts by wall clock; live deltas are numbered and a gap asks for a snapshot.
Rewriting those parts would rebuild the same thing. The races come from two places where the
design was not followed:

1. **The running reply is not part of the transcript value.** It travels on a side channel
   (`liveRun(in:)` or `drafts[id]`) that holds at most one reply per conversation. The view
   merges it with the transcript itself, so ordering between "the stream", "my send" and "a
   new message" is decided ad hoc, in three places.
2. **The view diff never checks order.** `HomeDiff.plan` finds the new keys and emits
   `.receive` for each; the reducer appends. When the store's order puts a new message
   *before* a row the view already shows (my pending send, or the running stream's bubble),
   the view and the store disagree, and nothing ever corrects it until an unrelated rebuild
   jumps the transcript.

## 2. The model

### 2.1 One value per conversation: `HomeTimeline`

`HomeStore.timeline(for:)` returns one immutable value, the only thing a view draws:

```
HomeTimeline
  items:   [TranscriptItem]      committed by seq, then my pending sends in the order I made them
  streams: [HomeStreamRow]       every running reply, in the order each turn began
  rows:    items ++ streams      display order (ids: the item key / the turn key)
```

Ordering rules (total, deterministic, no clocks):

1. A committed message sorts by its owner `seq`. Nothing else orders committed messages.
2. My pending sends come after every committed message, in the order I made them (the send
   queue already commits them to the owner in that order).
3. Running replies come last, in the order their turns began. A reply's id is its turn key
   (the `client_msg_id` its posted message will carry), fixed at turn start, so its bubble is
   one row from the first delta to the post. Several replies can run at once (two Chiefs in a
   group, a new turn that starts before the last turn's reply has landed): each is its own row.
4. When a reply is posted, its stream row leaves and the message takes its `seq` place in
   the same value (the turn key is the message key, so the view hands the bubble over in place).
5. A user message sent mid-stream is a pending send (rule 2): it shows above the running
   bubble at once, and the turn it starts is a new stream row below. If the owner posts the
   running reply *before* it commits my send (the reply got its seq first), rule 1 puts the
   reply above my message: that is the owner's order, and the view follows it (2.3).

### 2.2 Deltas are idempotent

- `chief-live-v1` (`HomeLiveBook`): a step's frames are numbered; a frame at or below the
  last applied one is a repeat and is ignored; a jump asks the owner for `run.live`, whose
  answer never takes a step back. Unchanged.
- `conversation-draft-v1` (`HomeDraftBook`, older owners): the same rule. A repeated or older
  item is ignored (today it marks a gap and freezes the bubble until the next `fresh` item).
- A run that ended `done` keeps its text until its own reply lands. A new run of the same
  Chief no longer ends it (today the bubble vanishes and the reply pops back as a new message);
  the Chief's next posted message, or `failed`/`cancelled`, still ends it.

### 2.3 The view applies the value; it never decides order

`HomeProjection` reads `timeline(for:)` once per store pass and diffs it against what it shows,
by stable ids:

- Unchanged value: no work (an `==` on the cached value; see 2.4).
- Only stream text changed: one `.streamSet` for that stream; no transcript diff.
- New ids that sort after every row the view already shows: `.receive` (animated).
- A new id that sorts before a row the view already shows, or rows whose relative order
  changed: one `.replaceWindow` with the store's order (no animation, scroll kept). Correctness
  first; an animated move is a follow-up (`.cmuxMove` in the vendored reducer).
- Streams: `.streamBegin` per new turn, `.streamEnd(replacedBy:)` when its message landed
  (in place when it lands last, else through the rebuild), `.streamEnd(nil)` when it ended
  without one.

The invariant checked by every test in section 4: **after each pass, the view's rows (messages
then streams) have exactly the timeline's ids in the timeline's order, and every reply's text
shows in exactly one bubble.**

### 2.4 Cost per chunk

A streamed chunk changes one stream row. `timeline(for:)` caches the items per
`transcriptVersion`, so a chunk does not map the window again; the projection compares stream
rows only. Coalescing to one pass per display frame stays where it is (`observedPass` holds a
pass that falls in a keystroke's frame; Observation folds a burst of changes into one pass).
a197 owns the layout side (the resize fast path rebuilds all rows per chunk).

### 2.5 Width

Layout reads the current width; a width change invalidates sizes. That is the renderer's
(`Engine`/`Layout`), owned by a197/a102 (resize fast path keeps an old-width frame mid-stream).
The model has no width state.

### 2.6 Why not an actor

The task asked for a serial reducer actor. `HomeStore` is already `@MainActor` and is the
single writer; the reducers (`TranscriptWindow`, `IntentLog`, `HomeLiveBook`, `HomeDraftBook`)
are pure value types it mutates. An extra actor would add a hop between the event and the
frame that draws it, and the view needs the value synchronously on the main thread anyway.

## 3. Bug list

| # | Bug | Root cause | Test (red first) | Status |
|---|-----|-----------|------------------|--------|
| B1 | I send while a reply streams; the owner posts the reply before it commits my send: the view shows my message above the reply, the store below; a later rebuild jumps it | `HomeDiff.plan` appends; never checks order | `HomeTimelineOrderTests.replyPostedBeforeMySendCommits` | fixed here |
| B2 | Someone's message (another Chief, the CLI, a reply with no stream) commits while my send is pending: it lands below my bubble in the view, above it in the store | same | `HomeTimelineOrderTests.theirMessageWhileMySendIsPending` | fixed here |
| B3 | Two replies running in one conversation (two Chiefs in a group; a new turn while the last reply is awaited): one bubble, flipping between them per frame; the other reply hidden | `HomeLiveBook.shown` keeps one run per conversation (newest touched) | `HomeTimelineOrderTests.twoRepliesStreamAtOnce` | fixed here |
| B4 | A run ends `done`, the next run starts before its reply lands: the reply's bubble vanishes, then the message pops in | a new run ended the awaiting run | `HomeTimelineOrderTests.aNewTurnKeepsTheLastReplyUntilItLands` | fixed here |
| B5 | Legacy `conversation-draft`: a repeated item (reconnect replay) freezes the bubble until the next `fresh` item | a repeat counted as a gap | `HomeDraftBookTests.aRepeatedItemDoesNotFreezeTheReply` | fixed here |
| B6 | A reply splits around a message sent mid-stream | fixed by a102 (eb0eac7e114, 9112a6087dd, 04ccf5cebb5) | `HomeMidStreamSendTests` (f63045147bb) + property test | fixed (a102) |
| B7 | Lag while streaming | other conversations' traffic (d50e62c7169, fixed); every chunk re-maps the window (2.4, fixed here); resize fast path rebuilds rows (a197) | stress harness (4.3) | partly fixed; a197 |
| B8 | Bubbles clip after a resize mid-stream | resize fast path keeps an old-width frame | a197 | a197 |
| B9 | History and the first message missing | a100 (b125749b6c2), a227 | a227 | a227 |
| B10 | Long-press bubble shows upside down | renderer transform | a231 | a231 |

## 4. Tests

### 4.1 Order tests (real view over a real `HomeStore` on the mock owner, offscreen window)

One test per bug B1-B5, each failing before the fix. Mock seams: `MockHomeSource.holdSubmits()`
/ `releaseSubmits()` (a send stays pending while the test posts other traffic) and
`post(_:from:in:key:)` (a Chief's reply with its turn key).

### 4.2 Property test: random interleavings

`HomeTimelinePropertyTests`: seeded random runs of 60-200 steps over send, ack (release
held submits), live deltas (with repeats and jumps), run done / failed, reply post, someone
else's message, reconnect snapshot, older page load and resize. After every step the invariant
in 2.3 holds; at the end, the view equals the store's final timeline. 200 seeds per run; a
failing seed prints its step list.

### 4.3 Stress harness

`HomeStreamStressTests`: 100 agents streaming fast (one delta per agent per 4 ms) into their
conversations while the Chief's reply streams in the open view; records the main-thread time of
each pass and of each layout, p50/p95/p99/max, written to `HOME_STRESS_OUT` and the test log.
Runs on the Mac minis (`cmux-ci run --class light`), never on this Mac.

## 5. Follow-ups (not in this change)

- Owner-reserved reply seq (`message.begin` at turn start, the post fills it): a reply would
  hold its place from its first delta and B1's single reorder would go too. Needs a cmux-tui
  protocol change and a Cloud owner change.
- Animated reorder (`.cmuxMove`) instead of the rebuild for B1/B2.

## 6. Results (Oct 20, Mac minis)

- Red (test commit, aws-m4pro-5): B1-B5 tests fail; 24/24 property seeds fail.
- Green (fix commit): all CmuxHomeCore and CmuxMessagesLab order, property (24 seeds x 90 steps),
  mid-stream, send-order and stress suites pass.
- Stress, same worker (aws-m4pro-5), before -> after, 100 agents streaming + the Chief's reply:
  Chief chunk frame p50 5.41 -> 5.26 ms, p95 8.70 -> 9.53, p99 9.82 -> 10.02, max 13.9 -> 13.1;
  other-conversation pass p99 0.097 -> 0.046 ms; send frame p50 4.98 -> 4.92 ms.
  Drag over field while streaming: frame p95 2.40 -> 2.45 ms. No change in speed; the order fix is free.

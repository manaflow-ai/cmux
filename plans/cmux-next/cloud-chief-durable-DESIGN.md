# Cloud Chief D: a rebuild on pi-durable

Status: phase 1 being built (Oct 27, 2026), behind a flag. Production keeps the current Cloud
Chief ("P") until D passes the staging evals.

The ask (Lawrence, Oct 27): "rebuild cloud chief from scratch, current version is not very good at
all. let's build on top of pi-durable."

## 0. Which pi-durable

- **Used:** `@earendil-works/pi-durable` 1.0.0, hosted in a Durable Object by the Cloudflare `agents`
  `PiHarness` (0.28.1). This is the same stack as the team's own reference build,
  `manaflow-ai/optchat-lab` `impl/pi-durable` (OptChat on Pi on Durable Objects, 38 workerd tests,
  local only). The backend already depends on these exact versions.
- **Not used:** `disler/durable-pi` and `disler/pi-durable-news-agent`. They are a third party's
  demos. They are not the Earendil framework, and nothing at manaflow-ai depends on them.

## 1. Why P is not good enough (from its code at 47b4dbb1c15)

P (`backend/apps/api/src/chief-brain/`, about 6,000 lines plus `chief-brain-cc/`) runs on pi-durable,
but it uses almost none of what pi-durable guarantees. It keeps a second durability layer of its own.

1. **A second turn state machine.** `cb_inbox` (queued, running, done, failed, skipped), `cb_turn`
   (submitted, post pending, posted, refused, post_tries, post_key), steer ops in `cb_config`, and
   in-memory flags (`turnLive`, `turnId`, `steered[]`, `posting`). These copy what pi already keeps:
   its inbox, its steers and follow-ups, and its run state. The two layers can disagree after an
   eviction, which is where the "stuck typing", "reply never came" and "answered twice" bugs live.
2. **A reset on every turn.** `runTurn` calls `session.reset()` and submits the whole view again.
   Then it prunes pi's entries (`pi-prune.ts`), because pi's transcript is never read again. So pi is
   only a request runner, and the turn loop is written by hand around it.
3. **A wait before every turn.** `drain` waits up to `SETTLE_MS` (5 s) for the compactor before the
   model is called. This is the largest fixed delay before the first token of a group-chat reply.
4. **One class with seven roles.** `ChiefBrainDO` is a settings object (`<agent>`), a conversation
   brain (`<agent>/<conv>`), a child subagent, the Claude sign-in holder, an owner's turn counter, a
   sandbox registry and a GitHub host, chosen by the object's name. Every role pays for every
   constructor (wasm load, nine schemas, the pi harness), and a change to one role risks all others.
5. **A VM per turn on the personal route.** On `CHIEF_CC_OWNERS` (Lawrence's team in production),
   each turn boots a Freestyle VM and runs `claude -p` in it (`chief-brain-cc/turn.ts`). That costs a
   machine boot per message and a second set of retry rules ("never silent", three tries).

## 2. What D keeps and what it throws out

| Keep (D uses it as is) | Why |
| --- | --- |
| Brain contract (`contract.ts`): Run, Step, `step.delta`, `run.activity`, `run.live`, `conversation-run-changed` | Home and iOS render it; D must be invisible to them |
| Runs readers and tables (`brain-runs.ts`: `cb_turn`, `cb_step`, `cb_usage`, `cb_timing`, `cb_marks`) | `GET /v1/chiefs/<agent>/runs` and the run page read them |
| Conversation I/O (`brain-io.ts`): chief principal, `conversation.snapshot`, `message.send`, `mux.ack`, typing | The only way out; the reducer's loop guard and thread rules apply |
| MuxDO wake delivery (`mux-wake-delivery.ts`) and `brain_impl` routing | At-least-once wakes, ordered per conversation; D is one more `brain_impl` |
| Settings object, admission, daily turn cap (P's `<agent>` object, `admit`) | One source of profile settings for every brain (as O already does) |
| Model route (`models.ts` `brainModels`, `claude-auth.ts` holder, `model-gateway/`) | Auth, Bedrock route, credits metering, usage, live token frames |
| OptChat memory (`memory.ts` over optchat-wasm, `compactor.ts`), its tables `oc_message`, `oc_node`, `oc_checkpoint` | The memory format; migration copies rows, nothing is rebuilt |
| System prompt and text rules (`prompts.ts`, `brain-text.ts`: formatMessage, NO_REPLY, linkIds, replyTarget, group owner rules) | The behavior the evals guard |
| Credits gate and the out-of-credits notice | Billing |

| Throw out (D does not have it) | Replaced by |
| --- | --- |
| `cb_inbox` state machine, `steer:` config rows, `turnLive`, `steered[]` | pi's inbox: `submit(..., requestId)` with `whenBusy: "steer"` |
| `runTurn` timers, `hands_cont` continuation, wait loops over steered ops | pi's run: one generation task chain per input |
| `session.reset()` + full resubmit + `pi-prune.ts` | a `beforeRequest` hook that renders the memory view into the request (section 3) |
| `SETTLE_MS` wait before the turn | no wait: the view shows unsummarized messages whole (`Memory.turnInput(n, false)`) |
| Post retry columns (`post`, `post_tries`, `post_key`) and the post alarm | the post runs inside pi's `onYield` hook, idempotent by run id (section 4) |
| Roles by object name | D is one role: one conversation brain. Settings, holder and turn counter stay in P's objects and are called by RPC |
| Per-turn VM (`chief-brain-cc/turn.ts`) on the hot path | not in D. Hands (phase 2) run on a kept machine, not one per message |

## 3. Architecture

```
ConversationDO --wake--> MuxDO --(brain_impl = "durable")--> ChiefDurableDO <agent>/<conversation>
                                                               |- PiHarness (agents): pi-durable over this DO's SQLite,
                                                               |    Lifecycle job = the wake that resumes pi after eviction
                                                               |- Memory + Compactor (optchat-wasm), same tables as P
                                                               |- extension "chief-d": system section, zoom/date tools,
                                                               |    beforeRequest (view), afterResponse/afterTool (log),
                                                               |    onYield (post + ack)
                                                               '- RPC to P's settings object (admit), holder (Claude auth),
                                                                  turns object (paid-turn count)
```

- **One DO class, one role**: `ChiefDurableDO`, named `<agent>/<conversation>` (one memory per
  conversation, as P: a reply never draws on another conversation's messages).
- **One pi conversation, never reset.** pi's transcript is the run log. Old entries stay in storage
  (pi never sends them; see the hook below).
- **Intake** (`wake` RPC, serialized per object): read the conversation as the chief, format every
  new message (`formatMessage`), append each to the memory log once (key `user:<message id>`), and
  submit ONE pi input for the batch with `requestId = batch:<first message id>` and
  `whenBusy: "steer"`. A repeated wake finds the same request id and submits nothing. A batch that
  arrives while a run works joins it after the current tool round (pi's steer).
- **What the model sees** (`beforeRequest`): `[system] [memory view, rendered once per run]
  [this run's messages and tool rounds]`. The hook drops every message before the run's first input
  and puts the view in front of it. The view text is stored with the run (`cd_run.view`), so every
  request of the run, and a request resumed after an eviction, sends the same bytes (one cached
  prefix per run).
- **Logging**: `afterResponse` logs `talk`, `afterTool` logs `tool` and `echo` into the memory and the
  run's Step rows, keyed so a rerun logs once (as P).

## 4. Durability and resume

pi commits every input, model response and tool call before it shows it. PiHarness keeps one
Lifecycle job per session, so an evicted object is woken by its alarm and pi resumes its own tasks.
D adds one small table, `cd_run(id, view, trigger, last_seq, state)`, and no in-memory turn state:

| Crash point | What happens on restart |
| --- | --- |
| Before `submit` commits | MuxDO resends the wake (its delivery row is still there); same request id; submitted once |
| After `submit`, during a model call | pi resumes the generation task; the request is sent again with the same bytes (view from `cd_run`) |
| During a tool call | `zoom`/`date` are `replay: "safe"` and rerun; other tools get pi's `interrupted` result |
| In `onYield` after the post, before its commit | the hook reruns; the post's `client_msg_id` is `chief-reply:<agent>:<run>`, so ConversationDO keeps one message |
| After the post | `cd_run.state = posted`; the ack (`mux.ack`) is idempotent by `brain-ack:<conv>:<seq>` |

The loop guard's `agent_rate` (another agent spoke under 2 s ago) is retried inside the hook, as P
does (every 2.5 s, up to 120 s after the run).

## 5. Tools

- Phase 1 (this change): `zoom`, `date` (memory), and NO_REPLY. This is what the reply-only eval
  cases need.
- Phase 2: P's hands (`hand-api.ts`: Freestyle sandbox and the Mac host), `chiefs`, `spawn`
  (pi-durable background subagents, its example 23: a background anchor task owns each child, a
  reporter task posts the answer back as a follow-up), chief jobs, GitHub. Each is a pi extension
  that wraps P's existing service code; none of them lives in the DO class.
- Not in D: the per-turn Claude Code VM.

## 6. Memory

Same format and tables as P (`oc_message`, `oc_node`, `oc_checkpoint`, `oc_frozen`), built by the
same Rust core. The compactor runs in the background after every append, as in P. The turn does
not wait for it (P's 5 s settle is removed); an unsummarized message shows whole in the view.

## 7. Flag, rollout and migration of existing Cloud Chief users

- **Deployment flag** `CHIEF_DURABLE_ENABLED = "1"` (staging only in phase 1) and the DO binding
  `CHIEF_DURABLE_DO`. Without both, `brain_impl: "durable"` is refused and every wake goes to P.
- **Per Chief**: `PUT /v1/chiefs/<agent>/brain-impl {impl: "durable"}` (owner only), the switch O
  already uses. MuxDO stores it and routes each wake.
- **Memory copy**: the first wake of a D conversation brain copies the P brain's memory rows
  (`oc_message`, `oc_node`, `oc_checkpoint`) and its read cursor, page by page, through a read-only
  RPC on P (`memoryExport`). Summaries come along, so nothing is recompacted.
- **Old runs** stay in P. The runs route reads D first and falls back to P for a run id D does not
  have.
- **Rollback**: `PUT brain-impl {impl: "pi"}`. Messages D saw since the switch are not yet copied
  back into P's memory (gap; phase 2 adds the reverse copy).
- **Promotion to production**: after D passes the staging evals at a rate equal to or better than P
  (section 9), add the binding and migration tag in production, turn the flag on, then switch Chiefs
  one at a time (Lawrence's first), then make `durable` the default for new Chiefs.

## 8. Cost

- Model spend is the same per token as P (same route, same Bedrock prices). D sends fewer tokens
  per turn when messages come in bursts: a message during a run joins it (one view) instead of
  starting a second run with a second view.
- No settle wait: the first token comes up to 5 s sooner when the compactor is behind.
- DO cost: one object per Chief conversation, active only while a run works (duration billing for
  a 5-20 s run at 128 MB is under $0.0001). No VM per turn, so the cc route's machine boot
  (tens of seconds and VM-seconds per message) is gone for Chiefs that move to D.

## 9. Evals

The Chief eval cases (`Native/OptChat/optchat-chief/evals/cases/*.json`) were written for the Rust
Chief. `backend/scripts/chief-durable-evals.ts` runs the cases that a Cloud Chief can answer (no
host CLI stubs needed: their checks are on the reply) against a staging Chief, once with
`brain_impl: "pi"` and once with `"durable"`, with the same model, and grades the deterministic
checks (`reply_matches`, `reply_not_matches`, `no_raw_ids`, `max_words`, `no_reply`). It writes a
JSON report and a pass rate for each brain.

## 10. Phase 1 scope (this change)

1. `ChiefDurableDO` with intake, view hook, logging, post and ack in `onYield`, memory copy.
2. Routing: `brain_impl: "durable"` in MuxDO and the brain-impl route, wakes to D, runs reads to D.
3. Tests through the product boundary (fake model): one reply per message, a repeated wake answers
   once, a message during a run joins it, NO_REPLY posts nothing and acks, eviction in the middle of
   a run answers once, the flag off keeps P answering, the memory copy from P.
4. Staging: binding, migration tag, flag on; the eval runner against both brains.

## 11. Relation to chief-engines-DESIGN.md (Oct 28)

`chief-engines-DESIGN.md` (commit 03c0c73c0fe, the Chief-engines lane) landed after D phase 1. It
sets one Rust kernel for every Chief (memory, ledgers, rules, tool contract, prompt), engines behind
an adapter (pi-durable is one), and the Cloud Chief as a placement: the Rust kernel on a cloud VM
with a pi-durable Bun sidecar.

Agreed: one prompt source (D still reads `chief-brain/prompts.ts`; it must read the kernel's rendered
text), the OptChat view on every engine with pi compaction off, ledgers in the kernel, and "done =
not worse on the replay, barrage and health evals".

Proposed change to the cloud placement (sent to the Chief-engines lane): one kernel, compiled two
ways. The native binary runs on a Mac, a Linux box or a VM; the same kernel compiled to wasm runs in
the Durable Object, as the memory core already does (`optchat-wasm`). pi-durable runs in process in
the DO as the engine (start = `submit`, steer = `whenBusy: "steer"`, cancel = `abort`); tools that
need a machine call a hand (Freestyle sandbox or the Mac). Reasons against a VM per user: a cold
wake is a VM start plus a host start (never measured; the cc route already boots a machine per
message), a VM costs money while idle (a DO costs nothing idle and starts in about 1 s), and a sidecar
adds an RPC hop per tool call.

Until the two lanes agree: D gets no kernel features in TypeScript (no ledgers, no new tools). It
stays the flag-gated DO placement and the measured baseline against P.

# One Chief, many engines: Claude Code, Codex, Muse, pi-durable and Cloud Chiefs

Lawrence, Oct 28: "for chief we want to decouple a bit more, like see if we can make a claude code
chief, codex chief, muse chief, durable-pi chief, cloud chief, etc... make a cohesive design for
this. think from first principles + make evals for how chief deals with a barrage of tasks … we
need more innovations besides just optchat … use one team key for everything (including end
users)."

## 1. First principles

A Chief is three things, and each has its own job:

1. **The kernel.** This is what makes it the same Chief across months: the one chat, its OptChat
   memory, the ledgers (replies, outcomes, asks, schedules), the rules from `person.md`, and the
   tool contract. It must be durable, run as a single writer, and be the same code everywhere.
2. **The engine.** This is how one turn's model loop runs: which harness or API, which model, and
   how tool calls and steering work. It should be easy to swap from one turn to the next.
3. **The placement.** This is where the kernel and the engine run: this Mac, a Linux box, a cloud
   VM or a Durable Object. It decides what the tools can reach and whether the Chief is awake while
   the Mac sleeps.

Today these three are tangled. The Rust host (`optchat-chief`) is the kernel and drives turns
through acpmux harnesses. The Cloud Chief is a second kernel in TypeScript (6,051 lines in
`chief-brain/`, plus 2,696 in `chief-brain-cc/` for its Claude Code VM route). The ledgers exist
only in Rust, and the prompts have drifted: since Oct 13 the Mac prompt changed 65 times and the
cloud one 9 times.

**Rule:** one kernel, in Rust, for every Chief. Engines and placements plug into it. A new kind of
Chief is a new engine or a new placement, never a new kernel.

## 2. The engine interface

The kernel already gives each turn the same input: the system text, the frozen view and the delta
(`Frozen`, `turn_input_at`). An engine only needs four calls:

```text
start(turn: TurnInput { system, view, delta, tools, model, effort }) -> events
steer(text)        // a message that arrived mid-turn; engines that cannot steer queue it
cancel()           // the owner's stop or the kernel's interrupt
capabilities()     // { steer: AtToolBoundary | AtTurnEnd | No, mcp: bool, images: bool, cache: … }
```

The events are the ones the turn fold already reads: text chunks, tool calls and results, usage,
and the end of the turn.

| Engine | How a turn runs | Tools reach the kernel by | Steering | State |
| --- | --- | --- | --- | --- |
| Claude Code | acpmux harness `claude` / `claude-sr2` | MCP (`optchat` server) | at tool boundaries | exists, default |
| Codex | acpmux harness `codex` | `chief` CLI shims (AGENTS.md) | at turn end | exists (Codex Chief) |
| Muse / Unii | acpmux harness `muse`, `unii` | `chief` CLI | at turn end | exists (Muse Chief, Unii) |
| OpenCode, Gemini | acpmux harnesses | `chief` CLI | varies | harness exists |
| Native API | `native/` Messages API loop, with any OpenAI-compatible base URL (Vercel AI Gateway) | in process | at tool boundaries | exists for Claude; gateway route new |
| pi-durable | in the Cloud Chief's Durable Object, in process with the wasm kernel (start = `submit`, steer = `whenBusy: "steer"`, cancel = `abort`); off the cloud, a Bun sidecar behind the same adapter if one is ever wanted | in process | `whenBusy: "steer"` | building (a749, `cloud-chief-durable-DESIGN.md`) |

What each engine does not own:

- **Memory.** Every engine gets the OptChat view, and every engine's own compaction stays off.
  pi-durable's `compact()` and Claude Code's autocompact never run on a Chief turn.
- **Ledgers.** The kernel keeps them, whatever the engine, so the reply, outcome, ask and schedule
  rules hold for a Codex Chief exactly as for a Claude Chief.
- **Prompt.** One prompt source with small engine sections (how its tools are named). The kernel
  renders it; the Cloud Chief bundles the same rendered text.

## 3. Placements

| Placement | Kernel runs | Awake when the Mac sleeps | Reaches |
| --- | --- | --- | --- |
| Mac (Home Chief) | `optchat-chief host` on the Mac | no | the Mac's apps, browser, files, fleet |
| Linux box / Mac mini | the same binary (CI already builds Linux targets) | yes | its own machine; the Mac through the hub |
| Cloud | the same Rust kernel compiled to wasm, inside the Chief's Durable Object; pi-durable engine in process; models through the Vercel AI Gateway | yes | cloud APIs; a machine through a hand (Freestyle sandbox or the Mac) |

**One kernel, built two ways** (Oct 28, agreed with a749; its section 11 in
`cloud-chief-durable-DESIGN.md`): the native binary on a Mac, a Linux box or a VM, and the same
kernel compiled to wasm inside the Durable Object, as the memory core already is (`optchat-wasm`).

The **Cloud Chief** becomes a placement, not a codebase:
- the same kernel and ledgers, as wasm in the DO;
- the pi-durable engine in process for durable mid-turn steps (a tool's intent is stored before it
  runs; a crash replays only `replay: "safe"` tools);
- tools that need a machine call a hand: a Freestyle sandbox, or the Mac through the hub;
- any model through the gateway.

Why not a VM per user (this doc's first version): a cold wake would be a VM start plus a host start
(never measured; the cc route already boots a machine per message), a VM costs money while idle (a
DO costs nothing idle and starts in about 1 s), and a sidecar adds an RPC hop per tool call.

What that asks of the kernel: everything a turn needs compiles to `wasm32-unknown-unknown`. Memory,
ledgers, prompt rendering and the tool contract are pure logic. Clock, storage, network and
processes come in through traits that the DO and the native host each implement. The native-only
parts (acpmux, PTYs, the app socket) stay outside that core.

The TypeScript brain retires once the wasm kernel passes the same replay and barrage evals on the
cloud placement. Until then it gets no new kernel features (no ledgers, no new tools), and step 1
below stops the prompt drift.

## 4. One inference key for everyone (Vercel AI Gateway)

Decision (Lawrence, Oct 28): one team key for everything, end users included. This goes with the
"Free DeepSeek fallback endpoint" lane (a725, `plans/cmux-next/paid-plan.md`). Decisions (Lawrence,
Oct 28, defaults picked):

- **Key:** `INFERENCE_VERCEL_GATEWAY_KEY` is the one team key and stays a Worker secret. Clients never
  hold it. All three provider keys stay configured; paid traffic routes cheapest first (paid-plan.md §2).
- **Free:** every free model (`qwen/qwen3.7-flash`, `openai/gpt-oss-120b`, `deepseek/deepseek-v4-flash`)
  reaches a signed-out device only through our Vercel AI Gateway route (`freeProviders: ["vercel"]`).
  A Mac that passes App Attest gets a short-lived `aud inference` token and a device quota of 300,000
  tokens a day and 20 requests a minute (`INFERENCE_FREE_DAILY_TOKENS`, `INFERENCE_FREE_PER_MINUTE`).
- **Paid:** a plan or prepaid credits, metered by the existing usage ledger.
- **Chief engines** (Claude Code, Codex, any engine not on a person's own login) call
  `<cloud api>/v1/inference` (`/chat/completions` or `/v1/messages`). Auth, in order:
  1. the install bearer token (`Authorization: Bearer`). An install token carries its team claim, so
     the install's team is the one billed; there is no separate team token. `x-cmux-team` may name
     another team only where that team is allowed for the install (team-select.ts);
  2. a signed-out Mac with no plan uses the short-lived `aud inference` token from App Attest
     (free models only).
- **Models:** the router serves only the ids in `backend/apps/api/src/inference/catalog.ts` (the
  allowlist, list at `GET /v1/inference/models`). Any other id gets a 404 `model.not_found` whose
  message names the allowlist. A Chief cannot name an arbitrary gateway model.

## 5. Ideas taken from prime-agent and Connectome, beyond OptChat

| Idea | From | For Chief |
| --- | --- | --- |
| A goal that stays open until it is closed (`/goal`) | prime-agent | the **ask ledger**: each ask of a message gets an owner (a subagent, "me", or "declined because …"), and stays open until a post closes it with evidence |
| Heartbeats and schedules that re-enter the session | prime-agent, Connectome | `schedule(cron, prompt)` and `watch(command, until)`, saved in the kernel; each firing is a note in the one chat |
| Bounded autonomy with quality gates ("reaching a limit does not imply success") | prime-agent | "done" needs evidence: a landed sha range, a passing run, or a link. A report without it stays open in the outcome ledger |
| Retained subagents and agent-to-agent messages | prime-agent | exists: `tell` and peers |
| Refining supplemental state with rollback, never the base prompt | prime-agent | `remember` writes versioned rules to `person.md`, each change journaled and undoable |
| Skills as packages, with a skill creator | prime-agent | tool packs exist; add "make this workflow a skill" |
| A watchdog for "messages arriving but no reply" | Connectome | the reply ledger inside the kernel, plus an outside health check for a stuck kernel (`chief_health`) |
| First-person, as-known-then summaries | Connectome | a compaction prompt variant, A/B tested with `replay_compactions` |

## 6. Barrage evals (Oct 28)

`evals/cases/barrage-*.json`, 5 cases, judged by rules only:

1. six asks of four kinds in one message;
2. five messages in one turn;
3. follow-ups while agents work (`tell` the running one, spawn the new one, answer the status);
4. two turns, the second asking what is in flight;
5. a status check that comes back empty must not spawn duplicates.

Real brain (Opus 5.5, medium effort, sr2 gateway): 3 of 3 runs passed for each of the first 4 after
two of my checks were fixed, and 8 of 8 for the fifth.

Findings:

- **In a single turn, a barrage is handled well.** Every ask was taken in every run.
- **A reminder goes to the Cloud Chief as a job**, as the prompt says. In one run Chief had to say
  "it hasn't confirmed yet". A local `schedule` tool would make it certain.
- **An empty status check led Chief to start all four agents again** (a905–a908), once, before the
  runner's fake `control status` was made truthful. It did not happen again in 8 runs. Austin saw
  the real version ("please do not have duplicate workspaces").
- **The real losses are not in one turn.** They are messages that arrive mid-turn (165 steer
  failures in a week on Lawrence's Chief), outcomes never told (32%), and promises across turns
  (1 in 10 kept). The next barrage cases need the runner to deliver a message during a running tool
  call. That is runner work: a `during` field on a turn.

## 7. Order of work

1. One prompt source for every engine and placement, with a CI check (stops the drift).
2. Ask ledger, then the `schedule` and `watch` tools in the kernel (tests first; one engine-neutral
   tool contract).
3. The `Engine` trait over today's acpmux path, with no behavior change. Then the native engine
   through the gateway endpoint.
4. Split the kernel into a wasm-clean core (memory, ledgers, prompt, tool contract, behind clock,
   storage and network traits) and the native host. CI builds both targets.
5. The Cloud placement (a749): the wasm kernel in the Durable Object with the pi-durable engine in
   process and hands for machine tools. It is compared with the TypeScript brain on the replay,
   barrage and health evals, and the TypeScript brain retires once it is not worse.
6. The barrage runner's `during` field, and harder barrage cases built from real corrected messages.

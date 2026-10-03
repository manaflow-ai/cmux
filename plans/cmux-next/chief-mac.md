# cmux-next Chief on the Mac: the Rust brain (package P1)

Status: design note, P1 lead, 2026-10-03. Decisions: H8 (Rust port in cmux, in-process with the
conversation owner and acpmux; the TypeScript brain stays for the cloud MuxDO; one shared behavior
corpus), D10 (local conversations; promotion to a `ConversationDO`), IOS2. Inputs: home.md sections
4, 5 and 8, home-messaging.md section 20, code-mode.md, mcp.md, `mux/host`, `mux/packages/brain`.
Not in scope: decision X1 (the isolated chief experiment with its own memory model, Worker and
branch). This note does not use or change anything from X1.

## 1. What the brain is

The Chief is an ACP agent session (`mux` in acpmux, harness `claude-sr`). The model loop runs in the
harness. The "brain" that P1 ports is the deterministic host around it (today `mux/host`, Bun):

1. Inbox: it reads the conversation owner's `conversation-changed` events, applies the wake rule
   (home.md section 5), and prompts the session (`promptId` = message id).
2. Replies: it folds the session's acpmux events into turns and posts each turn's text as
   `message.send` by `agent_mux` (key `turn:<session>:<turn seq>`); it sets typing during a turn.
3. Supervisor: it tracks child sessions tagged `mux.parent=mux`, posts and edits their `work`
   cards, and sends `[mux-event]` prompts when a child ends a turn or asks for a permission.
4. Outbox: durable, ordered conversation ops; one retry after `agent_rate`; drop on any other
   reject; reconnect and keep the entry on `actor_mismatch`.
5. Memory: the OptMem-style log (`LOG.txt`, `TREE/`), the Claude Code hooks that write it, and
   compaction through a summarizer session.
6. Session setup: the session directory (CLAUDE.md, `.claude/settings.json`, hooks), the tool
   servers, the pid lock, and catch-up after a reconnect.

## 2. Process placement

Today the conversation owner (`cmux-conversation` + `conversation_store.rs`) runs in the session
daemon (`cmux` server). The acpmux hub runs in a second process from the same binary
(`cmux acp daemon run`). S8 puts both roles in the one `cmux` binary, but not yet in one process.

Placement: the Chief is an actor in the session daemon process (the conversation owner's process).

- Conversations: in-process calls to the store through a trait `ConversationPort`. The owner stamps
  `agent_mux` directly on the actor's writes. No socket, no minted token, no token file.
- acpmux: a trait `AgentSessionPort`. Its first implementation is the Rust acpmux client
  (`acpmux::client`) over the acpmux socket. The daemon starts `<current exe> acp daemon run` when the
  socket does not answer (the same rule as `ACPMUX_BIN` today, without the env var). When the acpmux
  hub moves into the daemon process (S8 hosting change, not P1), a second implementation calls the
  hub in-process. The core does not change.
- Lifecycle: the daemon starts the actor when the session has a `kind: home` workspace
  (`workspace.ensure_home`) and stops it with the session. One actor per `$MUX_HOME`: the actor takes
  the same pid lock as the TypeScript host (`$MUX_HOME/state/host.lock`), so the two hosts never run
  together. The daemon advertises capability `chief-v1`.
- Why not the acpmux process: the conversation owner is the single writer of conversations and its
  owner-stamped actor is the security boundary (home.md section 2). An in-process client of the
  owner removes the token handoff (the 0600 file and the "any same-uid process is user_local" gap
  stays only for other clients). acpmux sessions are already a client protocol with replayable
  events and `promptId` dedupe, so a socket hop there costs nothing in correctness.

DECISION (to main): placement in the session daemon process now, with the acpmux hop behind a
trait. RECOMMEND: yes, because H8 asks for in-process with both owners and the conversation owner is
the one whose boundary matters; merging the acpmux hub into the daemon process is the S8 hosting
change and belongs to its own owner.

## 3. Core shape: one pure core, two hosts

Both brains get the same sans-I/O core: `step(state, input, now) -> effects`. Hosts do only I/O.

- TypeScript: `mux/packages/brain/src/core/` (extracted from `mux/host/src/host.ts`, `turns.ts`,
  `wake.ts`, `supervisor.ts`, `state.ts`). `mux/host` becomes a thin shell around it. The cloud
  MuxDO uses the same core later (H8 keeps the TypeScript brain for the cloud).
- Rust: crate `cmux-tui/crates/cmux-chief` (core, memory, prompts; serde only, no I/O), plus the
  daemon shell `cmux-tui-core/src/server/chief/` (ports, timers, persistence).

Inputs (tagged `kind`): `daemon_connected {conversation}`, `conversations_listed {summaries}`,
`snapshot {summary, messages}`, `history {conversation, messages}`, `conversation_changed {event}`,
`op_result {idempotency_key, ok | reject}`, `acpmux_connected {session_id, sessions, events}`,
`acpmux_event {event}`, `session_changed {session}`, `permission_pending {session_id,
permission_id, request}`, `child_events {session_id, events}`, `prompt_accepted {prompt_id}`,
`timer {key}`, `disconnected {port}`.

Effects (tagged `kind`, in order): `conversation_op {conversation, idempotency_key, op}`,
`typing {conversation, on}`, `prompt {prompt_id, text}`, `fetch_snapshot {conversation, tail}`,
`fetch_history {conversation, before_seq, limit}`, `fetch_child_events {session_id, after}`,
`reconnect {port}`, `arm_timer {key, at}`, `persist {state}`, `log {line}`.

Durable state keeps the `host.json` shape of `mux/host/src/state.ts` (field names unchanged), so
the Rust host takes over a TypeScript host's state and memory with no migration step.

## 4. Shared behavior corpus

Format `cmux-chief-corpus/1`, file `mux/packages/brain/conformance/chief-cases.json`, written by
`mux/packages/brain/conformance/generate.ts` (the home-core pattern: each case states its intent,
the TypeScript core must agree, and the generator records the full effects).

```
{"format": "cmux-chief-corpus/1",
 "cases": [{"name", "state": <durable state before>, "volatile": <summaries, cursors, sessions>,
            "steps": [{"now": RFC 3339 ms, "input": <Input>, "effects": [<Effect>]}],
            "state_after": <durable state>}],
 "memory": [{"name", "fn": "to_lines"|"decompose"|"wake_cover"|"render_wake", "args", "result"}]}
```

Rules: effects compare as JSON values in order; `persist` compares the whole state; times come only
from `now`. Case groups: wake rule (1:1, group, DM, mention, reply to the Chief, retracted, own
message), catch-up from the read cursor with paging, turn folding (steer, queue, error, replay at or
below the cursor), reply keys, typing, outbox (`agent_rate` once, `agent_budget` drop,
`actor_mismatch` keep and reconnect), children (start, permission, finish, lost on reconnect),
memory functions. Rust runs it with `include_str!` in `cmux-chief/tests/corpus.rs`; TypeScript runs
it in `bun test`. A required check runs both (the corpus is the contract, like
`cmux-conversation-conformance/1`).

## 5. Tools come from the catalog

No hand-written tool list. The Chief's verbs become catalog operations in
`cmux-tui/spec/resource-operations-v2.json`, owner `chief` (session daemon), with `cli.path`, so the
CLI verbs and the MCP tools are generated like every other operation:

| op | class | replaces |
| --- | --- | --- |
| `chief.agent.spawn {name, cwd, harness?, policy?, prompt}` | mutation, idempotency key | `mux agents spawn` |
| `chief.agent.prompt {name, text}` | mutation | `mux agents prompt` |
| `chief.agent.list {}` | read | `mux agents list` |
| `chief.permission.answer {name, option_id? , deny?}` | mutation | `mux agents allow/deny` |
| `chief.memory.recall {pattern, limit}` / `zoom {lo, hi}` / `wake {budget}` | read | `mux memory` |
| `chief.memory.note {text}` | mutation | `mux memory note` |
| `chief.compact {}` | mutation | `mux compact` |
| `chief.status {}` | read | none (health: lock, ports, outbox depth) |

The Chief's session gets one MCP server, `cmux mcp serve --profile chief`. A profile is a filter on
catalog fields (an operation with `agents.chief: true`), never a list of names. The profile holds
the `chief.*` ops and the workspace, tab, terminal and browser ops the curated CLI offers. When the
code-mode executor ships on macOS (code-mode.md: needs a macOS sandbox profile), the profile switches
to the two code-mode tools (`cmux_docs`, `cmux_exec`) over the same generated SDK; the Chief's rights
do not change. Claude Code hooks are not tools: they call `cmux chief hook <event>` (stdin JSON),
which runs in the daemon's memory owner. The CLAUDE.md section about tools is generated from the
profile (group names and one line each), so the prompt and the tool list cannot disagree.

## 6. `conversation.promote` (D10)

A local conversation becomes a cloud `ConversationDO`. The local owner stays the single writer of
the local copy; the cloud owner is the single writer of the new one.

1. Local op `conversation.promote.begin {conversation, idempotency_key}` (actor `user_local`):
   the owner freezes the conversation (writes refused with `promoted`) and returns the export
   (summary, all messages, reactions, read cursors) and a deterministic target id
   `conv_<base32(sha256("promote:" + local id + ":" + user id))[0..26]>`.
2. The app (it holds the account session) calls the cloud op `conversation.import {id, source:
   {owner: "local", conversation, rev}, participants, messages}` through Home ops routing. The import
   maps `user_local` to the account's `user_<id>` and `agent_mux` to the user's Chief agent id
   (home-messaging.md section 20 item 9). Import is idempotent by `id`.
3. Local op `conversation.promote.commit {conversation, cloud_id}`: the local copy becomes read-only
   with a pointer (`promoted_to`). A crash between 1 and 3 replays 2 (same id) and then 3.
   `conversation.promote.abort` unfreezes when the import is refused.

The Chief follows the pointer: it stops waking on the local copy; the cloud brain owns the cloud
copy. Dependencies: `conversation.import` in home-core (lane 15) and its Worker route (backend lead,
urgent finding 2).

## 7. Migration and landing order

1. This note (plans only).
2. TypeScript: extract the core into `mux/packages/brain/src/core/`, keep `mux/host` green on the
   core, add the corpus generator and cases. No cmux-tui change; no window.
3. Rust: crate `cmux-chief` (core, memory, prompts) and its corpus test. Needs a cmux-tui window.
4. Daemon shell, capability `chief-v1`, `chief.*` catalog ops, `cmux chief` CLI, MCP profile,
   `cmux chief hook`. Needs a window and a review subagent (daemon, protocol, catalog).
5. App: `HomeBrainHost` stops reading `CMUX_NEXT_MUX_HOST` when the daemon advertises `chief-v1`
   (the daemon starts the Chief; the app mints no token). Swift via nx-remote. The env-var path is
   deleted after the next pin carries `chief-v1`.
6. `conversation.promote` after `conversation.import` and Home ops routing exist.

Done when: a tagged build answers in Home with no `CMUX_NEXT_MUX_HOST`; the corpus passes in
`bun test` and in `cargo test -p cmux-chief`; promote passes an end-to-end test against staging.

## 8. Open points

- Name: the wire ids stay `agent_mux`, acpmux session `mux` and `$MUX_HOME` so that the corpus and
  the state carry over. Product copy says Chief (IOS4). A rename of wire ids needs its own decision.
- Compaction keeps the acpmux summarizer session (`MUX_COMPACT_HARNESS`, model `haiku`). Model
  calls in tests go through the subrouter only.
- PATH for the Chief's tools stays the phase A stand-in until D26 (daemon login environment).

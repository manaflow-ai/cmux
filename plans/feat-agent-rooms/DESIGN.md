# Agent Rooms: provider-neutral messages between cmux agent sessions

Status: in progress. The provider-neutral broker and ACP prompt seam are
implemented under `agent-chat`. In cmux-next the durable store and the
`cmux agent message` / `cmux agent inbox` CLI are implemented (see "cmux-next
slices" below); hook delivery, native Codex and Claude delivery, `cmux agent
list`, UI, remote federation, and external mail providers remain proposed.

## Problem

cmux can already run several coding agents in one workspace, but a Claude
session and a Codex session do not have a shared address or a durable way to
ask one another for bounded work. Today a person must copy a prompt, select a
different session, paste context, and keep the relationship in their head.

This loses the distinction between a provider conversation and the work that
conversation is carrying. A provider session may be forked, resumed, paused,
or replaced while the review request or handoff still needs to exist.

## Outcome

An agent or human can send a typed message to a stable cmux conversation
identity, for example `reviewer@payments`. The message is stored before cmux
tries to wake the receiving session. A live session receives it through its
native adapter or ACP; an offline session keeps it queued. Replies retain the
same thread and can be inspected alongside the participating panes.

The message layer owns routing, threading, delivery receipts, and
deduplication. Persistence and adapter schedulers will own retry and replay
once a durable store exists. Provider adapters own model turns, tools, permissions,
worktrees, and provider-specific session IDs. A message never grants authority
to perform an external effect.

## Existing foundations

- `agent-chat` already normalizes Claude stream-JSON, Codex app-server, pi,
  and ACP sessions into a common `AgentEvent` stream.
- ACP is the local client-to-coding-agent boundary. cmux can use the official
  Claude and Codex ACP bridges without requiring either provider to implement
  peer messaging.
- A2A is a later network boundary for independently hosted agents. It should
  map into cmux threads rather than replace the local message store.
- MCP can expose mailbox operations to agents. It is a tool/data interface,
  not the durable conversation store.
- Stensibly's responsibility/authority ledger model is a useful companion:
  durable work facts and approval state remain separate from disposable model
  conversations.

## First slice

Add a pure TypeScript module under `agent-chat/mail/` with:

1. A message envelope containing immutable `id` (the message ID), `threadId`, sender,
   recipients, body, timestamps, optional parent message, and optional context
   references.
2. Per-recipient delivery records with explicit states:
   `queued`, `delivered`, `acknowledged`, `failed`, and `dead-lettered`.
3. An idempotent append operation keyed by `id` and a deterministic
   reply operation that preserves `threadId` and sets the parent message ID.
4. A small in-memory broker for focused tests and future persistence adapters.
5. An on-disk JSONL or SQLite persistence adapter in a follow-up slice. The
   persistence boundary must support restart recovery and replay without
   treating a notification or WebSocket delivery as durable storage.

The first slice deliberately has no email, A2A, UI, wake-up policy, or model
calls. It establishes the contract that those adapters can consume.

## Delivery model

The in-memory core records delivery states and notifies currently subscribed
listeners; it does not itself redeliver after a process exit. A future durable
store plus adapter scheduler will provide at-least-once delivery. A transport
acknowledgement means that the target adapter accepted the message, not that a
model understood it or completed the requested work. Clients must be safe to
retry the same message ID.

When a provider session is running, the broker may queue a message until the
adapter reports that another prompt can be accepted. Steering an active turn
is an explicit provider capability and policy choice; it is not assumed by the
mail layer.

The durable store remains authoritative. Push notifications, WebSockets, and
terminal hooks are wake-up hints. A reconnecting client can list messages from
its last cursor and reconcile delivery receipts.

## Trust and authority

The current `MailEnvelope.metadata` field is caller-supplied JSON and is
untrusted, just like model-controlled subject, body, and attachments. It is
not a cmux assertion and cannot be used as an authority grant. Future broker
owned provenance will be a separate field. Incoming content is untrusted input. An agent message
cannot approve a merge, deployment, credential change, spending action, or
other consequential effect.

The broker should support bounded recipient allowlists, wake budgets, reply
depth/fan-out limits, expiry, and human escalation. A future Stensibly or
cmux authority record may be referenced by a message, but the message itself
does not grant that authority.

## Later adapters

- **ACP adapter:** prompt rendering into `session/prompt` is implemented. The
  future delivery adapter will correlate `session/update` output and receipts
  back to the thread.
- **MCP surface:** expose `send`, `inbox`, `reply`, `acknowledge`, and
  `list_threads` as tools with explicit scopes.
- **A2A gateway:** expose selected cmux identities as Agent Cards and map A2A
  task/context IDs to cmux thread IDs.
- **Mail projection:** optionally mirror a thread to email, Slack, or another
  human attention surface. RFC-style `Message-ID`, reply ancestry, and stable
  list IDs are useful projections, but are not required internally.

## Acceptance conditions for the first implementation

- Two fake sessions can exchange a message and a reply through the broker.
- Repeating an append with the same message ID and identical payload creates
  no duplicate; divergent payloads are rejected.
- Each recipient has an independent delivery receipt.
- A queued message survives a broker restart once the persistence adapter is
  added.
- Provider adapters are not imported by the core message module.
- Tests cover duplicate delivery, reply threading, failure/dead-letter state,
  and bounded recipient fan-out.

## Open questions

- Should durable local state use SQLite, matching other cmux stores, or a small
  append-only journal first?
- Is a stable address owned by a workspace, a task, or a role alias that can
  point to a replacement session?
- Which message classes should cmux understand structurally (`review`,
  `handoff`, `question`, `answer`, `acknowledgement`) before exposing freeform
  messages?
- When should an offline message start a fresh provider session, and when must
  it wait for a human to attach one?

## Out of scope for this RFC

Remote agent discovery, cross-organization identity, arbitrary email sending,
automatic execution of message bodies, transcript replication, and a general
workflow engine are separate proposals.

## cmux-next slices

cmux-next has no long-lived TypeScript process, so the store is a Rust port of
this envelope in the cmux-tui daemon, which already owns the `agent` scope and
the agents' hooks and keeps its state in the session registry (SQLite). The
TypeScript broker stays the reference for the envelope and states.

| Slice | State | Where |
| --- | --- | --- |
| Persistence: `agent.message.send`, `list`, `mark` on `cmux.protocol/2`; one envelope and one receipt per recipient, kept across daemon restarts | implemented | `cmux-tui-core` `agent_message_store.rs`, spec `resource-api-v2.md` |
| `cmux agent message` / `cmux agent inbox` | implemented | `cmux-tui` `cli/agent_message.rs` |
| ACP delivery: the CLI prompts each acpmux recipient with the message id as the prompt id (acpmux runs an id once), sending older queued messages first (a failed one is not retried) | implemented | `acpmux` `deliver.rs` |
| Hook delivery to terminal agents: Claude and Codex `UserPromptSubmit` add queued messages as context, Codex `Stop` continues the turn with them; at least once (list, print, mark delivered) | implemented | `cmux-tui` `bin/cmux-tui-hook.rs`, `agent_hook_install.rs` |
| Native delivery to Codex: the CLI hands a Codex terminal agent its queued messages through the shared app-server daemon (`turn/start` when idle, `turn/steer` when running), only for a thread the daemon already loaded | implemented | `cmux-tui` `cli/codex_app_server.rs` |
| Native delivery to Claude Code through its peer socket: not built. The socket's message format is not documented (only its path and auth line are), so Claude stays on hooks | not planned | |
| `cmux agent list` from acpmux sessions and terminal agents (cmux #16417) | proposed | |

Choices in the port, compared with the TypeScript broker:

- Addresses are `term_<id>` for a terminal agent and `acp:<session id>` for
  an acpmux session; a sender may also be `cli`. The CLI resolves `agent_`
  ids and acpmux session names to these before it sends.
- Receipt states are `queued`, `delivered`, `acknowledged` and `failed`.
  `acted`, `replied` and `dead-lettered` are not used yet.
- The daemon mints `msg_<32 hex>` ids. Idempotency comes from the protocol's
  idempotency key, not a caller-chosen message id.
- Messages are not published on `session.events`. Like every operation on
  the session socket, the caller is trusted: the sender address is asserted,
  and any caller can list or mark any message.
- Retention: messages beyond the newest 2000 are pruned once none of their
  receipts is queued. A `failed` delivery is not retried automatically.

Room left for the proposals that build on this (not implemented):

- Message kinds (#16439 `--kind question`): `kind` is already a column and a
  snapshot field (`message`, `reply`); a new kind is an added enum value.
- Group recipients (#16438): a group expands to its members at send time, one
  receipt each, so "who has seen rules version N" is a receipt query. The
  64-recipient limit applies to the expanded list.
- A mux (#16279) is another participant; a local mux is an acpmux session.
- `cmux agent list` rows (#16437, #16417 comment) can carry the launch spec
  (model, effort, account, machine) and a count of queued messages from
  `agent.message.list`.

## Validation status

The implemented slice currently passes:

```text
bun run check
bun test ./test/mail.test.ts ./test/acp-mail.test.ts
bun ./test/acp-mail.e2e.ts
```

These checks cover the existing agent-chat suite, broker idempotency and
threading, per-recipient receipts, fan-out limits, dead-letter state, ACP
prompt formatting, and delivery through the fake ACP process. No persistence
or user-facing room UI has been claimed by these checks.

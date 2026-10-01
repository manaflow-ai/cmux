# mux: design

Living design note. Decisions from the 2026-09-30 interview with Lawrence;
reversible choices made during implementation are recorded here too.

## Vision

Cmd+1 in cmux next opens **Messages**: conversations between humans and
**muxes**. A mux is an orchestrator agent with its own context and memory. It
spawns sandboxes, drives acpmux agents, and sets up automations on the local
Mac, on remote Macs (minis running cmux next) and in the cloud. Multiplayer is
group chat: teammates and several muxes in one conversation. Spawned ACP
agents are not conversations in this list; they are work a mux reports on.

There can be many muxes. Each has its own context and memory, and muxes
message each other and humans through the same conversations.

## Components and licenses

mux has two forms. The **local form** runs the brain on your machine through
acpmux and is open: GPL-3.0-or-later, like the rest of cmux. The **cloud form**
runs the brain in a Durable Object and is Business Source License 1.1 with the
shared cmux grant: anyone may run it for themselves or their organization, but
not host it for others or resell it (root `LICENSE`, `cloud/LICENSE`).

| Path                | License | What                                                                                                                                                                                                                             | State      |
| ------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| `apps/web`          | GPL     | Vite+ React app, TanStack Router + Query. Web client and the fast harness for iterating on mux logic.                                                                                                                            | scaffolded |
| `packages/protocol` | GPL     | Types shared by web, both brains and native clients (chat model from `Prototypes/MessagesLab/shared/MODEL.md`).                                                                                                                  | chat types |
| `packages/brain`    | GPL     | Loop, OptMem memory and compaction, `MemoryStore` interface, code-mode API contracts. Used by both forms.                                                                                                                        | slice 1    |
| `local/`            | GPL     | Local form: the brain as an acpmux agent, memory in a local git repo, worktree sandboxes.                                                                                                                                        | slice 1    |
| `link/`             | GPL     | Rust binary on each machine. Dials a brain outbound, drives local cmux-tui and acpmux sockets.                                                                                                                                   | slice 1    |
| `cloud/`            | BSL     | Cloud form: Worker (`cloud/`) with a Durable Object per mux and per conversation, Stack Auth, memory host service on Freestyle, VM providers and environment snapshots, automation ingress and delivery, Dynamic Worker runtime. | slice 1    |

Rule for placement: code both forms need goes in a GPL package; code that only
exists to run mux as a hosted multi-user service goes in `cloud/`. Nothing in a
GPL package may import from `cloud/`.

The UI depends only on `ChatSource` (`apps/web/src/chat/source.ts`), so the
fixture, the worker WebSocket and a native bridge are swappable. The native
Cmd+1 screen will be one of the MessagesLab variants, chosen later; the web app
is where the logic is iterated first.

## Brain

In the cloud form the loop runs inside the mux's Durable Object, so a mux keeps
working when every Mac is offline. In the local form the same loop from
`packages/brain` runs as an acpmux agent. The UI treats both as a participant
of kind `mux`, and the provider interface leaves room for other ACP brains.
The two forms compact differently: the cloud form runs compaction from
Durable Object alarms; the local form replaces the harness's own compaction
with `wake` and runs merges between turns.

Model calls go to coderouter's Responses API (`https://coderouter.dev/v1`,
`CODEROUTER_API_KEY` as a Worker secret). Per-mux config: `baseUrl`, `model`,
`reasoningEffort`, `serviceTier`. Default: `gpt-6.1-sol`, `high`, `priority`.
Coderouter reports `tool_mode: code_mode_only` for that model, which fits the
tool design below.

## Memory

Modelled on [OptMem](https://github.com/VictorTaelin/OptMem): the chat IS the
memory. Every message, event and spawn result a mux sees is appended to one
append-only log of short lines. A binary summary tree over the log (`#a-b`
nodes) is a rebuildable cache. The mux's context on each turn is `wake`: the
recent raw tail plus the coarsest nodes that cover everything older, within a
fixed reading budget. `recall <regex>` (rg over the log) and `zoom <a-b>` give
exact detail on demand.

Compaction rules (our additions to OptMem):

- Build a node only when `wake` needs it, which is when the raw tail no longer
  fits the budget. Nothing is summarized that is still shown raw.
- Leaves and low levels are most of the work (n/2 leaf summaries, only log n
  levels above). A small model (`gpt-6-luna`, low effort) writes levels below
  a configurable cutoff; the main model writes the few upper levels that
  dominate what the mux remembers.
- Compaction runs off the critical path (a Durable Object alarm after a turn),
  never inside a reply. A turn that finds a missing node uses its children.
- The log is never edited. A bad node is forgotten and rebuilt.

Storage sits behind a `MemoryStore` interface: append, read range, recall,
tree get/put, sync. The first implementation is a git repo on the smallest
Freestyle VM (git and a little disk only), fronted by a small memory service.
The same interface must port to another VM provider, a local MacBook, or a Mac
mini, so `rg`/`grep` work wherever the repo lives.

## Tools: code mode

A mux has one tool: run code. The code runs in a Cloudflare Dynamic Worker with
egress controlled and a typed `mux` API passed in as bindings:

- `messages`: later (send to other conversations, react, reply in thread). Slice 1 has none: the final answer is the reply, and an early `messages.send` made the model post everything twice.
- `memory`: recall, zoom, note.
- `machines`: registered Macs and VMs, via their links.
- `agents`: spawn, prompt, steer, cancel acpmux sessions on a machine.
- `sandboxes`: two interfaces. `worktree` (git worktree plus acpmux session on
  a registered Mac) and `vm` (Freestyle VM that boots cmux-tui, acpmux and the
  link). `environments` lets a mux create and refresh Freestyle snapshots per
  project, so new sandboxes start with repo, dependencies and tools ready.
- `automations`: create, list, pause, inspect runs.
- Data: `calendar`, `people` (humans and muxes), `tasks` (Linear), `projects`
  (repos, snapshots, machines), `browser` (browser use).

Linear: reimplement all of [linear-cli](https://github.com/schpet/linear-cli)
from one core, exposed as a CLI, an MCP server and the code-mode `tasks` API.

Notion-like documents are **mux apps**: React apps on a Bun hot-reload dev
server, from a template with a typesafe WebSocket protocol and TanStack. They
run on Freestyle or locally, so realtime works.

## Link

Each machine runs a separate `link` process (Rust; launchd on Macs, a service
on VMs). It dials the mux worker over an outbound WebSocket and acts as an
ordinary local client of cmux-tui and acpmux. cmux-tui stays a standalone tmux
alternative and acpmux keeps its rule of never calling a control plane; only the
link knows about muxes. A headless mini needs no app running. Cloud VMs run the
same link, so local, remote and cloud share one path.

## Automations

Reliability comes first:

- Ingress: per-automation webhook URLs for any service, with signature
  verification (GitHub HMAC, Stripe, generic HMAC or bearer).
- Durability: every event is appended to the mux's event log before the
  request is acknowledged, with an idempotency key from the source.
- Dispatch: an event either becomes a message in the mux's chat (it then lives
  in memory like everything else) or first passes a deterministic filter or
  handler that runs as a Dynamic Worker, so noisy sources cost no model calls.
- Retries with backoff, a dead-letter list, and run history per automation.
- Triggers in scope: messages (sender and keyword rules), GitHub and arbitrary
  webhooks, machine events from links (agent finished or needs input, command
  exited, build done), and schedules (Durable Object alarms).

## Accounts and deploy

Humans sign in with Stack Auth (cmux accounts); the worker verifies Stack JWTs.
Development runs under `wrangler dev`; a staging Worker deploy comes after, and
the first deploy is confirmed with Lawrence. Freestyle VMs use the cmux
Freestyle account and are named `mux-*`.

## Slice 1

Chat, brain and link to acpmux: web client on the worker, humans and muxes in
conversations, the Durable Object loop on coderouter, OptMem memory on a
Freestyle memory VM, code mode with `messages`, `memory` and `agents`, and a
Rust link that lets a mux spawn and drive acpmux agents on a Mac.

## Open

- Cloudflare account and Worker names for staging.

## Slice 1 findings (2026-10-01)

- VMs boot at their snapshot's size, and `freestyle/busybox` is 1 vCPU /
  128 MiB / 1 GB. `cloud/worker/scripts/bake-memory-snapshot.ts` bakes
  `mux-memory-base`: BusyBox plus git and its shared libraries copied from an
  Ubuntu VM, run through the bundled loader. Memory VMs boot from it and pause
  after 300 s idle; exec wakes them in about 0.1 s. They run no service:
  memory operations are BusyBox and git commands through Freestyle exec.
- `cf deploy` (cf 0.13) sends no Authorization header in its deploy step, so
  `cloud/worker/scripts/deploy-staging.sh` runs wrangler with the cf OAuth
  token. `cf dev` works.
- Stack's REST API allows any origin, so email and password sign-in needs no
  Stack configuration. OAuth (GitHub, Google) needs the staging domain in the
  Stack project's trusted domains.
- Sign-in uses the cmux development Stack project (cmuxterm-dev). Production
  accounts need that project switched in `cloudflare.config.ts`.

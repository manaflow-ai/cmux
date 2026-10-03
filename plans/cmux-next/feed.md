# The feed: notifications and agent requests as one system

Status: proposal 1, feed lead (lane 9), 2026-10-02. This file is the "spec proposal: feed"; only the coordinator writes the spec. Binding inputs: cmux-next-spec decisions N10 to N13, SV1 to SV3, B10, D20, D48, U4, U5; spec/passkeys.md, app-platform.md, identity-and-permissions.md, sync-and-transport.md, operation-catalog.md, acp-ui.md, tasks-design.md, backend.md; OWNERSHIP-PRINCIPLES.md, architecture.md, notifications.md, status-indicators.md, app-platform.md, browser-host.md, browser-isolation.md, skills/cmux-next-feature.

## 0. Decided (Lawrence, 2026-10-02, through the coordinator)

| # | Decision |
| --- | --- |
| FD1 | Email items are id-only: connection, account, thread, message and history ids and labels; headers and snippets are fetched live and cached only in client memory (S2 holds). |
| FD2 | Plain `codex` in a terminal gets no feed answers; Codex answers flow only through an app-server cmux owns (acpmux through codex-acp, or a launch wrapper). Its hooks stay telemetry. |
| FD3 | HttpOnly cookies set during a user sign-in (the duplicate tab D, section 10) are hidden from agent cookie reads (`browser.cookies.get`, `Storage.getCookies`). |
| FD4 | N12 duplication replaces passkeys.md 3.5 rules 1 and 2 (hand over, reload, seal) for feed-driven sign-in and passkey requests. |
| FD5 | sessionStorage copy-back covers the top origin only; no swap fallback. |
| FD6 | App manifest `server.scope: team \| device` and catalog `fallback_owner` (app platform lead). The per-user feed stays on `cloud:FeedDO`. |
| FD7 | No `cmux feed answer` CLI verb until the actor stamp lands. |
| FD8 | Default views: list on Cmd-I, inbox as the wide mode, menu bar opt-in. |

## 1. Summary for agents

- The feed is one per-user list of **items**. An item is a **notice** (no answer) or a **request** (it needs an answer). Agents, harnesses, apps, servers, VMs, automations, integrations and cmux itself post items through one op family, `feed.*`.
- Owner: `FeedDO`, one Durable Object per user (N10). A local feed server (`cmux-feed serve`, the feed app's server in `local` mode, section 4.1) takes new items when the user has no account or the DO is unreachable; on reconnect it hands its items to the DO (section 5). One item has exactly one owner at all times.
- Verbs: `cmux feed request <kind>`, `cmux feed notify`, `cmux feed watch`, `cmux feed cancel`, plus the user's verbs (answer, decline, read, archive, snooze). Kinds: `question`, `choice`, `approve`, `confirm`, `sign-in`, `passkey`, `review`, `input`, `file`, `handoff`, and custom kinds with an inline answer schema (section 3).
- Delivery is decided per client from that client's own view state (do not notify about what the user is looking at). iPhone push is decided by the owner from presence. Posting never moves focus.
- Harness adapters mirror native prompts into the feed and keep the native prompt alive in the terminal. The first answer wins; an answer in the terminal cancels the feed item (section 8).
- Today's notifications (cmux notify, OSC 9/777/99, agent hooks, rings, badges, the Cmd-I panel) become notices in the feed. The daemon notification ledger becomes a producer only (section 9).
- Sign-in and passkey requests open the agent's tab in a temporary user-owned pane to the right (section 10).
- The first-party inbox app is a view on the feed, never a second store. Tasks keeps task state; the feed carries only the attention events (section 11).

## 2. Vocabulary

| Term | Meaning |
| --- | --- |
| feed | one user's ordered set of items (stream `feed:<user>`) |
| item | `fi_…`, one notice or request, with a lifecycle state and a triage state |
| poster | the principal that posts an item, with a poster kind (table in 3.2) |
| kind | the typed shape of an item: prompt schema plus answer schema |
| answer | the value that closes a request; only the user gives it (3.6) |
| waiter | a process blocked in `feed.watch` on an item (an agent, a hook, a script) |
| home | the owner of an item: `cloud` (FeedDO) or `local:<install>` (a daemon's local owner) |
| context | references the item is about: host, workspace, tab, terminal, browser tab, ACP session, task, URL |

## 3. Item model

### 3.1 Fields

| Field | Type | Set by | Notes |
| --- | --- | --- | --- |
| `id` | `fi_` + 20 | owner | derived from the post transaction; stable across a home transfer |
| `home` | `cloud` \| `local:<inst>` | owner | changes only by the handoff op (section 5) |
| `type` | `notice` \| `request` | poster | |
| `kind` | string | poster | `notice` for notices; a registry kind for requests (3.4) |
| `title` | 1-200 chars | poster | one line; the banner title |
| `body` | markdown, 0-4096 chars | poster | larger content goes into attachments |
| `prompt` | object | poster | kind-specific, validated against the kind's prompt schema |
| `answer_schema` | JSON Schema subset | poster | only for custom kinds (3.4) |
| `priority` | `low` \| `normal` \| `high` \| `urgent` | poster | default per kind (3.4) |
| `dedupe_key` | 1-200 chars | poster | 3.5 |
| `thread` | 1-200 chars | poster | groups items, for example one agent session; scoped like the dedupe key |
| `context` | object of refs | poster | `{host, workspace, tab, terminal, browser_tab, acp_session, task, url}`, all optional |
| `attachments` | up to 8 refs | poster | `{id, name, mime, size, sha256, ref}`; bytes in R2 (cloud) or the local store (local); a diff is an attachment |
| `actions` | up to 4 | poster | buttons: `{id, label, style: default\|primary\|destructive, answer?}`; a button with `answer` answers the request with that value; others only open the context |
| `open` | `{action, args}` | poster | what selecting the item opens; only open-style actions (11.1) |
| `mail` | object | integration | mail items only (11.2): connection, account, thread and message ids, labels; never content |
| `expires_at` | ms | poster | requests default to 24 h, notices to 7 days; clamp 10 s to 30 days |
| `poster` | object | owner | `{kind, identity, label, install?, host?, agent?, app?, run?, harness?}` from the authenticated principal plus the poster's declared `label` and `harness` |
| `state` | `open` \| `answered` \| `cancelled` \| `expired` | owner | lifecycle (3.6) |
| `answer` | `{value, by, device, at}` | owner | set once, by the first accepted answer |
| `cancel` | `{reason, by, at, note?}` | owner | reasons: `poster`, `declined`, `answered_elsewhere`, `superseded`, `poster_gone` |
| `read_at`, `seen_at` | ms or null | owner | triage; `seen` = shown in view (3.7), `read` = the user opened or acknowledged it |
| `archived_at` | ms or null | owner | triage ("done") |
| `snoozed_until` | ms or null | owner | triage; the item leaves the active list until then |
| `count` | int | owner | how many posts the dedupe key coalesced (3.5) |
| `revision` | int | owner | per item, increments on every change |
| `created_at`, `updated_at`, `closed_at` | ms | owner | |

Lifecycle state and triage state are separate. A request is open until answered, cancelled or expired. Triage (read, archived, snoozed) is the user's own sorting and never answers anything.

### 3.2 Posters

| Poster kind | Example | Principal | How it posts |
| --- | --- | --- | --- |
| `agent` | Claude Code in a terminal, an ACP agent, chief | install + agent (launch credential) | CLI or MCP through the local daemon |
| `harness` | a hook adapter that mirrors a native prompt | install + agent | `cmux feed hook <harness>` (section 8) |
| `app` | the inbox or usage app, a third-party app | `app:<id>@<version>` | the `cmux` global, scope `feed:post` |
| `server` | a cmux server (SV1), a CI runner, a user's script on a VPS | install (daemon) | HTTP `POST /v1/ops` with the install token |
| `vm` | software on a Cloud VM or the team VM | install (VM daemon) | same API as server |
| `automation` | a Workflow run | `run_…` token | the catalog `env.cmux.feed.*` |
| `integration` | GitHub review request, failing check | the ConnectionDO (system) | DO RPC to FeedDO |
| `system` | cmux itself: `status run` finished (U4), update ready, server health (SV3), terminal OSC notifications | daemon or DO system principal | internal |

### 3.3 Item types

A **notice** has no answer. It may carry open-only actions. It closes when the user archives it, when it expires, or when its poster cancels it (for example the Tasks service cancels "assigned to you" when the task is reassigned).

A **request** needs exactly one answer. Its waiter blocks until the request closes. Every request is answerable from every client (Mac, iPhone, web) unless its kind needs a Mac (sign-in and passkey need the browser pane on the Mac that holds the tab).

### 3.4 Kinds and the registry

Built-in kinds are catalog entries with JSON Schemas (subset of 2020-12 that every generator supports). The owner validates `prompt` on post and `answer.value` on answer.

| Kind | Prompt | Answer value | Default priority | Native parity |
| --- | --- | --- | --- | --- |
| `question` | `{question, suggestions?: [string ≤ 8], multiline?}` | `{text}` | high | free-text questions |
| `choice` | `{questions: [{id, question, header?, options: [{id, label, description?}] (2-8), multi, allow_other}] (1-4)}` | `{answers: {<qid>: {selected: [id], other?}}}` | high | AskUserQuestion |
| `approve` | `{action: {type: command\|edit\|tool\|network\|install\|custom, summary, command?, cwd?, tool?, input?, diff?: attachment id, risk?}, scopes: [once\|session\|always]}` | `{decision: allow\|deny, scope?, reason?, updated_input?}` | high | permission prompts (Claude Code, Codex, OpenCode, ACP `request_permission`) |
| `confirm` | `{statement, confirm_label?, cancel_label?, destructive?}` | `{confirmed: bool}` | high | yes/no |
| `sign-in` | `{origin, url, browser_tab, profile?, reason}` | `{status: signed_in\|cancelled\|failed\|origin_changed}` | high | section 10 |
| `passkey` | `{origin, rp_id?, ceremony: get\|create, browser_tab, reason}` | `{status: completed\|cancelled\|failed\|unavailable}` | high | section 10 |
| `review` | `{subject: diff\|pr\|file\|document\|url\|plan, ref, checklist?: [string]}` | `{verdict: approve\|request_changes\|comment, comment?, notes?: [{path, line?, text}]}` | normal | plan review, PR review |
| `input` | `{schema}` (flat object of string, number, integer, boolean, enum fields; formats email, uri, date) | an object that matches `schema` | high | MCP elicitation forms |
| `file` | `{purpose, accept: [mime or .ext], multiple, max_bytes ≤ 50 MiB}` | `{files: [attachment]}` | high | "give me the screenshot" |
| `handoff` | `{reason, resume_hint?}` with `context` naming what to take over | `{status: resumed\|taken_over\|declined, note?}` | high | "I am stuck, please take over this terminal" |
| `x-<publisher>.<name>` | any object | matches the item's `answer_schema` | normal | custom kinds (apps, scripts) |

Registry rules:
- Built-in kinds live in the catalog (`feed.kinds` read returns them with schemas), so CLI, MCP, Swift and TS get typed builders.
- A custom kind needs no registration: the poster sends `answer_schema`, and the owner validates the answer against it. The generic renderer shows title, body, actions and a form generated from `answer_schema` when it is a flat object.
- Apps can contribute a renderer for their kinds (`contributes.feedKinds: [{kind, render}]`, a scene export). Without the app, the generic renderer is used. A kind name never changes meaning; a new shape is a new kind name.
- A kind declares `needs_mac: true` when only a Mac can answer it (`sign-in`, `passkey`, `handoff` of a Mac terminal). Other clients show it read-only with "Open on <Mac name>".

### 3.5 Dedupe and threads

- `dedupe_key` is scoped to the poster: `(poster scope, dedupe_key)`, where poster scope is the agent principal when present, else the app id, else the install. A post whose scoped key matches an item that is still open (lifecycle open, not archived) does not create a new item. For a notice, the owner updates title, body, context and priority, increments `count`, clears `read_at` and returns the same id with `deduped: true`. For a request, it returns the existing open item unchanged (`deduped: true`), so a hook that restarts after a crash reattaches to the same request instead of asking twice.
- `dedupe_key` is not the idempotency key. The idempotency key makes one transport retry safe; the dedupe key merges separate posts that mean the same thing.
- `thread` groups items from one poster scope for display (for example all requests of one agent session). It never changes lifecycle.

### 3.6 Lifecycle (enforced by the owner's reducer)

```
           post                 answer (user, first wins)
  (none) ───────▶ open ───────────────────────────────▶ answered
                   │  cancel (poster, user "decline", adapter "answered in terminal", superseded, poster gone)
                   ├──────────────────────────────────▶ cancelled
                   │  expire (owner alarm at expires_at)
                   └──────────────────────────────────▶ expired
```

- Answered, cancelled and expired are final. An answer to a closed item is refused with `feed.closed` and the item, so the late device shows "Answered on iPhone 3 s ago".
- Two devices that answer at the same time: the owner serializes them; the first wins.
- Who may answer: only the user, from a user client with origin `user` (Mac, iPhone, web, or the CLI typed by a person). Agents never answer requests, also not their own (no self-approval). `sign-in` and `passkey` are answered only by the Mac app's browser system (3.4, section 10), never by a typed value. Delegation (the rule): an agent may answer a request only when the user delegated exactly that, by a user-origin grant `feed.delegate {grantee: agent principal, posters: [scope selector], kinds: [kind], max_priority, expires_at}` owned by `FeedDO`. The owner then accepts an answer from the grantee when (a) a live delegation covers the item's poster scope and kind, (b) the grantee is not in the item's poster scope (an agent never answers its own request, even when delegated), (c) the kind is not `sign-in`, `passkey` or `handoff` (never delegable), and (d) for `approve`, the action's risk is not `send-external`, `money` or `destructive` unless the delegation names that risk. The answer records `by` (the agent) and `delegation` (the grant id), and the item shows "answered by <agent> for you". Phase 1 ships without delegation: the reducer refuses every agent answer. Until the actor stamp lands (identity spec section 6), the local socket cannot tell a person's CLI from an agent's; the gap is listed in section 16.
- Who may cancel: the poster scope, or the user ("Decline", reason `declined`).
- An open request cannot be archived or snoozed. The user answers or declines it. This keeps a waiter from hanging on an item the user hid.
- Expiry: the owner's alarm closes overdue items with the system op `feed.expire` (deterministic key `expire:<item>:<expires_at>`), never a client.
- Poster gone: when the terminal or ACP session in `context` ends, the session host's daemon cancels the open requests it posted for it (`poster_gone`). A waiter that died does not cancel anything by itself; the item stays open until it expires or the user declines it.

### 3.7 Read and seen

- `seen_at` is set when a client reports the item was in view (its context visible to the user, 7.1) or shown in an open feed surface. Seen items do not push.
- `read_at` is set when the user opens the item, acknowledges it, or (per `feed.dismissal`, same modes as notifications.md) types into the context terminal. Answering a request also reads it.
- The badge counts open requests plus unread notices (setting `feed.badge = requests | requestsAndUnread | none`).

## 4. Ownership

| State | Owner | Role |
| --- | --- | --- |
| items, lifecycle, answers, triage (read, seen, archived, snoozed), dedupe index, per-user push preferences | `FeedDO` (one per user) | single writer |
| items posted while the DO is unreachable or the user has no account | the local feed server (`cmux-feed serve`, the feed app's server in `local` mode, supervised by the daemon; never PTY code) | single writer of its own items until handoff |
| attachment bytes | R2 (cloud), local store (local) | the owner writes the reference |
| presence for push (which client is active and what it shows) | each client, sent as `presence.set` to `FeedDO`; kept in memory, never committed | client view state |
| per-device presentation (banners, sounds, rings, dock badge) | config layer, cmux.json on that machine | owner |
| filters, selection, scroll, layout variant, unsent answer drafts | each client | client view state |
| sign-in/passkey tab handover | the Mac app that holds the browser tab (section 10) | browser runtime owner |
| history beyond the retention window | PlanetScale `cmux-next` projection via outbox (later step) | projection |

Why a separate `FeedDO` and not `UserDO`: the feed has high write volume (read marks, posts) and a large state; `UserDO` holds installs and grants, which must stay small and fast. Both are keyed by the user id. `FeedDO` asks `UserDO` for install and grant checks like `TeamDO` does today.

### 4.1 The feed as a first-party app with a server (N13, coordinator 2026-10-02)

The app manifest's `server` block (`{kind: native, binary, args, catalog, hosts: [team-vm, cmux-server, local], data: durable}`, one host per team runs it, catalog owner `app:<id>`, `owner_for` routes to that host; first example Tasks, tasks.md section 13) applies to the feed like this:

| Data | Scope | Owner | Why |
| --- | --- | --- | --- |
| a user's items, answers, triage, push prefs | per user | `cloud:FeedDO` (N10) | the feed is the path that wakes the user (push to the iPhone); it must not depend on a team VM that pauses when idle (D21) or a cmux server Mac that sleeps; personal accounts have no team host; every device must reach it |
| items a daemon holds while offline or without an account | per user per machine | the feed app's server in `local` mode: `cmux-feed serve` (Rust, `cmux-feed-core` reducer), supervised by the daemon like any server app, `data: durable` in the app data directory | the same supervisor and catalog as server apps; the item's `home` (`local:<install>`) makes each item single-writer even though every machine runs one instance |
| team-scoped feed (later): requests addressed to a team or role ("any admin approves this deploy", first answer wins), shared team notices, team routing rules | per team | the feed app's server on the team host (`app:dev.cmux.feed`, hosts `team-vm`, `cmux-server`) | team data with one writer per team, exactly the server block's model |

Manifest: `dev.cmux.feed` (publisher cmux, first-party, installed by default): `server {kind: native, binary: cmux-feed, args: [serve], catalog: catalog/feed-catalog.json, hosts: [local], data: durable}` for the fallback now, `team-vm` and `cmux-server` added with the team feed; `contributes.paneKinds: [{id: feed, renderer: native}]` (CmuxNextFeed), `statusItems` (menu bar count), `sidebarSections` (open requests), `commands` from the catalog, `feedKinds` renderers; `mcp: {group: feed}`.

`owner_for` per op:

| Op | Routed to |
| --- | --- |
| `feed.post` | `cloud:FeedDO` when the posting daemon's link is up; else `app:dev.cmux.feed@local` on that machine (item home `local:<install>`) |
| item ops (`feed.answer`, `feed.cancel`, triage, `feed.get`, `feed.watch`) | the item's `home` from the client's mirror: `cloud` -> FeedDO; `local:<inst>` -> that machine's feed server (through the host relay for other devices); `owner.moved` redirects to the new home |
| `feed.list`, `feed.counts` | both: FeedDO and every reachable local feed server; the client merges by id |
| `feed.adopt` | FeedDO, called only by a local feed server |
| `feed.team.*` (later) | `app:dev.cmux.feed` on the team host |

Conflicts with the server block, and recommendations:
1. "Exactly one host per team runs an app's server" does not hold for the local fallback: every machine runs one. RECOMMEND a manifest field `server.scope: team | device` (`device` = one instance per user per machine, each the single writer of the entities homed on it), and the feed declares `device` for `local`.
2. The catalog has one `owner` per op. The feed's per-user ops have a primary cloud owner and a per-item fallback owner. RECOMMEND catalog field `fallback_owner: app:dev.cmux.feed@local` plus "route item ops by the entity's home", one rule in `owner_for` (it already must route documents by home, D2).
3. A server app whose host sleeps makes its ops unavailable. Acceptable for Tasks, not for the feed's wake-up path. RECOMMEND per-user feed data stays on `cloud:FeedDO` and the server block is used only for the fallback and team-scoped data.

Size bounds (the engine writes the whole state per commit): at most 500 items in state; at most 200 open requests (`feed.full` beyond, retryable after the user closes some); closed and archived items leave the state after 7 days (`feed.prune`, system op); body 4 KiB; prompt 16 KiB; larger content goes to attachments. Per poster scope: at most 60 posts per minute (`feed.rate_limited`, retryable). A row-level engine variant is a later step shared with other large owners.

## 5. Local owner and handoff

Rules:
1. Every item has one home. A new item goes to `cloud` when the posting daemon has a live link to the DO; otherwise to `local:<install>` of that daemon. A user without an account always posts locally.
2. Clients merge both streams for display: the DO stream and each reachable local owner's stream. An item shows its home ("this Mac only" badge on local items).
3. On reconnect, the local owner hands each local item to the DO:
   a. It marks the item `handing_off` in its own commit. While in that state it refuses ops on the item with `feed.moving` (retryable; the client retries after the move).
   b. It sends `feed.adopt {item}` (the full item, same id) to the DO with the idempotency key `adopt:<item id>`.
   c. The DO commits the item with `home: cloud` (or answers the existing one from its ledger on a retry) and becomes its owner.
   d. On the result the local owner commits `moved {home: cloud}` and from then on answers ops on the item with `owner.moved {home}`. Clients and waiters reroute to the DO with the same id.
   e. If the DO is unreachable or the result is lost, the local owner keeps `handing_off` and retries with the same key on the next connection. The DO's ledger makes the retry safe. It never unfreezes after a send that may have committed.
4. Waiters on the Mac keep their watch through the move: the local daemon follows `owner.moved` and re-subscribes on the DO.
5. Cloud items are read-only while the Mac is offline (U5: nothing queues). An agent that waits on a cloud item keeps waiting; its native prompt in the terminal still works (section 8), and an answer there cancels the item after reconnect.
6. The DO never hands items back to a local owner. Local storage is the fallback, not a second home.

This is single-writer handoff, not a merge: no item is ever writable in two places, so no conflict resolution exists. The TLA+ model `formal/FeedHandoff.tla` checks it (`formal/run-feed-tlc.sh`): at most one owner accepts ops (`SingleWriter`), at most one answer (`AtMostOneAnswer`), a local answer reaches the cloud copy (`NoLostAnswer`), the waiter reports the final answer (`WaiterSeesFinal`), and a started handoff completes despite bounded loss (`HandoffCompletes`). 114 distinct states pass; the NoFreeze mutant (ops accepted while the adopt is in flight) fails `NoLostAnswer`, and the Unfreeze mutant (back to owned on a timeout) fails `SingleWriter`.

Considered and rejected: the posting host as the permanent owner, with the DO as a cache. It lets a user answer an agent on an offline Mac, but VM, server, automation and integration items have no host, the feed would have many owners per user, and ordering, counts and push need one place. The local fallback covers the offline Mac for new items.

## 6. Operations (catalog family `feed`, owner `cloud:FeedDO`, fallback owner `app:dev.cmux.feed@local`; both serve the same ops)

| Op | Class, risk | Who | Result | CLI | MCP |
| --- | --- | --- | --- | --- | --- |
| `feed.post` | mutation, mutate-own | any principal with `feed:post` | `{item, deduped}` | `cmux feed notify`, `cmux feed request <kind>` | `feed_notify`, `feed_request` (default) |
| `feed.answer` | mutation, mutate-own | user clients, origin `user` | `{item}` | `cmux feed answer <id> --json '<value>'` | never |
| `feed.cancel` | mutation, mutate-own | the poster scope or the user | `{item}` | `cmux feed cancel <id> [--reason]` | `feed_cancel` (default; own items only) |
| `feed.read` | mutation, mutate-own | user clients | `{items}` | `cmux feed read <id…>\|--all` | never |
| `feed.seen` | mutation, mutate-own | user clients | `{items}` | none (exempt: view report) | never |
| `feed.archive`, `feed.unarchive` | mutation, mutate-own | user clients | `{items}` | `cmux feed archive <id…>` | never |
| `feed.snooze` | mutation, mutate-own | user clients | `{items}` | `cmux feed snooze <id…> --until <time>` | never |
| `feed.prefs.set` | mutation, mutate-own | user clients | `{prefs}` | `cmux feed prefs set …` | never |
| `feed.adopt` | mutation, mutate-own | installs (local owner handoff) | `{item}` | none (internal to the daemon) | never |
| `feed.expire`, `feed.prune`, `feed.snooze_wake`, `feed.push_due` | internal (system) | the owner's alarm | | none | never |
| `feed.list` | read | user clients; posters see their own items | `{items, revision}` | `cmux feed list [--open] [--kind] [--json]` | `feed_list` (own items only) |
| `feed.get` | read | user clients; the poster | `{item}` | `cmux feed get <id> --json` | `feed_get` (own items) |
| `feed.watch` | stream | user clients; the poster | events until the item closes | `cmux feed watch <id> [--timeout]`; `request … --wait` | `feed_request` with `wait: true` |
| `feed.counts` | read | user clients | `{open_requests, unread, by_priority}` | `cmux feed counts --json` | never |
| `feed.kinds` | read | anyone | registry with schemas | `cmux feed kinds --json` | default |

CLI exit codes (for agents): 0 answered (the answer JSON on stdout), 2 usage, 3 declined or cancelled, 4 expired, 5 timed out (the item stays open; `watch` again, never post again), 6 owner unreachable (nothing was posted; fall back to the native prompt).

Events: each committed op is one event with the op and its params (the engine's mirror-replay form), plus the resulting item in the result. Waiters subscribe to `feed:<user>` filtered by item id (server-side filter, so an agent never receives other items).

Agents see only their own items: `feed.list`, `feed.get` and `feed.watch` from a non-user principal are filtered to the caller's poster scope. A mux sees items of the agents it spawned (later, with delegation records).

HTTP and WebSocket: the generic `POST /v1/ops` and `/v1/read` endpoints carry every op; OpenAPI at `/v1/openapi.json` publishes the schemas (the catalog export). `GET /v1/wire/feed` is the WebSocket (`cmux.wire/1`) for subscriptions. A VM posts with one curl:

```
curl -s https://cloud-api.cmux.dev/v1/ops -H "authorization: Bearer $TOKEN" \
  -d '{"op":"feed.post","idempotency_key":"build-42","params":{"type":"notice","kind":"notice","title":"Build 42 failed"}}'
```

## 7. Delivery

### 7.1 Visibility heuristic (per client, no owner involvement)

An item is "in view" on a client when all hold: the app is active, a window that shows the item's context is key and not occluded, the context (terminal, tab, browser tab, ACP session) is the selected tab of a visible pane, and the user gave input to the app in the last `feed.inViewIdleSeconds` (default 60). A context-free item is in view only while a feed surface is open and shows it.

In view: no banner, no sound, no ring animation; the client sends `feed.seen`. A notice in view is also read per the dismissal mode (notifications.md rules 1 and 2 carry over). A request in view is seen but stays open: the user sees the native prompt in that terminal.

### 7.2 Presentation per client (cmux.json on that machine)

`feed.desktop` (`unlessInView` default, `always`, `whenInactive`, `never`), `feed.sound`, quiet hours, muted posters and workspaces, per-kind and per-priority overrides, the attention ring (notifications.md visuals carry over, driven by unread items whose context is that pane), dock badge mode. Every key has a Settings row, a cmux.json key, a docs entry and a default test.

### 7.3 iPhone push (owner decides)

On post (or snooze wake) of a push-eligible item, the owner sets a push deadline: urgent 0 s, high 20 s, normal 120 s, low never (`feed.prefs.push.delay.*`). At the deadline (`feed.push_due`, owner alarm), it pushes only if the item is still open (requests) or unread (notices), not seen, and no Mac client of the user reported `active` presence in the last 120 s (the user is at the desk and got the Mac banner), unless the item is urgent. Answer actions in the push (Allow/Deny, choice options) call `feed.answer` from the iPhone with origin `user`. Push delivery is an external effect after commit: the owner commits the decision (`feed.push_due`), then its wake sends to the user's iOS push targets (owned by `UserDO`: only an iOS install registers, topics limited to the cmux apps, a revoked install's tokens are released) through APNs from the Worker (ES256 provider token, collapse id = item id, category `FEED_<KIND>` for answer actions, payload cut under 4 KB, mail items carry no content). Delivery is at most once (decided): a send that fails after the commit is logged, not retried, because a late push for a request that may be answered by then is worse than none; a `push.send` outbox with retries can come later if dogfood shows lost pushes. A send never fails the owner's wake.

### 7.4 Focus

Posting, answering from another device, expiry and cancel never change focus, selection or scroll on any client. Selecting an item (click, Return, palette, notification click) is a user action: it reads the item and opens its context with focus (origin `user`). `cmux feed open <id>` from the CLI opens the context only with `--focus`.

## 8. Harness adapters

### 8.1 Contract (one helper, never block the agent)

`cmux feed hook <harness>` (Rust CLI) reads the harness's native event on stdin, maps it to `feed.post` (type request) with a dedupe key, waits with `feed.watch` up to a deadline, prints the harness's native reply and exits 0. The native prompt in the terminal stays alive in parallel: the first answer wins.

- No feed owner reachable, connect slower than 300 ms, deadline passed, item cancelled or expired: print the native "no decision" output (`{}` for Claude Code and Codex hooks, no reply for OpenCode and ACP, `undefined` in the pi race). The harness then shows or keeps its own prompt.
- Deadline: 115 s inside a 125 s hook timeout (the old app's proven values); configurable `feed.hooks.waitSeconds`.
- Dedupe key: `<harness>:<session>:<native id>`, so a hook that runs twice for the same prompt joins the same item.
- Content: the adapter posts the full prompt (command, question, options, diff as an attachment). The daemon's agent journal keeps redacting these fields; the feed owner is the only store of prompt content.
- Custom harnesses use `cmux feed request <kind> --dedupe-key K --wait --timeout S --json` (exit codes in section 6), the `feed_request` MCP tool, or HTTP.

### 8.2 Per harness

| Harness | Pending signal | Answer path | Answered in the terminal | Native id |
| --- | --- | --- | --- | --- |
| Claude Code | synchronous `PermissionRequest` hook (separate from the async journal hooks, 125 s timeout); `Elicitation` hook for MCP forms | hook stdout `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow\|deny","updatedInput"?,"updatedPermissions"?,"message"?}}}`; AskUserQuestion: allow with `updatedInput` that echoes `questions` and adds `answers {question text: label}` (multi-select labels joined by commas); ExitPlanMode: allow or deny with message; Elicitation: `{"action":"accept\|decline\|cancel","content":{…}}` | no hook reports it; supersede rule: a later `PreToolUse` (not AskUserQuestion or ExitPlanMode), `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, `Stop` or `SessionEnd` of the same session cancels the open item with `answered_elsewhere`; a dead agent pid cancels with `poster_gone` | `sha256(tool_name + canonical tool_input)` (PermissionRequest has no tool_use_id) or `elicitation_id` |
| Codex | app-server server requests `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request` | JSON-RPC reply `{decision: accept\|acceptForSession\|decline\|cancel}`, `{answers}`, `{action, content}` | `serverRequest/resolved {threadId, requestId}` to every subscriber | `threadId` + `itemId` |
| OpenCode | `permission.asked`, `question.asked` (SSE `/event` or plugin `event`) | `POST /permission/:id/reply {reply: once\|always\|reject}`, `POST /question/:id/reply {answers}` | `permission.replied`, `question.replied`, `question.rejected`; a `reject` cascades to the session's other requests, so the adapter cancels those too | `per_…` / `que_…` id |
| pi | the cmux pi extension's `tool_call` handler (pi has no own approval prompt) | return `{block: true, reason}` or continue | `Promise.race` between `ctx.ui.select(…, {signal})` and the feed watch; the loser is aborted or cancelled | `toolCallId` |
| ACP agents (acpmux) | `_acpmux/permission_pending` (`session/request_permission`) | `_acpmux/permission_respond {sessionId, permissionId, optionId, answers?}` | `permission_decision` event; `cancel_pending_permissions` on stop | `permissionId` |

Kind mapping: permission prompts become `approve` (Claude Code `permission_suggestions` become the `session` and `always` scopes; Codex `acceptForSession` is `session`); AskUserQuestion, Codex `requestUserInput` and OpenCode questions become `choice` (or `question` for free text); ExitPlanMode becomes `review` with subject `plan`; elicitation forms become `input`; elicitation with a URL becomes `sign-in`.

### 8.3 Gaps and changes needed

- Codex answers from the feed only when cmux owns the app-server (acpmux through codex-acp, or a launch wrapper). A plain `codex` in a terminal with its embedded server gives no outside answer path; its hooks stay telemetry. DECISION in the report.
- cmux-tui installs Claude Code hooks async with a 5 s timeout today (observe only). The installer adds one synchronous `PermissionRequest` and `Elicitation` entry.
- The OpenCode and pi hook templates in `cmux-tui/crates/cmux-tui/assets/agent-hooks/` gain the reply and race logic.
- acpmux mirrors pending permissions into the feed and answers through `_acpmux/permission_respond`. This is the cleanest path: no hook process and no deadline.
- The Swift compat `feed.push` (`CompatFeed.swift`) answers `timed_out` at once today; it routes to the feed owner once the Rust CLI verb exists.

Live finding: `sr claude` drops hooks passed with `--settings`; project or user `.claude/settings.json` hooks load. UNVERIFIED (read from docs and source): whether Claude Code shows its dialog while a `PermissionRequest` hook still runs; `updatedInput.answers` for AskUserQuestion in interactive mode (the old app ships it); whether the `Elicitation` hook delays the dialog; whether a second Codex app-server client receives requests that were pending before it subscribed.

## 9. Migration of today's notifications

| Today | In the feed |
| --- | --- |
| `cmux notify`, `notification.create` (v1/v2) | `feed.post {type: notice, kind: notice, context: caller terminal}`, poster `agent` or `system`; the old verbs stay as aliases |
| OSC 9 / 777 / 99 parsed by the daemon | the daemon posts notices with poster kind `system`, label the program name, context the terminal, dedupe key `osc:<terminal>:<hash>`; Ghostty's rate limits stay in the daemon |
| agent hooks (`feed.push`, `agent_journal_append` attention events) | harness adapters (section 8); attention events that need no answer become notices; `agent-status` on the tab stays the session host's agent record |
| attention ring, tab unread marker, sidebar unread dot | derived on each client from unread items whose context is that pane, tab or workspace; no second unread flag |
| dock badge | `feed.counts` |
| Cmd-I notifications panel | the feed panel (prototypes, section 12) |
| `ack-tab-notifications`, Mark Read verbs | `feed.read` on the items of that tab |
| `status run` done notice (U4) | `feed.post` notice from the daemon, context the terminal |

Steps: (1) bridge: the daemon's `notify` path also posts the notice to the feed owner; the app keeps today's ledger; (2) the app reads rings, badges and the panel from the feed mirror; (3) the daemon ledger stops keeping read state (producer only), and `ack-tab-notifications` becomes `feed.read`. Step 3 changes a daemon protocol and needs the daemon owners (COORDINATION.md line).

## 10. Sign-in and passkey requests (N12)

### 10.1 Feasibility per engine (code and docs read; nothing run live)

| Mechanism | CEF | WebKit |
| --- | --- | --- |
| (a) copy cookies and storage into another profile | partial: HttpOnly and SameSite cookies copy through `cmux_shim_import_cookies`; partitioned cookies do not (`cef_cookie_t` has no partition key); no IndexedDB write path; the session must be copied back. Rejected. | partial: `getAllCookies` includes HttpOnly; batch `setCookies` needs macOS 26; no public localStorage or IndexedDB copy. Rejected. |
| (b) hand the live tab to the user and back | works (`cmux_tab_move_to_window` keeps the WebContents) and keeps in-memory state, but agent shims stay in the page until a reload, the login POST stays in history and the back/forward cache, and the tab must stay sealed for its lifetime, so the agent loses evaluate. Rejected. | works (a WKWebView moves like any NSView); same taint and seal problems. Rejected. |
| (c) new user-owned tab, same profile, copied history and sessionStorage | **recommended.** Chromium `NavigationController` clone copies history with page state (scroll, form fields; password fields are never saved) and a sessionStorage snapshot; cookies, localStorage, IndexedDB and service workers are shared by the profile. In-memory JS state is lost (the copy reloads). | **recommended, prototyped** (`plans/cmux-next/feed/prototypes/webkit-duplicate`, 26/26 checks). Same `WKWebsiteDataStore` shares cookies (HttpOnly stays HttpOnly), localStorage and service workers; `interactionState` (macOS 12) carries history and scroll, NOT the current page's form values (WebKit saves them only when a page leaves memory) and NOT sessionStorage; a one-shot app-private seed script writes sessionStorage before page scripts run. Two traps: a restored POST entry is sent again without a prompt (a restore-phase guard must cancel main-frame POST and load the last GET page), and `WKWebViewConfiguration.copy()` shares A's script controller (D needs a fresh one). |
| (d) a second live view of the same renderer | impossible: a WebContents has one view; a screencast mirror is not interactive and WebAuthn needs the real WebContents `VISIBLE` (K16). | impossible: an NSView has one superview. |

Verdict: CEF feasible with one fork export (`cmux_tab_duplicate`, requested from the browser lane); WebKit proven in a prototype with public API plus an app-private seed script, a POST guard and a fresh script controller. The passkey ceremony in D stays UNVERIFIED until a signed build.

### 10.2 Flow

1. The agent posts `feed.post {kind: sign-in | passkey, prompt: {origin, url, browser_tab: A, reason}}` (or the browser host does it for `sites.browserAuth.request`). The browser host pauses the agent's lease on tab A (`paused_for_user`): agent calls on A are refused until the request closes.
2. The user selects the item (user action). The Mac that holds A creates tab D in the same profile, with no lease:
   - CEF: new fork export `cmux_tab_duplicate(browser_id, window_browser_id, index) -> browser_id`: a WebContents in the same profile, a new BrowsingInstance, no opener, history from the sanitized API 10 serialization (drops POST bodies and SiteInstances), sessionStorage from a clone of A's namespace at creation, inserted without activation, current entry reloaded. Not `IDC_DUPLICATE_TAB` (it activates the tab in A's window and shares A's SiteInstance and opener).
   - WebKit: a new WKWebView with a fresh `WKUserContentController` (no agent scripts), `D.interactionState = A.interactionState`, and A's top-origin sessionStorage written by a document-start script in an app-private content world.
3. D opens in a temporary pane to the right of A's pane (focus moves to D because the user asked). D is visible (K16); the passkey sheet anchors to D's window (K10). Password fill is on in D (new WebContents, not agent-marked); WebAuthn mode `allow` in D while A stays `refuse` (passkeys.md 3.5). CEF: the app (never the agent) calls `Network.setBypassServiceWorker` on D so a service worker the agent registered cannot see the login POST. WebKit has no per-view bypass: the app removes service-worker registrations for that origin that appeared during the lease.
4. The user signs in or approves the passkey in D. The password and the passkey assertion stay in D's renderer, the engine's authenticator code and the request to the site.
5. The user clicks Done (or cmux sees D back on A's site and offers Done). The app copies D's top-origin sessionStorage (CEF: DevTools `DOMStorage` through `cmux_shim_devtools_call`; WebKit: the private world), closes D, and navigates A with GET to D's final URL with that sessionStorage. The app answers the item `{status: signed_in}` (or `completed` for a passkey); the lease resumes. Cancel closes D and answers `cancelled`.
6. A reloads for function, not security: A never held a credential, so A is not sealed. D's history (which holds the login POST in memory) is never moved into A.

Where things end up: password and assertion only in D and the site; D may save the password in the agent profile's password store, which agents cannot read; session cookies in the agent profile's cookie jar (intended: that is how the agent continues).

What the agent can read after: the page in A as the signed-in site shows it, and (the remaining gap) cookies through `browser.cookies.get` and `Storage.getCookies`, which return HttpOnly session cookies. The raw CDP relay must refuse `Target`, `Network`, `Storage` and `ServiceWorker` domains for agents (CEF's DevTools client is trusted, so `Target.attachToTarget` would otherwise reach D). Screen-capture agents can see D on screen unless D's window sets `sharingType = none` (UNVERIFIED that it hides a child page window).

### 10.3 Open points

- Decided (FD3): HttpOnly cookies set during a user sign-in are hidden from agent cookie reads.
- Decided (FD4): this section replaces passkeys.md 3.5 rules 1 and 2 for feed-driven sign-in.
- Decided (FD5): copy-back covers the top origin only; sites that keep tokens in other-origin iframes are not covered.
- UNVERIFIED (live prototype, step F7): history restore into a new BrowsingInstance with sessionStorage at creation on CEF 154; `setBypassServiceWorker` covering D's navigations; `DOMStorage.setDOMStorageItem` into an origin A has not loaded; WebKit document-start ordering; a POST entry restored in D; the passkey sheet over D on a signed build; automatic "done" detection.

## 11. Boundaries with the inbox app, email and Tasks

### 11.1 Lane 3's inbox requirements (first-party-apps.md section 9) against this design

| Requirement | Answer |
| --- | --- |
| id `feed_…` | `fi_…` (built). The stream is `feed:<user>`; an item id that starts with the family name reads like a stream. Conflict, low stakes. |
| kind `notify` / `request <kind>` / `watch` | `type: notice\|request` plus `kind`. `watch` is a verb (`feed.watch`), not a kind. |
| urgency, `needs_response` | `priority`; `needs_response` is derived (`type == request && state == open`) and is a `feed.list` filter. |
| source `{kind, id, name}` | `poster {kind, scope, label, install, agent, harness}`; kinds add `user` (built). |
| subject refs `{machine, workspace, tab, terminal, browser, agent, url}` | `context {host, workspace, tab, terminal, browser_tab, acp_session, task, url}`; same refs, catalog names. |
| thread key, dedupe key | built (3.5). |
| status with `done` | lifecycle (`open`, `answered`, `cancelled`, `expired`) and triage (`read_at`, `seen_at`, `archived_at` = done, `snoozed_until`) stay separate, because an open request cannot be done (3.6). |
| response schema, recorded response | built-in kinds: JSON Schemas of prompt and answer from `feed.kinds` (built); custom kinds: `answer_schema` on the item; `answer {value, by, device, at}` (built). |
| actions `{id, title, kind}`, open target `{action, args}` | `actions [{id, label, style, answer?}]` plus `open {action, args}` limited to open-style actions (`tab.focus`, `workspace.focus`, `browser.open`, `browser.duplicateRight`, `url.open`, `task.open`, `acp.session.open`, `app.open`), so a poster can never make a click close or run something (built). |
| owner computes order, groups, counts | built: `feed.list {order: urgent\|recent, group_by: thread\|poster\|workspace, needs_response, poster_kind, workspace, query, after, limit}` returns items in the owner's order, groups and a cursor; `feed.counts` adds `by_poster_kind`. |
| `feed.mark {items or filter, state}` | separate verbs with distinct risks and CLI names: `feed.read`, `feed.seen`, `feed.archive`, `feed.unarchive`, `feed.snooze`; `feed.read` and `feed.archive` take `items`, `all` (read) or `filter` (built); a filter archive skips open requests. Conflict: verb names. |
| owner fires snooze wake-ups | built (alarm, `feed.snooze_wake`). |
| `feed.changed {revision, changed[], counts}` on every change | the wire carries one op event per commit (mirror replay form). The client mirror and the app host derive `feed.changed` from it (the mirror runs the same reducer, so it knows the changed ids and the counts). No second event type on the wire. |
| `feed.respond`, origin user, never MCP for agents | `feed.answer` (built, origin `user`, `mcp: never`), plus the delegation rule above. Conflict: verb name. |
| `feed.cancel` poster only | poster, plus the user's Decline (reason `declined`), so no waiter hangs on an item the user rejects. Conflict. |
| scopes `feed:read`, `feed:write`, `feed:respond` | `feed:read`, `feed:write` (derived from risk `mutate-own`: post own items and triage, D43), `feed:answer` (restricted, first-party, origin user). |
| registry actions `tab.show`, `browser.duplicateRight` | `tab.focus` already exists in the app operation router (reveal and focus with origin user); no new `tab.show`. `browser.duplicateRight {tab}` is new (browser lead plus step F7): the section 10 duplicate, user origin, `focuses: true`. The inbox calls `feed.openItem {item}`, which runs the item's `open` target, and for `sign-in` and `passkey` items the full handover (lease pause, duplicate, answer), never a bare duplicate. |
| read state the same on all devices; host sets `client_id = app:<id>` for app calls (accepted by Lawrence) | read state is per user in `FeedDO`, so it is the same on every device for every caller. App calls carry actor `app:<id>`; the owner records it in the ledger and in `answer.by`. |

### 11.2 Email in the feed (Lawrence, 2026-10-02)

Email is a feed source. There is no separate inbox store.

Conflict with decision S2 ("never store email; keep only message, thread and history ids"): a feed item that shows a subject and a snippet stores email content. RECOMMEND ids-only items: the item keeps `mail {connection, account, thread_id, message_ids (latest 20), history_id, labels, provider_unread}`; title, participants and snippet are fetched live through the integration gateway (`mail.threads.peek {ids}`, batched for the visible rows) and cached in client memory only; the iPhone push text is fetched at send time and never committed. Alternative (needs Lawrence): store `from`, `subject` and a 200-character snippet for the item's lifetime (7 days after archive). DECISION in the report.

Item model: type `notice`, kind `mail` (a built-in notice kind), `thread = mail:<connection>:<thread id>`, `dedupe_key = mail:<connection>:<thread id>` (a new message in the thread updates the same item: `count` grows, the item becomes unread and returns to the active list), poster kind `integration`, `context.url` the provider's web link, `priority` from rules (important or primary: normal; other categories: low; `feed.mail.rules` customizes by label, sender and category). Full bodies are never stored: opening the item fetches the thread (`mail.thread.get`) and renders sanitized HTML in an isolated web view (no remote images by default). Attachments are handles (`mailatt_…` = connection, message id, attachment id), downloaded through the gateway (`mail.attachment.get {handle}`) by a user client; agents need the integration scope.

Accounts: connected through the integration flow (`integration.connect {provider: gmail}`), OAuth in a host-owned browser flow; tokens sealed in `ConnectionDO` (existing KEK sealing); apps and agents see a connection id and secret handles only (lane 3 R5), never a token. Gmail first (scopes S3: readonly, send, modify; CASA S1). Outlook through Microsoft Graph later. IMAP and SMTP later through the feed app's server on the team host (IMAP IDLE needs a persistent connection), with the app password entered in a host secure sheet and kept as a sealed secret handle.

Sync: inbound by provider push (Gmail Pub/Sub watch to our webhook, then `ConnectionDO` reads the history diff and sends `feed.post`, label and read changes to `FeedDO` as integration ops); a server-side scheduled history check only as fallback (S2). Outbound: triage on a mail item is also a provider effect: `feed.archive` removes `INBOX`, `feed.read` removes `UNREAD`, `feed.mail.label {item, add, remove}` changes labels. The owner commits the triage with `mail_sync: pending` and an outbox effect; `ConnectionDO` applies it with its own idempotency key; the result is a second op (`feed.mail.synced {item, ok}`); a failure reverts the triage and shows the error; a lost result is `mutation.indeterminate`, settled by a history read, never a guess. The provider is the system of record for mail state: a change made in the provider's web app arrives by push and wins. Feed snooze is cmux-only (the provider API has no snooze). Offline: the client refuses mail ops while it cannot reach the owner (U5); provider outages are retried server-side after commit.

Reply and compose are feed actions with risk `send-external`: `mail.reply {item, body, reply_all, attachments: [handles]}` and `mail.compose {connection, to, cc, subject, body, attachments}` run only with origin `user`. An agent drafts (`mail.draft.create`) and posts an `approve` request ("Send this reply?", the draft as an attachment); the user's allow sends it. Agents never send mail without that answer or a delegation that names `send-external`.

Build: after F3 (ids-only items and the gateway peek op with the integrations lead and lane 3).

### 11.3 Inbox app and Tasks

Inbox app (lane 3): a view on the feed. It reads `feed.list` and live feed events and triages with `feed.read`, `feed.archive`, `feed.snooze`. It keeps no item store and no snooze state. Integration work items (review requested, check failed) are posted to the feed by the integration gateway (poster kind `integration`, dedupe key per PR or check) and cancelled by it when resolved. Scopes: `feed:read`, `feed:triage`, `feed:post` (own app items), and the restricted `feed:answer` (first-party only; answers come from user taps in host-rendered scenes with origin `user`).

Tasks: the Tasks service owns tasks, assignment and the "Assigned to you" group. The feed carries only attention events about tasks: "Leo assigned you T-123" is a notice posted by the Tasks service with dedupe key `task:<id>:assigned` and `context.task`; the Tasks service cancels it when the task is reassigned or done. An agent working a task that waits for input posts a request with `context.task`; the Tasks pane shows `attention: needs_input` from its own session record and links to the feed item. Badges count feed items only, so nothing counts twice.

## 12. Surfaces and prototypes

Every op and action is on every surface or has a reasoned exemption (check-action-surfaces.sh).

| Action | Palette | Shortcut | CLI | MCP | Right-click |
| --- | --- | --- | --- | --- | --- |
| `feed.show` (toggle the feed panel) | Show Feed | Cmd-I (replaces Show Notifications) | `cmux feed show` (exempt guiOnly) | exempt | sidebar background |
| `feed.openItem` | per item ("Open: <title>") | Return in the panel | `cmux feed open <id> [--focus]` | exempt (focus) | item row |
| `feed.answerItem` (choice of the item's actions) | per item | per action number in the panel | `cmux feed answer` | never | item row |
| `feed.decline` | per item | Delete in the panel | `cmux feed cancel <id>` | never | item row |
| `feed.archive`, `feed.snooze`, `feed.markRead`, `feed.markAllRead` | yes | Cmd-Shift-U jumps to the oldest open request | yes | never | item row |
| `feed.jumpToLatestRequest` | Jump to Latest Request | Cmd-Shift-U | exempt focusMove | exempt | none |
| `feed.toggleMenuBarItem` | Show Feed in Menu Bar | none | `cmux feed menubar on\|off` | never | menubar item |

Prototypes (Debug Settings, DEV/NIGHTLY; module `CmuxNextFeed` with a mock source):
- `feed.layout = list`: one chronological list, requests pinned on top with inline answer controls (choice chips, Allow/Deny, a reply field), notices below with read dots.
- `feed.layout = inbox`: two panes: a grouped list (Needs you, Today, Earlier, by thread) on the left and the selected item's detail with full prompt, diff attachment and answer form on the right; Done, Snooze, Decline in the toolbar.
- `feed.menubar = compact`: an NSStatusItem with the open request count; a popover with the open requests only, one-line rows with the primary answer buttons, "Open feed" at the bottom.
Screenshots and the recommendation are in section 15 when built.

## 13. Build steps

| # | Step | State |
| --- | --- | --- |
| F1 | Owner: `FeedDO`, `feed.*` ops in the cloud catalog, pure reducer with lifecycle, dedupe, expiry, triage, limits; reducer property tests; DO tests (ledger replay, events, alarms); shared conformance vectors for the local owner | this branch |
| F2 | CLI and MCP verbs (Rust CLI owner, requests in the report); generated MCP tools from the catalog | requested |
| F3a | App mirror over `FeedDO` (`CloudFeedSource`, `FeedService`), Cmd-I list panel, `feed.request`/`feed.cancel`/`debug.feed` control methods; FeedDO live events carry the changed items | #16855 |
| F5a | Prototype Claude Code adapter `scripts/cmux-next/feed-hook.py` (stand-in for `cmux feed hook`); proven live: Claude Code's PreToolUse hook -> app -> FeedDO -> user answer -> allow or deny with reason | #16855 |
| F8a | Push targets on UserDO + Worker-native APNs sender called from FeedDO's push decision | feat-cmux-next-feed-push |
| F7a | WebKit duplication prototype | #17033 |
| F3 | Mac: `CmuxNextFeed` module (model mirror + intent log, three prototypes, mock source), app wiring to the DO stream and the local owner, actions and settings | next |
| F4 | Local feed server (`cmux-feed-core` Rust reducer passing the same vectors, `cmux-feed serve` supervised as a server app, `feed.adopt` handoff, `formal/FeedHandoff.tla`) | after F1 review |
| F5 | Harness adapters (`cmux feed hook claude-code\|codex\|opencode\|pi`, acpmux `request_permission` bridge) | after F2 |
| F6 | Migration steps 1 to 3 (section 9) | after F3 |
| F7 | Sign-in and passkey handover (section 10) | after the browser host lease work |
| F8 | iPhone: push sender, iOS feed list, answer actions in pushes | iOS lane |
| F9 | Email as a feed source (11.2): ids-only mail items, gateway peek, triage effects, reply and compose actions | with the integrations lead and lane 3 |
| F10 | Delegation (`feed.delegate`, 3.6) | after the actor stamp |

## 14. Settings (cmux.json, Settings > Feed)

`feed.desktop`, `feed.sound`, `feed.quietHours`, `feed.mutedPosters`, `feed.inViewIdleSeconds` (60), `feed.dismissal` (`keystroke`), `feed.badge` (`requestsAndUnread`), `feed.attention.*` (ring, from notifications.md), `feed.layout` (prototype switch), `feed.menubar` (`off`), `feed.requestDefaults.expiry` (24 h). Owner-side (synced, `feed.prefs.set`): `push.enabled` (true), `push.delay.{urgent,high,normal,low}` (0, 20, 120, never), `push.skipWhenMacActive` (true).

## 15. Prototype screenshots and recommendation

Module `CmuxNextFeed` (#16829, 53b07a31f3c): model mirror + intent log (`FeedModel`, `FeedIntent` with idempotency keys), `FeedSource` protocol, `MockFeedSource`, views `FeedHostView` (list, inbox) and `FeedMenubarHostView`, tunables `feed.layout` (`list` default, `inbox`) and `feed.menubar` (`off` default, `compact`), 25 tests (intent log, a late answer shows "Answered on iPhone", no queueing while disconnected, inbox groups, menu bar filter, choice validation, a 30-seed convergence test). Not yet linked into the app: `FeedTunables.all` joins `TunableCatalog` and the app wires a `FeedSource` to `FeedDO` in step F3.

Screenshots (light and dark, from a demo executable; in the hq checkout under `artifacts/feed-prototypes/`, not committed): list, inbox, compact menu bar, empty menu bar. They predate the second commit, which fixed a blank inbox row (two open requests of one session shared a row id) and a clipped menu bar height.

Recommendation:
- `list` as the default Cmd-I panel: inline answers clear most requests in one click, and it fits a side panel.
- `inbox` as the expanded mode: the only variant that shows a full diff and a plan review with a comment.
- `compact` menu bar as an opt-in: quick Allow/Deny while cmux is in the background; long titles truncate at 360 pt.

Known issues: in light appearance the demo's glass backdrop over a dark desktop lowers label contrast in the menu bar (a real `NSPopover` draws its own material; check in the app); a single-question single-select choice answers on one tap (fast, but a wrong click answers).

## 16. Risks, gaps, shortcuts

- Actor stamp gap: until the daemon stamps the launch credential on every request, an agent on the same Mac can call `feed.answer` through the control socket as if it were the user. The owner refuses answers from agent principals as soon as the stamp exists; until then `feed.answer` is not an MCP tool and the CLI prints a warning when `CMUX_TUI_TERMINAL_ID` is set.
- Whole-state commits bound the feed size (section 4).
- Push needs the APNs sender (iOS lane) and presence frames on the DO gateway.
- Cloud items are read-only on an offline Mac; the native prompt is the fallback.

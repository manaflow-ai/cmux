# Remote state ownership: what lives where, and why Cmd+D must not wait

Status: APPROVED by the chief with amendments (section 0), 2026-10-09, hq-ff lane. Base: feat-cmux-next
64d57f35a20f; app measured: Release `cmux DEV ffperf1` (tree 4ff26ee0d050).
Ask (Lawrence, 2026-10-09): "i feel lag when i do cmd+d, we need it to be instant. typing indicator
needs to respect my local theme too. agent chat on remote workspaces needs to work too. and feel
instant. think about what state should live where, what should own what state."

This file applies OWNERSHIP-PRINCIPLES.md (binding), layer-ownership.md (binding) and
zero-latency.md to remote workspaces. It does not replace them. Where they already decide a point,
this file cites them. It adds: the measured cost of Cmd+D local and remote, the owner of each piece
of state for a workspace on another machine, the remote agent chat transport, and the slices.

## 0. Decisions and amendments (chief and coordinator, 2026-10-09)

These override the text below where they differ.

- A1 (D10, decided by the chief, Leo informed; recorded on https://github.com/manaflow-ai/cmux/issues/13742):
  the user's own Mac app that reaches a remote acpmux through its own daemon over SSH gets
  LocalApp-equivalent rights, except folder choice outside the workspace roots. Rationale: SSH
  authenticates the same user to their own machine, and the daemon sees a same-uid local client.
  This does not apply to shared or team machines: team VMs keep the team policy.
- A2 Client-minted ids are namespaced per client: client id + UUIDv7. The daemon validates
  uniqueness and rejects an id in another client's namespace. A remote client can never mint into
  another client's namespace.
- A3 Accept-first durability: accept means "applied in memory, journaled in the next batch". After a
  crash between accept and commit, the client reconciles from the owner's journal and shows a
  one-line notice when an optimistic pane vanished. Test T4b covers it.
- A4 The app pushes its theme on connect and on every theme change; the terminal host answers OSC
  queries from the input-owning client's colors. S5 also fixes the hardcoded dark first frame of the
  agent pane.
- A5 The agent install offer on an SSH machine runs only on a user click, never automatically. No
  local-agent fallback by default.
- A6 The daemon starts acpmux on the remote machine (open decision 2 closed).
- A7 S2 reuses the accept-first design of https://github.com/manaflow-ai/cmux/pull/11784 and ports
  only what split and new-tab need.
- A8 Each slice reports its numbers against the budgets B1 to B6.
- A9 (coordinator, 2026-10-09): the federation daemon half is not superseded by this design; it is slice S9, after S1.
- Process: CORE slices land one at a time; the coordinator requests each token from a gated SHA.
  Before S6 the coordinator sends this doc to Leo. This doc lands with the first slice.

## 1. Measurements

Hosts: m1max (Lawrence's M1 Max, load 20 to 60 from other agents' jobs during the run, so local
numbers are pessimistic) and aws-m4pro-1 (M4 Pro, idle, ec2-user@100.106.216.105, scratch daemon
in `~/ffre-scratch-ffre2`, deleted after). Network m1max to aws-m4pro-1: ICMP RTT 66 ms, one warm
daemon request over the SSH carrier 67.5 ms p50. Tools: a raw daemon client that repeats the app's
request sequence (`split`, `list-workspaces`, new connection `identify` + `set-client-info`,
`attach-surface`), `CMUX_TUI_DEBUG_SPANS` in the daemon, and the Release app driven by
`action.run splitRight` on its control socket with `log stream --signpost` (the app's own `stalls`
signposts). 12 to 15 runs per row. Scripts: hq `.cmux-scratch/ffre/` (split_bench.py, app_bench.py,
sp_parse.py).

### 1.1 Cmd+D, app path (ms after the split request, p50, Release app on m1max)

| Stage | Local workspace | Remote workspace (SSH, aws-m4pro-1) |
| --- | --- | --- |
| key dispatch + app action (KeyRouter -> PaneHandlers.split, sync main thread) | not measured in Release (no debug verbs); by code under 1 ms, UNVERIFIED | same |
| daemon `split` round trip ends, store starts resync (`daemon.snapshot_start`) | 79 (54 to 149) | 174 (140 to 202) |
| resync `list-workspaces` ends (`daemon.snapshot_end`) | 86 | 257 |
| new pane view + Ghostty surface exist (`createSurface`) = pane visible on next frame | 89 | 261 |
| terminal attach starts (new socket connection) | 105 | 274 |
| terminal attach ends (replay applied) = first terminal frame with content | 106 | 511 (436 to 587) |
| budget (this doc, 3.1) | pane in 1 frame (8.3 to 16.7) | pane in 1 frame; content when PTY ready |

### 1.2 Daemon side (raw client, p50 / p95)

| Stage | m1max local (loaded) | aws-m4pro-1 on host (idle) | m1max -> aws-m4pro-1 over SSH link |
| --- | --- | --- | --- |
| `split` reply | 143 / 307 | 79 / 98 | 147 / 206 (= 79 + 1 RTT) |
| `list-workspaces` resync | 1 / 15 | 0.3 / 0.5 | 67 / 98 (1 RTT) |
| new connection: stream open + `identify` + `set-client-info` | 2 / 20 | 0.2 / 0.4 | 137 / 173 (2 RTT) |
| `attach-surface` reply | 1 / 23 | 0.2 / 0.2 | 67 / 94 (1 RTT) |
| sum (the app's critical path) | 147 | 83 | 435 / 521 (5 RTT + daemon) |
| shell first output after attach | 740 (user zsh, loaded host) | 31 | arrives with the attach reply |

Inside `split` (daemon spans, per split, p50 on the idle M4 Pro): 6 SQLite commits with
`synchronous=FULL` + `fullfsync` at 4.4 ms each (26 ms), host publication 4 ms, terminal host
process ready 8 ms, bootstrap 13 ms, launch 15 ms, reply queued 6 ms. Total 79 ms. On the loaded
m1max the same steps are 5.6 ms per commit and 62 ms of host start: 138 ms. A cold new connection
over the link answered its first request in 200 to 1100 ms in a separate probe.

### 1.3 Root causes of the Cmd+D lag

1. No optimistic layout for a split. `PaneHandlers.split` (`CmuxNextApp/Handlers/PaneHandlers.swift:61-96`)
   sends `split` from a detached task. The pane exists only after the daemon reply, its
   `layout-changed` event and a full `list-workspaces` resync (`DaemonStore+Events.swift:212`). The
   `Intent` log (`CmuxNextDaemon/Store/Intent.swift`) has `createTab` with a provisional tab but no
   provisional pane.
2. The daemon replies to `split` only after the whole creation pipeline: 6 fullfsync commits,
   fork/exec of `__terminal-host`, two handshakes (`mux/resource_topology.rs:3636-3762`,
   `mux/surface_spawn.rs:48-182`). Split does not adopt the prewarmed spare host; only `new-tab` does
   (`server/terminal_create.rs:70,124`). This breaks the accept-first law of
   hq `plans/cmux-tui-zero-wait-interaction.md` (IX2/IX3 are not on this branch).
3. Every `layout-changed` forces a full `list-workspaces` resync: one more round trip.
4. Every terminal view opens its own connection (`TerminalAttachment.swift:96-175`). Over the link
   that is a new mux stream (`cmux-remote/src/bridge.rs:174-200`, waits for `opened` on all lanes),
   then `identify` + `set-client-info`, then `attach-surface`: 3 sequential round trips.
5. Focus waits for the split reply (`expectFocus(on: created.surface)`), so the user cannot type into
   the new pane before step 1 ends, even locally.

Remote total: 5 sequential network round trips plus the remote daemon's 79 ms. Every one of them
sits between the key and the visible pane or its content. Nothing on the path is CPU-bound in the
app: the app's own work (resync apply, view and surface creation) is about 3 ms.

Harness finding: `action.run splitRight` with `wait:true` returned before the new pane was in the
store in 3 of 5 local runs (`created: []`). The wait does not cover the handler's detached task.
Automation that waits on it races.

### 1.4 Typing indicator and theme (measured)

OSC queries from a program in the terminal, answered by the terminal host:

| Query | Local workspace (m1max, Ghostty theme "dark:Monokai Classic") | Remote workspace (aws-m4pro-1) |
| --- | --- | --- |
| OSC 10 (fg) | `rgb:fdfd/ffff/f1f1` (local theme) | no answer |
| OSC 11 (bg) | `rgb:2727/2828/2222` (local theme) | no answer |
| OSC 4;1 (red) | `rgb:f9f9/2626/7272` (local theme) | `rgb:cccc/6666/6666` (Ghostty built-in default) |

Root cause: the terminal host answers color queries with the defaults of the daemon's own machine
(`config.rs:3324` `ghostty_application_defaults()`; `--owner-host-fg/bg` exists but the app never
passes it; `DaemonConnection.setDefaultColors` has no caller; `main.rs:3092` "Remote sessions keep
their server-side defaults"). The local daemon happens to read the same Ghostty file as the app, so
local looks right; app-level overrides (`appearance.*`, room/workspace/terminal themes) are never
sent to any daemon. A program in a remote terminal (Claude Code, Codex, the acpmux TUI) cannot see
the local background, picks its light/dark styling and explicit RGB colors for spinners, "working"
and typing rows from wrong or missing answers, and the Mac draws those explicit colors as given.
The app's own indicators already use the local theme: the agent pane typing/Thinking row
(`webviews/src/agent-session/acpmux/direct.ts:1193`, `conversation.css:518-540`, variables from
`AgentPaneTheme.swift`), the Home typing bubble (`CmuxHomeRender` `typingDot` from
`HomeThemePalette.resolveInScope`), the tab and sidebar dots (`StatusIndicatorLayer.swift:36-41`).
One gap there: the agent pane's first frame uses hardcoded dark CSS (`shared/styles.css:7-28`)
until the host pushes the theme. Not confirmed: which indicator Lawrence saw; the remote terminal
agent is the case that matches "remote".

### 1.5 Agent chat in a remote workspace (tried)

`palette.newAgentChat` on a pane of the SSH workspace: the tab record is created on the remote
daemon (`kind: conversation`, `cwd: null`, `agent_session: null`); the page connects to the LOCAL
acpmux (`localApp=true`, home `~/.acpmux/tags/ffperf1` on the Mac); its first frame
`_acpmux/harnesses` is refused with `transport.path_invalid` because the remote cwd
(`/Users/ec2-user`) is not a local path. The chat cannot list harnesses or start. Code:
`AgentTabs+Lifecycle.swift:29-39` (no `daemon.isLocal` check, `host: localHost`),
`AgentTabs.swift:242-258` (local acpmux), `AcpmuxPathPolicy.swift:160,197` (local realpath).
Existing remote path: `agent-session-attach-v1` (remote-agent-attach.md, G2) streams and types into
a session that ALREADY runs in the remote machine's acpmux, through the tab's daemon. Nothing starts
acpmux or a session on a remote machine. GPUI has no remote chat either (cmux2-0b: docs/agent-tabs.md
sec. 7). Cost today: a chat keystroke is page-local (0 round trips; draft to localStorage and a
non-awaited `_acpmux/draft_set`); a send is one page->host message plus one acpmux frame; on the G2
remote wire it is one daemon request over the link, and `draft_set` is refused there.

Not measured: a Cloud (Freestyle) machine. The shared dev backend was at 76/88 running stacks with
disk-pressure evictions, and my Release app had no backend. The Cloud link is the same
`cmux-tui remote connect` over `--wireguard-hub` (`CloudMachineLink.swift:106-115`), so the round
trip count is the same 5; the RTT per trip is not known. UNVERIFIED.

## 2. Ownership: who owns each piece of state, where it lives

Roles from OWNERSHIP-PRINCIPLES.md: session host (processes), workspace store (layout record),
client (view). For a remote workspace the session host and the workspace store both run in the
remote machine's cmux-tui (its daemon is the single writer of that workspace). The client is the Mac
app. "Remote" never changes who presents: presentation is always the client's.

| State | Owner (single writer) | Lives | Client behaviour | Network on the gesture path |
| --- | --- | --- | --- | --- |
| Layout: split tree, panes, tabs, tab order | workspace store of the daemon that hosts the workspace | that daemon's registry + journal | mirror + intent log; split, move, close are intents applied in the input frame through the Rust layout reducer (L4) | none; confirm async |
| Split ratios, column widths, row heights | workspace store | registry | drag is local continuous state; the release is one intent (rows-v1 `setRowHeights` pattern); even sizing travels inside the `split` op, not as a second request | none |
| Focus, selected tab, zoom, key window, scroll | client (this install) | client memory; per-install view record in the store when tools must read it | changes in the input frame; never waits for a reply | none |
| Window frames, sidebar width, window to workspace mapping | client (this install) | per-install window record (per-record CAS) | local | none |
| Terminal PTY, process, cwd, title, exit, scrollback, canonical grid | session host on the machine that runs the shell | that machine | Ghostty mirror fed by attach; typeahead queued per terminal id until the PTY is ready | one attach, not on the frame path |
| Terminal colors used to answer OSC 4/10/11/12 | client theme (presentation); daemon stores only what the client pushed | client config; pushed to each attached daemon as a per-client value | push at attach and on every theme change; daemon answers from the input-owning client's set | async push |
| Agent processes, sessions, transcripts, permissions, queue | acpmux on the machine where the workspace's files are (remote for a remote workspace) | `$ACPMUX_HOME/sessions` on that machine | page renders events; never starts the agent on the wrong machine | send = 1 request; render pending row in input frame |
| Tab <-> agent session binding | workspace store (`agent_session_tabs`) | daemon of the workspace | intent (`createTab` provisional, `bindConversationTabSession`) | none |
| Composer draft text | page (live text) + acpmux session record (durable copy) | page memory; acpmux `composer_draft` on the agent's machine | echo in the keystroke's frame; debounced non-awaited `draft_set`, also over the remote wire | none |
| Browser tab record (URL revision, title) | workspace store | daemon of the workspace | intents | none |
| Browser runtime (page, history stack) | the Mac that shows it (decision 2026-10-01) | local Chromium; remote localhost via the link's forward | local | page load only |
| Theme, appearance, fonts, motion | client config layer (presentation) | Mac config | never read from a remote daemon | none |
| Keybindings | client config layer | Mac cmux.json / Ghostty config | resolved locally | none |
| Typing indicator / agent working state | the fact: acpmux (turn open) or session host (presence of attached clients); the colors: client theme | fact on the machine; colors local | render the fact with local tokens | event only |
| Presence of attached clients | session host | machine | render | event only |

Rules this adds for remote workspaces:

- R1. A local gesture never waits on the network. The app commits the visible result in the input
  frame from its mirror plus the intent; the owner confirms or rejects later. This is
  OWNERSHIP-PRINCIPLES "Clients are projections" applied to creation, not a new mechanism.
- R2. Creation uses client-minted ids. The client mints the pane key, the tab key and the
  `terminal_id` (UUID) and sends them in the op. The owner adopts them (idempotency key = op key).
  The provisional pane and the confirmed pane are the same id, so reconciliation is a fold, not a
  match. Today only `terminal_id` exists (`terminal-placement-env-v1`).
- R3. A link down is not "slow": when the owner is unreachable the intent is refused in the input
  frame with the disconnected state (OWNERSHIP-PRINCIPLES "nothing queues"). Optimism applies only
  while the link is up. A link that drops with intents in flight: the intents stay visible as
  pending; on reconnect the client resends only those intents with the same keys; an owner reject
  or a timeout (5 s, the current spawning deadline) reverts exactly and shows the reason in the pane.
- R4. Presentation never crosses the link in the server-to-client direction. Theme, fonts, keys,
  motion, window state are read only from the client's config. The only presentation data that
  crosses the link goes client-to-server, and only where a remote program must read it (terminal
  color answers).
- R5. The machine that owns the files owns the processes that act on them: PTYs and agents for a
  remote workspace run on that machine. The Mac never runs an agent against a remote cwd.

## 3. Design

### 3.1 Cmd+D (local and remote use the same path)

Frame N (key-down):
1. KeyRouter -> `splitRight` -> handler mints `pane_key`, `tab_key`, `terminal_id`, `op_key`.
2. `store.intend(.splitPane(target, axis, ratio, newPane: pane_key, newTab: tab_key, terminal:
   terminal_id))`. The visible layout = mirror + intents, computed by the Rust reducer through
   `cmux-layout-reducer-ffi` (L4; RustSidebarClient is the precedent). The new pane's view and
   Ghostty surface are created now; the surface shows a "starting" state (machine name for a
   remote pane) on the theme background.
3. Focus moves to the new pane in the same frame (client-owned). Keys typed into it go to a
   per-terminal typeahead queue (bounded, ordered; order law of the zero-wait plan).
4. The op is queued to the owner. The frame ends. Nothing above awaits.

Async:
5. The owner validates against its state, assigns revision, publishes the tree delta and replies at
   acceptance (accept-first): no fsync and no process start before the reply. The terminal sits in
   the tree as `launching`. Durable commit and host launch run after the reply on the effect
   executor; split adopts the prewarmed spare host as `new-tab` does.
6. The client applies the delta (no `list-workspaces` resync for a delta that carries the
   transaction) and the intent leaves the log on its echo.
7. The attach for `terminal_id` is sent at step 4 on an already-open attach channel, pipelined after
   the op on the same link (attach-identity-v1 with `expected_terminal_id`; the daemon holds the
   attach until the terminal is ready instead of refusing it). When the PTY is ready the replay
   arrives, the "starting" state is replaced, and the typeahead queue flushes in order.

Remote cost after this design: 0 round trips to visible, focused, typeable pane; 1 round trip plus
host start (about 66 + 30 ms on aws-m4pro-1) to shell output, instead of 5 round trips + 79 ms.

Budgets (latency tests in 4):
- B1 key-down to new pane drawn and focused: within the input frame or the next (2 frames, 16.7 ms at
  120 Hz, 33 ms at 60 Hz), local and remote. Target 1 frame.
- B2 key-down to keystroke accepted into the new pane: same frame as B1.
- B3 daemon `split` reply (accept stage): p99 under 5 ms on the host, zero fsync on the request thread.
- B4 local: key-down to first terminal content under 50 ms on an idle machine (spare host + attach).
- B5 remote: key-down to first terminal content under 1 RTT + 50 ms.
- B6 chat: keystroke echo in the input frame; send shows the pending user row in the input frame.

Strongest expert objection: "An optimistic pane lies. A split that the owner refuses (no room, pane
gone, another client closed it) appears and then disappears; with two clients the trees diverge for
one RTT." Answer: refusals of a split are rare and are pre-checked locally against the same reducer
(the `splitRoom` check already runs in the handler); a reject reverts exactly because the base never
contained the intent, and the pane shows the reason for 1 s where it was. Divergence for one RTT is
inherent to any remote multi-writer UI; the owner serializes, and invariant 4 (projection
convergence) is model-checked in `formal/OwnershipConvergence.tla`. The alternative, waiting, costs
every user 5 RTT on every split to spare a rare user one reverted pane.

Second objection: "Client-minted ids let a buggy or hostile client choose ids that collide." Answer:
UUIDv4 keys are scoped per workspace and checked for uniqueness by the owner, which rejects a
collision as `idempotency.conflict`; the existing `frontend_browser_tab_keys` and
`conversation_tab_keys` already work this way.

### 3.2 Terminal attach channel

One long-lived attach channel per daemon connection (multiplexed attaches on the control link, or a
pool of pre-opened streams), instead of one new socket per view. This removes the stream-open round
trip and the `identify` + `set-client-info` round trip for every pane. Objection: "one channel
couples a slow terminal to the others (head-of-line)". Answer: the link already has lanes
(interactive, bulk); each attach keeps its own bounded backlog and snapshot fallback
(`terminal-snapshot-v1` already replaces a slow viewer's backlog with a READY), so a slow terminal
gets a snapshot, not a stall of its neighbours. A pre-opened pool of 2 streams is the smaller first
step if the multiplex is too large.

### 3.3 Theme in remote terminals and the typing indicator

- The app pushes its resolved colors (fg, bg, cursor, 256-color palette, light/dark) to every daemon
  it attaches, per client, at attach and on every theme change, including room, workspace and
  terminal overrides (the color set of the terminal's scope).
- The terminal host answers OSC 4/10/11/12 from the set of the client that owns input for that
  terminal (the client that sent the last input; same tie-break as the size policy), else the
  daemon's config defaults.
- acpmux TUI derives its shimmer and colors from the terminal's answered background, not from
  `COLORFGBG` and hardcoded RGB (`acpmux/src/tui/theme.rs:125-203`).
- The agent pane's first frame gets the theme variables injected before first paint (user script at
  page creation), so no hardcoded dark fallback shows.
- Fonts: the agent pane gets the local font family through the same theme message.

Objection: "Two clients with different themes share one terminal; a program asks once and caches
the answer, so one client sees colors chosen for the other." Answer: that is true and unavoidable
for a shared PTY; the input-owning rule matches the user who is typing, which is the user who sees
the result of the program's choice. Programs that re-query on SIGWINCH or focus (Claude Code does on
focus-in) follow the switch. Palette indexes still render with each client's own colors.

### 3.4 Agent chat in a remote workspace

Where things run: acpmux runs on the machine that owns the workspace (R5), started and supervised
by that machine's cmux-tui daemon (cmux-tui already links acpmux: `cmux acp`; layer-ownership.md
plans acpmux in-process, cx-ncc.27). The agent process, its cwd, files, transcript and session list
are on that machine. The daemon owns the tab <-> session binding (as today). The page owns live
draft text; acpmux owns the durable draft.

Transport: extend the existing G2 path, not a new one. Page -> `AgentPaneTransport` (method allowlist,
gestures) -> `RemoteAcpmuxWire` -> `AgentSessionAttachClient` -> the tab's daemon over the link ->
daemon `agent-session-*` verbs -> the machine's acpmux unix socket. Add the verbs a new chat needs:
session create in the tab's workspace cwd (`agent-session-new`, harness/model/effort from the
picker, cwd resolved on the machine), harness and model catalog (`_acpmux/harnesses`), `draft_set`,
set_mode/config. Every frame passes `cmux-agent-pane-policy::check_frame` on the Mac (as today) and
again in the daemon (the daemon is the trust boundary on the machine). The daemon starts acpmux on
first use if no acpmux listens on its socket. The new verbs are served only to trusted local (Unix)
connections, as the G2 verbs are: they are not added to the remote relay allowlist
(`remote_relay/gate.rs`, default deny), and the PR carries the relay analysis and policy tests
required by the repo's "Remote CLI relay" rule (session-scoped ids, no command-bearing params).

Routing in the app: `AgentTabStore.open` picks the host by the pane's machine (`machines.daemon(for:)`,
one code path), never `localHost` for a remote pane; the folder picker for a remote pane browses the
machine through the daemon's `fs.*` ops, never the local NSOpenPanel.

Instant feel: keystrokes are page-local (0 round trips, already true). Send: the page shows the user
row as pending in the input frame (the store's "row made without an event" exists), then one daemon
request over the link; acpmux's `_acpmux/prompt_accepted` settles it. Typing indicator row appears
on `turn_started` from the machine, drawn with local tokens.

Open policy question (D10, acp-remote-guard.md): the app reaching a remote acpmux through its own
daemon over the user's SSH identity is the user's own LocalApp-equivalent client, not a Web client.
Today the daemon-side link would carry origin `remote`, which hides Send for Codex and opencode.
Proposal: a daemon-relayed connection from a trusted local (Unix) client of the remote daemon gets
the LocalApp rights except folder choice outside the workspace roots; needs Leo's and the chief's
decision.

Objection: "Running agents on the remote needs the harness installed and signed in there (claude,
codex auth on every SSH machine)." Answer: correct, and that is the honest model: the agent must run
where the files are, or every tool call becomes a remote file round trip. Cloud images already ship
claude/codex/opencode/pi (bake v5). For SSH machines the chat shows "Claude Code is not installed on
<machine>" with an install action, the same flow as the cmux-tui install. A local-agent-with-remote-
files mode is a later option, not the default.

### 3.5 Browser tabs (no change in principle)

Record in the workspace's daemon, runtime on the Mac (decision 2026-10-01), service routed per pane
machine (cx-2cob slice 1a). New browser panes use the same provisional split path as terminals.

## 4. Tests (red first)

| Test | Layer | What it proves | Budget |
| --- | --- | --- | --- |
| T1 `SplitIsProvisionalTests`: fake daemon answers `split` after 300 ms; assert the new pane is in the visible layout, focused, and its surface accepts a key before the reply | Swift (CmuxNext, fake connection) | R1, B1, B2 | pane in layout before any await |
| T2 `SplitFrameBudgetTests`: same fake, measure key-down to `layoutView` commit with the frame clock | Swift | B1 | 1 frame, fail above 2 |
| T3 reducer property test: provisional split + random interleaved remote ops + reject/accept converges (invariant 4); ids from the intent equal ids in the echo | Rust `cmux-layout-reducer` proptest | R2, convergence | n/a |
| T4b `crash_between_accept_and_commit`: kill the daemon after the accept reply and before the journal batch; on restart the client reconciles from the journal, the optimistic pane is gone and the one-line notice shows (A3) | Rust cmux-tui-core + Swift store | A3 | n/a |
| T4 `split_replies_before_host_ready`: reply arrives while the host is still launching; zero fsync on the request thread (writer assertion); split adopts the spare host | Rust cmux-tui-core | B3 | p99 < 5 ms on a CI host |
| T5 `attach_waits_for_launching_terminal`: attach by `expected_terminal_id` sent before the terminal exists completes when it is ready | Rust cmux-tui-core | 3.1 step 7 | n/a |
| T6 link round-trip count: through `cmux-remote` loopback with an injected 50 ms delay, key-to-content for a split costs at most 1 delayed round trip | Rust cmux-remote integration | B5 | <= 1 RTT + 50 ms |
| T7 typeahead order: keys typed during `launching` arrive in order after the replay | Rust + Swift | order law | n/a |
| T8 OSC answer follows the client theme: push colors, query OSC 10/11/4 from inside a remote terminal, compare | Rust cmux-tui-core host test | 3.3 | n/a |
| T9 agent pane first frame has theme variables before paint (WebKit snapshot, no dark flash on a light theme) | webviews test | 3.3 | first frame |
| T10 remote agent chat: page in a remote pane lists harnesses and creates a session through the daemon; acpmux on the remote host starts; no local acpmux frame | Rust daemon test + Swift routing test | 3.4 | n/a |
| T11 chat send pending row in input frame (latency harness, mock host answers after 40 ms) | webviews latency harness | B6 | 1 frame |
| T12 end-to-end bench (this doc's scripts): local and remote, Release, budgets B1, B4, B5 as a non-blocking scoreboard | fleet/m1max | all | scoreboard |

## 5. Slices and tokens

CORE = cmux-tui-core, cmux-tui bins, spec, bindings, protocol, Cargo.lock. Frozen without a token:
pbxproj, Package.swift, action catalog, settings. LINK = cmux link / cmux-remote carrier.
ACPMUX = acpmux (Leo's lane). CATALOG and SETTINGS are not needed by any slice below.

| Slice | Content | Areas / tokens | Tests | Depends |
| --- | --- | --- | --- | --- |
| S0 | Bench scripts into `scripts/cmux-next/` (split_bench, app_bench with signpost parse); fix `action.run` wait to cover the split task | none (scripts); Swift ControlRouter fix: no token | T12, red: wait race | none |
| S1 | Daemon: client-minted, per-client-namespaced (A2) pane and tab ids on `split`/`new-pane` (capability `split-client-keys-v1`; S9 applies the same ids to `new-remote-terminal-tab` and detached create), even-ratio param in the op, split adopts spare host | CORE | T3 (keys), T4 (spare) | none |
| S2 | Daemon: accept-first for split/new-tab (reply at acceptance, `launching` in tree, effects after reply); attach waits for a launching terminal | CORE (overlaps zero-wait IX2/IX3; reuse #11784's design, do not fork it) | T4, T5, T7 | S1 |
| S3 | App: `Intent.splitPane` with provisional pane via `cmux-layout-reducer-ffi`, local focus, typeahead per terminal id, "starting" surface state, no resync on transaction-tagged delta | Swift CmuxNext (no frozen file if the FFI target exists; else Package.swift token) | T1, T2, T7 | S1 (keys); works before S2 with a slower confirm |
| S4 | Attach channel: pre-opened stream pool, then multiplexed attaches | LINK + CORE (`cmux-remote` bridge) | T6 | S2 |
| S5 | Theme push: per-client colors to every daemon, OSC answers from the input-owning client; agent pane first-frame theme; font in theme message | CORE + Swift + webviews | T8, T9 | none |
| S6 | acpmux TUI colors from the terminal's answered background | ACPMUX (Leo review) | acpmux unit test | S5 |
| S7 | Remote agent chat: daemon supervises acpmux on its machine; `agent-session-new`, harness/model catalog, `draft_set`, mode/config over the G2 wire; daemon-side `check_frame`; app routes by pane machine; remote folder picker via `fs.*` | CORE + ACPMUX (Leo review) + Swift | T10, T11 | D10 decision |
| S8 | Cloud: run T12 and T10 against a Freestyle machine on an own-tag dev stack | none | T12 | S3, S7 |
| S9 | Federation daemon half (cx-wb5.2, branch feat-cmux-next-federation-tui-r22): `new-remote-terminal-tab` / `update-remote-terminal-tab` / `remote-terminal-snapshot` (remote-terminal-tabs-v1), `create-terminal {detached:true}` (detached-terminals-v1), terminal.project/move tree-changed. A port of its 15 commits onto the tip, red tests first; the Swift half is already on feat-cmux-next. Uses S1's namespaced client ids for the tab and the detached terminal | CORE | its own red tests + T3 | S1 |

Leo must review for acpmux: S6 (theme detection), S7 (acpmux started by the daemon: home, socket,
lifetime, upgrade; new session-create path through the daemon; `draft_set` from a relayed client;
the origin and rights of a daemon-relayed trusted client vs D10's Web rules).

## 6. Decisions (closed)

All five open decisions of the first draft are closed in section 0 (A1, A6, A4, A5, A7).

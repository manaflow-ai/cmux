# cmux next: ownership design (session host, workspace store, client)

Detailed design under the binding rules in OWNERSHIP-PRINCIPLES.md (that file wins on
conflict). Counts are from `origin/feat-cmux-next` a548b67d7a8. Model: "the server owns
the session, the client owns the view" (peterp.org/blog/terminal-multiplexers.html),
adapted for one laptop, many Mac minis and many Cloud VMs.

## Summary

1. Three roles. A **session host** runs on every machine with terminals and owns PTYs, processes, output, the canonical grid, ordered and attributed input, and presence; it knows no layout. The **workspace store** is per user and owns the arrangement (windows as records, workspaces, columns, panes, tabs that reference sessions on any host, browser tab records, pins, groups, spaces, history). The **client** (Mac app, iPhone, TUI) owns view state and renders.
2. Single writer per entity: the owner applies typed ops through a pure reducer; everyone else is a mirror plus one log of pending intents settled by transaction echo or reject.
3. Not strict projection, each with a named owner: client view state (the client; persisted only in its own window record), browser runtime (the hosting Mac app, which alone writes the browser record), preferences (config layer), terminal geometry (session host arbitrates client claims), gestures (local until their commit intent).
4. The store has one sequencer per document. Synced documents are sequenced by a Cloudflare Durable Object (user decision); each device's local store is a replica that forwards ops. Whether a document may stay local-only (editable offline) is open for the cloud spec lead. Replicas never accept writes on their own.
5. Mac minis and Cloud VMs run session hosts only for this user's Mac. Their own TUI users get a store on that machine, so the same terminal can be arranged differently by each viewer.
6. Remote CLI and agent layout verbs (`cmux pane split` inside a VM terminal) become layout intents: the session host forwards them to every store that places that terminal, and each store applies them once by idempotency key.
7. Offline (user decision): nothing queues. While an owner is unreachable every change to its entities is refused and the client shows the disconnected state; on reconnect the client resends only intents it had sent before the disconnect (same keys, the ledger dedupes).
8. App inventory: 65 optimistic sites, 54 with no patch, 60 never settled by op id, 31 never send the op id; 11 second copies of shared state, 5 can drift; 6 per-client facts written as shared; one window document that two Macs overwrite.
9. Daemon inventory: one commit choke point with an exactly-once ledger, but about 156 layout entry points, a client echo on one event kind, terminal death by direct callback (inferred on host loss), shared focus written by single clients, no reducer, proptest or model.
10. TLA+ (`formal/OwnershipConvergence.tla`, companion to the landed `TabLayout.tla`): two clients, intent logs, reordered, duplicated and lost messages, disconnect, reconnect, owner restart, commit before publish, client-owned records. TLC passes every safety invariant (5,680,649 states) and liveness `EventuallyConverged` (1,785,780 states); seven mutants each fail, including today's drop-at-next-snapshot (`PendingVisible`), publish-before-commit (`NoLostAck`) and trusting a client-sent owner (`RecordSingleWriter`).
11. Agreed with PR 16174 (session feat-cmux-next-99): the store is built on `cmux-tui-core::state`; window records are one row per `(install_id, window_id)` with an owner field and per-record compare-and-swap; `mutation-echo-v1` uses an opaque tag (keyed hash of client id and idempotency key) set centrally in the dispatcher plus `request-settled` for every request.
12. Steps (section 7), each shippable alone with a failing test first: ownership.md and TLA+; pure layout reducer crate with proptest and kani; `mutation-echo-v1`; authenticated client identity per connection with owner-checked single-writer records; app mirror plus one intent log; daemon-owned workspace lifecycle; session host / store split after PR 16174 lands.
13. Decisions (section 8): all answered: Durable Objects sync hub, account directory discovery, TUI closes emptied workspaces, each Mac renders its own Chromium, nothing queues offline, smallest attached viewer sets the canonical grid with a presence list and kick.

## 0. Agreements and related plans

- PR 16174 (`feat-cmux-next-acpmux`, session feat-cmux-next-99; plans `cli.md` and
  `state-ownership.md`) makes the Rust cmux-tui binary the `cmux` CLI, deletes the Swift
  CLI and `CmuxNextControl/Compat`, and puts 51 typed v2 state operations behind
  `cmux-tui-core::state` (no PTY or session code). That module is the workspace store's
  base. Kept: its consistency contract (a CLI mutation returns only after every later
  read sees it, idempotency keys end to end, `after` read barrier), public ids for every
  object, routing by owner. It already fixed three principle violations: browser zoom
  goes through an app action, the daemon closes ephemeral workspaces at start, and
  `workspace.create {ephemeral}` is atomic.
- Agreed with that session: per-window selection and focused pane are client owned and
  published to the client's own window record (2.1); `mutation-echo-v1` uses an opaque
  tag (3).
- The tab-loss agent owns the typed LayoutOp, the daemon conservation check, its
  proptest and `formal/LayoutConservation.tla`; step 2 builds the pure reducer from its
  LayoutOp. The sticky-column lead adds `sticky` to columns through LayoutModel's
  transaction override (migrates in step 4). The federation branch adds remote-terminal
  tab rows and detached kept terminals (the store's "tab referencing `{host, terminal}`").
- data-model.md 1 (sessions, home session, personal state) is superseded where it puts
  shared layout on a remote home session: layouts live in the user's store, never on a
  Mac mini or Cloud VM.

## 1. Ownership table

| Entity | Role and owner | Writers (send ops) | Readers | Persistence | When the owner is unreachable |
| --- | --- | --- | --- | --- | --- |
| PTY, process, exit status, cwd, title, git branch, OSC progress | session host on the machine that runs it | clients and CLIs attached to it | every viewer | host process, registry | refuse ops; show last snapshot and "reconnecting" |
| Output record and checkpoints (bounded, per-session opt-out) | session host | none (derived) | viewers, search, agents | replay today (10 MiB); durable transcript is new | read the last snapshot |
| Canonical grid size | session host (sizing reducer; default policy: smallest attached viewer wins) | viewport reports from each attached viewer | viewers (each renders its own viewport of the grid) | memory | n/a |
| Input order with attribution | session host | each attached participant | session host journal | journal | refuse; never queue keystrokes |
| Presence, kick-off, revive | session host | connections, `set-client-info`; any attached user may kick a client | viewers (presence list of every client) | memory | the kicked client shows "disconnected by X" (the old cmux screen) |
| Notifications, unread, agent state | session host (terminal-derived) | hooks, agents; viewers ack | viewers | registry | refuse (nothing queues) |
| Workspaces, screens, columns incl. sticky, splits, panes, tab order, tabs referencing `{host, terminal}` | workspace store | local app, CLI, TUI; remote agents via layout intents | every client of that store | store registry + journal | the local store is always reachable |
| Workspace identity (name, color, icon), tab names, pins, tab groups | workspace store | same | same | same | same |
| Browser tab record (placement, URL with revision, title, profile, zoom, short history) | workspace store | any app showing the tab: `browser.navigate` with `expected_revision`, page info for the current URL revision only; user ops (move, close) | clients (each Mac's page follows the URL) | store | same |
| Spaces, workspace groups and order, saved groups, closed history, keep-layout records, session registry, browser profiles | workspace store (personal) | local app, CLI | clients | store | same |
| Window records (workspaces per window, selected tab per pane, focused pane, frame, sidebar) | the owning app install (client view state), stored as one row per `(install_id, window_id)` in the store | that install only (owner field, per-record CAS) | that app; CLI, TUI, iOS read | store | n/a (local) |
| Remote-terminal tab snapshot (at most 64 KiB of text the app last showed of a remote terminal) | the app install that showed it: per-client view cache, single-writer record (today on the home store's `remote_terminal_tabs` row via `update-remote-terminal-tab`; owner field added with the v2-ops follow-up) | that install only | that app | store | shown labeled as a stale cache; never terminal output, never replayed as output; live output replaces it once the host answers |
| Focus, key window, strip scroll, drag, hover, omnibar draft, palette query | client memory | that client | that client | none | n/a |
| Chromium runtime (page, live URL, history stack, loading, page focus, devtools) | the Mac app hosting the page | that app | that app | engine store per browser profile | n/a |
| cmux.json, themes, keys, accounts | config layer on that machine | user, settings UI | the app | file, Keychain | n/a |

## 2. Cases that are not strict projection

1. Client view state. The client owns it. Other tools read it only from the client's own
   window record, which only that client writes (2.1).
2. Browser runtime. Each Mac that shows a browser tab runs its own Chromium page (user
   decision 8.4); the page's live state is that Mac's. The store's browser record stays
   single-owner (the store): navigations are ops from any showing app, title and favicon
   updates are accepted only for the current URL revision, and each page follows the
   record's URL.
3. Preferences. Owned by the config layer of each machine; never synced through the store.
4. Terminal geometry. The session host owns one canonical grid; by default the smallest
   attached viewer sets it (user decision), and every viewer renders its own viewport
   (crop, pan, scale). A presence list shows every attached client, and any user can kick
   a client, which then shows "disconnected by X".
5. Gestures. A drag, divider resize or strip scroll is local continuous state; only its
   commit becomes an intent. A reject animates back.
6. Launch snapshot. A read-only provisional mirror drawn before connecting, replaced in
   place, never written back.

### 2.1 Window records

One row per window keyed `(install_id, window_id)`, an `owner` field equal to
`install_id`, and compare-and-swap per record. Only the owning install writes a row; the
store refuses a write whose `owner` differs. The CLI, TUI and iOS read rows and change
what a window shows only by asking that app (`cmux tab <id> focus` is app scope). The
daemon's shared `active*` fields stay defaults for clients with no window and are never
written by ordinary UI focus. The CLI's `current` resolves, in order: the caller's own terminal
(`$CMUX_TUI_TERMINAL_ID`), then the attached app's published window record (its key
window's workspace, focused pane and selected tab), and only with no app attached the
daemon's default focus. This replaces today's single `windows` subject that
`WindowStateStore.update` rewrites whole, which lets two Macs on one daemon overwrite
each other. Implemented by session feat-cmux-next-99 after its catch-up.

## 3. Protocol: ops, echo, intents

- Op: `{transaction, idempotency_key, kind, args, expected_revision?}`. The owner runs
  the pure reducer `(state, op) -> Result<(state', events), Reject>`, then commits rows,
  the replay record and the event batch in one transaction (`MutationResult<T>`). The
  idempotency ledger survives restart, so a retried key replays the original result.
- `mutation-echo-v1` (additive capability): the dispatcher sets an opaque
  `transaction` tag on every event a request causes and ends every request, including
  no-ops and rejects, with `request-settled {transaction, sequence}`. The tag is a keyed
  hash of (client id, idempotency key), so a client recognizes its own requests and other
  subscribers learn nothing about its keys (session events null `correlation_id` on
  purpose today).
- Owner order: validate, commit durably (rows, ledger entry, replay record, event batch),
  and only then publish the events and `request-settled`. Publishing before the commit
  lets a restart lose an op a client already settled (`PublishBeforeCommit` mutant).
- `request-settled {transaction, sequence, ok}`: `sequence` is the event sequence of the
  op's last event (0 for a reject or a no-op). A retried key answers from the ledger with
  the original `sequence`.
- Snapshot: carries the state, its sequence, and the requesting client's decided keys at
  that sequence (the client cannot read the owner's ledger otherwise). The client adopts
  it only if it is not older than its mirror, then drops those intents. Events that
  arrive while a snapshot is outstanding are buffered and applied after it if newer.
- Client: a confirmed mirror written only by owner events and snapshots, plus one ordered
  intent log. Visible state = mirror + intents. A reject removes its intent at once. An
  `ok` reply removes its intent only when the mirror has applied `sequence`; a reply that
  arrives earlier is held in client memory (it survives disconnects) until then. A delta
  gap requests a snapshot. Reconnect resends every intent in the log with its key (the
  ledger dedupes) and requests a snapshot. No other optimistic mechanism remains.
- Owner selection: one function maps an entity to its owner (`machines.daemon(for:)`);
  nothing assumes the local daemon.

### 3.1 Wire shapes (steps 3 and 3a)

`client-identity-v1`:
- Local socket: the daemon reads the peer's uid with `getpeereid` and refuses other
  users. The first request on a connection is `client.hello {install_id, proof}` where
  `proof` = HMAC-SHA256(per-install key, daemon nonce from the socket banner); the key
  lives in the app's Keychain item (CLI: a 0600 file under the app support directory).
  The connection's identity is `install_id` from then on; a later request cannot change it.
- SSH, Iroh, Cloud links: the identity is the link's authenticated principal (the SSH
  carrier key, the Iroh node id admitted by the account directory, the Cloud machine's
  account); `client.hello` on such a link may only narrow it to an `install_id` that
  principal has registered.
- Records with a single writer (`window_record`, `browser_record` fields,
  `remote_terminal_snapshot`) store `owner = install_id`. A write from another identity
  is `forbidden {owner}`; writes carry `expected_revision` per record.

`mutation-echo-v1`:
- Every request may carry `idempotency_key`; the daemon computes
  `transaction = base64url(HMAC-SHA256(daemon secret, client identity || key))[0..16]`
  (or of a per-request random id when no key is sent) and returns it in the reply.
- Every event a request causes carries `transaction`. The dispatcher sets it from a
  task-local request scope, so no handler needs to pass it.
- The request ends with one event to the requesting connection only:
  `request-settled {transaction, sequence, ok, reason_code?}`, where `sequence` is the
  last event sequence the request caused (0 if none). A replayed key returns the original
  `transaction` and `sequence`.
- Other subscribers see the tag but cannot derive the key or the client.

### 3.2 Workspace lifecycle in the store (step 5, `workspace-lifecycle-v1`)

Today the app decides (`EmptyWorkspaceRepair`, 242 lines): a workspace this connection
saw with a pane and now without one closes, unless the store's terminal registry says its
last terminal ended with outcome `unknown`, in which case the app creates a new
terminal; a workspace first seen empty gets a terminal; a drag that empties a workspace
marks it `closing`. Three clients (app, TUI, CLI) can disagree, and the decision races the
mirror. Target, decided by the store inside the commit that causes it:

| Cause | Store action in the same commit |
| --- | --- |
| Last tab closed by a client (Cmd-W, CLI, TUI) | remove the tab; the workspace empties and closes (user decision 8.3, same for every client) |
| Last process exits normally and its tab is not kept (`keep_on_exit` false) | same as above, caused by the session host's typed `exited` event |
| Terminal host lost (outcome `unknown`: crash, kill, reboot), or a process ended by a signal from 2 s before to 60 s after the daemon began shutting down (logout, `server stop`, SIGTERM to the daemon; the shutdown start is recorded durably so a restarted daemon classifies exits found at adoption) | nothing is removed: the tab becomes `dead` with a Respawn action, or respawns per policy; the workspace never empties (principle 3) |
| A move, drag or tear-off takes the last tab out | the move op names the source workspace as closing; it closes in the same commit (tear-off is one op) |
| `workspace.create` | creates the workspace with its first terminal in one op; there is no empty workspace for a client to repair |
| Legacy empty workspace found at open (older builds, hard kill) | the store gives it a terminal once at open, recorded in the journal |

Logout race (2026-10-02): logout signals the shell and the daemon at the same time, so a
shell's signal exit can reach the daemon before it records its shutdown start. A signal
exit is final only once the 2 s lead has passed: until then the daemon commits the exit
receipt without removing the tab, then classifies the receipt again (a shutdown that
started meanwhile makes it a host loss, and the receipt is rewritten to the host-loss
shape so later daemons agree without the window). A daemon that stops first leaves the
receipt to the next one, which classifies and rewrites it the same way. Visible cost: a
command ended by Ctrl-C or a user's `kill` shows its tab dead for 2 s before it goes. The
receipt records no provenance (the public `TerminalExit` shape is closed and older
daemons reject unknown receipt keys), so an older host's status-less exit and an
abandoned launch read as host losses after a restart: the tab stays dead, the safe side
of principle 3. A separate provenance table keyed by the receipt revision is the path if
that ever matters.

Restart of a host-lost tab (user decision 2026-10-02): a dead tab shows one-click
Restart (same cwd and command); the setting `terminal.restartLostTerminals` (default
false) restarts automatically. Ownership: the store owns the decision and the record; the
client only shows the action. The op is `tab.restart {tab, idempotency_key}`: the session
host starts a new terminal with the dead terminal's cwd and argv (from its registry
record), and the store swaps the tab's terminal reference in the same commit (the tab id,
placement, name, pin and group stay; the dead terminal is tombstoned). A second restart
with the same key replays; a restart of a tab that is not dead is a typed reject. The
automatic policy is a setting the app sends as an op field on reconnect
(`tab.restart` per dead tab with a key derived from the dead terminal id), never a store
read of client config. Surfaces: the dead-tab overlay button, tab right-click, palette
action `tab.restart`, and `cmux tab <id> restart`.

The app deletes `EmptyWorkspaceRepair`, `EmptiedWorkspaceCause`, the `isDead` membership
pruning and `claimClosing`; the window rule (a window exists only while it holds a
workspace) reacts to the store's `workspace-closed` event.

## 4. Scenarios

| Scenario | Behavior |
| --- | --- |
| One laptop, local terminals | the local cmux-tui is session host and store (separate actors and crates); the app projects both |
| Mac + 4 Mac minis | each mini is a session host; the laptop's store places their terminals next to local ones; a mini's own TUI user arranges the same terminals in the mini's store |
| Mac + Cloud VMs | each VM is a session host; layouts never live on a VM; a VM going to sleep turns its tabs into placeholders with the last snapshot |
| iPhone + Mac | the phone projects the Mac's store (window records included) and attaches terminals through the Mac or directly to the host |
| Two Macs, same user | separate stores until the sync hub is decided (8.1); both attach to the same terminals, input is ordered and attributed, the grid is shared |
| Agent in a VM runs `cmux pane split` | the VM's session host creates the terminal and forwards a layout intent (anchor terminal, verb, idempotency key) to every store that places the anchor; each applies it once; a store that does not place the anchor lists the new terminal under the machine |
| Partition (Mac loses a VM) | that VM's tabs are placeholders and every op on its terminals is refused (nothing queues); layout ops are refused too while the layout's own owner (the synced document's Durable Object) is unreachable, unless the document is local-only (open, 8.1) |
| Reconnect | mirror resyncs from a snapshot; decided intents leave the log; undecided intents are resent with the same key (the ledger dedupes) |
| Session host restarts | adopts running terminal hosts; viewers reattach; layout untouched |
| Store restarts mid-op | ledger and journal are durable; clients resend undecided intents; nothing is applied twice |
| Terminal host dies | the session host emits a typed lifecycle event; the tab shows dead or respawns per policy; no workspace closes |
| Two clients race (both close tab X, or move it to different panes) | the store serializes; the first applies, the second is a no-op or a typed reject; both see `request-settled` |

## 5. Inventory (from the code)

### 5.1 App (Swift)

The mirror itself is protected: every `DaemonStore` model setter is `internal(set)`, and
the App reaches the mirror only through 12 public writers (9 used, one call site each).
The problems are around it:

| What | Count | Where |
| --- | --- | --- |
| Optimistic patch call sites | 65 (18 call expressions) | `DaemonService.perform` / `commit` |
| ... with a real patch | 11 | rename, pin, collapse, place/move workspace, move tab |
| ... with an empty `.custom { _ in }` patch (the optimistic copy lives elsewhere or nowhere) | 54 | `SidebarBridge+Intents` `command`, `SidebarBridge+Personal` `personal`, `PaneController+Groups` `groupCommand`, `TabGroupHandlers.run`, `Drag/TabMoves` x4, `Drag/TabGroupMoves` x3 |
| ... never settled by op id (`expectEcho: false`, patch dropped at the next snapshot) | 60 | every `perform` (default false) and `TabGroupMoves` |
| ... never send the transaction to the daemon at all | 31 | closures written `{ c, _ in }` |
| Second copies of shared state mutated outside `DaemonStore` | 11 | sidebar model (25 `model.apply` sites, 3 local-only: `.setIcon`, `.setGroupPinned`, `.openGroup`), tab strip `orderOverride`/`membershipOverride`/`detachedID`, `PaneController.pendingClosed`, `pendingSelect*`, `LayoutModel` split/width overrides (local `UInt64` gesture ids, not transaction ids), new-column resize, `WindowRegistry`, session-local browser tabs, incognito overlay, live page overlay, drag restore |
| ... that can drift (no echo, no deadline) | 5 | sidebar local-only intents, screen-bar reorder (`daemon.send`, no rejection path), `pendingSelect*`, an unended layout gesture, `pendingClosed` (cleared on reply, `cache.release` even on failure) |
| Per-client view state written to shared state | 6 | `zoom-pane` (shared `zoomed_pane`), 4 collapse writes (workspace and tab groups), 1 window projection |
| Window projection clobber | 1 | `WindowStateStore.update` replaces the whole `windows` array with one default subject for every client: two Macs on one daemon overwrite each other's windows |
| App-side destructive inference | 3 | `EmptyWorkspaceRepair`, workspace `isDead` membership pruning, `claimClosing` |
| Out-of-band snapshot | 1 | `DaemonService.reconcile()` applies a snapshot without the inbox hold or barrier (state-audit X1) |
| Swift copies of daemon semantics | 1+ | `DaemonStore.placeWorkspace` re-implements `presentation.rs move_workspace_to_group` |
| Single-daemon assumption | 1 confirmed | `TabGroupMoves` uses `services.daemon` for remote workspaces; four different ways to pick a daemon |

Good news from the same audit: the app sends no focus, select or activate commands to the
daemon, never writes `active*`, and never infers terminal death (it reacts to `tab.dead`).

Coordinator audit additions: cmux-tui echoes a client transaction on about 10 of about 190
commands (the audit found it only on `tab-changed`, through `emit_tab_changed_for_transaction`);
`tree-changed`, `layout-changed` and inbox overflow force a full resync, after which pending
patches are reapplied (DaemonStore+Driver.swift:139-164).

### 5.2 cmux-tui (Rust)

| Area | Today | Gap against "one owner, typed ops" |
| --- | --- | --- |
| Document storage | `Mux.state: Mutex<State>` (workspaces, screens, split trees, panes, surfaces, terminal catalog, three revisions) plus `workspace_registry` (SQLite); lock order registry then state | about 133 `state.lock()` sites in mux.rs (about 45 mutable) plus about 60 in `mux/*.rs` and surface.rs; about 156 pub layout-shaped fns |
| Commit | one real choke point at commit: registry lock + SQLite transaction + exactly-once ledger `(origin, mutation_id)` with fingerprint, result, revision; CAS by `expected_revision` | two styles: plan-then-apply (`ResourceMutationPlan`, 25 callers) and mutate-then-project (legacy `commit_*_projection`); plus 30 terminal-registry commits |
| Op log | `session_journal` with `resource_revision = previous + 1`, `correlation_id` = mutation key | a log of row changes, not of ops; restart rebuilds from tables, not by replay |
| Echo | protocol-v2 journal deltas carry revision and correlation id; legacy `TreeDelta` has `transaction` | legacy echo only on `tab-changed`; about 15 other `TreeDelta`s hard-code `transaction: None` |
| Terminal lifecycle -> layout | typed pieces exist (`HostedTransition`, `TerminalLifecycle`, `TerminalExit`, `TerminalHostLiveness`) | the runtime calls `Mux::surface_exited` directly through `Weak<Mux>`; a lost host connection is turned into `Dead` by probing the host record (inferred exit when no sidecar); detach retries in a thread |
| Per-client state | `client_focus_memory`, `last_reported_focus`, `client_sizing`, `set-client-info` are per-client | `focus-pane`, `select-tab/-screen/-workspace`, pane focus direction and `zoom-pane` commit durable shared focus; split ratio and column width are client gestures written into the shared layout |
| Federation | `cmux-remote` transport and sessions; `ResourceMachineService::dispatch` trait with only a local implementation | no remote-terminal node on origin; the federation branch (unlanded) adds remote-terminal tab rows and detached kept terminals |
| Invariants | SQLite-side `validate_touched_resource_invariants` per patch; full `validate_resource_invariants` only at open | no tab-conservation check, no proptest or fuzz, no TLA+ (tab-loss agent is adding all three) |

What cmux-tui's session-host side holds today that belongs to the workspace store: the layout tree
(`session -> workspaces -> screens -> split-tree panes -> tabs`), tab order, tab groups,
pins, workspace names and colors, shared `active*` focus defaults, zoom, layout undo.

What the post says the server should own that cmux-tui lacks or only partly has: a
durable searchable output record (today a bounded replay), input attribution per
participant, presence as a first-class read, a canonical grid with per-client viewports
as the default policy (today `latest`).

## 6. Formal model

`formal/OwnershipConvergence.tla` models the op protocol shared by every owner: one
owner with an idempotency ledger and an op log, two clients each with a confirmed mirror
and an intent log, retries with the same key, channels that reorder, duplicate and (on
disconnect or owner restart) lose messages, and reconnect that resyncs and resends
undecided intents. Ops are `move(tab, pane)` and `close(tab)`; the owner rejects an op on
a tab that no longer exists. A client applies a delta only at `version + 1` and resyncs on
a gap.

The owner stages one op, commits it, then publishes; a restart loses only the staged
op. Clients hold early replies in memory. Faults (disconnect, owner restart) and timeout
resends are bounded per config so liveness can be checked.

| Invariant | Principle |
| --- | --- |
| `NoDoubleApply`: log length = version = ledger size; keys unique in the log | 5 |
| `NoLostAck`: every op a client settled as applied is in the durable store, across restarts | 6 |
| `MirrorIsPrefix`: a mirror at version k equals the replay of the owner's first k log entries | 4 |
| `PendingVisible`: an undecided intent stays in its sender's log, hence its visible state | 6 |
| `NoFlicker`: an intent settled as applied is already in its sender's mirror | 4, 6 |
| `RecordSingleWriter`: a client-owned record is written only by its owner, judged by the connection's identity | single writer |
| `Convergence`: nothing in flight => every visible state equals the owner, every log empty | 4 |
| `EventuallyConverged` (liveness, fair delivery, bounded faults): the system always reaches `Convergence` | 4 |
| `Conservation`, `NoSilentLoss`: no tab duplicated or silently removed in any state | 1, 2 |

`Conservation` and `NoSilentLoss` mostly test the shared reducer (`Apply` strips a tab
before it places it), so they hold for any protocol that uses it; the reducer crate's
proptest and `TabLayout.tla` (emptied panes, columns, workspaces) are where principles 1
and 2 are really checked.

TLC 1.8.0, `formal/run-ownership-tlc.sh [cfg] [--mutants]` (2 clients, 2 panes; client
symmetry for safety configs), at machine load ~400:

| Config | Result |
| --- | --- |
| default: 2 tabs, 1 op per client, 1 fault, 1 retry, unbounded messages | pass: 5,680,649 distinct states (53,562,840 generated) |
| liveness (`-live.cfg`): 1 tab, 1 op per client, 1 fault, no retry, no symmetry, `EventuallyConverged` | pass: 1,785,780 distinct states (15,538,291 generated), 5 min 51 s |
| earlier revision without held replies, 2 faults and 2 retries | pass: 3,367,200 distinct states, depth 23 |
| `-2ops.cfg`: 2 ops per client, 1 fault, 1 retry, at most 3 messages in flight | not run on this revision (the previous revision passed at 25,134,993 distinct states in 19.5 min) |

Mutants (each must fail; `--mutants`, default config):

| Mutant | Fails with |
| --- | --- |
| `NoLedger`: no idempotency check | `NoDoubleApply` |
| `NoGapCheck`: apply any newer delta | `MirrorIsPrefix` |
| `DropAtNextDelta`: today's `expectEcho: false` | `PendingVisible` |
| `SettleBeforeMirror`: settle on the reply before the mirror has the event | `NoFlicker` |
| `PublishBeforeCommit`: reply before the durable commit | `NoLostAck` |
| `TrustClaimedOwner`: owner taken from the op, not the connection | `RecordSingleWriter` |
| `NoResendOnReconnect` | `Convergence` |

Review (subagent, 2026-10-01) found that the first revision passed for the wrong reason
in two places: clients read the owner's ledger directly, and commit and publish were one
step, so `NoLostAck` could not fail. Both are fixed above (snapshot carries decided keys,
staged commit, held replies), and each now has a mutant that fails. Still open from that
review: the default config gives each client one intent, so overlay order between a
client's own intents is checked only in `-2ops.cfg`; records carry no content or
per-record compare-and-swap (identity only).

The `DropAtNextDelta` mutant is today's app rule: 60 sites drop their patch at the next
snapshot instead of on their own echo, so an undecided op can vanish from the view and
come back.

Companion model: the tab-loss agent's `formal/TabLayout.tla` (landed 2c4f2bb293e) models
the layout side of the same protocol: panes, workspaces, drag presentation, split and
tear-off intents, one batch per transaction, `request-settled` with a write barrier, a
fault budget (duplicate batch, replayed request, disconnect, owner restart) and
liveness; fixed config 3,953,751 distinct states and live config 573,873, both pass.
This model adds what that one does not: client-owned records judged by connection
identity, commit-before-publish with held early replies, snapshots that carry the
requester's decided keys, and resend of every intent on reconnect over an unbounded
duplicating channel. Not modeled yet: layout intents from remote session hosts, and the cross-device sync hub.

## 7. Steps

Each step lands alone, shippable, failing test first, a review subagent (correctness
against OWNERSHIP-PRINCIPLES.md) before every daemon, store or protocol landing, and a
COORDINATION.md line.

1. This document and the TLA+ model with TLC results.
2. Pure layout reducer crate (no I/O), starting from the tab-loss agent's LayoutOp:
   `(LayoutState, LayoutOp) -> Result<(LayoutState, Vec<LayoutEvent>), Reject>`;
   proptest for invariants 1-3 and 5 over random op sequences; kani proofs for small
   bounds where feasible; wired into the hosted cmux-tui CI. The daemon's tab-move paths
   call it first (validate), then become its callers (apply). Agreed 2026-10-01: the
   tab-loss agent's Rust sub-agent builds the crate `cmux-tui/crates/cmux-layout-reducer`
   (`apply(&LayoutState, &LayoutOp) -> Result<(LayoutState, Vec<LayoutEvent>), Reject>`)
   with the first op set MoveTab, MoveTabToSplit, MoveTabToColumn,
   MoveTabToNewWorkspace, MoveTabToWorkspace, CloseTab (each with an idempotency key);
   `mux/tab_drag.rs` validates through it. This stream then adds tab-group ops and the
   remaining layout ops. Kani result (2026-10-01, branch `feat-cmux-next-kani`
   28ec1c620f5, harnesses in `src/proofs.rs`): infeasible on the crate as written. Kani
   0.68.0 on a 32 vCPU Testbox finished no harness, not even a concrete one-tab layout
   (timeouts at 7 and 8 minutes, unwind 8 and 3), because symbolic execution cannot rule
   out `BTreeMap`/`BTreeSet` internal-node paths. Evidence for invariants 1-3 and 5 is
   therefore the reducer proptest (20,000 reducer cases, 5,000 daemon sequences) plus
   `TabLayout.tla` and `OwnershipConvergence.tla`. Kani becomes feasible only with a
   fixed-capacity array representation checked equal to the real reducer by proptest;
   not scheduled.
3. `mutation-echo-v1` in the dispatcher: central transaction tag on every caused event,
   `request-settled` for every request; additive capability, advertised in
   `awaitingPin` until the pin carries it.
3a. Authenticated client identity (`client-identity-v1`). Today v2 requests carry no
   client identity, so "only the hosting app writes the browser record" and "only the
   owning install writes its window record" are enforced by clients alone. Bind an
   install id to each connection: locally, unix-socket peer credentials plus a per-install
   key; over SSH, Iroh and Cloud, the link's authenticated identity. Single-writer records
   store `owner` and the store rejects a write from any other identity, with per-record
   compare-and-swap. Never trust an owner field the client sends (the
   `TrustClaimedOwner` mutant in section 6 shows the failure).
4. App: confirmed mirror plus one intent log. Migrate the seven optimistic mechanisms
   one at a time (moveTab first, then tab groups, sidebar, layout overrides, pending
   close and select, window pending state); delete `.custom` no-op patches, `expectEcho`,
   `reconcile()`'s out-of-band snapshot and the Swift copy of `move_workspace_to_group`;
   a debug-build check flags any mirror write outside event apply and the intent overlay.
5. `workspace-lifecycle-v1`: the store closes an emptied workspace in the same commit per
   client policy, host death never closes, tear-off is one command; delete
   `EmptyWorkspaceRepair`, the `isDead` pruning and `claimClosing`.
6. After PR 16174 merges: split cmux-tui along the module boundary into session host and
   workspace store crates (the store on `cmux-tui-core::state`); the session host emits
   typed lifecycle events on a channel instead of calling `Mux::surface_exited`; per-client
   focus and zoom leave the shared tree.

## 8. Decisions

Answered by the user (2026-10-01):

1. Cross-device sync hub: Cloudflare Durable Objects for now (unit per user or team
   document chosen by the cloud spec lead; teams first-class), an own peer-to-peer
   overlay later. Consequence for ownership: a synced document's sequencer (its single
   writer) is its Durable Object; each device's local store is a replica that forwards
   ops and keeps the last confirmed state. Open for the spec lead: whether a document can
   be local-only (owned by the local store, never synced) so layout stays editable
   offline, and how a document moves between local and synced ownership (an explicit
   handover op, never two sequencers at once).
2. Host discovery: account directory with local fallback.
3. Emptied workspace in the TUI: closes, same as the app (the store applies one policy).
4. A browser tab shown by two Macs: each Mac renders its own Chromium. Ownership rule
   that keeps one writer: the browser record is owned by the store; URL changes are ops
   (`browser.navigate {tab, url, expected_revision}`) from any app that shows the tab,
   and every app's page follows the record's URL; title and favicon updates name the
   URL revision they belong to and are refused for a stale revision. Page-local state
   (back/forward stack beyond the record's short list, scroll, form state, loading,
   devtools) stays per Mac. Remote desktop, VNC and remote Chrome tabs come later.

5. Offline: nothing queues. While an owner is unreachable every change to its entities
   is refused and the client shows the disconnected state. Reconnect resends only the
   intents sent before the disconnect, with their keys (the model's `Reconnect`; `Issue`
   requires a live connection).
6. Grid policy default: one canonical grid per terminal, the smallest attached viewer
   wins; a presence list shows every client; any user can kick a client, and the kicked
   client shows a "disconnected by X" screen (reuse the old cmux UI). Maps to the
   `smallest` policy of `shared-sizing-v1` plus `detach-client` with a reason and actor.

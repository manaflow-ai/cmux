# State ownership principles (binding)

Every agent that touches state, the daemon, the store, the protocol or the CLI reads this first. ownership.md holds the detailed design; this file holds the rules. When they disagree, this file wins until the coordinator changes it. Source of the model: "the server owns the session, the client owns the view" (https://peterp.org/blog/terminal-multiplexers.html), adapted for local, remote Mac minis and Cloud VMs.

## Three roles

| Role | Owns | Runs | Knows layout? |
| --- | --- | --- | --- |
| Session host | PTYs and processes, scrollback, durable transcripts (bounded, per-session opt-out), canonical terminal size, ordered input with attribution, presence of attached clients, kick-off, revive | every machine that runs terminals (laptop, each Mac mini, each Cloud VM); headless | no |
| Workspace store | the layout document: windows-as-records, workspaces, columns (incl. sticky), panes, tabs that reference sessions on any host, browser tab records, pins, tab groups, rooms, saved groups, closed history, keep-layout records | per user; a replica on each device, synced; on a laptop it may run inside the local binary as its own actor and crate | yes (arrangement only) |
| Client | view state, gestures, animation, rendering; on the Mac the Chromium runtime | inside each app (Mac, iPhone, TUI) | renders it |

Today cmux-tui mixes session host and workspace store. New code must not deepen that: new shared or personal state goes into the workspace-store side (`cmux-tui-core::state` from PR #16174, or the presentation store until it merges), never into PTY/session code.

## Single writer per entity

- Every entity has exactly one owner. Everyone else is a projection.
- Terminal facts (alive, exited, cwd, size, output) are written only by the session host that runs the terminal. The store never infers a terminal's death; it reacts to the host's typed lifecycle event.
- Layout facts are written only by the workspace store, through validated ops.
- Client view state (which workspace a window shows, focus, selected tab per client, key window, strip scroll, sidebar width, window frames, omnibar draft) is owned by that client. If other tools must read it (for example the CLI's `current`), the client publishes it to its own per-client record in the store; only that client writes that record.
- Browser runtime (page, history stack, loading, page focus) is owned by the Mac app that hosts the page; the store's browser tab record is written only by that app (and by user ops on the record, such as move or close).
- Preferences (cmux.json, themes, keys, accounts) are owned by the config layer on that machine.

## Ops, not mutations

- Every change to shared state is a typed op with a client-chosen idempotency key, sent to the owner.
- The owner validates the op against the invariants below with a pure reducer `(state, op) -> Result<(state', events), Reject>` and commits the write, the replay record and the event batch in one transaction (`MutationResult<T>`).
- Every event caused by a request carries that request's transaction id, tagged centrally in the dispatcher, and every request ends with `request-settled {transaction, sequence}`, including no-ops and rejects.
- Destructive policy (close an emptied workspace, remove a pane, reap a terminal) is decided by the owner in the same commit, never by a client from differences in its mirror.

## Clients are projections

- A client keeps a confirmed mirror written only by owner events, plus one ordered log of pending typed intents. The visible state is mirror + pending intents. An intent leaves the log on its echo or reject. No other optimistic mechanism is allowed; existing ones migrate to the intent log.
- Gestures (drag, divider resize, scroll) are local continuous state; only the commit at the end becomes an intent. Animation interpolates between visible states keyed by stable ids; a reject animates back.
- When an owner is unreachable, the client shows that and refuses ops on that owner's entities; only ops marked safe may queue, and the owner validates them on reconnect.
- One code path picks the owner for an entity (`machines.daemon(for:)` style); nothing assumes the local daemon.

## Invariants (checked by the reducer, property tests, model checking and debug builds)

1. Tab conservation: a move, split, drop, reorder or tear-off never changes the set of tabs; only an explicit close removes one.
2. Every tab is in exactly one pane; every pane has at least one tab or is removed in the same commit; every column has at least one pane.
3. A terminal host's death never closes a workspace or removes a tab; the tab becomes dead or is respawned per policy.
4. Projection convergence: when a client's intent log is empty, its visible state equals the owner's state.
5. Idempotency: replaying an op with the same key has no further effect.
6. Two clients' concurrent ops serialize to one valid state; neither client loses an acknowledged op.

## Verification (required, not optional)

- The store's reducer is a pure Rust crate with no I/O. proptest runs random op sequences against invariants 1 to 3 and 5; `kani` proves them for small bounds where feasible.
- A TLA+ model in `plans/cmux-next/formal/` covers the protocol: two clients, pending intents, reordered and duplicated events, reconnect, owner restart; TLC checks invariants 4 to 6. CI runs it at small bounds.
- Swift side: seeded property tests for the drop resolver and the mirror + intent log against a reference model.
- Debug builds check invariants 1, 2 and 4 live and report violations in `debug.desync`.

## Rules for every agent

- New state: name its owner and its role before you write code. If it does not fit the table above, ask the coordinator.
- No new client-side optimistic copy, no client-side destructive inference, no new "pending" dictionary.
- Every new op ships with reducer invariant tests; every change to the protocol or store adds a line to COORDINATION.md.
- Before landing a change to the daemon, the store, the protocol or the projection, run a review subagent (correctness first, against this file) and fix its findings.
- The Swift CLI is frozen until #16174 merges; CLI requests go to session feat-cmux-next-99 (`uds:/tmp/cc-socks/18283.sock`).

## Open decisions (coordinator asks the user)

- Store sync hub across devices (account relay with end-to-end encryption, peer-to-peer, or both).
- Host discovery for many Mac minis and Cloud VMs (account directory with local fallback, or manual).
- Default for emptied workspaces for plain cmux-tui clients.
- Browser runtime outside the app (off-screen CEF in a host process) as a later prototype.

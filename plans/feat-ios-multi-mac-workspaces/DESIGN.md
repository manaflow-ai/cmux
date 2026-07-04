# Multi-Mac aggregated workspaces + compound filtering (iOS)

Status: in progress. Builds on the paired-Mac backup/restore (so the phone knows
every Mac). Goal from Lawrence: the home screen shows workspaces from EVERY
connected Mac, and filtering is rethought so you can compose read-state × machine
(e.g. "unread on Mac X"). The single-active-Mac "connect / add device" model goes
away.

## Today (single-Mac), the blockers

From the architecture survey:
- `connectionState` is a binary `connected`/`disconnected` enum that gates the
  whole root screen.
- One `remoteClient` / `activeTicket` / `activeRoute`; attaching a Mac tears down
  the previous one.
- `workspaces: [MobileWorkspacePreview]` is a flat list with NO device id.
- A single global `connectionGeneration` cancels all in-flight RPC on every attach.
- Root state machine: `.connected` → workspaces (one Mac), else → add-device.

## Target model

The phone maintains a **per-Mac connection** to each known Mac and merges their
workspace lists into one aggregated, machine-tagged list. The home screen is
always the workspace list (whatever Macs are reachable); "add device" is a
secondary affordance, not a full-screen gate. Filtering is two orthogonal,
composable dimensions: read-state (All · Unread) × machine (All · multi-select).

```
pairedMacs (restored) ─┬─ MacConnection(macA) ─ workspace.list ─┐
                       ├─ MacConnection(macB) ─ workspace.list ─┼─ merged [WS tagged macDeviceID]
                       └─ MacConnection(macC) ─ workspace.list ─┘        │
                                                                          ▼
                                                          filter(readState × machines)
                                                                          ▼
                                                                 grouped workspace list
```

## Phases (each independently shippable, single-Mac stays working throughout)

- **P1 (this slice): device identity on the model.** Add `macDeviceID` to
  `MobileWorkspacePreview` (and the terminal preview). Populate it from the
  connected Mac's `activeTicket.macDeviceID`. Nothing else changes yet — the list
  still shows one Mac — but every workspace now carries which Mac it's from. Pure
  groundwork, additive, low risk.
- **P2: connection pool.** Replace the single `remoteClient`/`activeTicket`/
  generation with `[macDeviceID: MacConnection]`, each with its own client,
  ticket, route, and generation. Keep a notion of the "foreground" Mac for
  terminal I/O. Single-Mac behavior = a pool of size 1.
- **P3: aggregate the list.** Connect to all known Macs (read-only workspace.list
  first; terminal I/O still only to the foreground Mac initially), merge into one
  list keyed by `macDeviceID`, recompute the published snapshot on any Mac's list
  change.
- **P4: always-on home + compound filter.** Replace the binary root gate with an
  always-shown aggregated list. Filter model = `{ readState: All|Unread, machines:
  Set<macDeviceID> (empty = all) }`; the visible set is the composition. Group
  rows by machine; per-machine connection status shown inline. "Add device"
  becomes a toolbar affordance.
- **P5: per-Mac terminal I/O.** Thread `macDeviceID` through terminal subscribe /
  render-grid / drafts so opening a workspace attaches that workspace's Mac.

## Filter model (P4 detail)

```
struct WorkspaceFilter {
  enum ReadState { case all, unread }
  var readState: ReadState = .all
  var machines: Set<String> = []   // macDeviceIDs; empty == all machines
}
visible = workspaces.filter {
  (filter.readState == .all || $0.hasUnread) &&
  (filter.machines.isEmpty || filter.machines.contains($0.macDeviceID))
}
```

Two orthogonal selectors in the filter UI (a read-state segment + a machine
multi-select), so any combination ("unread on Mac X and Mac Y") is expressible
without a combinatorial menu.

## Test Mac

`cmux-lawrence` (Mac mini, Tailscale `100.89.225.106`) will run the dev build
signed in as the dev account, so it auto-publishes its route to the backup and
appears as a second real Mac to aggregate. Provisioned once P3 can consume it.

## Non-goals (for now)
- Concurrent terminal sessions to many Macs at once (P5 attaches the foreground
  workspace's Mac on open; background Macs are list-only until then).
- Cross-Mac workspace ordering guarantees beyond per-Mac grouping.

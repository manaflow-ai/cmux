# Messages reach a live receiver: successors, role addresses, synchronous refusal, bounces

Leo, 2026-11-24 23:12Z: "well clearly we need to have better listeners/scheduling to make sure those messages are
recievable"

## What failed (desktop-leo, 22:55-23:10Z)

`leo-forward --to gcp-codex-swarm-10/goal-ci-linux-on-pool-a-2` printed "sent queued". The peer was down, so the
outbox kept it and relayed it to the mesh hub (`server/mesh_send.rs` `relay`), which answered
`404 mesh.unknown_recipient` four times; the delivery ended "failed attempt 4" and the sender was never told. The live
owner was `gcp-agent-lane-12/goal-ci-linux-on-pool-240936`: the goal restarted the lane under a suffixed name and
nothing recorded old -> new.

## Design

One mechanism carries both successors and roles: what a live session answers to besides its name, which its daemon
lists in the mesh heartbeat and the hub matches when no live session has the name.

### Wire (heartbeat `sessions[]` row, both optional)

- `formerNames: string[]` (at most 16, each 1..160 chars). A bare `NAME` is a name this session had on its own host
  (`SessionMeta::former_names`, kept by renames since 11-20). `HOST/NAME` is a session on any host this one succeeds
  (a rotation, a goal restart, a promote, a lane-place move). A successor copies its predecessor's entries, so a
  chain A -> B -> C resolves in one hop.
- `roles: [{address, claimedAt}]` (at most 16). `address` matches `^(goal|area|topic):[A-Za-z0-9._-]{1,128}$`;
  `claimedAt` is ms since the epoch.

### Hub resolve (cmux-platform `src/server/mesh/Core.ts` `resolve`), for a prompt named by `name` (no sessionId)

1. A live session with that name (and host) - as today.
2. Its handle - as today.
3. A role address (`goal:`, `area:`, `topic:`): the live session that claimed it most recently. Never ambiguous.
4. A successor: a live session listing `HOST/NAME` (or a bare `NAME` on that host) in `formerNames`. Several are
   refused as `mesh.ambiguous` with the candidates, never one picked.
5. Else `mesh.unknown_recipient`, synchronously, as today.

The receipt's `resolution` says which rule found it (`asked`, `via: name|handle|role|successor`, the session reached).

### The daemon (cmux-tui `acpmux`)

- Heartbeats list `formerNames` and `roles`.
- `acpmux succeed [--session S] OLD...` records OLD (`HOST/NAME`) as a name S answers to, copying OLD's own former
  names when OLD is a session this daemon or a peer still lists. `acpmux role claim|release|ls ADDRESS
  [--session S]`; a claim here releases the address from every other session on this daemon.
- Submit-time check: a send whose target nothing here resolves (no local session, no live peer row, or the peer is
  down) asks the hub before it is queued. A name the hub refuses as unknown or ambiguous is refused in the sender's
  own call; one it resolves goes to the session it names. Only a transient hub failure (5xx, 429, no connection)
  is queued, and the reply says the name was not checked.
- No silent drop: a queued delivery that ends failed or expired (outbox or hub receipt) bounces into the sending
  session as a waking notice, and is appended to the dead-letter list `~/.acpmux/dead-letters.jsonl` that NOW reads.

### Tooling (leo-workspace, cmuxterm-hq)

- `sessions rotate`, `goal` restart, `sessions promote`, `lane-place` move: run `acpmux succeed` on the new session
  naming the old one; this generalizes fleet-registry `coordinators.retired`.
- `goal` start/claim/restart claims `goal:SLUG` on the owner session; when the role's holder changes, the goal
  record's `owner:` line is rewritten to it.
- A dead letter whose recipient owned a goal or area is handed to the goal's tooling (revive/replace) or to its
  coordinator.
- Detector: a test sending to a dead name, a renamed name and `goal:SLUG` must reach a live session or be refused
  synchronously; cmuxterm-hq `docs/handbook/lost-message-to-dead-session.md` names it.

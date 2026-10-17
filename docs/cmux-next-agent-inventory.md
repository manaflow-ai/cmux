# Native agent inventory carrier

The native daemon exposes cached inventory on its trusted owner connection.
These internal carrier commands are not new app execution or session routes.
App-facing inventory reads still require `agent_cli:read` and a currently
admitted route, with owner and connection checks after each read.

## Cached reads

`agent-inventory` uses the configured local acpmux socket, negotiates
`harnessInventory`, and asks only for `_acpmux/harness/health {view:"inventory"}`.
It never starts acpmux, probes, refreshes, updates or tries another owner. The
optional `expected_machine_id` fence requires `agent-inventory-owner-v1` and
must match this native daemon's canonical full `machine_…` ID.

Only bounded allowlisted fields return. Inventory is partial even when it has
rows; unknown installation, CLI family and sign-in evidence stay unknown.

## Change subscriptions

Require the native capability `agent-inventory-watch-v1` before sending:

```json
{"id":1,"cmd":"agent-inventory-watch","expected_machine_id":"machine_…","enabled":true}
```

The full canonical owner ID and a boolean `enabled` are required. The Unix
carrier is required; WebSocket and conversations-only remote relay clients
are refused. Extra fields, commands, paths, machine/session selectors and
client-supplied watch IDs are refused before connecting to acpmux.

The daemon negotiates `harnessInventoryWatch` on one existing-owner socket
connection and then calls `_acpmux/harness/inventory/watch {enabled:true}` on
that same link. No legacy health fallback or reconnect occurs. The enabling
acknowledgement returns `{machine, watch_id, revision}`. The opaque watch ID
belongs to this control connection and one subscription generation.

Changes produce only targeted invalidations:

```json
{"event":"agent-inventory-changed","machine":"machine_…","watch_id":"inventory_watch_…","revision":2}
```

Cache rows, diagnostics, account labels, paths and commands are never event
payloads. Each acpmux snapshot is validated, older/duplicate revisions are
discarded, and pending notifications cannot precede the successful lease
acknowledgement. A consumer can re-read the existing cached inventory through
the same captured admitted connection; a watch does not grant another read.

Enabling again returns the current lease without another acpmux connection.
While its handshake is pending the duplicate returns `agent_inventory.busy`.
Disabling with the same owner and `enabled:false` returns `{}` and closes the
lease. Disconnect also closes it. Replacing the configured acpmux socket or
losing/invalidating the feed retires the lease and, for a live subscriber,
sends `agent-inventory-watch-ended {machine, watch_id, reason}`. No newer lease
can be removed by an old callback. Activation and invalidation enqueue are
ordered before socket replacement; disable orders the end of notifications.
Replacement atomically detaches the old leases before allowing new admissions,
then closes only those detached leases outside the socket lock. An internal
connection epoch rejects stale admissions even when a socket path is reused.

At most eight watches exist per native owner. Watch handshakes share the
existing eight-worker cache-read budget, including cancelled attempts still
inside a socket connect. Each RPC has a deadline. Invalidations use the
native bounded control queue; a failed enqueue closes the connection rather
than silently losing an update. No subscription creates polling timers.

The caller must match every event to its captured native handshake generation,
canonical owner and watch ID. Reconnection requires fresh admission and a new
subscription. A revision is scoped to its acpmux run, not a durable identity.

The app-facing subscription bridge remains open. The existing app supervisor
admits `agent_cli.changed` through the read scope of `agent_cli.list` and
currently carries invalidations, not arbitrary inventory payloads. Do not
advertise `agent_cli.watch` until native/app subscription, revocation and
replacement behavior is implemented and verified. CLI/MCP remain on the
existing read catalog during this carrier slice.

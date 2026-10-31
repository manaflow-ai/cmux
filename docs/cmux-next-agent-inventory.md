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
client-supplied watch IDs on enable are refused before connecting to acpmux.

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
lease. A client managing asynchronous cleanup must negotiate
`agent-inventory-watch-fence-v1` and include
`expected_watch_id:"inventory_watch_…"` on disable. The owner atomically
compares it only to this control connection's lease. A missing or different
current lease returns `{}` without closing anything; a matching lease closes.
This is an identity condition, never a selector for another client or owner.
Malformed IDs and IDs on enable are refused. The original unconditioned
disable remains available for explicit connection-wide retirement.

Disconnect also closes the lease. Replacing the configured acpmux socket or
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

## Swift native consumer contract

`MachineAgentInventoryWatchRequest` and `MachineAgentInventoryUnwatchRequest`
require `agent-inventory-watch-fence-v1` before enabling, so compatible
conditional cleanup is available. Both carry the captured canonical owner and
a fixed boolean. Unwatch additionally carries the exact watch ID returned by
that lease's receipt. No selectors, commands or caller-created lease IDs are
accepted, and no unconditioned disable fallback is attempted. Enabling decodes a typed
`AgentInventoryWatchReceipt` directly from native bytes, preserving every
`UInt64` revision.

`AgentInventoryWatchEvent` recognizes only the two targeted inventory notices.
Wire decoding validates canonical owner and lease IDs, bounds ended reasons and
projects only lease fields. In the generic side-event payload, a revision is
retained as exact decimal text (as pairing IDs already are), avoiding the
`JSONValue` floating-point boundary. This is a Swift projection; native wire
revisions remain unsigned JSON numbers. Malformed notices have no usable
payload, and unrelated event payloads retain their existing shape.

These lease events survive the tree snapshot barrier. The provider bridge
matches the captured ready connection generation, owner and watch ID, then
rechecks route admission. The typed value itself grants no permission.

`DaemonConnection.agentInventoryWatch(expectedMachineID:)` captures the ready
control session's shared `AgentInventoryWatch` manager after capability and
canonical owner checks. Repeated captures on that transport share admission;
a reconnect creates a new manager. Enable and conditional cleanup use only the
captured transport with a 15-second owner-read bound. Cancelling pending enable
retains its waiter until the receipt can be retired. Disable invalidates the
local admission before awaiting cleanup; readmission waits for that cleanup.
An uncertain admission or failed cleanup stays failed on this manager. It
neither reconnects nor redirects a delayed disable to a newer control session.
The app provider must still own route admission, callbacks and subscription demand.

### Explicit refusal recovery

`agent-inventory-watch-admission-v1` negotiates `admission_receipt:true` on
enable only. Success retains the existing owner/watch/revision receipt. An
eligible temporary refusal may include error `data` exactly
`{machine, admission:"not_admitted"}`. Native code observes no lease for that
control client and queues the refusal while holding the watch registry lock.
Worker failure stops and removes its lease before checking absence. If another
lease is present, including a pending enable, no absence proof is returned.

`agent_inventory.busy` alone is ambiguous: it can mean reservation pressure or
an already pending lease. Legacy requests keep their existing refusal shape.
Malformed opt-in, disable, trust/owner refusal and invalid cache responses do
not provide a recovery receipt. A proof names only the expected owner; it is
neither a selector nor permission to start an owner or run a job.

The shared Swift manager clears a failed admission only after negotiating this
capability and matching the owner, proof and eligible refusal code. A later
explicit demand/route admission can then enable on that same captured transport.
Cancellation recovers the proof without an unfenced disable. Legacy or uncertain
failures, transport timeouts, malformed receipts and failed cleanup remain fenced.
There is no automatic timer retry, alternate-owner fallback or reconnect.

## Verified app subscription boundary

`agent-cli-app-invalidation-v1` adds a fixed local provider carrier. A verified
non-agent app connection registers `agent_cli` through `apps-provider-register`.
Opting in with `inventory_watch:true` returns an `inventory_demand` snapshot
`{sequence, enabled}`; omission preserves the legacy `{families}` reply. The
same connection receives targeted `apps-agent-inventory-demand` events with
those two fields. Sequence is an exact unsigned 64-bit value for this supervisor
boot and provider connection. A provider must ignore older demand events and
fence them to its captured native control epoch, including across awaits.

Demand begins with the first readable `agent_cli.changed` subscription and ends
with the last. The supervisor checks current install/enabled state, manifest
requests, grants and live host state. Revocation, unsubscribe, disable, host
exit and provider replacement re-evaluate demand under the same state lock;
an old process or callback cannot establish a fresh subscription. Registration
returns a snapshot so the initial state does not depend on receiving an event
while a provider is attaching its handler. No timer, CLI health check or generic
daemon-event feed starts solely for this inventory subscription.

Only the current verified local provider may send
`apps-agent-inventory-changed {demand_sequence}`. It accepts no origin override,
event name, machine selector, rows, job outcome or command. WebSocket, remote,
page-relay, agent-bound and unverified connections are denied. The sequence
must match current enabled demand; otherwise the owner returns
`apps.provider.stale_demand`. Delivery queues only `{}` to currently readable
subscribers, ordered with revocation and unsubscribe under the supervisor lock.
The generic daemon event publisher cannot impersonate this family.

`AgentInventoryProviderBridge` connects this demand to the registry's already
admitted, policy-allowed ready owner connections. Disconnected, ambiguous and
blocked routes cannot acquire a lease. The bridge observes registry changes;
there is no polling or automatic owner start. `AppProviderSession` pins both
registration and strict invalidations to the actual ready transport. Legacy
owners retain compatible registration without inventory opt-in.

Demand sequences decode as UInt64 before generic JSON, then remain exact decimal
text in side events. Registration and events share one monotonic demand state:
an event received before the registration reply can supersede its older snapshot.
Every callback rechecks live registry admission, the original source and control
serial, canonical owner, route epoch and watch ID. An owner change or native
ended notice cannot redirect a callback or automatically create another lease.

Last unsubscribe, route removal, policy disable and provider replacement invalidate
callbacks before bounded conditional retirement on the original owner transport.
A retirement barrier prevents a replacement from reusing an old live receipt
before cleanup. Uncertain admission or cleanup remains fenced by the shared
watch manager. One pending invalidation and one dirty follow-up coalesce bursts;
only `{demand_sequence}` goes to the native carrier, and apps receive only `{}`.
Agents already rereads current owners on that empty invalidation. Neither cache
changes nor these notices authorize installs, updates or completion of jobs.

`DaemonSideEvents.subscribeEnvelopes` preserves the original native envelope
through tree snapshots and inbox collapse. Match its client-side `sourceID`
to the captured `DaemonConnection.eventSourceID`, and its `connectionSerial`
to the admitted ready transport. A replacement connection instance has a new
source ID even when its serial starts at the same value. Events applied without
a source ID or envelope never reach this listener. These fields are source
metadata, not owner identity or permission; existing event-only listeners keep
their current interface. The provider bridge must use this source-aware path
before interpreting a demand snapshot or watch notice.

## Native update recovery

The local registry stores non-secret update intents before dispatch: the original
key, batch key, canonical target machine/session, observed CLI family and profile
IDs. `agent-cli-intents-record` commits the whole batch atomically;
`agent-cli-intents-list` reads it, `agent-cli-intents-attach` saves the matching
public terminal receipt, and `agent-cli-intents-settle` deletes settled intents.
Records cannot be retargeted. Recording also drops rows older than seven days and
keeps the newest 256 per actor, so the ledger cannot fill up; reads never return
a row older than seven days, so one nothing settles stops blocking. The additive
`agent_cli_intents` table is created when an existing registry opens; older
binaries can ignore it without a schema-version change.

These raw carriers require `agent-cli-intents-v1`, a verified main Frontend Unix
connection and the local ledger's exact machine/session. The registry derives
the actor from that connection and journals writes. Actor claims, App callers,
agent-bound connections and remote transports cannot acquire this authority.
A saved intent is metadata, not an execution grant.

On the original target, `agent-cli-update-job-resolve` requires
`agent-cli-update-job-resolve-v1`, the original key and CLI, exact target
machine/session and the same verified Frontend admission as job creation. It
only reads the durable creation state: `not_found`, `prepared`, `pending`,
`indeterminate`, `failed`, or `created` with the original public receipt. It
never prepares a plan or starts an updater.

Settings Refresh restores intents only through an already admitted original
machine/session, then observes any retained terminal. It cannot fall back to
the focused or local machine. An unsettled intent blocks a fresh update of the
same CLI on that machine, from any session: an unreachable session may be a
live server still running the updater. Settings shows such a row as an unknown
update a person may dismiss (a local ledger delete); otherwise it waits out the
age bound. A ledger row that fails validation is skipped, not the whole list. Only a new user gesture or native confirmation may
resume an unstarted (`not_found` or `prepared`) intent, preserving its original
key and family. Pending execution stays fenced; a created receipt only
reattaches. An intent settles, and stops blocking, when its terminal exits (with
any outcome) or is closed (`terminal.closed`, or `selector.not_found` for the
terminal), when the owner refuses its start before journaling (`agent_cli_job.*`
other than `busy`, which may be this key running) or when the creation state is
`failed`. A failed record leaves no job behind. A person may dismiss an
unstarted or `indeterminate` intent, or one still `pending` ten minutes after a
recovery first saw it; dismissing stops nothing. App execution and remote
execution admission remain unsupported.

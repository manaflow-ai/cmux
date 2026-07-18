# Protocol-v9 Terminal Control

Protocol v9 adds independently owned input and geometry lanes to daemon-owned
terminals. Protocol v8 framing and commands remain unchanged. A terminal moves
one-way out of v8 shared mutation when its first v9 lane is acquired.

A v9 client must require these capabilities before mutation:

- `terminal-control-lease-v1`
- `terminal-split-leases-v1`
- `terminal-lease-transfer-v1`
- `terminal-input-delegation-v1`
- `terminal-input-groups-v1`
- `terminal-global-input-order-v1`
- `terminal-input-idempotency-v1`
- `terminal-input-receipt-ack-v1`
- `terminal-nonrenderer-presentation-v1`
- `terminal-ordered-input-v1`

## Connection claim

Each transport has a server-generated `connection_id`. The client registers a
stable logical UUID and a per-process UUID once on that transport:

```json
{"id":1,"cmd":"register-client","protocol_min":9,"protocol_max":9,"client_uuid":"11111111-1111-4111-8111-111111111111","process_instance_uuid":"22222222-2222-4222-8222-222222222222"}
```

Stable UUIDs support receipt lookup. They do not authorize mutation. Every
lease is bound to the numeric connection claim, stable client UUID, process
UUID, visible presentation UUID, and exact presentation generation. A stale
process or reconnected transport cannot reuse the old claim.

## Independent leases

Input and geometry are acquired separately after a presentation becomes
visible. A renderer uses `configure-renderer-presentation`; a TUI or another
nonrenderer frontend uses `activate-terminal-presentation` with the exact
presentation generation. Publishing visibility acquires neither lane. A
frontend acquires input for actual input and geometry only for an explicit
canonical resize:

```json
{"id":2,"cmd":"acquire-terminal-lease","kind":"input","surface_uuid":"33333333-3333-4333-8333-333333333333","presentation_id":"44444444-4444-4444-8444-444444444444","presentation_generation":3,"ttl_ms":5000}
{"id":3,"cmd":"acquire-terminal-lease","kind":"geometry","surface_uuid":"33333333-3333-4333-8333-333333333333","presentation_id":"44444444-4444-4444-8444-444444444444","presentation_generation":3,"ttl_ms":5000}
```

`ttl_ms` is clamped to 1 through 30000 milliseconds. Each result contains its
own `lease_id`, `lease_generation`, `revocation_sequence`, `expires_at_ms`, and
`next_sequence`. Input also contains `next_global_input_sequence`. The first
lane acquired reports `migrated_from_legacy:true`; the other lane is still
independent.

The holder renews an exact lane without changing generation:

```json
{"id":4,"cmd":"renew-terminal-lease","kind":"input","surface_uuid":"33333333-3333-4333-8333-333333333333","presentation_id":"44444444-4444-4444-8444-444444444444","presentation_generation":3,"lease_id":"55555555-5555-4555-8555-555555555555","lease_generation":2,"ttl_ms":5000}
```

`release-terminal-lease` carries the same reference and `kind`. Input release
does not release geometry, and geometry release does not release input.
Disconnect, presentation detach, terminal close, or TTL expiry revokes only
matching lanes. Input revocation also revokes its delegations and open input
group. Legacy shared mutation never returns.

The holder can atomically transfer one idle lane to an exact live target claim:

```json
{"id":5,"cmd":"transfer-terminal-lease","kind":"geometry","surface_uuid":"33333333-3333-4333-8333-333333333333","presentation_id":"44444444-4444-4444-8444-444444444444","presentation_generation":3,"lease_id":"55555555-5555-4555-8555-555555555555","lease_generation":2,"target_client_uuid":"66666666-6666-4666-8666-666666666666","target_presentation_id":"77777777-7777-4777-8777-777777777777","target_presentation_generation":8,"ttl_ms":5000}
```

The target stable UUID must resolve to exactly one registered v9 connection,
and its presentation must show the same terminal. Transfer increments that
lane's generation and revocation sequence. An input lane with an unfinished
group cannot be released, transferred, or have its active delegation revoked.

## Input order and groups

The input holder sends typed terminal input with its lane-local sequence and a
non-nil idempotency UUID:

```json
{"id":6,"cmd":"terminal-input","surface_uuid":"33333333-3333-4333-8333-333333333333","presentation_id":"44444444-4444-4444-8444-444444444444","presentation_generation":3,"lease_id":"55555555-5555-4555-8555-555555555555","lease_generation":2,"sequence":1,"request_id":"88888888-8888-4888-8888-888888888888","input":{"type":"text","text":"hello","paste":false}}
```

Typed payloads are `text`, base64 `bytes`, `named-key`, semantic `key`, and
renderer-resolved cell `mouse`. Encoding uses the daemon's canonical Ghostty
VT state. Frontend cell pixel sizes never enter the input contract.

Every accepted input receives a monotonically increasing
`ordered_input_sequence` assigned by the daemon for that terminal. A new lease
or transfer resets its caller-local `sequence` to 1 but never resets the global
order. Input and geometry can execute concurrently because they use separate
in-flight lanes.

Multi-request bracketed paste and another deliberately indivisible input batch
carry all three group fields:

```json
{"input_group_id":"99999999-9999-4999-8999-999999999999","input_group_index":0,"input_group_end":false}
```

The first member has index 0. Each later member increments by one, and the
final member sets `input_group_end:true`. While a group is open, another lease
holder or delegate cannot insert input. A one-request paste uses index 0 and
`end:true`. Every physical key press, repeat, release, mouse press, motion, and
release is its own index-0, `end:true` group. This permits key rollover and
keyboard input during a mouse drag without allowing bytes within one physical
event to split. Rejected validation or encoding restores the previous group
state and consumes neither local nor terminal-wide sequence.

The server fingerprints kind, local sequence, payload, and group metadata. It
retains at most 512 unacknowledged receipts per terminal. Capacity exhaustion
rejects new work before PTY or geometry mutation and never evicts an older
recoverable result. Reusing `request_id` with the same stable client and fingerprint returns the original receipt with
`replayed:true`, including its original terminal-wide order, and never writes the PTY
again. A changed payload or client is a conflict. An indeterminate PTY write
stores a queryable receipt, consumes its order, and revokes the input lane.

## Automation delegation

Only the current input holder can delegate input. Geometry is never delegated:

```json
{"id":7,"cmd":"grant-terminal-input-delegation","surface_uuid":"33333333-3333-4333-8333-333333333333","presentation_id":"44444444-4444-4444-8444-444444444444","presentation_generation":3,"lease_id":"55555555-5555-4555-8555-555555555555","lease_generation":2,"delegate_client_uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","ttl_ms":2000,"scopes":["text","key"]}
```

The delegate UUID must resolve to exactly one live v9 connection. Delegation
TTL is clamped to 1 through 10000 milliseconds and cannot outlive the owner
lease. Scopes are a nonempty subset of `text`, `key`, and `mouse`.

The delegate uses `terminal-delegated-input` with its delegation ID,
delegation generation, local sequence, request ID, payload, and optional group.
The server checks its exact connection, stable client UUID, and process UUID.
Owner release, transfer, expiry, disconnect, or explicit
`revoke-terminal-input-delegation` invalidates the delegation immediately.

## Geometry

Only the geometry holder can send `terminal-geometry`:

```json
{"id":8,"cmd":"terminal-geometry","surface_uuid":"33333333-3333-4333-8333-333333333333","presentation_id":"44444444-4444-4444-8444-444444444444","presentation_generation":3,"lease_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","lease_generation":6,"sequence":1,"request_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","cols":120,"rows":40}
```

Rows and columns are clamped to 1 through 10000. The receipt includes settled
`cols`, `rows`, and `changed`. Other GUI, TUI, browser, and automation clients
may crop or letterbox, but they cannot resize the PTY without geometry transfer.

## Recovery and v8 compatibility

`terminal-request-status` looks up a retained receipt by surface and request
UUID after reconnect. The registered stable client UUID must match. Lookup
grants no authority. A queued mutation owns one request UUID and its complete
payload until recovery is definitive. After an uncertain send, the client must
query before resending: `applied` dequeues without another write, `unknown`
permits reacquiring the required lane and resending the same UUID and payload,
and `indeterminate` is surfaced without a resend.

After consuming an `applied` or `indeterminate` result, the client sends:

```json
{"id":9,"cmd":"acknowledge-terminal-request","surface_uuid":"33333333-3333-4333-8333-333333333333","request_id":"88888888-8888-4888-8888-888888888888"}
```

Acknowledgement is idempotent. It removes the retained receipt only for the
same stable client UUID and frees one capacity slot. A lost acknowledgement
response can be retried without resending terminal input.

Protocol v8 clients retain their existing shared PTY mutation until the first
v9 lane migrates that terminal. The deprecated early-v9
`acquire-terminal-control` alias acquires input only and exists for wire
transition. Clients advertising the split-lease capability must use the lane
commands above.

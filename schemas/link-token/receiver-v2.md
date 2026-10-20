# Native receiver generation contract

A Native receiving process accepts a link token only for the generation pinned
by its private root bootstrap. Recreating the process gives it a fresh replay
map, so retaining the same WireGuard key, host and epoch is insufficient to
reject a saved token from an earlier process.

The v2 JWS uses `typ: cmux-native-link-v2+jwt` and signs this additional claim:

```json
{"receiver":{"version":2,"generation":"<64 lowercase hexadecimal characters>"}}
```

The existing `network` claim remains version 1 and identifies the source client.
The new claim identifies the destination receiving attempt. The issuer derives
it from the private ready record, revalidates the original VM grant and scope
before and after signing, and caps expiry by both client and VM grants.
Neither a caller-selected generation nor a ready phase alone authorizes minting.

A v2 receiver obtains its expected generation from the root's private frame,
never from a token. It requires the v2 type, exact claim shape and version, and
matching generation before spending a JTI. The legacy type is refused even if
its signature and original peer binding are valid. A generation mismatch must
not consume a current-generation token with the same JTI. The replay map remains
shared across policy and key renewals within one process.

Signed service hellos have a separate bound: an 8,192-byte token plus 128 bytes
for the JSON envelope. Other control requests and replies retain their
1,024-byte limit. Both hello readers use the same typed parser and token bound.

## Root and VM lifecycle

The common startup prefix remains `CMR\x01`. Native v2 support uses suffix
`NVR2`; its private frame has version 2 and a required generation. Lifetime-only
startup remains separate and receives no private frame. The default root mode
does not activate Native reception.

The original VM credential calls `cloud.vm.receiver.lifecycle` without a generic
idempotency key. `expected` is the generation CAS witness; `attempt` is a fresh
128-bit nonce for `begin`. Retries recheck authority and cannot revive a stopped
attempt. Before preparing another frame, the current root ticket can recover
and retire an observed attempt whose begin reply or READY was never seen.

One private frame owns one receiving process attempt. The daemon reports READY
only after that actual child installs its original policy and becomes ready.
Root then marks the same generation ready. On loss or stop, ingress is removed
and the child drains and is reaped before completion is acknowledged. Root
retires the generation before conditionally advancing its still-current, wanted
ticket. A stopped or obsolete worker cannot create a replacement ticket.

The VM-self policy has `schema_version: 2` and `receiver_generation`. It publishes
the generation during starting and ready, and `null` while closed. Its authority
version includes the generation. A receiving process rejects a fresh policy
whose generation is absent or differs from its immutable pin; existing streams
lose authority as well.

The frame and public policy contain no original VM grant ID, install private key
or account credential. The original keys remain unchanged across attempts.
Suspend, clone and provider-instance fencing require their own verification;
generation matching does not replace those checks.

# Native Cloud guest receiver

Fresh Native-backed Cloud images opt in with `cmux host run --native-receiver`.
The flag requires Linux root and is incompatible with `--roles-only`. Existing
`cmux host run` invocations retain lifetime-only bootstrap behavior. Do not add
the flag to images whose machines still use direct Freestyle transport.

The root host passes a private lifetime channel to its own session daemon.
After original Cloud enrollment, it reads the receiving policy using the
protected original install identity, advances the receiver generation, and
passes the receiving bootstrap privately to the daemon's owned child. The
bootstrap contains the VM WireGuard key and public verification authority;
it does not contain an account bearer or the original install private key.

The receiver accepts signed Native v2 tokens for its current generation and
only the current policy's peers and services. Policy removal, expiry, receiver
restart and suspend retire existing authenticated streams. Root lifecycle
control remains available when receiving fails; Cloud status reporting and
existing terminal supervision continue.

## Deploying a development image

1. Deploy matching CloudDO `cloud.vm.network_policy` and
   `cloud.vm.receiver.lifecycle` operations and the Native network service's
   receiver-policy endpoint. Bind through the existing original VM enrollment;
   the guest accepts only the configured environment's API origin.
2. Build the matching guest binary and bake it into a new image. The existing
   image's pinned binary does not include this receiver. Add
   `--native-receiver` to that image's root host service invocation.
3. Create a fresh Native-backed machine through NEXT CloudDO with confirmed
   Native network metadata. Use matching Native client token and tunnel support.
4. Verify encrypted daemon and SSH connections, current-generation policy,
   revocation and receiver restart on the fresh machine before promoting it.

This does not upgrade existing machines or adopt direct Freestyle machines.
It does not use the classic web `/api/vm` API. Existing supervisor commands,
terminal-host adoption and the remote WebSocket carrier remain supported.

## Verification

Run receiver library and integration tests on fleet Linux and macOS. On a
trusted hosted Linux runner, `scripts/ci/verify-link-root-boundary.py` additionally
runs the ignored root/work-user boundary, receiver child, and original-policy
producer tests. Those tests must execute rather than being counted as skipped.

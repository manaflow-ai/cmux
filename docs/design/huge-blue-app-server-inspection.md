# Huge Blue app-server inspection route

Tracking issue: [#21332](https://github.com/manaflow-ai/cmux/issues/21332)

This design is intentionally separate from the durable Run attach-ticket work in
[#21305](https://github.com/manaflow-ai/cmux/pull/21305). Inspection answers
whether a registered remote host can be observed. It does not create a Run,
redeem a terminal attach ticket, or mint a terminal route credential.

## Boundary

The inspection request is read-only and authenticated at the existing Cloud or
VM route boundary. It accepts a registered host identity and an optional cmux
authenticated session identity. It never accepts a raw provider URL, an SSH
command, a private key, a daemon token, or a provider machine id supplied by a
caller.

The implementation should expose a typed status with these states:

- `disabled`: the organization or local policy has disabled remote inspection.
- `unavailable`: the configured Huge Blue adapter or app-server link is absent,
  unhealthy, or not supported by this build.
- `unenrolled`: the target answers, but the caller's device is not enrolled for
  the read-only inspection channel.
- `admitted`: the target is reachable and the caller has an enrolled,
  authenticated inspection session.

Malformed, incomplete, or contradictory probe data must resolve to
`unavailable` or `unenrolled`; it must never be upgraded to `admitted`.

## Existing primitives to reuse

For an SSH-backed registered host, use the existing `SSHHost` identity and
`SSHService`/session registry. `SSHHost.machineID` already binds the route,
session, state directory, and optional remote mux socket. The inspection route
should reference that registered identity instead of copying a route string into
its own credential store.

For a Cloud/app-server-backed host, reuse the existing app-server read path and
machine connection inspection (`cloud.machine.list` and
`cloud.machine.connect_info`). The existing cmux-tui daemon attach bundle also
provides the fail-closed evidence we need: daemon build/protocol, enrolled-device
membership, and the trusted-carrier listener probe. The trusted-carrier probe
must remain an authentication signal, not a replacement for route ownership or
team authorization.

The response may include safe capability facts such as daemon protocol,
connection state, and enrollment state. It must omit provider credentials,
terminal tokens, invitation material, shell commands, raw route addresses, and
arbitrary provider metadata.

## Proposed response shape

```json
{
  "host": "ssh-… or cloud-…",
  "session": "main",
  "state": "admitted",
  "reasonCode": "trusted_carrier_enrolled",
  "retryable": false,
  "checkedAt": "2026-10-17T00:00:00.000Z",
  "capabilities": {
    "readOnlyInspection": true,
    "daemonProtocol": 2,
    "trustedCarrier": true,
    "enrolled": true
  }
}
```

The final URL and transport envelope should be selected in the implementation
PR after the owner of the app-server route confirms whether the inspection is
served by the Cloud app server or the authenticated VM API. This design avoids
coupling the route to the Run API while that decision is open.

## Implementation slices

1. Add a pure status mapper and redaction tests for disabled, unavailable,
   unenrolled, admitted, and malformed probe states.
2. Add the authenticated read-only route using the existing account/team route
   helper and registered SSH/session identity.
3. Connect the Cloud/app-server adapter to `cloud.machine.connect_info` and the
   trusted-carrier/enrollment probe; keep Huge Blue adapter absence explicit and
   non-retryable.
4. Add a client inspection view that shows the typed state and remediation,
   without offering terminal attach or shell execution.

A later PR can implement these slices independently. None of them should modify
the Run attach-ticket redemption or retention paths.

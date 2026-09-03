# cmux-lite iOS

cmux-lite is the clean-room proving ground for cmux mobile connectivity. It
separates protocol, transport, authorization, terminal synchronization, and
rendering so each layer can be understood and verified independently before it
is integrated into the production apps.

## Current slice

`Packages/CmuxLiteProtocol` defines and tests the renderer-independent protocol
kernel. `Packages/CmuxLiteSession` owns one conversation over an injected byte
stream and tests it against a deterministic fake Mac host. Neither package has
a dependency on the existing cmux mobile implementation.
`Packages/CmuxLiteTransport` now owns route ordering and one serialized dial
attempt, while still leaving concrete network adapters out of the experiment.
`Packages/CmuxLiteIroh` adds the unit-testable Swift adapter boundary and a
concrete provider backed by the isolated `manaflow-ai/iroh-ffi` `cmux-lite`
branch. The provider binds one endpoint lazily, publishes its public route,
resolves current address hints, validates peer identity and ALPN, accepts one
owned inbound connection at a time, and opens one bidirectional stream without
wiring the experiment into production. Its real loopback suite drives the
generic transport dialer and session owner, not a renderer. A dedicated
endpoint host owns the listener loop and accepted session lifetimes.

Later slices will add, in order:

1. a Tailscale compatibility adapter;
2. session reconnect and migration policy;
3. terminal synchronization over deterministic transcripts;
4. a Ghostty consumer and renderer verification.

Nothing under this experiment is wired into the production app targets unless
a later, explicit design decision promotes it.

`./scripts/ci/run-cmux-lite-tests.sh` runs every isolated package suite,
including the real local Iroh endpoint checks, without launching cmux.

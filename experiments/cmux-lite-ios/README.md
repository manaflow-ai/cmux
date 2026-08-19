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

Later slices will add, in order:

1. an Iroh byte-stream adapter;
2. a Tailscale compatibility adapter;
3. session reconnect and migration policy;
4. terminal synchronization over deterministic transcripts;
5. a Ghostty consumer and renderer verification.

Nothing under this experiment is wired into the production app targets unless
a later, explicit design decision promotes it.

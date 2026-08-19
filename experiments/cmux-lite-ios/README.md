# cmux-lite iOS

cmux-lite is the clean-room proving ground for cmux mobile connectivity. It
separates protocol, transport, authorization, terminal synchronization, and
rendering so each layer can be understood and verified independently before it
is integrated into the production apps.

## Current slice

`Packages/CmuxLiteProtocol` defines and tests the renderer-independent protocol
kernel. It has no dependency on the existing cmux mobile implementation.

Later slices will add, in order:

1. a deterministic fake Mac host;
2. a session owner joining the codec, state machine, and byte stream;
3. an Iroh byte-stream adapter;
4. a Tailscale compatibility adapter;
5. terminal synchronization over deterministic transcripts;
6. a Ghostty consumer and renderer verification.

Nothing under this experiment is wired into the production app targets unless
a later, explicit design decision promotes it.

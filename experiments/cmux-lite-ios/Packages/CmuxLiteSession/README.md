# CmuxLiteSession

`CmuxLiteSession` owns one protocol conversation over an injected
`CmuxLiteProtocol.ByteStream`.

The owner is deliberately small. It connects the stream, serializes outgoing
writes, decodes arbitrary incoming chunks, feeds every message through
`SessionStateMachine`, answers server handshakes, answers pings, and exposes
an `AsyncStream` of lifecycle events. It owns no socket, authentication,
Iroh, Tailscale, UI, renderer, filesystem, clock, or global state.

The test target uses two owners over the protocol package's in-memory stream:
one configured as a deterministic fake Mac host and one as the iOS client.
That gives us a complete handshake and ping/pong exercise before selecting a
real transport adapter.

```swift
let client = SessionOwner(
    configuration: .client(
        hello: .init(clientName: "cmux-lite-ios", nonce: "client-nonce")
    ),
    stream: clientStream,
    codec: codec
)
```

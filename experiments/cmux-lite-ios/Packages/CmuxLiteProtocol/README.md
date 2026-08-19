# CmuxLiteProtocol

`CmuxLiteProtocol` is the renderer-independent conversation contract shared by
the cmux-lite iOS client and Mac host.

The package currently owns four things:

- typed version-1 control messages;
- deterministic length-prefixed JSON framing;
- client and server handshake/session state validation;
- the transport seam that future loopback, Iroh, and Tailscale adapters implement.

It deliberately has no UI, authentication, terminal, Iroh, Tailscale, socket,
filesystem, clock, or global state dependency.

## Frame format

Each frame is a four-byte unsigned big-endian payload length followed by one
UTF-8 JSON message. Control payloads are limited to 64 KiB by default, and one
decoder call accepts at most 256 complete messages before failing closed.

```json
{
  "message_id": 1,
  "payload": {
    "client_name": "cmux-lite-ios",
    "nonce": "client-nonce"
  },
  "type": "hello",
  "version": 1
}
```

Transport reads are arbitrary chunks. One chunk may contain part of a frame,
one frame, or several frames. `FrameCodec.Decoder` preserves partial input and
emits only complete messages.

## Session order

The initial client conversation is:

1. transport starts;
2. transport becomes ready;
3. client sends `hello`;
4. server replies with `welcome`, correlated to the `hello` message ID;
5. both peers enter `ready`;
6. either peer may exchange correlated `ping` and `pong` messages;
7. either peer may close explicitly, or the transport may end.

Every sender uses positive, strictly increasing message IDs. A response has its
own message ID and identifies the request through `reply_to`. Invalid versions,
ordering, direction, or correlation close the state machine as a protocol
violation.

## Test construction

Tests construct the pure values directly and use a test-target-only in-memory
`ByteStream` pair. No app, simulator, daemon, renderer, or network is involved.

```swift
var client = SessionStateMachine(role: .client)
try client.beginConnecting()
try client.transportDidConnect()
try client.recordSent(
    WireMessage(
        messageID: 1,
        body: .hello(.init(clientName: "cmux-lite-ios", nonce: "nonce"))
    )
)
```

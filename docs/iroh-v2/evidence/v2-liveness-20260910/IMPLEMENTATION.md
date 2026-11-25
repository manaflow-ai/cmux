# Peer liveness and iOS suspension

`IrxConnection` now owns one shared ping/pong probe. Normal successful probes reuse their stream. A timeout or stream error retires that stream, and the next attempt opens a fresh stream on the same QUIC connection. The deadline covers opening, sending and receiving. Late callbacks cannot update the next probe. This fixes the previous retry against an already stopped reader.

`setApplicationActive(_:)` pauses application probes and resets their strike count before iOS suspension. `IrxPeerEngine` also pauses automatic redial work, retains connection intent, and resumes it without a user action. Explicit application requests can still use an operating-system background execution window. Returning to foreground cancels obsolete work by generation and starts fresh deadlines. iOS connects the hooks in `MobileIrxRuntimeComposition`, its lifecycle extension and its dial extension; newly created engines inherit the current app state.

Foreground recovery probes an apparently open connection before replacement, with two attempts capped at 400 milliseconds each. A known native closure reconnects immediately. Repeated foreground triggers join the owned recovery task. Control renewal starts independently of peer recovery, and no Durable Object heartbeat is added. The six real QUIC tests cover a delayed first response, a suspended outstanding probe, an old healthy connection, a known dead peer, a silent peer with open streams, and deferred connection intent. Loopback timing is evidence for the mechanism, not a promise about cellular or relay latency.

The broader run reproduced a pre-existing admission race: a native read could throw a remote `irx:invalid-grant` error before the EOF/deadline branch classified it. The client now converts already-published terminal rejection codes into `IrxAdmissionDenied` across open/write/read errors. Cancellation remains cancellation, and unrelated transport failures retain their retry behavior. The original failing test and its output are retained beside the passing run.

The actual iOS app compiles with these changes. Shared tests and the exact source snapshot are recorded in `verification.json`, `shared-tests.log`, and the SHA-256 manifests. No local build, local app launch, phone installation or backend deployment was performed.

## Native two-minute suspension limit

The tested Swift package pins `iroh-ffi` tag `1.0.2-cmux.7`, commit `20f0e67cc3cb5179e816ef45b7a7ec5c8c58b0e0`. Its endpoint options expose initial stream limits but no idle-timeout setting; those limits construct the default transport configuration. [Pinned FFI endpoint source](https://github.com/manaflow-ai/iroh-ffi/blob/20f0e67cc3cb5179e816ef45b7a7ec5c8c58b0e0/src/endpoint.rs#L59).

The pinned IROH transport starts with noq defaults and enables native keepalive, while the pinned noq configuration sets a 30,000-millisecond idle timeout. The effective connection idle timeout is the minimum negotiated by both peers. [Pinned IROH transport builder](https://github.com/manaflow-ai/iroh/blob/4152d81047a6024881cb24e00dfd49b6cc73c65b/iroh/src/endpoint/quic.rs#L152), [pinned noq default](https://github.com/manaflow-ai/noq/blob/2271bbc25890f9577d2ce9bd0bb0f872af32e105/noq-proto/src/config/transport.rs#L514).

Consequently, a fully suspended process that cannot exchange packets for two minutes cannot be assumed to retain the same native connection. An app that remains able to run and answer native packets may retain it. The accepted path is to preserve a live connection where possible and reconnect a closed one using cached v2 authority while control renewal proceeds. Actual two-minute iPhone background/resume and relay timing remain live acceptance work. No Rust or FFI change was made for this limit.

## Separate renewal issue

`IrxEndpointSupervisor.rotateCredentials` currently logs an `insertRelay` failure without reporting installation failure to its caller. A newly fetched token may therefore be cached without being installed before the previous native token expires. This round does not change that behavior. The parent task owns the separate native installation retry fix and its tests.

# A3 `link`: the CmuxLink seam

Status: landed on `feat-cmux-next-ios-a3-link`, 2026-10-06. Plan: [PLAN.md](PLAN.md) section 2, A3.
Binding: `OWNERSHIP-PRINCIPLES.md`, `transport.md` (paths, roaming, 12a), `zero-latency.md`.
Code: `Packages/Shared/CmuxLink` (Swift package, iOS 17 and macOS 14, Swift 6).

## 1. What the seam is

Feature modules (terminal, browser stream, remote desktop, files) talk to one `CmuxLink` and never
import a carrier. Carrier lanes (B2 WebRTC, B3 WebRTC over WireGuard, B4 direct address, plus the
`HostDO` relay) implement one small `LinkCarrier` protocol. Everything that must behave the same on
every carrier lives once, in `CmuxLink`, between the two:

```
feature (C1..C4)            LinkChannel, MediaTrackHandle, LinkState, PathBadge
  -> CmuxLink (LinkSession) state machine, channels, revisions, resume, credit, priority, migration
  -> PathSelector           races carriers in policy order direct > p2p > turn > relay
  -> LinkCarrier/Transport  dumb lanes of opaque frames with a reliability class (carrier lanes)
```

A carrier moves opaque frames on lanes; it never sees a channel, a revision or a cursor. That keeps
each carrier lane small and makes the conformance suite meaningful: the suite tests the session over
the carrier, so a carrier passes when its lanes keep their promises.

## 2. Ownership

| Fact | Owner | Others |
| --- | --- | --- |
| Which carrier and path carry a session | the dialer's `LinkSession` (its `PathSelector`) | host sees the transport it accepted |
| Channel sequence numbers (revisions) per direction | the sending `LinkSession` | the receiver keeps only its consumed cursor |
| Retained unacknowledged reliable messages | the sending `LinkSession`, bounded by the channel budget | none |
| Session epoch | the accepting side (`LinkHost`), new on every new session | dialer stores it in cursors |
| Application state and its revision (`cmux.mobile/1`) | the owner (session host, DO) per A0 | link carries envelopes unchanged |

Link revisions are transport sequence numbers of one channel direction, contiguous from 1. They are
not the owner's state revision from A0; an A0 envelope rides inside a link message unchanged. A link
gap (`ChannelEvent.gap`) tells the feature that messages were lost beyond what the sender retained,
and the feature resyncs from a snapshot through its own RPC, as the realtime contract requires.

## 3. Connection state machine

`idle -> connecting -> connected(path) <-> degraded(path, reason)`, `connected|degraded ->
reconnecting(attempt) -> connected(path)`, and any state `-> closed(reason)` (terminal). The pure
`LinkStateMachine` validates every transition; `LinkSession` is the only writer and publishes each
state on `states()` (an `AsyncStream`, latest value first). A path change mid-stream keeps
`connected` and publishes a new `PathBadge`. Close reasons: `local`, `remote`, `unauthorized`,
`unreachable(attempts)`, `protocolViolation`.

Nothing polls. Reconnect waits with a `Backoff` on the injected `Clock` after a failure, and the
preference window of the race is a one-shot sleep on the same clock. A network change
(`networkDidChange()`, fed by NWPathMonitor in the app) restarts the race at once.

## 4. Channels

A channel is bidirectional, named by the feature (`stream`, for example `terminal/term_ab12`), and
declared with a `ChannelDescriptor`:

| Field | Values |
| --- | --- |
| `reliability` | `reliableOrdered`, `unreliableUnordered`, `partial(maxLifetime:)` |
| `priority` | `input > control > render > media > bulk` |
| `budgetBytes` | send credit: max unacknowledged bytes (reliable) or queued bytes (others) |

Semantics:
- reliable-ordered: every message is delivered exactly once, in order, across transport loss and
  reconnect, while the sender retained it. Acks are cumulative and sent when the consumer takes the
  message from the channel, so credit is end-to-end: a slow consumer suspends the remote sender's
  `send` instead of growing a buffer. Acks are coalesced by the session's send pump (the latest
  cumulative ack per channel wins), with no timer.
- partial: newest wins. The receiver delivers in revision order and drops anything older than what
  it delivered; the sender drops a queued message older than `maxLifetime`. Not resumed.
- unreliable-unordered: delivered as it arrives; a full send queue drops the oldest (media
  semantics, transport.md 12a). Not resumed.
- partial and unreliable sends made while the channel is not declared on a live transport (before
  the open handshake, while reconnecting) are dropped; they still consume a revision.

Priority: one send pump per session drains its queues strictly by priority, so an input frame
queued behind 4 MiB of bulk leaves next. Payloads above the path's `maxFrameBytes` are refused
(`LinkError.messageTooLarge`); bulk features chunk.

The DO relay is control-sized: its transport reports small `maxFrameBytes` and no bulk or media
capability. On such a path, `bulk` sends and media requests fail with `LinkError.unsupportedOnPath`
so the UI says "needs a direct connection"; nothing queues behind the relay.

## 5. Reconnect and resume

The dialer opens a transport and sends `hello(sessionID, epoch?)`. `LinkHost` answers
`welcome(epoch, resumed)`: a known session resumes, otherwise a new epoch starts. Then every open
channel is re-declared with the dialer's receive cursor, the host answers with its own, and each side
replays retained messages above the peer's cursor. A cursor below the sender's retention floor, or
from another epoch, yields one `gap(from:to:)` event, then delivery continues. Features can also open
a channel with a cursor saved from an earlier session (`openChannel(_:resumeFrom:)`), which follows
the same rule. Offline sends are not queued (OWNERSHIP-PRINCIPLES "nothing queues"): while
`reconnecting`, reliable sends wait for credit as usual only up to the channel budget and fail with
`LinkError.notConnected` once the session is closed.

Path upgrade is make-before-break: when the selector finds a better path while connected (after a
network change or the upgrade retry), the session resumes on the new transport, switches its pump,
then closes the old one. Retained messages cover anything in flight on the old transport.

## 6. Path selection

`PathPolicy.order` is `[direct, p2p, turn, relay]`. `PathSelector` starts every carrier at t=0.
Each carrier declares the paths it can produce (`candidatePaths`; WebRTC gives p2p or turn). The
first success is taken at once when no attempt that could produce a better path is still pending;
otherwise the selector waits up to `preferenceWindow` (default 150 ms) for a better one, then takes
the best success. Losers are closed. When the session is connected below the best rank it retries
the better carriers after `upgradeRetry` (one-shot, cancelled on close) and on every network change.

`PathBadge` = path kind + carrier kind + smoothed RTT. Interactive surfaces show it for relayed or
TURN paths and above 50 ms RTT (transport.md 1.1).

## 7. Media tracks

`MediaTrackHandle` names a video or audio track (id, kind, label) and exposes `states()` and
`attach(_ sink: MediaFrameSink)`. The host publishes a track (`publishMediaTrack`) and the dialer
receives it on `incomingMediaTracks()`. A carrier with real tracks (WebRTC) backs the handle with its
native track and adapts its renderer to the sink; the loopback carrier emits synthetic frames.
Tracks end on transport loss; the feature re-requests through its RPC (C2, C3).

## 8. Carrier contract (what B2, B3, B4 and the relay implement)

```swift
public protocol LinkCarrier: Sendable {
    var kind: CarrierKind { get }
    var candidatePaths: [PathKind] { get }
    func connect(to peer: LinkPeer) async throws -> any LinkTransport
}
public protocol LinkTransport: Sendable {
    var path: LinkPath { get async }
    var capabilities: TransportCapabilities { get }
    var events: AsyncStream<TransportEvent> { get }   // frame, pathChanged, rtt, mediaTrack, closed
    func send(_ frame: TransportFrame) async throws   // suspends while the carrier buffer is full
    func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle
    func close() async
}
public protocol LinkAcceptor: Sendable { var incoming: AsyncStream<any LinkTransport> { get } }
```

Lane promises a carrier must keep: frames on a reliable lane arrive once and in order while the
transport lives; partial and unordered lanes may lose or reorder; `send` back-pressures instead of
dropping on reliable lanes; `closed` is emitted exactly once; `pathChanged` is emitted when ICE or
the overlay moves without dropping the transport. WebRTC maps lanes to data channels
(`ordered: true` for reliable, `maxPacketLifeTime` for partial, `ordered: false, maxRetransmits: 0`
for unordered); the direct carrier maps unreliable lanes to datagrams and reliable lanes to a stream.

Conformance: `CmuxLinkTesting.LinkConformanceSuite` runs ordering, loss recovery, reconnect resume,
back-pressure, close semantics, path change mid-stream and priority against any carrier through a
`ConformanceHarness` (make a dialer carrier and host acceptor; optionally drop transports and change
paths). Carrier lanes call it from their own Swift Testing target; the loopback and lossy simulator
carriers run it in this package.

## 9. Mocks

- `LoopbackNetwork` and `LoopbackCarrier`: in-process pairs, with fault hooks (refuse connects,
  drop live transports, change path).
- `SimulatedCarrier` with `NetworkConditions` (latency, jitter, loss and reorder on non-reliable
  lanes, seeded) and `roam(to:)` that drops live transports and changes the path the next connect
  gets. Delays use the injected clock.
- `ManualClock`: a test `Clock` advanced explicitly.

## 10. Rust boundary (for lane B5)

The Mac session host runs Rust (cmux-tui). `cmux-tui/crates/cmux-link` is the contract of the
`cmux link` overlay process (stamps, `link.dial`, tokens, caller checks) and has no notion of
channels or carriers, so a channel trait does not belong there; it would also need cargo on a
Testbox, which this lane does not need. B5 owns the Rust side and must match this note:

- Wire: the `LinkFrame` codec in `CmuxLink/Wire` (hello, welcome, open, openAck, data, ack, close,
  gap; little-endian, version byte 1) with the golden vectors in
  `Packages/Shared/CmuxLink/Tests/CmuxLinkTests/Fixtures/link-frames.json`. B5 adds a Rust codec
  (suggested crate `cmux-link-session`, or a `session` module next to `cmux-transport`'s pure core)
  that replays the same vectors.
- Host behavior: B5 implements the `LinkHost` role (sessions by id, epoch, retention per reliable
  channel, cumulative acks on consumption, gap on stale cursors, priority pump) or embeds the Swift
  `LinkHost` in the Mac app process when the service lives there (browser host).
- Carriers on the Mac: B2/B3/B4 provide the Mac `LinkAcceptor`; for the overlay path, the Rust link
  stream from `cmux link` (`link.dial`, service `daemon`) can carry `LinkFrame`s as one reliable
  lane plus overlay datagrams (port 4103 style) for unreliable lanes.

## 11. Not in this lane

Carrier implementations (B2 to B4), signaling (B1), the RPC envelope (A0), UI for the badge (C11,
D1), the Rust codec (B5).

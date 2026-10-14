# Browser video as a WebRTC video track

Branch `feat-cnx-ios-rbvideo`, 2026-10-14. User decision: "use WebRTC video
tracks for browser streaming". This replaces, on WebRTC links, the reliable
`browser` channel as the carrier of a streamed tab's pictures
(verify/browser-stream.md). Everything else about the tab (rb control,
input, clock probes, popups) stays on the channel.

## Why

On the channel, every rd shard rides SCTP's ordered, reliable stream. One
lost packet holds every later frame, and every other channel on the link,
until it is retransmitted (head-of-line blocking). The browser-stream run on
a loaded Mac fell to 8 fps with a p90 of 200 ms. A track gives RTP over
SRTP: a lost packet is NACKed or the frame is skipped, nothing else waits,
and congestion feedback (TWCC) measures the real path.

## Design

```
Mac: cnx-hostd                                   iPhone: cnx-ffi (CnxKit)
browser host (CEF, VT encoder, rd engine)
  │ rd shards on loopback
  ▼
TrackBridge (hostd = rd viewer of stream 0)       ReceiverCore
  reassemble ─▶ SenderCore ─▶ RTP ═══ track ═══▶ release on marker ─▶ BrowserFrame
  feedback ◀── target, window ◀── TWCC, PLI ◀═════ TWCC, NACK, PLI      (VideoToolbox, unchanged)
  rb control, input, clock probes ◀────── `browser` channel ──────▶ rd Session (as before)
```

### One lane per link, one track switched by tab

- Negotiation is pre-negotiated in the first offer, so there is no
  renegotiation and no second ICE or TURN session. The phone's offer has one
  `recvonly` H.264 transceiver and lists the lane `video` in the signaling
  `lanes` (the same field as the input lane).
- A Mac that streams browser video adds a `sendonly` track before it
  applies the offer, so webrtc-rs's `satisfy_type_and_direction` binds it
  to the phone's m-line. It lists `video` back.
- An older Mac answers with an empty media engine. webrtc-rs rejects the
  m-line, the lane stays out and the link works (test
  `an_older_mac_leaves_the_lane_out_and_the_link_works`).
- An older phone offers no m-line, so no track is created.
- The version service adds `browser-video-track-v1` next to
  `browser-stream-v1`.
- The phone opens `browser {tab, url, video: "track"}`:
  - hostd honors `video: "track"` only when the link has a lane.
  - An older hostd ignores the field and streams on the channel.
  - The phone's viewer reads frames from both sources, so every mix works.
- One track per link is switched by tab. A newer `browser` channel's claim
  takes the lane. The older tab's video returns to its channel, with an IDR
  forced for its own rd viewer (test `browser_video_rides_the_webrtc_track`).
  The phone shows one page at a time, so per-tab tracks would only add
  renegotiation.
- WireGuard links carry the same lane as RTP inside the tunnel (option A
  below, built on `feat-cnx-ios-wgmedia`; section "WireGuard carrier").

### Mac side: hostd bridges rd to RTP; the host is unchanged

hostd becomes the rd viewer of the page's main stream on loopback. The
`browser_track.rs` `TrackBridge` reassembles the host's shards with
`cmux-rd-core`'s `Reassembler` and writes each access unit to the track. The
host's capture time becomes the RTP timestamp at 90 kHz, so the phone can
still compute each frame's age from the rd clock probes.

The bridge answers the host's media engine as a viewer at the end of the
real path would:

- **Bitrate.** Each host datagram is timed through a virtual bottleneck at
  the lane's TWCC-derived target. Sending above the target builds virtual
  queueing delay, which the host's delay-based controller reads as overuse.
  The VideoToolbox bitrate therefore follows the WebRTC path with no change
  to the host. Unit test `the_hosts_bitrate_follows_the_lanes_target`:
  - it uses the real `MediaEngine`;
  - the host starts at 8 Mbit/s;
  - it settles at 0.9 to 2.2 Mbit/s for a 1.5 Mbit/s lane.
- **Frame skipping.** A frame is acknowledged once it is on the track,
  unless the lane's in-flight window is full. The window is the target times
  the feedback delay plus 60 ms, and at least 96 KB. While the window is
  full:
  - the ack waits and the host's frame gate stays shut;
  - the page's damage coalesces into the next frame;
  - so frames are dropped at the source and never queued.
- **Keyframes.** The phone's PLI or FIR, rate-limited to one per 250 ms,
  becomes rd `need_recovery`. The engine answers with an IDR
  (VideoToolbox `ForceKeyFrame`).

### Phone side

Frames go from the track into `ReceiverCore`:

- **No jitter or playout buffer.** A frame is released the moment its
  marker packet completes it, in order.
- **Gaps.** A gap holds later frames only while a NACK can still recover it.
  The deadline is 2 × (RTT + NACK interval) + 20 ms, clamped to 80 to
  400 ms, using the link's ping RTT.
- **Giving up.** After the deadline the frame is dropped, a PLI goes out,
  and the next complete keyframe (STAP-A with SPS) is released however much
  was skipped. The decoder never gets a frame whose reference is missing.
- **Decoding.** Frames become the same `BrowserFrame` as before, so Swift's
  `BrowserVideoDecoder` and `AVSampleBufferDisplayLayer` path is unchanged.
  The overlay and log name the carrier (`track` or `channel`) and the
  dropped and recovered counts.

### Latency choices

| Choice | Value | Why |
| --- | --- | --- |
| Playout delay | 0 (release on marker) | UI, not a call: show a frame the moment it can be decoded. |
| NACK generator interval | 20 ms (webrtc-rs default 100 ms) | One NACK round on a 13 ms TURN path instead of a frame stall of 100 ms or more. |
| TWCC feedback | every 25 ms (default 100 ms) | Fresher delay samples for the controller. |
| Give-up deadline | 2 × (RTT + 20 ms) + 20 ms | Two NACK rounds, then skip to a keyframe. |
| RTP payload | 1100 bytes | Fits TURN, SRTP and extension overhead on a 1280-byte IPv6 path. |
| Start bitrate | 2.5 Mbit/s lane (host starts at 8 and follows) | |
| Congestion controller | rd's delay-gradient controller (`cmux-rd-core::cc`) | Same algorithm and constants as the channel path, now fed by TWCC. |

### What webrtc-rs provides and what we wrote

Taken from webrtc-rs 0.17 as is:

- ICE, DTLS and SRTP on the link's existing peer connection;
- RTP and RTCP routing per SSRC;
- the `rtp` crate's H.264 payloader (STAP-A for the parameter sets, FU-A)
  and its depacketizer;
- the NACK generator and responder interceptors (the responder keeps the
  send history);
- the TWCC receiver interceptor (feedback generation) and its `Recorder`;
- sender and receiver reports;
- the RTCP packet types (PLI, FIR, NACK, TWCC).

Written here, because webrtc-rs has no fitting part. I checked webrtc-rs
0.17, `interceptor` 0.17 and `webrtc-media` 0.17; none has a bandwidth
estimator or a GCC port, and there is no `cc` crate:

1. **Bandwidth estimation.** The core stamps the transport-cc extension
   itself, so it knows each packet's send time. It parses TWCC feedback
   (`media/twcc.rs`, about 40 lines) and feeds the existing rd
   delay-gradient controller and loss meter. These are reused, not new.
2. **The frame buffer** (`media/receiver.rs`). webrtc-media's
   `SampleBuilder` releases a frame only when a packet of the next frame
   arrives (`PendingTimestampPacket`). That costs a frame interval, and a
   still page's last frame is never released. It also hands on frames whose
   reference was lost.
3. **Encoder bitrate control from congestion feedback.** This is the
   virtual bottleneck plus the ack window in `TrackBridge`, because the
   encoder lives in the browser host's rd engine.
4. **Decode pacing.** There is none by design: frames decode on arrival, as
   on the channel path.

The transport-cc sequence stamping is about 5 lines in `SenderCore`, kept so
send times are known. webrtc-rs's TWCC sender interceptor stamps the same
numbers but does not expose them.

### Prior art: cmux-screen (feat-cmux-screen-kit, feat-cmux-next-vnc-rust)

- cmux-screen runs Google libwebrtc (LiveKit's `libwebrtc` crate) on the
  Mac. That gives it GCC, a pacer and libwebrtc's VideoToolbox encoder. It
  only sets sender parameters:
  - `DegradationPreference::MaintainResolution` for text;
  - 12 Mbit/s maximum at 60 fps in Auto;
  - fixed presets that pin `min_bitrate`.
- It measured 30 to 63 ms p50 glass-to-glass.
- We keep webrtc-rs, for these reasons:
  - it is already the phone's link stack, so a second WebRTC stack on iOS
    would bring the binary size and the duplicate `RTC*` Objective-C
    classes that effort hit;
  - the browser host already owns capture, the VideoToolbox encoder and a
    delay-based controller;
  - only GCC is missing, and the rd controller fed by TWCC covers it.
- Their text-first preference matches the rd ladder's text path, which
  keeps resolution and lowers fps.
- We would revisit if field data shows the rd controller under-using
  cellular paths, where GCC's probing is stronger.

## WireGuard carrier (built: option A, `feat-cnx-ios-wgmedia`)

The user approved option A below: RTP on the tunnel's datagram path with
webrtc-rs's `rtp`, `rtcp` and `interceptor` crates, no PeerConnection in the
tunnel and no SRTP.

```
Mac: hostd TrackBridge ─▶ VideoOut ─▶ SenderCore ─▶ interceptors ─▶ WgCarrier
                                                   (resend guard,      │ overlay UDP 7422,
                                                    NACK responder,    │ RTP = Priority::Media
                                                    sender reports)    ▼ inside boringtun
phone: BrowserFrame ◀─ VideoIn ◀─ ReceiverCore ◀─ interceptors ◀─ WgCarrier
                                                   (NACK generator, TWCC receiver,
                                                    receiver reports) ─▶ RTCP back, Interactive
```

- **Carrier** (`cnx-link/src/media/wireguard.rs`, `WgCarrier`). Binds overlay
  UDP 7422 on the session's `WgNet`, beside TCP 7420 (the link) and UDP 7421
  (roaming). One task owns the socket: it sends what the writers queue and
  sorts what arrives into RTP and RTCP by the second byte (RFC 5761). A
  datagram from another overlay address, or RTP with another SSRC, is
  dropped and counted.
- **Interceptors.** The registry the track uses (`interceptor_registry`)
  is built once per carrier and bound as `RTCRtpSender` and `TrackRemote`
  do: RTCP writer first (the NACK generator and TWCC receiver start their
  loops on it), then the RTCP reader, then the local (Mac) or remote (phone)
  stream with a fixed `StreamInfo` (payload type 102, TWCC id 1, SSRC
  `0x636e7876`, `nack`, `nack pli`, `ccm fir`, `transport-cc`). Pump tasks
  read the chains so a reader that stops waiting never loses a packet half
  way through a chain.
- **MTU.** The datagram service takes 1232 bytes (1280 minus IPv6 and UDP).
  The carrier reports a payload limit of 1232 − 12 (RTP) − 24 (extensions:
  the TWCC block plus room for two more) = 1196 bytes, and `SenderCore`
  packetizes at the carrier's limit (the WebRTC track keeps 1100). A packet
  over the limit would be counted and dropped, never fragmented; the tests
  assert it never happens.
- **Negotiation.** `wg-init` and `wg-resp` carry `lanes: ["input","video"]`.
  The Mac binds 7422 before it answers and lists `video` only if that
  worked; the phone binds before it opens the link stream. Older Mac or
  phone: no lane, video on the channel (tests below).
- **Roaming.** The `WgNet` and its sockets survive a roam (only the
  underlay's UDP socket changes), so nothing is renegotiated. The session
  counts network changes (its own roam after the rebind, and each endpoint
  announcement the peer sends on 7421) and the carrier exposes the count
  (`MediaCarrier::path_changes`). The phone's receiver sends a PLI at once
  without dropping what it holds; the Mac's sender forgets its in-flight
  bytes, resets the controller's delay baseline (`on_path_changed`) and asks
  the source for a keyframe, rate limited together with PLIs, so one
  keyframe results.
- **Reused unchanged.** `ReceiverCore` (release on marker, give-up deadline,
  keyframe gating), hostd's `TrackBridge` (rd to RTP, virtual bottleneck to
  the VideoToolbox bitrate, ack window and frame skipping, PLI to IDR, tab
  switching), the cnx-ffi viewer. The overlay names the carrier `wg-rtp`.

### Two fixes to the shared cores, found with the capped-link test

Both affect the WebRTC track too.

1. **NACK storm.** webrtc-rs's generator asks for every missing packet each
   interval (20 ms) with no retry limit, and the responder resends each time.
   On a 1.5 Mbit/s bottleneck with a 250 ms queue the resends queued behind
   the losses they repaired and were lost too: 30 to 55 % loss for four
   seconds with the target at its 250 kbit/s floor. `media/resend.rs` sits
   below the responder and lets a sequence number go again only 40 ms after
   its last send, at most 3 times (libwebrtc bounds resends by RTT and count
   as well). A packet still missing is the receiver's to give up.
2. **Controller cadence.** The rd controller cuts 15 % per overusing sample
   and assumes rd's 50 ms feedback. TWCC comes every 25 ms. `SenderCore` now
   batches TWCC arrivals into one sample per 50 ms and, after a decrease,
   holds the next sample for the feedback delay plus 50 ms (100 to 400 ms):
   one decrease per round trip, so a queue that is still draining does not
   read as fresh overuse.

Capped-link test (1.5 Mbit/s, start 2.5 Mbit/s, adaptive source, 10 s):

| | target after 1 s | after 10 s | loss on the way |
| --- | --- | --- | --- |
| neither fix | 259 kbit/s | 531 kbit/s | not traced |
| cadence only | 250 kbit/s (the floor) | 464 kbit/s | 30 to 55 % for 4 s (NACK storm) |
| both | 915 kbit/s (lowest 459) | 830 kbit/s, rising 8 %/s | 15 to 35 % for 1.2 s, then 0 |

The controller still overshoots on a start above the path: rd's controller
cuts relative to its own target rather than to the measured delivery rate
(GCC's 0.85 × acknowledged rate), and grows at most 8 % per second. Moving
it closer to GCC is a change to `cmux-rd-core` and is left as follow-up.

### Review of the whole lane (rbvideo and wgmedia), 2026-10-14

A correctness-first review of the branch found, and these commits fixed:

- **Frames still arriving were given up.** The receiver started the give-up
  deadline when a frame's first packet arrived, so a large IDR on a slow
  path (100 kB at 2.5 Mbit/s is about 320 ms) was dropped with no loss at
  all, and the PLI asked for another large IDR. Only a hole in the
  sequence numbers starts the deadline now.
- **A lane task leaked per WebRTC link that never streamed.** The phone's
  receiver waited forever for a track. Both cores now end when the link
  closes.
- **A packet could be lost without a NACK on WebRTC.** `recv_rtp` read the
  track through the interceptors inside a `select!`; a read dropped after
  the NACK generator counted the packet lost it. A task now pumps each
  track into a queue, as the WireGuard carrier does.
- **Frame ages of 13 hours** when the RTP timestamp was slightly ahead of
  the clock estimate (signed now).
- **Extra keyframes after a roam.** One roam is announced twice, and a
  signaling move announces an empty list; only a new first endpoint moves
  the path epoch now, and path-change PLIs are rate limited.
- **Tab switch ordering.** The phone subscribed to the lane before it sent
  the new tab's `open`, so the keyframe request could reach the old tab's
  claim. It subscribes after. Remaining: frames are not tagged by claim, so
  for about one round trip after a switch the new tab's view can show the
  old tab's frames until the new claim's first keyframe (follow-up: a
  claim id in a header extension, or a new SSRC per claim).
- **hostd** treated a lagged keyframe receiver as no request, and reopened
  the frame gate up to 100 ms after the lane drained.

Open suspicion: NACK resends reuse the original transport-wide sequence
number (no RTX), so a late resend can make TWCC report numbers in between
as lost and overstate the loss the controller sees. RTX (or restamping
resends) is the follow-up if field data shows it.

## WireGuard: media on the datagram lane vs a PeerConnection in the tunnel

The user has decided on WireGuard for everything, with WebRTC used only for
media. Research is in `verify/transport-wireguard-everything.md` (branch
`feat-cnx-ios-wgresearch`, `2ad07df5`). This is the comparison the decision
needed; option A is now built (above).

Both options keep what this branch built:

- the `MediaLane` and `MediaCarrier` seam;
- `SenderCore` (rtp-crate packetization, TWCC send times, the rd
  controller, the ack window, PLI and FIR);
- `ReceiverCore` (release on marker, give-up deadline, keyframe gating, PLI);
- hostd's `TrackBridge` (rd to RTP, virtual bottleneck to the VideoToolbox
  encoder);
- the cnx-ffi viewer.

They differ only in what moves the RTP and RTCP packets.

| | A. RTP on the tunnel's datagram lane | B. PeerConnection inside the tunnel |
| --- | --- | --- |
| Carrier | `WgDatagramCarrier: MediaCarrier` over `WgDatagramSocket`. RTP goes as `Priority::Media` (50 ms stale drop) and RTCP as `Interactive`, on one port, demuxed by payload type (RFC 5761). | `WgUdpConn: webrtc::util::Conn` over the same socket, then `UDPNetwork::Muxed` with the overlay IP as the only host candidate. The track carrier from this branch is reused unchanged. |
| NACK, TWCC, reports | The `interceptor` crate used as a library: the same `Registry` (generator, responder, TWCC receiver, reports) built with `Registry::build`, with its `bind_local_stream`, `bind_remote_stream` and `bind_rtcp_writer` writers pointed at the socket. No SRTP, because WireGuard encrypts. | The same interceptors inside the PeerConnection, as on WebRTC links today. |
| Negotiation | No SDP. Fixed payload type 102, TWCC extension id 1 and the Mac's SSRC, announced on the `video` lane (link `lanes` or the version service). | SDP offer and answer over a link channel in the tunnel (no Worker), then ICE checks, DTLS and SRTP keying. |
| Effort | About 3 to 4 days: carrier 1, interceptor wiring 1, lane negotiation 0.5, tests (loopback WireGuard pair, loss and reorder) 1. | About 3 to 4 days: `Conn` adapter, settings, in-link signaling and tests. The research's "1 to 2 weeks for media tracks" is mostly done in this branch. |
| What we write that webrtc-rs has | Nothing protocol-level. We skip ICE, DTLS and SRTP, which WireGuard makes redundant. We write the about 100-line glue that webrtc-rs's `RTCRtpSender` and `TrackRemote` do internally (binding interceptors to a stream). | Nothing. |
| Added per-packet cost | WireGuard only. | Also SRTP and DTLS, a second encryption layer, plus ICE consent checks. CPU not measured; likely more than WireGuard itself (research §2). |
| First frame after link up | No extra handshake. | Plus about 1 RTT of ICE checks and 2 of DTLS before the first frame, on every link. |
| Latency and quality | Same cores, so the same behavior: release on marker, NACK, TWCC to the rd controller, PLI. | Same. |
| MTU | We packetize at 1100 B of payload, so RTP is about 1130 B against a 1232 B datagram limit: about 100 B spare. | About 1146 B with SRTP, so about 86 B spare. Data channels using webrtc-rs defaults have 4 B. |
| Risks | The `interceptor` crate outside webrtc-rs is less used; its public API works, but no webrtc-rs code path exercises it that way. The Worker-relay fallback (TCP) loses unreliability, which applies to both. | A second connection state machine (ICE consent, DTLS) inside a tunnel that roams. The interface-enumeration plus `nat_1to1` trick to get a single overlay candidate. Tight data-channel margins. |
| Roaming | Needs WireGuard roaming (not built: no `WgNet::rebind`; 2 to 3 days, research). Then the lane is unaffected. | Same dependency. The PeerConnection's single overlay pair survives WireGuard roaming without an ICE restart. |

The research's own recommendation is a third option: carry the
`cmux.rd/1` shards themselves on the datagram lane. That uses rd's FEC,
NACK and controller, needs no RTP and no hostd bridge, and takes about 2 to
3 days. It reimplements nothing either, because rd exists already. It does
not reuse this branch's RTP core or the WebRTC track, and on WebRTC links it
would need a second unreliable data channel to match.

### Recommendation

If the user wants standard RTP media, meaning one media path that WebRTC
links have today and later screen viewing could share, choose A:

- it has the same cores;
- the webrtc-rs `rtp`, `rtcp` and `interceptor` crates are used as
  libraries;
- there is no double encryption and no in-tunnel handshake.

B costs about the same effort, adds a second encryption layer and a
per-link handshake, and buys nothing A lacks.

If the user prefers the smallest change for browser tabs alone, the rd
datagram lane is smaller, but browser video then has two media formats
(RTP on WebRTC, rd on WireGuard) until the WebRTC transport is retired.

Option A was chosen and is built (section "WireGuard carrier").

## Tests

- cnx-link `media::*` unit tests:
  - H.264 STAP-A and FU-A round trip;
  - TWCC feedback read-back;
  - sender sequence numbers and timestamps;
  - PLI and FIR rate limiting;
  - stalled-path window;
  - TWCC from a 1 Mbit/s path lowering the target;
  - receiver in-order release with no buffering;
  - a NACK resend completing a frame in order;
  - reorder;
  - an unrecoverable gap leading to PLI and resuming at a keyframe;
  - a late joiner releasing nothing before a keyframe.
- cnx-link `tests/media.rs`, over real webrtc-rs peer connections:
  - frames ride the track with TWCC flowing;
  - 3% loss below the NACK responder recovers by NACK and stays decodable;
  - older Mac and older phone leave the lane out;
  - a newer claim preempts the older one.
- cnx-link `tests/media.rs`, WireGuard (two in-process boringtun peers over
  loopback UDP with the fake signaling relay):
  - frames ride RTP in the tunnel, keyframes over 30 kB arrive whole, TWCC
    flows, the link's TCP streams still work;
  - 3% loss below the NACK responder recovers by NACK (at least 200 of 240
    frames, recovered frames seen);
  - a 1.5 Mbit/s bottleneck: the target ends under the cap, never falls
    under a fifth of it, and the queue drains (no standing delay or loss);
  - an unrecoverable loss (600 ms of packets and all their resends):
    the gap is given up, PLI, and decoding resumes at the requested keyframe;
  - the phone roams mid-stream: same lane, a PLI, a keyframe after the roam
    (the source makes none unasked), 150+ frames after it;
  - an older Mac and an older phone stay on the channel.
- cnx-link unit tests: RTP/RTCP demux, a full packet fits the 1232-byte
  datagram, the test bottleneck and blackout, the resend guard.
- cnx-hostd `browser_track` unit tests, against the real rd `MediaEngine`:
  - the host's bitrate follows the lane;
  - a full window holds the gate;
  - PLI leads to an IDR;
  - only the main stream's media is the bridge's.
- cnx-hostd `tests/host.rs`:
  - `browser_video_rides_the_webrtc_track`, including the takeover;
  - `browser_video_rides_rtp_inside_the_wireguard_tunnel`, the same over
    WireGuard;
  - `browser_video_stays_on_the_channel_for_an_older_phone_over_wireguard`.
- cnx-ffi `tests/browser.rs`: the exported viewer over the track, the
  channel, and RTP inside the WireGuard tunnel.

## Measurement support

- hostd `CNX_VIDEO_DROP_PERMILLE=N` drops N of every 1000 outgoing video RTP
  packets. The drop sits below the NACK responder, so the responder can
  resend them, as on a lossy path.
- hostd `CNX_VIDEO_LANE=0` turns the lane off.
- hostd `CNX_VIDEO_CAP_KBPS=N` (or `$CNX_STATE_DIR/video-cap-kbps`): a
  bottleneck of N kbit/s with a 250 ms queue for outgoing video RTP, on the
  WireGuard lane only.
- Phone (simulator) `SIMCTL_CHILD_CNX_DEV_NO_TURN=1`: no TURN server, so a
  relay-only WireGuard link rides the backend's WebSocket relay; the bench's
  `-wss` configurations use it.
- Phone, Settings → Transport → Developer → "Browser video on channel"
  (`-cnx.dev.browserVideoOnChannel YES`) is the baseline with no lane.

## Live verification (2026-10-14): blocked by the Mac's browser host

The comparison did not run. The tools are ready, but the browser host
produced no video on either machine, on either carrier.

### What ran

- Mac: the fleet DEV build `cnx-e2e-1bd377aa` (job `da84189e`), which is
  `feat-cnx-ios-mactry` `fe736b45` with this branch's `cnx-ios/rust`. The
  linux-pool fleet route does not bundle `cnx-hostd`, so this branch's
  `cnx-hostd`, built locally, was placed in `Contents/Resources/bin`.
- Phone: the Demo build of this branch, in one simulator.

### What worked

- The E2E rig signed in, paired with the DEBUG seed and connected over
  WebRTC direct.
- hostd logged `link up ... video=true`, so the lane was negotiated live
  through the TeamHub signaling.
- The `browser` channel opened, and hostd logged `browser: video on the
  link's media lane`.

### What failed

The app-launched `cmux-remote-browser-host` sent no media datagrams. hostd's
5-second report stayed at `host_datagrams=0 frames=0`, and the phone showed
0 fps. It is the host, not the track:

- **Rig on this Mac** (macOS 27.0.1): the `track` configuration showed
  0 fps.
- **mini-cmuxs-mac-mini-2 GUI session** (macOS 27.0.1, as in
  browser-stream.md): `track` again gave `host_datagrams=0`.
- **Offline harness** (`cnx-ffi/tests/browser.rs real_host_over_the_track`,
  ignored, `CNX_RB_HOST_EXE`): hostd started the host binary itself. Both
  this build's host and the 2026-10-13 known-good `cnx-br-2` host (job
  `8c3a903d`) gave 0 frames, on the track and on the channel
  (`CNX_RB_CHANNEL=1`). The host answered `welcome`, `started`,
  `rb.opened`, `rb.screen_applied` and `rb.page`, but sent no frame and no
  clock pong.

Every host log shows `CVDisplayLinkCreateWithCGDisplay failed. CVReturn:
-6670`. The likely cause is the 27.0.1 update, which postdates the
2026-10-13 run. That is unconfirmed, and it is outside cnx-ios.

The mini also ran out of disk (100%, under 2 GB free), so the known-good app
could not be installed there.

### Ready to rerun once the host streams again

- `verify/scripts/browser-track-bench.py`:
  - rig mode, or `--remote HOST --team --mac-device --offset-ms` with
    `verify/scripts/browser-track-mac.sh` on a fleet Mac;
  - configurations `track`, `channel`, `track-relay`, `channel-relay` and
    `track-loss30`;
  - `--record-only`, then `--analyze DIR`.
- It measures:
  - glass to glass, by OCR of the page clock against the phone overlay's
    clock in each recorded frame;
  - frame pacing, from page-area changes per video frame;
  - input to frame, split at the page's own receipt time;
  - the carrier, from the overlay's `· track` or `· channel`.
- Loss: hostd reads `$CNX_STATE_DIR/video-drop-permille` at each new link.
  The app passes no other environment to hostd.

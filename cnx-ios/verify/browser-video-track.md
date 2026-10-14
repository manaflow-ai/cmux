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
- WireGuard links never offer the lane yet. The `MediaCarrier` seam is in
  place; the carrier is described below and its stub answers `Unsupported`.

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

## WireGuard carrier (on hold: the user is choosing the transport architecture)

A WireGuard media lane must not lose smooth video. There are two candidate
designs.

### Option 1 (preferred if built): the same peer connection over the tunnel

This option runs webrtc-rs with the WireGuard tunnel as its network, so
video is the same code on both transports.

Findings on feasibility:

- `SettingEngine::set_udp_network(UDPNetwork::Muxed(UDPMuxDefault::new(
  UDPMuxParams::new(conn))))` accepts any `webrtc_util::Conn`. The trait has
  async `recv_from` and `send_to` plus `local_addr`.
- A smoltcp UDP socket on the tunnel's overlay address can implement it.
  The tunnel already runs smoltcp TCP streams.
- ICE gathers host candidates from OS interfaces even when muxed, so the
  setup needs:
  - `set_nat_1to1_ips([overlay_ip], Host)`, to advertise the overlay
    address;
  - an interface filter that keeps one interface;
  - no STUN or TURN servers.
- WireGuard-via-TURN is unaffected: TURN stays at the outer layer.
- The cost is double encryption (SRTP and DTLS inside WireGuard), which is
  acceptable.

Effort is about 1 to 2 days:

- a smoltcp UDP `Conn` adapter;
- a second, media-only peer connection per WireGuard link, with signaling
  over a link channel instead of the TeamHub DO (no backend change);
- tests.

### Option 2: RTP and RTCP in UDP inside the tunnel

This option uses the `MediaCarrier` seam with no SRTP. The cores are
already transport-agnostic, but NACK and TWCC generation would have to move
out of webrtc-rs's interceptors into the cores. That re-implements what
webrtc-rs does, so it is not recommended.

### Seam

`MediaCarrier` (cnx-link `media/mod.rs`) has `send_rtp`, `recv_rtp`,
`send_rtcp` and `recv_rtcp`. Today:

- `media::wireguard::carrier()` returns `Unsupported`;
- the WireGuard dialer never lists the lane;
- the phone keeps the reliable path (test
  `wireguard_links_keep_the_reliable_path_for_now`).

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
  - older Mac, older phone and WireGuard each leave the lane out;
  - a newer claim preempts the older one.
- cnx-hostd `browser_track` unit tests, against the real rd `MediaEngine`:
  - the host's bitrate follows the lane;
  - a full window holds the gate;
  - PLI leads to an IDR;
  - only the main stream's media is the bridge's.
- cnx-hostd `tests/host.rs`:
  - `browser_video_rides_the_webrtc_track`, including the takeover;
  - `browser_video_stays_on_the_channel_over_wireguard`.
- cnx-ffi `tests/browser.rs`: the exported viewer over the track, the
  channel and WireGuard with the lane offered.

## Measurement support

- hostd `CNX_VIDEO_DROP_PERMILLE=N` drops N of every 1000 outgoing video RTP
  packets. The drop sits below the NACK responder, so the responder can
  resend them, as on a lossy path.
- hostd `CNX_VIDEO_LANE=0` turns the lane off.
- Phone, Settings → Transport → Developer → "Browser video on channel"
  (`-cnx.dev.browserVideoOnChannel YES`) is the baseline with no lane.

## Live results

See "Live verification" below.

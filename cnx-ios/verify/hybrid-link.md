# WireGuard for the link, WebRTC for browser video

Branch `feat-cnx-ios-hybrid-link`, 2026-10-19 (base `origin/feat-cnx-ios`
`3e6a2b56eff`). The contract is PROTOCOL.md "Media session".

## What changed

- **WireGuard is the default transport.** An install with no saved choice
  dials WireGuard (it dialed WebRTC). A saved choice stays: the key
  `cnx.settings.transport` is written only when the person picks a row.
  Settings → Transport lists "WireGuard (recommended)" first ("Encrypted
  tunnel to your Mac. Browser tabs stream over WebRTC when that is
  faster.") and "WebRTC only" ("Everything over one WebRTC connection,
  direct when possible."). The Settings root shows "WireGuard" or "WebRTC
  only". An install that never chose is treated as new: there was no
  choice to keep.
- **One WebRTC media session beside a WireGuard link.** The link (every
  channel, the input lane, and browser video as RTP in the tunnel) rides
  WireGuard. A WebRTC peer connection to the same Mac carries only the
  browser video track while it works. It is signaled through the same
  TeamHub (`webrtc-offer` with `mediaFor`), uses the same `GET /v1/ice`
  Cloudflare TURN credentials, and has no data channel.
- **"WebRTC only"** is unchanged: one peer connection carries the link and
  the video track, as before.

## Design

### Two routes, one stream, switched at keyframes

```
Mac: browser host ─ rd ─▶ TrackBridge ─▶ VideoClaim::send ─▶ route table (media/routes.rs)
                                                   ├─▶ WebRTC media session track  (preferred)
                                                   └─▶ RTP on overlay UDP 7422 in the tunnel (floor)
phone: WebRTC track ─▶ ReceiverCore ─┐
       tunnel RTP   ─▶ ReceiverCore ─┴─▶ VideoIn gate (current source; a keyframe moves it) ─▶ viewer
```

- The Mac's `VideoOut` keeps one sender core per route (own sequence
  numbers, TWCC, NACK history and congestion controller). A frame goes on
  the preferred usable route. A route is usable while its sender runs, its
  carrier says healthy (the media session's peer connection is
  connected), and it is not waiting out a stall.
- **Switching only at a keyframe.** When the preferred route changes, the
  Mac asks the browser host for a keyframe (rd `need_recovery`, at most
  every 250 ms). If the old route still works, its P frames keep flowing
  until the keyframe, which then starts the new route: no gap. If it does
  not, the frames in between are dropped and the phone keeps showing the
  last frame: no black tab, at most one keyframe round trip of freeze.
- **Stall detection.** A connected peer connection whose path died
  silently is caught by feedback: the current route with packets out and no
  TWCC feedback for 500 ms (TWCC comes every 25 ms) moves video to the next
  route, and is tried again after 1 s, doubling to 16 s, back to 1 s after
  10 s of feedback. ICE consent on the media session reports disconnected
  after 3 s and failed after 8 s (webrtc-rs defaults are 5 and 25 s).
- **The phone** runs a receiver core per source and passes a source's
  frames only while it is current; a keyframe from another source makes
  that one current. A late P frame of the old route is never decoded.
  Keyframe requests (PLI) go out on every source.
- **Channel fallback** is unchanged: without the tunnel's media lane (an
  older Mac, or the lane off) video rides the `browser` channel, and the
  Mac lists `webrtc-media` only when it has the tunnel's lane, so the
  session never exists without its floor.

### Lifecycle (phone, `cnx_link::hybrid::MediaManager`)

- Opened lazily: a shown browser stream (`BrowserStream.set_visible`, from
  `StreamedBrowserPage` appearing) holds it; a workspace with browser tabs
  warms it for 60 s (`LinkHandle.warm_media`, at most every 20 s), so the
  peer connection is usually up by the time a tab is opened.
- Closed (`bye`) 30 s after the last browser tab was hidden and the warm-up
  ran out.
- Never in the way of the link: the dial runs on its own task after the
  link is up, on the warm signaling socket, and nothing waits for it.
- A failed dial or a session that failed or closed is redialed after 1, 2,
  4, 8, 16, then every 30 s while video is wanted.

### The Mac (cnx-hostd `media_session.rs`)

- A media offer is admitted like any dial (`fromUserId` is the owner), and
  then only for a live WireGuard link registered with `webrtc-media`, from
  that link's phone device, and (with pairing on) after that link passed
  `auth`: no new trust path. Otherwise `bye unknown_link` / `unpaired`.
- The session's track becomes a route of that link's lane; a newer session
  for the link replaces the older; all end with the link.
- Labels: `phone_media {session_id, media_path}`; the iPhone card adds
  "Video over WebRTC (direct|TURN)".

### Input path

Input stays on the WireGuard link's input lane (PROTOCOL.md "Lanes"):

- Browser input is part of the `browser` channel's rd stream (exactly-once
  input events, acknowledged by the host in the same ordered stream as rb
  control); moving it to a second connection would split one ordered
  conversation across two paths.
- The input lane exists from link up; the media session is lazy and may be
  down (UDP blocked, or still dialing), so input there would need a
  fallback of its own for no gain.
- Both paths take the same network route on the rig, so their round trips
  match (measured below).

## Tests

Rust (on rbx, `cargo test --workspace`; all green):

- `cnx-link` `media::routes` unit tests: the WebRTC route wins and the first
  frame needs no keyframe; a dead route falls back only at a keyframe and
  drops frames meanwhile (keyframe asked once per 250 ms); a recovered route
  takes over at a keyframe while the old one keeps sending; a stalled route
  backs off (1 s, then 2 s) and is tried again; the last route never stalls
  away; no route left closes the lane.
- `cnx-link/tests/hybrid.rs` (in-process boringtun pair, real webrtc-rs
  peer connections, the fake signaling server):
  - `video_moves_onto_the_media_session_falls_back_into_the_tunnel_and_returns`:
    nothing opens before video is wanted; a held demand opens the session
    and video moves onto it; killing the Mac's session moves video back into
    the tunnel, the phone redials and video returns; every carrier change is
    a keyframe; no gap over 1.5 s; after the linger the session closes and
    video stays in the tunnel.
  - `a_silent_media_session_stalls_video_falls_back_and_the_session_is_tried_again`:
    the session's packets vanish under a connected peer connection; video
    is back in the tunnel within 1.5 s and returns to the session after the
    backoff once the path works.
  - `with_udp_blocked_the_media_session_fails_and_video_stays_in_the_tunnel`.
  - `a_mac_without_media_sessions_leaves_the_lane_out` (and an older phone).
- `cnx-ffi/tests/browser.rs`
  `browser_video_rides_the_media_session_beside_wireguard`: the exported
  API end to end with cnx-hostd's real `serve_signaling` and
  `media_session.rs`: the open tab's video rides `webrtc-track`, falls back
  to `wireguard-udp` when the session is killed, and returns.
- `cnx-hostd` `media_session::tests`: a media session needs a live, paired
  link of the same phone (another phone, a closed link and an unpaired link
  are refused).

Swift (`verify/termqa/cnxkit-test.sh` on mini-cmux11s):

- `TransportDefaultTests`: no saved choice gets WireGuard; a saved WebRTC
  or WireGuard choice stays; choosing saves; the picker order and titles.
- `LinkStatusMediaTests`: the status line with the session up (direct,
  TURN), failed ("video in the tunnel"), and a stale link's media ignored.
- CnxKit `CnxLiveTests|CnxBrowserStreamTests|CnxModelTests|CnxTransportTests|CnxShellTests`:
  345 tests in 94 suites passed.
- CmuxNext `CnxHostTests` (fleet step): `phone_media` parsing and state.

## Live check

See "Live results" below.

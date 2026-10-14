# Streamed browser tabs (video)

Branch `feat-cnx-ios-browserstream`, 2026-10-13. A workspace's browser tab on
the phone shows the Mac's browser page as H.264 video. Touches, scrolls and
typing go back to the page, and the page's URL, title and navigation state
drive the TabsKit toolbar and address bar.

## Decision: carry `cmux.rb/1` over the link (option a), stream carrier first

The Mac already has a complete remote browser stack: `cmux.rb/1` (the browser
tab service) on `cmux.rd/1` (the remote desktop media protocol). The cmux-next
app runs it for its own remote browser tabs. The parts are:

- `cmux-remote-browser-host`, the CEF fork host bundled in DEV builds at
  `Contents/Helpers/cmux-remote-browser-host.app`, which the app starts with
  `LocalRemoteBrowserHost`;
- VideoToolbox IOSurface encode (`cmux-encode`);
- the shared media engine (`cmux-rd-engine`: frame gate, delay-based
  congestion control, quality ladder, packetizer with FEC, NACK history,
  keyframe and recovery);
- the viewer core (`cmux-rd-ffi`: reassembly, loss feedback, clock probes,
  exactly-once input).

The phone reuses that stack unchanged. Nothing is added to the media path.

| Criterion | (a) rb/rd over the link | (b) WebRTC media track (RTP H.264/HEVC) |
| --- | --- | --- |
| Glass-to-glass latency | No jitter buffer: a frame shows the moment its last shard arrives. Input is sequenced and exactly-once, with a host-side gap timeout. | libwebrtc adds a jitter buffer and playout delay. You can push it toward 0, but the receive pipeline is tuned for calls, not UI. |
| Cellular quality | Delay-based congestion control and FEC already exist. NACK uses a 16-frame history, and recovery frames reference an acknowledged frame instead of forcing an IDR. | GCC, NACK and PLI are mature. That is (b)'s real advantage, but only on the WebRTC transport. |
| Battery | Hardware decode with VideoToolbox. Rust shard reassembly is cheap. | Hardware decode too. libwebrtc is a second large media stack running on the phone. |
| Reuse of the Mac host | 100%: the app's own host, encoder and engine. | The host would need an RTP sender, a second packetizer and congestion controller, and per-transport media logic. |
| Transport-agnostic (PROTOCOL.md) | Yes: any link channel carries it, over WebRTC and over WireGuard (direct, TURN or relay). | WebRTC only. WireGuard would still need (a), so you build both. |
| Input and page metadata | rb input events (pointer, wheel with phases and momentum, pinch, key, IME) and `rb.page`, `rb.history`, `rb.navigate`, `rb.screen` already exist. | You would need a data channel for these anyway, which is (a)'s control plane. |

Choice: (a) everywhere.

The MVP carries the rd **stream carrier** (`u8 kind, u32 len` frames, as the
app's loopback viewer uses) inside one reliable `browser` link channel.

The upgrade path is additive and needs no change to rb or rd:

- a datagram lane per link, carrying rd datagrams with `Carrier::Datagram`.
  The viewer core supports it already.
  - On WebRTC: a second data channel, unordered with `maxRetransmits=0`.
  - On WireGuard: a UDP overlay port next to the smoltcp stream.
- With that lane, FEC and NACK replace TCP-style retransmission. A lost
  packet then no longer stalls every later frame (head-of-line blocking).

The data-channel lane is the right next step for lossy cellular paths. It
touches the link's channel table, which the input and priority work
(termlive) is changing now, so it lands after that work merges.

## Architecture

```
iPhone (CnxKit)                       Mac: cmux-next DEV app
TabsKit page                          IPhoneHostService ─ CnxHostSupervisor
 StreamedBrowserPage                          │ stdin/stdout control lines
  AVSampleBufferDisplayLayer ◀─ VTDecompressionSession    ▼
  gestures, UIKeyInput ─▶ rb input      bundled cnx-hostd: `browser` service
 StreamedBrowserModel (rb.page → toolbar)     │ need_browser {request, tab, url}
cnx-ffi BrowserStream (Rust)                  ▼
 cmux-rd-ffi Session + InputChannel    IPhoneBrowserHosts → LocalRemoteBrowserHost
        ▲  rd stream carrier bytes             │ (the app's own bundled CEF host)
        └──── link channel `browser` ─────────▶ cmux-remote-browser-host --serve
              (WebRTC or WireGuard)              loopback rd stream carrier
```

- **Phone.** It opens `browser {tab, url}`, where `tab` is the daemon tab id
  (`s<surface>`).
  - Rust runs the rd viewer core. Swift receives whole access units, each
    with its capture time and age.
  - `rb.open` and `rb.screen` lay the page out at the page view's size in
    points. The scale is the screen scale capped at 2, so a 402×705 pt page
    renders at 804×1410 px.
  - Input:
    - A tap sends pointer move, down and up.
    - A one-finger pan sends precise wheel events with phases. A fling sends
      momentum wheel events (decay 0.95 per frame).
    - Pinch sends `pinch`.
    - Typed text goes as `ime_commit`. Return, Tab and Backspace go as keys.
  - The keyboard toggles from a glass button on the page, because the host
    does not report a focused text field yet.
- **hostd.**
  - It asks the app for a host for each tab (`need_browser`) and sends the rd
    `hello` with the host's per-launch secret. The phone never sees the
    secret.
  - It splices the carrier. Phone frames are filtered: datagrams pass, and of
    rd control only viewer rb messages and `stop` pass. `rb.navigate` must be
    http, https or `about:blank`, and a second `hello` and bulk frames are
    dropped.
  - A host outlives its channel. Reopening the tab takes the host over: the
    older channel closes with `replaced`, and the page and its history stay.
  - At most 4 hosts run (`CNX_RB_MAX_TABS`), and the least recently used one
    is stopped (`browser_stop`).
- **App.** `IPhoneBrowserHosts` (DEBUG, like the host it bundles) starts one
  `LocalRemoteBrowserHost` per phone tab, answers with port and secret, and
  reports `browser_gone` when the host exits. A hostd restart stops them all.

## Verification

See the results section below (filled in from the live run).

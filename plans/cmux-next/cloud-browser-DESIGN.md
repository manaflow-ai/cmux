# cmux next: cloud streamed browser (Mighty-style)

Status: design and prototype, 2026-10-20 (subagent "Cloud streamed browser", group Agents & routing).
User ask, 2026-10-20: "make sure work is getting done for the cloud version. Are we in the position of
Mighty App, where we stream a browser from the cloud? With extremely little latency. I want to focus on
that as well."

Parents (read these, this doc does not repeat them): `remote-tab.md` (RT1-RT14, the remote browser tab:
CEF fork, `cmux.rb/1`, split compositor), `remote-tab-r1.md`, `remote-tab-r2.md` (macOS host),
`remote-desktop.md` (RD1-RD11, `cmux.rd/1`, measured budget), `remote-tab-protocol.md`.
This doc adds: where cloud work stands today, the protocol comparison the user asked for, a working
cloud prototype with numbers measured from Lawrence's Mac, and the order to ship it.

## Direction change (2026-10-20, after remote-desktop-DESIGN.md, 902f2b13112)

[remote-desktop-DESIGN.md](remote-desktop-DESIGN.md) makes `cmux-screen-host` (Aziz's Rust WebRTC
host) the one host engine (U1, U2) and retires `cmux.rd/1` media and `cmux-rd-host` at M5. Its M3 step
moves this cloud browser onto that host. So:

- The `cmux-rd host --browser` prototype below stays as a measured baseline only: the "Cloud VM, software
  encode" row of that doc's section 4 targets. No more cloud browser work goes into `cmux-rd-host`.
- What carries over: the browser supervisor (`cmux-rd-host/src/browser.rs`: Chrome outlives viewers,
  restarts after a crash, stops with the host) is backend-agnostic and moves into the `desktop` role of
  `cmux-screen-host` at M3; the marker page and the click/scroll bench method carry over unchanged.
- The cloud browser on `cmux-screen-host` waits on three things that are not on feat-cmux-next:
  `cmux-screen` itself (draft [#20413](https://github.com/manaflow-ai/cmux/pull/20413); M0 merge order is
  Aziz's), Linux X11 input (M2: `backend/desktop.rs` logs "input is not implemented for this backend yet;
  the stream is view-only"), and a WebRTC source in the `remote_view` pane (U5; Aziz's #20426, draft).
- Section 2.2's choice of `cmux.rd/1` over WebRTC is replaced by U2. The trade-off stays: `cmux.rd/1`
  measured 13 ms key G2G in a VM; WebRTC adds about 30 ms of jitter buffer and pacing unless the
  section 4 measures (playout delay 0) land.

### View-only check on `cmux-screen-host` (2026-10-20)

One Freestyle VM (`vm-f2296c0030dd4bb0a0e6115c36bacca3`, 16 vCPU / 32 GiB, deleted after; under $1).
`cmux-screen-host --backend desktop --no-tailnet` from `feat-cmux-next-tailnet-media` (4fce3bda894)
built on the VM, streaming Xvfb `:1` (1920x1080) with Chrome full screen on a page that scrolls
text every frame. Viewer: headless Chrome on the same VM (its own WebRTC), joining the existing
room Worker as `viewer`, host candidates only. Scripts: `experiments/cloud-browser/screen-check/`.
View only: the Linux backend has no input (M2), so no input-to-frame number exists yet.

| Run | WebSocket open | answer | ICE connected | first frame | presented fps | decoded fps | Mbit/s | jitter buffer | host CPU |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 422 ms | 615 ms | 619 ms | **731 ms** | 48.6 | 58 | 2.9 | 9 ms | 129 % of a core |
| 2 | 418 ms | 782 ms | 785 ms | **1536 ms** | 50.4 | 60 | 3.0 | 8 ms | 125 % |

Connect to first frame 0.7-1.5 s (the design's target is ≤ 1.0 s); most of it is the round trip
to the Cloudflare room. The host held 59-60 fps at 1080p full-screen motion. Its log shows the
browser viewer negotiated **libvpx (VP8)**, software, not H.264: a cmux viewer must prefer H.264
(and on CPU VMs Cisco's OpenH264, per the codec default). Host CPU above one core is capture,
I420 conversion and VP8 at 60 fps; it is the number the 2-core encode budget must hold.

Build notes for M2: libwebrtc's prebuilt needs clang 21 (Ubuntu 24.04 has 18; apt.llvm.org works)
and the link needs gio/gobject/glib and the X11 libraries added (`build.sh` passes them as
RUSTFLAGS); the room's `/ice` has no CORS headers, so a web viewer cannot read it.

## 0. Answer in one paragraph

Not yet in Mighty's position, but closer than it looks. The hard parts exist: a low-latency media
engine (`cmux.rd/1`: FEC, delay-based congestion control, one frame in flight, exactly-once input),
a macOS client pane that decodes with VideoToolbox (`CmuxNextRemoteView`), and a Chrome-style CEF host
with native menus, dialogs and Cmd-click (`cmux-remote-browser-host`, macOS only). What is missing is
the cloud half: no Linux remote browser host (step r7 never started), no cloud VM image role, no
non-debug way for the app to reach a cloud host, and no relay path that carries UDP. The prototype in
section 3 closes the first gap the fast way: Chrome in a virtual display on a Freestyle VM, streamed by
the existing `cmux-rd` host. In the VM, a keypress reaches a decoded frame in 13.4 ms p50 and a click
in 24 ms p50. From this Mac over Wi-Fi and an SSH tunnel a keypress takes 30 ms p50 (under the
50 ms target) but 95-99 ms p95, and clicks 60 ms p50: the tail is the network path, not the browser.

## 1. Cloud status (2026-10-20)

Evidence: git history of `origin/feat-cmux-next` (bcd6c373839) and cmuxterm-hq `origin/main`
(f2d6b01bd1cf), read-only. Production `cmux-api` was not queried, so "prod" for the Worker means
"configured for prod", not "seen serving".

| Item | What | Status | Evidence |
| --- | --- | --- | --- |
| Cloud VMs (`cmux vm`, web `app/api/vm/*`, Freestyle driver) | Classic cmux Cloud VMs on Vercel + PlanetScale `cmux-prod` | **Live in prod** | deployed from `main` (5b084f4fc76) |
| Freestyle tenant VMs (a205) | The Cloud VM API as the per-team wrapper ("4 GB VM") | **Prod API live; the checkout-link fix is feat-cmux-next only** | cmuxterm-hq `plans/freestyle-tenant-DESIGN.md` (#2610); fixes b505c5d0d6b..08bd8ab1a7f not on `main`; acpmux not in the image |
| Org workflows (a203/a205) | Machine and agent steps in automations | **Prototype only** | `org-workflows-DESIGN.md` section 7: no run through the deployed staging Worker |
| Cloud Chief (a184/a196/a235) | Lawrence's Chief host on Freestyle VM `vm-4d2e45630a2c4814ac3d8b1884fcd9d1` (tailnet `cloud-chief`) | **Running on prod infra, not finished** | cmuxterm-hq `tools/cloud-chief/`, `plans/cloud-chief/REPORT.md`: pairing done by a196 (M7KP-SNJC); no full chat turn proven; a235's redeploy gap fix pending |
| Agent hub | Moved onto the Cloud Chief VM (`cloud-chief-hub`, 100.127.110.65:8790) | **Live (internal)** | cmuxterm-hq #2611 8e30537cb2f; old hub VM deleted |
| Cloud subagents (a242) | Subagents as acpmux peers on Freestyle VMs | **Prototype on HQ infra** | `cloud-subagents-PROOF.md`, cmuxterm-hq #2623 |
| Hosted Chief (`ChiefBrainDO`, `chief-cc`) and the other Durable Objects (TeamDO, CloudDO, TeamVmDO) | `backend/apps/api` Worker | **Staging current (347a9270354); production held** | `CMUX_NEXT_PRODUCTION_HOLD` is on; last `cmux-next-production` deploy 2026-10-03 |
| Open Cloud as Pane (a166) | Cloud page as a pane | **Shipped to nightly-next** | test cbb869c4d1c, fix 31681277023 |
| Pricing `/next/pricing` | Proposal page | **Preview only, noindex** | 01f72d5cbe8 |
| Remote browser tab (`cmux.rb/1`, CEF fork) | The Mighty-style tab | **macOS host only; no Linux host; r7 (cloud image role) not started** | `cmux-remote-browser-host/src/main.rs:165` "the macOS host is the only host in r2"; last host commit d48308b38a1 (10-14) |
| Remote desktop (`cmux.rd/1`, `cmux-rd-*`) | Low-latency desktop streaming engine | **Prototype; quiet since 10-07** | `remote-desktop.md` 15.7: in-VPC Freestyle marker G2G 9.4/11.8 ms |
| Cloud browser prototype (this doc) | Chrome in Xvfb streamed by `cmux-rd host --browser` | **Prototype, measured (section 3)** | this change |

Stalled, with the blocker:
1. Cloud Chief end to end: no proven chat turn; a235 owns the redeploy gap.
2. `cmux-api` production: held until Lawrence's first go (hold variable above).
3. Tenant checkout fix and acpmux in the VM image: on feat-cmux-next, not on `main`.
4. Remote browser on Linux: nobody owns r7; the remote tab lead has been quiet since 10-14.
5. cmux-next has no `vm` scope (`vm.list` is `method_not_found`), so Chief drives cloud VMs through the classic CLI.

## 2. Design: Mighty-style cloud browser

### 2.1 Shape

```
Freestyle (or GCP) VM, one per user or per session                     cmux-next on the Mac
  virtual display (Xvfb now; headless Ozone in the CEF host later)
  Chromium, full Chrome layer (extensions, passwords, DevTools)        remote_view / remote browser pane
     │ damage                                                            CmuxNextRemoteView: VideoToolbox decode,
  cmux-rd host (Rust)  ── cmux.rd/1 media + input ──►  overlay  ──►    Metal present (newest frame wins),
     capture → encode (x264 / NVENC / VA-API)        (WireGuard UDP;    local cursor, HID input, IME
     FEC, delay-based CC, one frame in flight         TCP fallback)
  browser supervisor (keeps Chrome up across viewers)
```

Two hosts, one wire. Stage A (now, this prototype) streams the display Chromium draws into: works
today, any Chromium, full fidelity, but Chromium-drawn menus and no damage hints from Viz. Stage B is
`remote-tab.md` RT2: the CEF fork's windowless Chrome style with Viz capture (damage rects, no extra
copy, native menus and dialogs through `cmux.rb/1`) built for Linux. Stage C is RT3's split compositor
(scroll and pinch run on the Mac). The client pane and the transport are shared by all three, so
nothing in stage A is thrown away.

### 2.2 Pixels: protocol comparison

| | WebRTC (H.264/AV1, HW encode) | CDP `Page.startScreencast` | Damage-region / tile protocol | `cmux.rd/1` (ours: video + damage gating) |
| --- | --- | --- | --- | --- |
| Latency floor | jitter buffer and pacer tuned for calls: 30-80 ms added in practice unless both ends are hacked (playout delay 0) | JPEG per frame, ack before next frame, renderer-side throttle: 50-150 ms, 10-30 fps measured widely | low when changes are small; big changes (scroll) cost full tiles | 13.4 ms p50 key-to-decoded in VM (3.2); no jitter buffer on direct paths (RD5) |
| Text crispness | 4:2:0 smears colored text; fine for motion | JPEG artifacts | lossless tiles: pixel exact | video for motion + idle refinement / lossless top-off (RD2, RT4) |
| Bandwidth | good (congestion control built in) | poor (JPEG) | poor for motion | 0.36 Mbit/s typing, 14 Mbit/s full-screen scroll (3.2) |
| Browser client (web dashboard, iOS Safari) | native everywhere | trivial | needs a JS decoder | needs WebCodecs or a WebRTC bridge |
| Ownership | libwebrtc is 1M+ lines; hard to remove buffering | Chrome-internal, no input path guarantees | ours | ours, landed, tested |
| Agent use | — | the natural agent API (CDP) | — | agents use CDP on the same Chrome; humans watch the stream |

Decision CB1: humans watch and drive through `cmux.rd/1` (and later `cmux.rb/1`) video, not WebRTC
and not CDP screencast. WebRTC stays an option only as a bridge for the web dashboard and iOS Safari
(the fleet Rust script has a `screen` mode for a WebRTC screen host workspace, `cmux-screen`, which is not in this tree). CDP stays the agent control plane on the same
Chrome; it never carries frames to a human.

### 2.3 Latency budget (target: under 50 ms input-to-photon at 60 fps on a good network)

| Stage | Budget | Measured (prototype) |
| --- | --- | --- |
| Mac input to wire | ≤1 ms | — |
| Network one way | RTT/2: 4-9 ms in-metro wired | Wi-Fi here: RTT p50 17 ms, p95 80 ms through the SSH gateway (3.3) |
| Chrome input to paint to capture | ≤8 ms (key), ≤12 ms (click) | key 4.6 ms, click 12.5 ms, scroll 39.7 ms p50 (software raster, smooth scroll) |
| Encode | ≤5 ms | x264 ultrafast 5.4-7.6 ms p50 at 1080p |
| Decode | ≤3 ms | 2.6 ms p50 (openh264 bench); VideoToolbox lower |
| Present (wait for refresh + scanout) | 4-8 ms at 120 Hz | not measured (bench stops at decode) |
| Total | ≤50 ms | VM-local 13.4 ms key; from this Mac 30 ms p50 / 99 ms p95 key, 60 ms p50 click (3.3) |

What it takes to hit 50 ms from a home: a region within about 15 ms RTT (Freestyle is in San Francisco;
this Mac is too), UDP media (not TCP through a proxy: one lost packet costs a retransmit timeout, RD
finding 8), and wired or good Wi-Fi. The pane must say when the path cannot be interactive
(`remoteDesktop.interactiveMaxRttMs`, default 80 ms).

### 2.4 Text, scrolling, and the rest

- Text crispness: stream at the pane's backing pixel size (2x on Retina) so the Mac never scales;
  `--force-device-scale-factor` = the viewer's scale; idle refinement (RD2) re-sends a static frame at
  low QP 150 ms after motion stops; lossless tiles in stage B (RT4).
- Scrolling: in stage A, every scroll is a full-frame encode (measured 14 Mbit/s, 55 ms p50 in VM,
  host CPU 91 % of a core). Fixes in order: disable Chrome smooth scrolling in the stream host (measured:
  same latency, 4x less bandwidth and host CPU, section 3.2); GPU raster and hardware encode on GPU VMs; local
  scroll prediction in the pane (translate the last frame by the predicted offset and reveal the
  exposed strip on the next frame, Mighty did this); the real answer is RT3's split compositor (scroll
  happens on the Mac at display rate, the server sends tiles ahead).
- Audio: Chrome's PulseAudio sink to Opus 20 ms frames on the rd datagram channel (RD section 9,
  not built); target added delay 30-40 ms, synced to video by capture timestamps.
- Clipboard: Cmd-C/Cmd-V as rd control messages with the user's consent per paste (remote-tab r3).
- Downloads: the host watches Chrome's download directory and offers the file to the Mac through the
  rd bulk channel (`cmux-rd-core/bulk.rs` exists), saved to ~/Downloads after the user picks.
- IME: Mac `NSTextInputClient` sends committed text as `InputEvent::Text` and marked text as
  composition updates (rb r3); X11 stage A gets committed text only.
- DevTools: open in the same streamed window (stage A) or as a second stream (stage B popup surface);
  `chrome://inspect` remote debugging stays on the VM loopback, reachable through the tunnel for agents.
- Agents: drive the same Chrome over CDP (the existing `cmux-browser-host` driver); the human sees the
  agent's moves in the stream and the browser-use cursor is drawn by the Mac from relayed CDP input
  events (`agent-cursor.md`), not burned into pixels. The automation lease (one writer) arbitrates
  human vs agent input.
- Sessions that survive disconnects: the browser lives on the VM, not in the stream. `cmux-rd host
  --browser` keeps Chrome running when the viewer leaves and restarts it after a crash (this change);
  a viewer that reconnects gets an IDR and the same tabs. The VM pauses after an idle timeout
  (Freestyle pause keeps memory, so a resume restores the exact session in about 1-2 s).

### 2.5 Cost per hour (Freestyle list, freestyle.sh/pricing via `pricing-DESIGN.md`)

$0.04032 per vCPU-hour + $0.0129 per GiB-hour.

| Size | $/hour | Fits |
| --- | --- | --- |
| 2 vCPU / 4 GiB | $0.13 | reading and typing (encode is idle when the page is idle) |
| 4 vCPU / 8 GiB | $0.26 | 1080p browsing with scroll (x264 takes about one core while scrolling) |
| 8 vCPU / 16 GiB (the prototype VM) | $0.53 | Retina-size streams, video pages |

Paused VMs cost storage only. Mighty's lesson: always-on GPU boxes per user killed the margin; a
paused-when-idle CPU VM at $0.13-0.26/h is in range of a $20-50/month plan at a few hours a day.

## 3. Prototype (2026-10-20)

### 3.1 What runs

- VM `vm-a15b441b602c4b33bf9cc5369a401793`, Freestyle (HQ account, `~/.secrets/freestyle-beta.env`),
  San Francisco, 8 vCPU / 16 GiB, Ubuntu 24.04, gpui snapshot; created with
  `experiments/cloud-browser/vm.ts create`.
- `experiments/cloud-browser/vm/start.sh`: Xvfb 1920x1080, then `cmux-rd host --browser URL` (Google
  Chrome 155 kiosk at scale 1, x264 ultrafast zerolatency) on 127.0.0.1:4103.
- The page is `experiments/cloud-browser/vm/marker.html`: the rd marker (20 cells, 16-bit counter) that
  increments on keydown, mousedown and wheel, over 400 paragraphs of text. The bench reads the counter
  out of decoded pixels, so a sample is the full input-to-decoded-frame time through real Chrome.
- From the Mac: the Freestyle SSH gateway (`<vm>.beta-ssh.freestyle.sh`, VM-scoped identity token)
  with `ssh -L 14103:127.0.0.1:4103`, so the stream carrier is TCP inside SSH (no UDP path yet).
- The client is `cmux-rd bench` built for macOS on the Mac minis (`cmux-tui-rust-check.sh rd-bench`).

### 3.2 In-VM numbers (loopback UDP; isolates Chrome + capture + encode + decode)

150 samples each, `cmux-rd bench --input key|click|scroll`, 0 lost.

| Input | G2G p50 / p95 / p99 ms | input→capture p50 | capture→decoded p50 | encode p50 | Mbit/s | host CPU (one core = 100) |
| --- | --- | --- | --- | --- | --- | --- |
| key | 13.4 / 19.0 / 46.6 | 4.6 | 8.7 | 5.4 | 0.36 | 5.4 |
| click | 24.2 / 29.4 / 36.4 | 12.5 | 11.0 | 7.3 | 0.52 | 10.4 |
| scroll (300-line wheel) | 55.2 / 79.5 / 99.1 | 39.7 | 13.5 | 7.6 | 13.98 | 91.2 |

| scroll, Chrome `--disable-smooth-scrolling` | 54.0 / 68.9 / 93.6 | 42.1 | 12.3 | 8.4 | 3.62 | 24.6 |
| key, same Chrome | 14.4 / 19.2 / 45.9 | 4.8 | 9.4 | 6.0 | 0.39 | 8.9 |

An earlier key run (Chrome started by `start.sh`, before `--browser`) gave 11.6 / 20.1 ms p50/p95.
Turning smooth scrolling off does not change scroll latency (Chrome still needs about 40 ms to
raster the scrolled page in software) but cuts the stream from 14 to 3.6 Mbit/s and host CPU from
91 % to 25 % of a core, because one wheel step becomes one frame instead of an animation.

### 3.3 From this Mac

Network: RTT through the SSH gateway p50 17.2 ms, p95 79.7 ms, min 8.8 ms (200 TCP echoes). The same
Wi-Fi pings 1.1.1.1 at 5.7 min / 13.9 avg / 74 max ms, so most of the tail is this Mac's Wi-Fi, not
Freestyle.

Bench: `cmux-rd bench` for macOS arm64 (fleet artifact, step 6d5c6b701ddbd6f569c98c19), stream
carrier through `ssh -L`, Chrome with `--disable-smooth-scrolling`, 1920x1080, x264 baseline. The
number is input sent on this Mac to the marker decoded on this Mac (display present not included;
add 4-8 ms at 120 Hz).

| Input | Run | G2G p50 / p95 / p99 ms | min | samples over 1 s (lost) | notes |
| --- | --- | --- | --- | --- | --- |
| key | 1 | 28.8 / 94.2 / 119.4 | — | 0 of 150 | decode 0.8 ms p50, client CPU 0.9 % |
| key | 2 | 30.3 / 98.9 / 111.6 | 17.4 | 0 of 200 | host settled at 1.06 Mbit/s |
| click | 1 | 60.5 / 108.2 / 143.3 | — | 9 of 150 | |
| click | 2 | 59.9 / 125.3 / 163.9 | 19.9 | 21 of 200 | |
| scroll | 1 | 81.6 / 158.1 / 284.7 | — | 41 of 150 | |

Same VM, same carrier inside the VM (no network): click 25.2 / 29.1 ms, scroll 53.1 / 70.6 ms, 0 lost.

Reading: the key path meets the 50 ms target at the median (30 ms = VM 14 ms + about 16 ms of
network and tunnel), but the p95 does not: the tail is Wi-Fi plus TCP inside SSH through a proxy,
and the congestion controller then backs the bitrate off (1 Mbit/s), so larger frames (click repaints,
scroll) wait behind the pacer and some samples pass 1 s. Clicks and scroll need the UDP path (CB-4)
and a wired or 5 GHz link before their numbers mean anything; the VM-local numbers (3.2) are the
floor they would reach.

### 3.4 What the numbers say

1. Chrome itself is fast for keys (4.6 ms to capture) and slow for scroll in software raster (40 ms):
   scroll is the stage-A weak spot, as remote-tab.md 1a predicted; it is why RT3 exists.
2. Encode cost follows damage: typing costs 5 % of a core and 0.4 Mbit/s; scrolling a full 1080p page
   costs a core and 14 Mbit/s. A 2 vCPU VM is enough for reading; scrolling wants 4.
3. The SSH gateway is fine for a prototype and wrong for the product: TCP plus a proxy hop doubles
   the RTT tail. The product path is UDP over WireGuard (Freestyle tunnels, transport.md), which the
   engine already speaks (RD4).

## 4. Order to ship (proposal)

| Step | Content | Size |
| --- | --- | --- |
| CB-1 | Done here: `cmux-rd host --browser` (supervised Chrome that outlives viewers), bench click/scroll, fleet bench artifact | landed |
| CB-1b | Seen in the app: fleet Debug build `cmux DEV cloud-browser-v2` (job a3eedbb24e00020f5eaf7f65, 4fd8b20dee9) with `CMUX_NEXT_RD_DEBUG_PORT=14103` / `_TOKEN_FILE`; `debug.remote_view` open + connect streamed the cloud Chrome page into a pane (hardware decode, 0 decode errors). Gaps: the tab came up in `mode=view` (the pane does not forward input in view mode, so in-app keyboard and mouse were not tried; the bench proved input on the same wire), and text was blocky (stream scaled into the pane, bitrate backed off on the Wi-Fi tunnel). | partly done |
| CB-2 | Cloud image role: `cmux-rd` + Chrome + Xvfb in the Cloud VM snapshot, started by `cmux host run --browser`; idle pause | 1-2 days |
| CB-3 | App: a non-debug `remote_view` connection to a cloud VM (today only `RemoteViewDebugRdHost`, DEBUG, loopback env vars): "Open Cloud Browser" in Cmd+Shift+P, CLI and MCP, the token through the server API | 2-3 days |
| CB-4 | UDP path: Freestyle tunnel (WireGuard) from the app's `cmux link`, so media rides datagrams with FEC | 2-4 days |
| CB-5 | Viewer-sized display (RandR on the virtual display; Chrome window follows the pane), scale 2 for Retina | 1-2 days |
| CB-6 | Clipboard, downloads, audio (sections 2.4) | 1 week |
| CB-7 | Stage B: Linux build of `cmux-remote-browser-host` (CEF fork headless Ozone + Viz capture): native menus, damage, no X | weeks (r7) |
| CB-8 | Stage C: split compositor (RT3) for local scroll | months |

## 4a. Contract for cloud subagents (B10 in cloud-subagents-DESIGN.md, a306)

A cloud subagent on a Freestyle VM uses the cloud browser on its own VM. The API stays usable from there:

1. Start: `cmux-rd host --browser URL --owner OWNER --display :99 --token-fd N` (flag off by default;
   `experiments/cloud-browser/vm/start.sh` is the reference). It binds 127.0.0.1 only, so an agent on
   the same VM reaches it with no network setup, and a human reaches it through a tunnel.
2. Drive: the agent controls the same Chrome through CDP on the VM's loopback, never through the video
   stream (CB1). Gap: `--browser` does not yet open a CDP port; CB-2 adds `--browser-cdp-port N`
   (loopback only, off by default) so the agent's CDP driver and the human's stream share one Chrome.
3. Watch and take over: the user's Mac opens a `remote_view` pane on that VM's host (today the
   DEBUG-only `CMUX_NEXT_RD_DEBUG_PORT` path; CB-3 makes it a normal action). One controller at a time:
   the automation lease decides between the agent and the person.
4. Lifetime: Chrome outlives viewers and restarts after a crash (tested); it stops with the host, so
   the subagent's VM teardown also ends the browser.

Landed for point 2 (CB-2): `cmux-rd host --browser-cdp-port N` (127.0.0.1 only, off by default),
proven by a test that starts real Chrome under Xvfb, runs `Runtime.evaluate` over the DevTools
WebSocket, sees the page title change, and checks the port does not answer on the VM's network
address (`browser::tests::cdp_an_agent_drives_the_cloud_browser_on_loopback_only`, `--ignored`; needs
Chrome and Xvfb). Image role: `/usr/local/bin/cmux-cloud-browser` and the `cmux-cloud-browser` unit in
the devbox image, shipped but not enabled; it does nothing without `CMUX_CLOUD_BROWSER=1`. Gap: the
`cmux-rd` binary is not in the image yet, so the unit exits with "cmux-rd is not installed" until
it is; and per remote-desktop-DESIGN.md M3 the stream side moves to `cmux-screen-host`.

Far users: one region (Freestyle, San Francisco) for now. Users far from the West Coast pay their
RTT to SF on every input; above `remoteDesktop.interactiveMaxRttMs` (80 ms) the pane is view only
until a second region exists.

Changes to these four points must keep a VM subagent able to start, drive and hand off the browser.

## 5. Open questions for Lawrence

1. Freestyle account: this prototype used the HQ key (`freestyle-beta.env`). Tenant cloud browsers
   must go through the tenant VM API (prod key on the server). Confirm that is the product path.
2. H.264 licensing (D-RD1): the prototype uses x264 (GPL, patent pool). Ship x264, Cisco's OpenH264
   binary (slow screen mode), or hardware-only (GPU VMs cost more)?
3. Region: Freestyle runs in San Francisco only as far as measured; users outside the West Coast need
   a second region (or GCP) to stay under 50 ms.
4. Who owns stage B (r7)? The remote tab lead has been quiet since 10-14.

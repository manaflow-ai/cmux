# D2 `bakeoff`: V1 vs V2 vs V3 and the path policy

Status: local loopback decision recorded; the device and WAN gates remain open. Plan: [PLAN.md](PLAN.md) D2.
Binding: [a3-link.md](a3-link.md), [b2-webrtc.md](b2-webrtc.md) (V1), [b3-webrtc-wg.md](b3-webrtc-wg.md)
(V2), [b4-direct.md](b4-direct.md) (V3), [c1-terminal-rpc.md](c1-terminal-rpc.md) section 8 (latency
telemetry), `transport.md` section 13 (prior WAN measurements). Code: `Packages/Shared/CmuxLinkBench`.
Raw results: [bakeoff/results](bakeoff/results), reproduced by [bakeoff/run-local.sh](bakeoff/run-local.sh),
tables by [bakeoff/summarize.py](bakeoff/summarize.py). Checked-in comparisons use a
`cmux-link-bench-manifest/1` file so a table names its exact result files and source commit.

Audit note (2026-10-07): the loopback harness and carrier conformance results are evidence for the
current DEV path policy only. The split Mac/iPhone harness (F2) is not implemented: there is no
`cmux-link-bench serve` command, no iOS DEV Link bench screen, and no `bakeoff/device/` result set.
The device pass bars in section 6 therefore remain release gates. V3's loopback `roam` row is also
synthetic: the direct carrier has no TURN alternate, so forcing `.turn` after a direct TCP drop does
not model a reachable path. Treat that row as unsupported until the rig has two real direct
endpoints (or omit it from carrier comparisons).

## 1. Decision

- Default stream carrier: **V1 `webrtc`** for every rendezvous path (p2p and TURN). V2 `webrtc-wg` stays
  behind the DEV switch and is not shipped as a default. V3 `direct` is not a competitor of V1: it is
  the first rung of the path policy whenever a direct route exists.
- Runtime path policy stays `direct (V3) > p2p (V1) > turn (V1) > relay (DO, control-sized only)`, the
  `PathPolicy` default with its 150 ms preference window and the B4 route planner (only V3 races while
  its route is up; fall back to the full race when the host does not answer).
- Why V1 over V2, on these numbers: V2 spends 6x the CPU per MiB of V1 for less throughput (268 to 326
  vs 44 to 86 ms/MiB, both ends), cannot carry media tracks (C2 browser and C3 remote desktop need V1
  anyway), and its fixed-window ARQ without congestion control collapses under loss (section 4.3). Its
  one structural advantage, an end-to-end boundary the relay cannot read, is matched by B2's signed
  DTLS fingerprints (b2-webrtc.md section 8): a relay that swaps SDP cannot sign for the pinned keys.
  V2's other advantage, roaming without a session reconnect, costs V1 about one reconnect (5 ms on
  loopback, 3 to 4 RTT on a WAN), which LinkSession resume already makes lossless.
- F1 (large-message collapse) is fixed in the carrier (B2, 2026-10-07): V1 splits lane frames into
  8 KiB messages, schedules them by lane priority against `bufferedAmount`, and bounds reliable bytes
  in flight with a 256 KiB credit window. 64 KiB bulk now measures 595 Mbit/s with 0.9/1.4 ms echo
  p50/p99 under bulk and no UDP drops (was 10 Mbit/s and 12.5/3944 ms). Senders no longer need to
  chunk; device runs (section 6, step 7) still confirm it on a phone.
- Revisit V2 only if device runs show V1 DTLS/SCTP failing where V2's single unreliable channel
  succeeds (for example a TURN path that throttles SCTP), and only after F4 to F6.

## 2. The harness

`CmuxLinkBench` (library + `cmux-link-bench` CLI, macOS) drives any `LinkCarrier`/`LinkAcceptor` pair
through `LinkSession` and `LinkHost`, wired the way the app wires them. Each workload gets fresh
endpoints, every step has a wall-clock limit, and each rig runs in its own process so the memory
high-water mark belongs to it. One JSON file per run (schema `cmux-link-bench/1`).

| Workload | What it measures |
| --- | --- |
| `connect` | fresh endpoints per sample: `connect()` to live, and to the first echoed byte on a newly opened `input` channel (5 samples, the first includes process setup) |
| `rtt` | sequential 64 B echoes on a reliable `input` channel, idle (up to 1000 samples or 6 s) |
| `rtt-bulk` | the same echoes while a reliable `bulk` channel downloads host to dialer without pause: head-of-line cost of bulk on interactive |
| `flood` | steady-state host-to-dialer throughput of 4 KiB records on a `render` channel with C1's 256 KiB credit (terminal flood) |
| `bulk` | the same with 64 KiB records (`--bulk-record`) on a `bulk` channel (4 MiB credit) |
| `raw` | bulk frames on a bare `LinkTransport`, no session: carrier cost alone |
| `reconnect` | transport drop, then one echo sent at once; fault to echo (retention and resume included) |
| `roam` | `roam(to: .turn)` for carriers with a TURN alternate (live transports die or move, new ones land on TURN); fault to echo, whether the session reconnected, path after. V3 direct has no valid TURN roam until its rig supplies an alternate direct endpoint. |
| CPU, memory | process user+system CPU over each throughput window per MiB (both ends in one process); `ru_maxrss` and `phys_footprint` |

Rigs: `v1` (two libwebrtc peers on loopback host candidates, in-memory signaling relay, real ICE,
DTLS, SCTP), `v2-webrtc` (B3 over B2's real `wg` data channel), `v2-mem` (B3 over the in-memory
underlay, with `--rtt-ms` and `--loss`), `v3` (Noise IK over TCP on 127.0.0.1), `ref` (A3's loopback
carrier: no sockets, no crypto; the cost of `LinkSession` alone). Throughput is measured after 1 MiB
of warm-up over a fixed window (4 s, 2 s with `--quick`).

```bash
swift build -c release --package-path Packages/Shared/CmuxLinkBench
Packages/Shared/CmuxLinkBench/.build/release/cmux-link-bench --rig v1 --out /tmp/v1.json
Packages/Shared/CmuxLinkBench/.build/release/cmux-link-bench --rig v2-mem --rtt-ms 80 --loss 0.01 --quick
plans/cmux-next/ios-next/bakeoff/run-local.sh      # the full set below, about 20 minutes
python3 plans/cmux-next/ios-next/bakeoff/summarize.py
# Reproduce the E1 table from its exact file set (the directory selector also finds manifest.json):
python3 plans/cmux-next/ios-next/bakeoff/summarize.py \
  plans/cmux-next/ios-next/bakeoff/results/e1/manifest.json
```

## 3. Results on loopback

Machine: Apple M4 Pro (14 cores), macOS 27.0.1, release build, load average 23 to 60 during the runs
(about 20 agents share this Mac). Unshaped rows are the median of 3 runs.

| Rig | first byte p50 ms | echo p50/p99 ms | under bulk p50/p99 ms | flood Mbit/s (CPU ms/MiB) | bulk Mbit/s (CPU ms/MiB) | raw Mbit/s | reconnect ms | roam ms (session kept) | max RSS MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ref (A3 loopback) | 0.1 | 0.03/0.05 | 0.4/2.7 | 4686 (4) | 48637 (0) | 340322 | 0.1 | 0.1 (no) | 69 |
| V3 direct | 1.3 | 0.13/0.21 | 4.7/11.9 | 726 (31) | 2871 (6) | 2604 | 1.3 | 1.3 (no) | 25 |
| V1 webrtc, 64 KiB bulk (F1 fix) | 7.4 | 0.22/0.30 | 0.9/1.4 | 334 (72) | 595 (32) | 662 | 5.2 | 4.8 (no) | 858 (a) |
| V1 webrtc, 8 KiB bulk (F1 fix) | n/a | 0.23/0.39 | 0.5/1.1 | n/a | 327 (63) | 353 | n/a | n/a | 309 (a) |
| V1 webrtc, 64 KiB bulk (before F1) | 11.4 | 0.27/0.92 | 12.5/3944 | 184 (86) | 10 (44) | 7 | 5.3 | 5.2 (no) | 68 |
| V1 webrtc, 8 KiB bulk (before F1) | n/a | 0.22/0.61 | 0.9/6.4 | n/a | 316 (46) | 431 | n/a | n/a | 65 |
| V2 over real WebRTC | 7.4 | 0.43/0.69 | 5.8/11.6 | 82 (326) | 97 (268) | 101 | 5.9 | 3.2 (yes) | 33 |
| V2 in-memory underlay | 0.7 | 0.08/0.13 | 1.7/2.0 | 351 (53) | 309 (48) | 292 | 0.7 | 0.1 (yes) | 25 |
| V1 webrtc, 64 KiB bulk (E1 back-pressure) | 6.5 | 0.22/0.32 | 0.9/1.4 | 335 (73) | 527 (36) | 619 | 6.0 | 5.2 (no) | 50 (b) |

(a) The V1 RSS high-water came from the `raw` workload. Fixed by E1 (b).

(b) E1 (2026-10-08, one full run, load average 27 to 31; raw in
[bakeoff/results/e1](bakeoff/results/e1)). Two causes: the carrier credited reliable bytes when a
piece arrived and queued frames in an unbounded event stream, and libwebrtc work left autoreleased
objects in pools that never drained (the lane scheduler's drain loop ran many sends in one job; the
data channel callbacks run on libwebrtc's C++ threads). With a bounded `TransportInbox` and credit
on consumption alone, raw still peaked at 487 to 516 MiB RSS; with each send and callback draining
its own pool, `raw` alone peaks at 38 MiB RSS (22 MiB footprint) in all 3 runs at 531 to 668 Mbit/s,
and the full V1 run at 50 MiB. Same build: V3 raw 3783 Mbit/s at 20 MiB, V2 over WebRTC raw 99 at
31 MiB, V2 in-memory raw 296 at 22 MiB. F1 rows: release
build, 3 runs each, 2026-10-07, load average 34 to 36, 0 UDP full-socket drops in every run
(64 KiB bulk spread 548 to 634 Mbit/s, under-bulk p99 1.4 to 2.6 ms).

Spread across the 3 runs (load): V3 flood 218 to 811 Mbit/s and bulk 1517 to 3557; V1 64 KiB bulk 5 to
15 and raw 5 to 583; V1 8 KiB bulk 28 to 509; V2 over WebRTC was the steadiest (bulk 95 to 101). One V1
64 KiB run lost its first echo under bulk for more than 10 s (the `rtt-bulk` error in `v1-webrtc-r3`).

V2 on the in-memory underlay (one run each, `--quick`; fixed one-way delay, independent datagram loss,
no rate limit, 1200 B datagrams):

| RTT, loss | first byte ms | echo p50/p99 ms | under bulk p50/p99 ms | flood Mbit/s | bulk Mbit/s | reconnect ms | roam ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 20 ms, 0 | 96 | 24/30 | 22/28 | 79 | 226 | 102 | 24 |
| 20 ms, 1 % | 105 | 24/84 | 48/1227 | 42 | 27 | 96 | 23 |
| 20 ms, 3 % | 108 | 24/180 | 47/1888 | 22 | 4 | 164 | 184 |
| 80 ms, 0 | 374 | 94/98 | 87/105 | 22 | 94 | 339 | 83 |
| 80 ms, 1 % | 374 | 93/223 | 190/1911 | 11 | 13 | 372 | 93 |
| 80 ms, 3 % | 377 | 94/212 | 1073/4035 | 8 | 2 | 638 | 327 |
| 200 ms, 0 | 845 | 214/216 | 214/376 | 9 | 39 | 847 | 210 |
| 200 ms, 1 % | 843 | 214/479 | 425/1167 | 5 | 6 | 837 | 208 |
| 200 ms, 3 % | 845 | 214/482 | 424/2224 | 2 | 6 | 858 | 663 |

## 4. Findings

### 4.1 V1 webrtc

- Interactive: 0.22 to 0.27 ms echo p50 idle; with 8 KiB bulk records, the best head-of-line result of
  any real carrier (0.9/6.4 ms p50/p99 under bulk): SCTP streams per lane plus `LinkSession`'s
  priority pump keep `input` ahead of `bulk`.
- Large messages: with 64 KiB records, bulk drops to 5 to 15 Mbit/s and the input channel stalls for
  seconds (p99 3.9 s, one run over 10 s). `netstat -s -p udp` shows hundreds of "dropped due to full
  socket buffers" per run; with 4 to 8 KiB messages there are none. The sender's SCTP bursts overflow
  the receiving UDP socket and dcSCTP's recovery from a burst loss is very slow; the whole association
  stalls, so every lane does. Part of this was the bench itself: both peers shared one libwebrtc
  factory, so one network thread sent and received for both ends. Commit `test(ios-next): give the
  loopback host its own libwebrtc factory` splits it (8 KiB raw went from 6 to about 700 Mbit/s), but
  16 KiB and larger still collapse. A phone's network thread is slower than an M4's, so a Mac sending
  to a phone on fast Wi-Fi can hit the same receiver overflow: F1.
- Cold connect on loopback 7.7 to 11.7 ms first byte (ICE host pair, DTLS, SCTP, DCEP). On a WAN this
  is signaling RTT through HostDO, STUN gathering, DTLS (2 RTT) and SCTP (1 RTT); device runs must
  measure it.
- Reconnect and roam both reconnect the session (5 ms on loopback; ICE restart is not exercised here
  because the injector drops the peer connection).
- CPU 44 to 46 ms/MiB for bulk, 75 to 93 for 4 KiB flood (per-message cost of the ObjC data channel
  path); memory high-water 65 to 76 MiB with libwebrtc loaded.

### 4.2 V2 webrtc-wg

- On its real underlay V2 is CPU-bound at about 100 Mbit/s and 260 to 330 ms CPU per MiB: each
  1200 B datagram is one WireGuard encryption, one ObjC `sendData`, one DTLS record and one SCTP
  chunk, in both directions. On the in-memory underlay the WireGuard engine and lanes alone cost
  48 to 53 ms/MiB, so about 80 % of V2's cost is the per-datagram WebRTC path, and the rest is the
  Swift engine. Double encryption is real but not the dominant term.
- No congestion control: throughput is the fixed 1 MiB window per RTT at zero loss (226, 94 and
  39 Mbit/s at 20, 80 and 200 ms, matching 1 MiB/RTT), and 1 to 3 % loss cuts it 8 to 50 times. The
  SACK bitmap covers 64 fragments while a 1 MiB window holds about 900, so most losses wait for the
  RTO; retransmissions of bulk then crowd the shared underlay and the input lane's p99 goes past 1 s.
- Roam is V2's strength: an underlay replaced under the same WireGuard session costs one RTT and no
  session reconnect (24, 83, 210 ms at 20, 80, 200 ms RTT). A full reconnect costs about 4 RTT.
- First byte about 4.2 RTT on the in-memory underlay (WireGuard handshake 1 RTT, hello/welcome 1 RTT,
  channel open and echo about 2 RTT), before any ICE or DTLS time on a real underlay.

### 4.3 V3 direct

- Fastest everywhere on loopback: 1.3 ms first byte, 0.13 ms echo, 726 Mbit/s flood, 2.9 Gbit/s bulk
  at 6 ms CPU/MiB (kernel TCP plus ChaChaPoly). Lowest memory (25 MiB).
- One TCP stream for every lane: the baseline run's echo waited behind whatever the kernel send buffer
  held (4.7/11.9 ms p50/p99 median, 102 ms p99 in one run). The direct writer now bounds the unsent
  application queue to one maximum-sized bulk frame and selects queued frames by lane priority (F7).
  The baseline numbers predate that change; WAN and device measurements still need to confirm the
  resulting tail latency.

### 4.4 Session layer (all carriers)

- The terminal `render` credit (256 KiB, end-to-end acks on consumption) caps flood throughput at about
  256 KiB per RTT: 79, 22 and 9 Mbit/s at 20, 80 and 200 ms on V2, and V1/V3 have the same ceiling.
  That is enough for terminal output (C1 drops to a snapshot when the viewer falls behind) but it is a
  latency-bound number, not a carrier property.
- `LinkSession` itself costs about 4 ms CPU/MiB for 4 KiB records (ref rig).

## 5. Caveats

- Loopback is not a phone on cellular: there is no radio, no NAT, no bottleneck queue, no real loss,
  and both ends share one fast CPU and one process. CPU per MiB is for both ends together on an M4 Pro,
  a proxy for battery, not a battery measurement.
- The machine was heavily loaded (load 23 to 60 on 14 cores); throughput varies 2 to 4 times between
  runs, latency tails are inflated. Medians are given; compare carriers within a run set, not with
  transport.md section 13.
- Loss and delay were injected only for V2 (in-memory underlay, independent loss, no rate limit, no
  queue). V1 and V3 under loss need the dummynet recipe (section 7), which was not run (no privileged
  commands here). V1 TURN, ICE restart and STUN were not exercised; the roam fault drops the peer
  connection.
- The in-process V1 rig still shares one process and one SCTP implementation build for both ends.

### 5.1 Result provenance and open carrier work

The post-F1/E1 measurements are under `bakeoff/results/e1/`. The checked-in
`bakeoff/results/e1/manifest.json` enumerates the exact ten JSON files, labels the full-session and
raw-transport groups, and records the source commit (`2aebd498ca`). Pass that manifest directly to
`summarize.py`, or pass its parent directory (the summarizer discovers `manifest.json`); this keeps
the one full V1 run and the three-run raw runs separate and prevents a mixed directory from silently
changing the table. The default `python3 bakeoff/summarize.py` invocation still summarizes the
top-level historical results directory, which has no manifest and is intentionally separate from E1.

Any new device or WAN comparison must add a manifest beside its result files with the same schema,
source commit, and run labels before it is used as release evidence. A manifest rejects missing files,
schema mismatches, and paths that escape its directory.

F8 implementation (2026-10-08): `LinkSession` now sizes reliable render credit from the latest path
RTT (`LinkConfiguration.renderCreditBudget`). The baseline remains 256 KiB until an RTT sample
arrives; the default target is 2.5 MB/s and the adaptive window is capped at 2 MiB. Terminal channels
are declared with a 64 KiB input budget, then the Mac bridge explicitly promotes its send direction
to the render baseline, so the adaptive budget applies to the real host-to-phone output path while
the input budget remains unchanged. Other explicit channel budgets are preserved, and waiters wake
when a new RTT sample can enlarge the window. This is a bounded protocol-side change, covered by
pure budget tests and an input-priority terminal integration case; it does not claim device
throughput.

F7 implementation (2026-10-07): `DirectWriter` keeps TCP record segments for a frame contiguous,
but queues later frames by `ChannelPriority` so input/control/render work can pass queued bulk. Reliable
bulk admission is bounded to one `TransportCapabilities.stream.maxFrameBytes` of unsent application
data; callers wait for capacity instead of growing an unbounded FIFO. Unordered media remains
drop-when-busy and partial frames still expire at their declared lifetime. `DirectSendQueueTests`
covers priority/FIFO behavior and bulk-byte accounting. This is a scheduling and admission fix, not
device or WAN evidence; the D2 measurement gate remains open.

F3 (continuous V1 RTT sampling and cancellation of a send waiting on a full channel) remains open.
F8 still needs WAN/device evidence before the default path policy is promoted beyond DEV dogfood.

## 6. Re-measure on device

Needs F2 (split mode) for the bench workloads; the app-level numbers need D1/D3 builds with B5 serving
V1, V2 and V3 on the Mac.

1. Build one tagged pair from this branch merged into D1: `./scripts/reload-cloud.sh --tag nxd2 --launch`
   then `./ios/scripts/reload-cloud.sh --tag nxd2 --device-id <iphone> --wait` (same account, trusted
   pairing, `auth status` verified, per the hq CLAUDE.md dogfood rules).
2. On the Mac run `cmux-link-bench serve --rig all` (F2) next to the tagged app; on the phone open
   DEV > Link bench, pick the Mac, carrier V1, V2 or V3, and run all workloads; results upload as the
   same JSON schema to `plans/cmux-next/ios-next/bakeoff/device/<date>-<network>-<carrier>.json`.
3. Networks, each with all three carriers where reachable: same Wi-Fi (V1 p2p host pair, V3 LAN);
   phone on cellular, Mac at home (V1 p2p srflx or TURN); DEV "Force TURN" (`iceTransportPolicy
   relay`); Tailscale on both (V3 over `100.x`); iPhone Settings > Developer > Network Link
   Conditioner profiles LTE, 3G, Very Bad Network, and custom 20/80/200 ms delay with 1 and 3 % loss.
4. Roam: start a flood, walk out of Wi-Fi range (or toggle Wi-Fi off) and back; record fault-to-first-
   byte, path badges before and after, and whether the session reconnected. Repeat 5 times per carrier.
5. Real terminal path (no bench): in the D1 terminal, C1 telemetry (`TerminalLatencyReport`: echo RTT
   p50/p95, frame age) while typing, idle and with `yes | head -c 500M` in a second pane on the same
   Mac; C4 download of a 200 MB file; first byte after tapping a workspace (signpost).
6. Battery and thermals: Xcode Instruments Power Profiler (`xctrace record --template "Power Profiler"`)
   for 10 minutes of flood per carrier on battery, screen on, same brightness; plus the Energy gauge
   and the Mac-side CPU of the cmux process. Memory: footprint from the same trace.
7. Pass bars before V1 ships as default: echo p95 within 1.5x the path RTT idle and within 3x under a
   C4 download; flood at least 20 Mbit/s on LTE; roam back to a working terminal in under 2 s; no stall
   over 1 s in the 64 KiB bulk case (else F1 becomes blocking).
8. Commit device JSON next to the loopback results and re-run `summarize.py` on that directory.

## 7. Network shaping recipes (documented, not run here)

macOS dummynet on loopback for V1 and V3 on one Mac (sudo; use a dedicated fleet Mac because it shapes
every matching flow on `lo0`). A packet crosses `lo0` once, so one `in` rule adds its delay once per
direction: RTT = 2 x delay.

```bash
# 80 ms RTT, 1 % loss each way, 50 Mbit/s, for UDP (V1, V2 real underlay) and TCP (V3).
sudo dnctl pipe 1 config delay 40ms plr 0.01 bw 50Mbit/s queue 100
echo 'dummynet in quick on lo0 proto { udp tcp } from any to any pipe 1' | sudo pfctl -a com.apple/d2 -f -
TOKEN=$(sudo pfctl -E 2>&1 | sed -n 's/.*Token : //p')
plans/cmux-next/ios-next/bakeoff/run-local.sh /tmp/d2-shaped     # or one cmux-link-bench --rig v1|v3|v2-webrtc
sudo pfctl -a com.apple/d2 -F all; sudo dnctl -q flush; sudo pfctl -X "$TOKEN"
```

Between two fleet Macs (closer to a phone and a Mac): run the split mode (F2) across them and shape
only the bench host's address on the dialer Mac (`from any to <host-ip>` and the reverse rule).
Network Link Conditioner on the Mac (Xcode Additional Tools) shapes all interfaces including loopback
and needs no pfctl; on the iPhone it is Settings > Developer > Network Link Conditioner.

## 8. Follow-ups

- F1 (B2): large-message collapse. Fixed 2026-10-07 on `feat-cmux-next-ios-b2-webrtc` (b2-webrtc.md
  section 6): 8 KiB lane messages with a piece header, a priority scheduler paced by
  `bufferedAmount` events, a 256 KiB credit window on reliable lanes. Regression test
  `LargeFrameTests` (64 B echo p99 under 16 MiB of 256 KiB frames: 4 to 11 s before, 1 to 80 ms
  typical after; rare outliers to 1.2 s at load 35, bound 2 s). Still open: confirm on device, tune
  the window for WAN RTTs (256 KiB caps one association at 40 Mbit/s at 50 ms), SCTP stats in `rtt`.
- F2 (D2/D3): bench split mode: `cmux-link-bench serve` hosting the acceptors and an echo/source
  service over B5's signaling, plus an iOS DEV "Link bench" screen running the same workloads, so the
  same JSON comes from device runs.
- F3 (B2): continuous RTT sampling from `getStats` (today only at connect and ICE `connected`), so the
  badge and C1 telemetry see path RTT on V1; cancellation for a `send` suspended on a full channel.
- F4 (B3, only if V2 stays): congestion control (cwnd with pacing; NewReno or BBR-style) instead of the
  fixed 1 MiB window; SACK ranges instead of a 64-bit bitmap; acks and retransmissions for `input`
  ahead of bulk retransmissions in the pump.
- F5 (B3, only if V2 stays): batch datagrams per `sendData` or move the underlay to libwebrtc's
  native path to cut the per-datagram cost (80 % of V2 CPU); reuse buffers in the engine.
- F6 (B3): pipeline `hello` into the WireGuard confirmation packet and send channel data with `open`
  to cut first byte from about 4 RTT to about 2.
- F7 (B4, implemented 2026-10-07): `DirectWriter` priority scheduling and a one-frame unsent bulk
  admission budget prevent an application-side bulk backlog from hiding interactive frames. It keeps
  record segments contiguous for Noise nonce order. Confirm WAN/device tail latency in D2; a separate
  bulk connection remains a future option if kernel buffering still dominates.
- F9 (E1, done 2026-10-08): bounded ingress on every carrier (`TransportInbox`, credit on
  consumption, conformance case `rawBackPressure`); see note (b) in section 3.
- F8 (A3/C1): the 256 KiB render credit caps flood at 256 KiB per RTT (9 Mbit/s at 200 ms); size the
  credit from the path's RTT if device runs show users waiting on flood catch-up.

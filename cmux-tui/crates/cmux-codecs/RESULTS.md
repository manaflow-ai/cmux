# Screen-share codec results

What `codec-bench` measured, and what each result decided. Every row runs the real host media
engine and viewer reassembler over a simulated link: 1920x1080 at 30 fps, 50 ms RTT, a 30 Mbps
bottleneck, 10 s per row. "2% bursty" is 2% average loss in Gilbert-Elliott bursts of 8 datagrams.
Text PSNR is the mean luma PSNR of the frames shown, against the picture each one carried.

## VideoToolbox H.264 against OpenH264 (macOS host)

Apple M4 Pro fleet worker, step da97d216fc652c42b9556838 at bad2b0ace62 (#43158). Both encoders
send constrained baseline and are decoded by OpenH264. IDRs count the stream's first frame and loss
recoveries; neither encoder set off scene-change IDRs in these rows.

| scene | loss | on-time fps OpenH264 / VT | text PSNR dB OpenH264 / VT | media Mbps OpenH264 / VT | IDRs per 300 frames OpenH264 / VT | encode ms p50 OpenH264 / VT |
|---|---|---|---|---|---|---|
| page | 0% | 17.6 / 29.6 | 31.5 / 29.0 | 9.0 / 7.2 | 1 / 1 | 7.9 / 5.8 |
| page | 2% | 16.7 / 29.4 | 31.3 / 27.6 | 8.9 / 6.5 | 1 / 1 | 7.8 / 5.8 |
| page | 2% bursty | 12.7 / 27.0 | 31.8 / 26.8 | 7.4 / 6.0 | 2 / 2 | 1.1 / 5.8 |
| scroll | 0% | 29.7 / 29.6 | 40.8 / 51.5 | 1.5 / 2.2 | 1 / 1 | 8.9 / 6.3 |
| scroll | 2% | 29.2 / 27.9 | 40.8 / 51.7 | 1.5 / 2.3 | 1 / 1 | 8.8 / 6.2 |
| scroll | 2% bursty | 28.2 / 27.1 | 40.6 / 51.5 | 1.7 / 2.5 | 2 / 2 | 9.0 / 6.3 |
| drag | 0% | 29.6 / 29.8 | 41.5 / 52.4 | 1.4 / 1.1 | 1 / 1 | 9.5 / 6.3 |
| drag | 2% | 29.0 / 28.9 | 41.5 / 52.4 | 1.4 / 1.1 | 1 / 1 | 9.4 / 6.3 |
| drag | 2% bursty | 26.9 / 28.2 | 41.0 / 52.2 | 2.1 / 1.6 | 2 / 3 | 9.5 / 6.4 |
| typing | 0% | 29.8 / 29.7 | 40.0 / 51.9 | 0.3 / 0.5 | 1 / 1 | 8.3 / 6.2 |
| typing | 2% | 28.7 / 27.8 | 38.9 / 51.6 | 0.8 / 1.2 | 4 / 3 | 8.3 / 6.3 |
| typing | 2% bursty | 29.8 / 24.1 | 40.0 / 51.0 | 0.3 / 1.2 | 1 / 3 | 8.4 / 6.3 |

- On the page scene (a full screen of new text every 4 frames), OpenH264 skips frames to hold its
  rate (44-56 in 120 in the Linux rows of #43158) and on-time fps falls to 12.7-17.6; VideoToolbox stays at 27.0-29.6
  at a lower bitrate, with 2.5-5.0 dB less text PSNR on those pages.
- On scroll, drag and typing, VideoToolbox's text PSNR is 10.7-12.7 dB higher. Its on-time fps is
  within 1.3 fps of OpenH264's except typing at 2% bursty (24.1 against 29.8); it spends 0.8-4x
  OpenH264's bitrate.
- Verdict: the macOS host keeps VideoToolbox, its default already (`cmux-rd-host/src/host.rs`,
  `DEFAULT_CODEC`). No switch lands; OpenH264 stays on Linux and Windows hosts (Media Foundation
  rows below).

## Media Foundation H.264 against OpenH264 (Windows host)

Run 43628916550 of the `cmux-codecs Windows bench` workflow, at ae97c3fc65f, on a 4-vCPU Windows
Server 2025 CI VM with no GPU and with the Server-Media-Foundation feature installed. With no
hardware encoder present, every `h264-mf` row reported "no Hardware H.264 encoder MFT". These
rows are Windows' software H.264 MFT (`h264-mf-sw`, "H264 Encoder MFT"), constrained baseline,
CBR, low-latency mode. Both encoders' output was decoded by OpenH264.

| scene | loss | on-time fps OpenH264 / MF sw | text PSNR dB OpenH264 / MF sw | media Mbps OpenH264 / MF sw | IDRs per 300 frames OpenH264 / MF sw | encode ms p50 OpenH264 / MF sw |
|---|---|---|---|---|---|---|
| page | 0% | 17.5 / 29.1 | 31.4 / 20.8 | 9.0 / 3.1 | 1 / 1 | 7.0 / 4.1 |
| page | 2% | 13.8 / 27.9 | 31.4 / 20.7 | 8.7 / 3.2 | 1 / 1 | 1.1 / 4.0 |
| page | 2% bursty | 15.7 / 25.1 | 31.5 / 21.4 | 8.7 / 3.7 | 2 / 3 | 6.8 / 4.2 |
| scroll | 0% | 29.7 / 29.5 | 40.8 / 31.1 | 1.5 / 2.0 | 1 / 1 | 9.6 / 4.0 |
| scroll | 2% | 29.1 / 28.7 | 40.8 / 34.9 | 1.5 / 2.3 | 1 / 1 | 9.8 / 3.5 |
| scroll | 2% bursty | 28.5 / 26.6 | 40.7 / 39.2 | 1.7 / 4.3 | 2 / 1 | 10.1 / 4.0 |
| drag | 0% | 29.4 / 29.9 | 41.4 / 43.1 | 1.5 / 1.0 | 1 / 1 | 8.3 / 3.6 |
| drag | 2% | 28.4 / 29.1 | 41.2 / 42.9 | 1.5 / 1.1 | 1 / 1 | 8.2 / 3.6 |
| drag | 2% bursty | 27.9 / 28.0 | 41.0 / 43.1 | 1.7 / 1.3 | 2 / 2 | 8.2 / 3.7 |
| typing | 0% | 29.8 / 29.8 | 40.0 / 42.0 | 0.3 / 0.8 | 1 / 1 | 6.9 / 3.6 |
| typing | 2% | 28.8 / 28.3 | 38.1 / 42.2 | 0.8 / 1.3 | 4 / 3 | 6.9 / 3.9 |
| typing | 2% bursty | 29.8 / 28.5 | 40.0 / 42.1 | 0.3 / 1.1 | 1 / 2 | 7.6 / 3.6 |

- Page scene: the software MFT skips no frames and reaches 25.1-29.1 on-time fps against
  OpenH264's 13.8-17.5. But it spends only 3.1-3.7 Mbps of a target near 9 Mbps, so its pages come
  out 10.1-10.7 dB lower in text PSNR (about 21 dB, which leaves text hard to read).
- Scroll: equal on-time fps (26.6-29.5 against 28.5-29.7), but text PSNR is 1.5-9.7 dB lower at a
  higher bitrate.
- Drag and typing: on-time fps within 1.3 of OpenH264's. Text PSNR is 1.7-4.1 dB higher. Drag uses
  less bitrate; typing uses 1.6-3.7x OpenH264's.
- Encoding takes 3.5-4.2 ms per frame (p50), against OpenH264's 6.9-10.1 ms in the rows without page skips, on the same 4 vCPUs.
- Verdict: the Windows host keeps OpenH264. The software MFT trades the page-scene frame skips for
  pages too blurred to read, and it loses on scroll. `mediafoundation::hardware_or` (a hardware MFT,
  else OpenH264) is ready for a host to call, but it stays unused until a machine with a GPU
  encoder produces `h264-mf` rows. The same workflow runs them on a runner that has one.

## Sharper or faster on Windows: encoder settings (CPU host)

Run 43651721508 of the same workflow, on the same kind of 4-vCPU VM with no GPU. No hardware MFT
rows: `codec-bench-windows-exe`, that run's codec-bench.exe, runs them on a machine with a GPU
encoder. Leo: "cant we sharpen up windows? or is there no way... fps on the open one is so wack".
The bar was a setting with at least OpenH264's text PSNR and more on-time fps. Earlier runs
(43643167390, 43645088338, 43646875809) predate #43095, the congestion controller's
sustained-delay rule. Under the old controller, frame skipping off left the target at its 1 Mbps
floor, so those rows are superseded.

OpenH264, page scene, frame skipping on / off. The off side covers two passes, one with
`threads=4`. "Target" is the congestion controller's bitrate at the end of the row:

| link | loss | on-time fps skip on / off | text PSNR dB skip on / off | media Mbps skip on / off | target kbps skip on / off |
|---|---|---|---|---|---|
| 30 Mbps | 0% | 19.2 / 26.4-27.4 | 35.1 / 32.8-33.1 | 10.9 / 10.1-10.3 | 16449 / 14590-14741 |
| 30 Mbps | 2% | 19.1 / 21.0-25.7 | 34.5 / 31.6-32.3 | 10.6 / 7.8-9.7 | 14306 / 8719-13779 |
| 30 Mbps | 2% bursty | 13.9 / 18.0-20.6 | 35.0 / 32.5-33.2 | 9.8 / 9.3-9.7 | 15896 / 14799-14871 |
| 10 Mbps | 0% | 0.0 / 0.0 | 33.1 / 31.6 | 3.3 / 7.0 | 1000 / 2177 |

- **Frame skipping off trades sharpness for frames.** It codes every frame at about the same
  bitrate, so pages arrive at 1.9-8.2 more fps but 1.8-2.9 dB less sharp. It loses on text PSNR,
  so the default stays on.
- **#43095 already moved the default.** Pages at 30 Mbps now run at 13.9-19.2 fps and 34.5-35.1 dB,
  against 13.1-17.5 fps and 31.2-32.0 dB before it. With skipping off, the target now follows
  the link instead of sitting at the floor.
- **Scroll, drag and typing at 30 Mbps are equal within the noise:** within 2.8 fps and 0.8 dB.
  Drag at 2% loss is 22.1-24.3 fps against 24.9.
- **At 10 Mbps, pages show nothing on time with either setting.** With skipping on, the target
  sits at 1000 kbps and the row sends 10-19 IDRs.
- **At 5 Mbps, no scene shows a frame with either setting.** Every row sends 40 IDRs in 10 s,
  5-8 Mbps of media against a 1 Mbps target, and 12-19 Mbps on the wire. That is a
  keyframe-recovery loop: a full-size IDR and its parity overflow the link, the loss asks for
  another IDR, and the cycle repeats. It is the engine's to fix (#43331).
- **Earlier runs, under the old controller:** turning skipping back on once output ran half a
  second past the target fell to 13.0-13.9 page fps. `threads=4` changed nothing measurable, and
  `complexity=2` (OpenH264's high) was slower, at 13.1-15.9 page fps.

Media Foundation's software MFT. The variants come from run 43643167390, under the old
controller. In run 43651721508 its CBR pages barely moved, at 20.7-21.0 dB and 3.4-3.5 Mbps,
against OpenH264's 34.5-35.1 dB:

- Quality VBR (`rc=quality`, 70 or 85): text PSNR 42-45 dB on pages, but at 19-23 Mbps, so
  on-time fps falls to 0.0-12.5.
- Peak VBR (`rc=pvbr,peak=200`): 26.5-26.9 dB on pages at 7.7 Mbps and 22-29 fps. On a 10 Mbps
  link it stalls (0 on-time fps on page and scroll).
- Low-delay VBR and a QP ceiling of 20 on still frames: the same as its CBR rows, within 0.1 dB.
- High profile with CABAC: pages at 21.1-23.3 dB, against CBR's 20.8-22.0.
- Quality-vs-speed 100 with a 1 s buffer: pages at 24.2-25.1 dB, 5.2-5.6 Mbps and 22.7-28.9 fps.

Verdict on a CPU host: nothing beats OpenH264's shipped settings on both fps and text PSNR, so the
Windows default stays. Frame skipping off buys page fps with sharpness, and no software MFT setting
is as sharp as OpenH264 at a rate the link carries. Pages on a 10 Mbps link, and every scene at
5 Mbps, wait on the engine's keyframe recovery (#43331). The hardware MFT rows still need a machine with a GPU encoder.

## VP9 and AV1 against H.264 (#43051, #43115)

- At H.264's own bitrate, VP9 (libvpx, WebRTC's screen settings) drops most frames: 3.2-28.9
  on-time fps against H.264's 25.1-29.8. With frame dropping off it ties on-time fps but its text
  PSNR is 2.5-12.3 dB lower in 10 of 12 rows. At twice H.264's bitrate it is ahead in 7 of 12.
- The native host matrix (scroll at 2% loss) agrees: H.264 27.4 fps at 2.1 Mbps and 33.2 dB,
  VP9 23.0 fps at 10.4 Mbps and 27.6 dB.
- AV1 (rav1e, speed 10) reaches 0 on-time fps: 22-51 ms per frame to encode.
- Verdict: no VP9 or AV1 setting; H.264 stays.

## Linux host encode against its floor (goal screen-share-linux-pairs)

a Linux lane VM (AMD EPYC 7003, 32 vCPU), feat-cmux-next b653865c327, 2026-11-22. Every row is pinned to 4 cores
(`taskset`), page, scroll, drag and typing at 1080p30, 0% loss. OpenH264 is this crate's build (its SSE2/AVX2
assembly linked in, as in Cisco's binary). x264 0.164 codes the very same frames (`scene-dump`), ultrafast with
zerolatency, sliced threads and a one-frame VBV at 8 Mbps; x264 prints a throughput, so its rows are the mean ms per
frame. `scripts/measure/linux-encode-floor.sh` reruns the shipped and floor rows and prints the ratio.

| Encode ms per 1080p frame, 4 cores | page | scroll | drag | typing |
| --- | --- | --- | --- | --- |
| OpenH264 shipped (screen usage, p50) | 14.0 | 17.0 | 14.7 | 11.4 |
| OpenH264 shipped, 32 cores and threads | 12.1 | 15.8 | 14.4 | 11.8 |
| OpenH264, 1 core and thread | 15.6 | 17.7 | 17.8 | 12.0 |
| OpenH264, `complexity=1` | 11.7 | 15.1 | 13.2 | 10.1 |
| OpenH264, camera usage | 4.5 | 3.9 | 3.8 | 3.3 |
| x264 ultrafast, zerolatency (mean): the floor | 5.2 | 4.7 | 3.8 | 3.8 |
| x264 superfast, zerolatency (mean) | 6.6 | 6.5 | 4.8 | 4.8 |

- The shipped encoder is 2.7x to 3.8x its floor (page 2.7x, scroll 3.6x, drag 3.8x, typing 3.0x).
- The cost is screen usage, not threads or effort: 1 to 32 threads moves the p50 by at most 1.3x, `complexity=1`
  by 1.1x, while camera usage on the same frames is at the floor. Its price: scroll at 4.7 Mbps against 1.5.
- Verdict: no default changes here. The cut is more frames in camera usage where the link has bitrate to spare;
  it lands with its own text-PSNR and bitrate rows.

## Camera usage on spare bitrate (`usage=spare`, opt-in; goal screen-share-linux-pairs cut 1)

A Linux lane VM (AMD EPYC 9B45, 32 vCPU, load 15-19 on the other cores), 2026-11-23, two runs of
`scripts/measure/linux-encode-spare.sh` (4 cores, `taskset -c 0-3`, 1080p30, 10 s, 0% loss, 30 Mbps link). `spare`
codes in camera usage while the target is at least 6 Mbps (`SPARE_KBPS`; back up at 7.5) and falls back to the shipped
`switch` rule below it. This host is faster than the 7003 above, so read ratios, not milliseconds. PSNR-Y is of
shown frames; screen PSNR is what the viewer sees against what the host shows, every capture tick.

| scene | usage | encode p50 ms (run 2 / 3) | x264 floor ms | ratio | media Mbps | PSNR-Y dB | screen PSNR-Y mean / p5 dB | shown fps |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| page | shipped | 8.63 / 8.37 | 2.56 / 2.37 | 3.37 / 3.54 | 13.2 | 38.8 | 19.2 / 13.9 | 22.6 |
| page | spare | 2.55 / 2.41 | | 1.00 / 1.02 | 18.6 / 17.6 | 39.7 / 38.7 | 17.5 / 13.9 | 21.4 |
| scroll | shipped | 11.17 / 10.80 | 2.81 / 2.21 | 3.97 / 4.89 | 1.5 | 40.8 | 14.4 / 14.1 | 29.8 |
| scroll | spare | 2.50 / 2.34 | | 0.89 / 1.06 | 4.7 | 51.0 | 32.1 / 14.1 | 28.3 |
| drag | shipped | 10.16 / 8.79 | 2.24 / 1.71 | 4.55 / 5.15 | 1.3 | 41.6 | 17.2 / 16.9 | 29.8 |
| drag | spare | 2.51 / 2.29 | | 1.12 / 1.34 | 2.2 / 2.1 | 55.1 | 41.5 / 16.9 | 29.7 |
| typing | shipped | 8.21 / 7.82 | 2.07 / 1.76 | 3.97 / 4.44 | 0.26 | 40.0 | 38.1 / 37.2 | 30.0 |
| typing | spare | 2.20 / 1.93 | | 1.06 / 1.10 | 2.2 / 2.0 | 54.3 | 46.9 / 14.6 | 29.6 |

- worst_ratio: shipped 4.55 / 5.15, spare 1.12 / 1.34 (all-camera `usage=camera` 1.17 / 1.29). Within 2x on every scene.
- Price: bits. Page 1.4x (13.2 to 18.6 Mbps), scroll 3.1x (1.5 to 4.7), drag 1.7x (1.3 to 2.2), typing 8x
  (0.26 to 2.2). The most any scene sends is 18.6 Mbps (page), under the 41.9 Mbps measured Linux to Mac.
- Text quality is not lower: PSNR-Y of shown frames is the same on page and 10-14 dB higher on scroll, drag, typing.
- One regression to close before any default: typing's screen PSNR p5 falls from 37.2 to 14.6 dB (scroll and drag
  read 14-17 dB p5 with either usage), so about 5% of typing ticks show a stale picture with camera usage.
- Not measured here: the fallback on a slow link. On a bench link of 15 Mbps or less the page scene shows under 3 fps
  with every usage, shipped included; the fallback is the unit test `spare_usage_follows_the_target_bitrate`.

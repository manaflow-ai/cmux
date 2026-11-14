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

Runs 43643167390, 43645088338 and 43646875809 of the same workflow, same kind of 4-vCPU VM, no
GPU (so no hardware MFT rows; `codec-bench-windows-exe`, the run's codec-bench.exe, runs them on a
machine with one). Leo: "cant we sharpen up windows? or is there no way... fps on the open one is
so wack". The bar was a setting with at least OpenH264's text PSNR and more on-time fps.

OpenH264 with frame skipping off (`frameskip=0`), page scene, ranges over the runs. "Target" is
the congestion controller's bitrate at the end of the row:

| link | loss | on-time fps skip on / off | text PSNR dB skip on / off | media Mbps skip on / off | target kbps skip on / off |
|---|---|---|---|---|---|
| 30 Mbps | 0% | 17.3-17.5 / 29.2-29.7 | 31.3-31.4 / 31.1 | 8.9-9.0 / 8.9 | 9143-9182 / 1000 |
| 30 Mbps | 2% | 14.6-15.2 / 16.7-26.9 | 31.2-31.3 / 31.1-31.2 | 8.8-8.9 / 8.9 | 7555-8168 / 1004 |
| 30 Mbps | 2% bursty | 13.1-15.2 / 20.9-22.9 | 31.4-32.0 / 31.4-31.6 | 8.8-9.0 / 7.9-8.6 | 6519-6539 / 1008 |
| 10 Mbps | 0% | 0.0 / 0.0 (shown 2.0 / 7.3) | 32.2 / 31.6 | 2.7 / 6.9 | 1338-1344 / 1000 |

- The fps comes from ignoring the target, not from coding better. With skipping off, the
  congestion controller fell to its 1 Mbps floor in every page row while OpenH264 kept sending
  about 9 Mbps. The 30 Mbps link had room for it; the 10 Mbps link filled (10.2 Mbps on the wire)
  and showed nothing on time.
- Frame skipping off, but back on once the output runs half a second past the target (tried in
  run 43646875809, not kept): the page rows at 30 Mbps fall to 13.0-13.9 fps, under frame skip on,
  because the target it follows is already at the floor.
- Why the target falls: the controller is delay-based, and each page change is one large frame
  that queues on the link for a moment. With skipping on, the encoder answers a lower target with
  fewer frames, the delay flattens and the target recovers. With skipping off its frames don't
  shrink enough, so the delay keeps rising and the target stays at the floor. That is the
  engine's fix to make (pacing a large frame, or not reading its own burst as congestion), and
  frame skipping stays on until it lands.
- Scroll and typing: within 0.4 fps and 0.3 dB at 30 Mbps. Drag at 2% loss on the 30 Mbps link
  loses with skipping off: 22.9-23.1 against 24.8-26.3 fps.
- `threads=4` changes nothing measurable; `complexity=2` (OpenH264's high) is slower: page
  13.1-15.9 fps.
- At 15 Mbps both settings show 0.2-0.5 on-time fps on pages, and at 5 Mbps neither shows a frame
  in any scene (40 IDRs per row): engine findings, not codec differences.

Media Foundation's software MFT, the knobs it accepted:

- Quality VBR (`rc=quality`, 70 or 85): text PSNR 42-45 dB on pages but 19-23 Mbps, so on-time
  fps falls to 0.0-12.5.
- Peak VBR (`rc=pvbr,peak=200`): 7.7 Mbps and 26.5-26.9 dB on pages at 22-29 fps, still 4.5 dB
  under OpenH264; at a 10 Mbps link it stalls (0 on-time fps on page and scroll).
- Low-delay VBR and a QP ceiling of 20 on still frames: the CBR rows again, within 0.1 dB.
- High profile with CABAC: pages 21.1-23.3 dB against CBR's 20.8-22.0.
- Quality-vs-speed 100 with a 1 s buffer: pages 24.2-25.1 dB at 5.2-5.6 Mbps and 22.7-28.9 fps,
  still 6 dB under OpenH264.

Verdict on a CPU host: nothing beats OpenH264's shipped settings on both fps and text PSNR while
following the congestion controller, so the Windows default stays. No software MFT setting is as
sharp as OpenH264 at a rate the link carries. The page scene's fps waits on the engine's handling
of large frames; the hardware MFT rows still need a machine with a GPU encoder.

## VP9 and AV1 against H.264 (#43051, #43115)

- At H.264's own bitrate, VP9 (libvpx, WebRTC's screen settings) drops most frames: 3.2-28.9
  on-time fps against H.264's 25.1-29.8. With frame dropping off it ties on-time fps but its text
  PSNR is 2.5-12.3 dB lower in 10 of 12 rows. At twice H.264's bitrate it is ahead in 7 of 12.
- The native host matrix (scroll at 2% loss) agrees: H.264 27.4 fps at 2.1 Mbps and 33.2 dB,
  VP9 23.0 fps at 10.4 Mbps and 27.6 dB.
- AV1 (rav1e, speed 10) reaches 0 on-time fps: 22-51 ms per frame to encode.
- Verdict: no VP9 or AV1 setting; H.264 stays.

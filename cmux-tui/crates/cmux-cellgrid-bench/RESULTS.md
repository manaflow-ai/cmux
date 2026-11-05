# Results, 2026-11-05

Run on a GCP lane VM (AMD EPYC 9B45, 32 vCPU, Linux 7.0), one bench process at a time, at
feat-cmux-next 540410a9a503. Pane: 120x40 cells, DejaVu Sans Mono 26 px (13 pt at 2x),
1920x1240 px. Link for the network stage: 20 Mbps unless named. Traces recorded on the same VM with
`scripts/record.py` (`flood`: `cat` of a 538 KB Rust file in a loop; `vim-idle` and `vim-typing`:
vim 9.1 with syntax colours on `ghostty-vt/src/render.rs`; `palette`: the 256-colour and 24-bit ramps).

## Headline

| | VT bytes (`terminal_bytes`) | cells (`render-delta`) | H.264 (OpenH264, 12 Mbps target) |
|---|---|---|---|
| typing in vim, bytes/s | 3.1 kbps (1.5 deflated) | 76 kbps (4.2 deflated) | 89 kbps |
| idle vim, bytes/s | 0 | 0 | 0 on damage only; 31 kbps with the 500 ms refresh |
| `cat` flood, bytes/s | 624 Mbps (310 deflated) | 7.5 Mbps (1.0 deflated) | 12 Mbps, picture stale or smeared (PSNR 18 dB) |
| key to view p50 / p95, 20 Mbps | 0.32 / 0.34 ms | 0.71 / 0.82 ms | 37.1 / 44.9 ms (G0 measures 40–55 ms p50 glass-to-glass on Macs) |
| key to view p50 / p95, 5 Mbps | 0.34 / 0.37 ms | 2.12 / 2.46 ms | 37.3 / 47.6 ms |
| exact text cells | 100% | 100% | 0% (near, ±8 per channel: 0%) |
| text colour ΔE2000 mean / p95, vim | 0 | 0 | 8.0 / 18.4 (YUV 4:2:0 round trip alone: 2.4 / 8.1) |
| attach keyframe, vim screen | GHOSTSNP READY 7.5 KB (2.5 deflated) | full delta 15.8 KB (1.8 deflated) | IDR 102 KB |

Video's key-to-view on this VM is mostly software encode (20.2 ms p50 at 1920x1240), the 60 Hz
capture wait (7.4 ms) and decode (8.4 ms, which here includes a CPU conversion back to BGRX that a real viewer does on the GPU); on a Mac VideoToolbox is faster, so G0's measured
40–55 ms glass-to-glass is the number to compare with. The cell paths' ~0.3–0.8 ms do not include
the network round trip, which every path pays the same.

## Findings

1. **Text is exact on the cell paths and never exact on video.** No video text cell matched the host's
   pixels at any bitrate, on any workload; the YUV 4:2:0 round trip alone, with no codec, already leaves only 0.7–2.4% of text cells exact.
2. **Colour is off on video by several just-noticeable differences.** Syntax-coloured text in vim:
   ΔE2000 mean 7.4–10.1 and p95 18–20 at 2–12 Mbps (typing: 5.5–5.8 mean); the 256-colour palette: 8–9.6 mean. The cell paths
   carry the exact RGB.
3. **A static screen stays blurry on video.** Damage-only encoding sends nothing more once the
   screen stops changing, and the 500 ms refresh (P frames) does not sharpen it: idle vim stays at
   PSNR 37 dB and 0% exact text either way, while the refresh costs 31 kbps and ~5x the encode CPU (47.3 against 8.8 ms/s).
4. **Raw VT does not survive a flood; coalesced cells do.** A `cat` flood is 624 Mbps of VT, beyond any
   link (the channel falls back to a GHOSTSNP snapshot once the viewer is 8 MiB behind).
   Cells at the daemon's 8 ms cadence send 7.5 Mbps, 1.0 Mbps deflated, and stay exact;
   video holds its bitrate but shows a stale, smeared picture (PSNR 14–18 dB).
5. **For typing and idle, VT bytes are the cheapest wire.** 3 kbps against 76 kbps of cell JSON
   (rows are resent whole); deflate brings the JSON to 4 kbps. A row diff with a scroll op saves
   little (59 kbps typing, 7.05 Mbps flood: a flood scrolls more than a screen per 8 ms).

So, per pane: a terminal pane goes over `terminal_bytes` (live VT, snapshots on attach and when
the viewer falls behind, which is the hybrid `plans/cmux-next/ghostty-next.md` already chose) and is
drawn by the viewer's own libghostty; video stays for panes that are not terminals. Kitty images
already ride `terminal_bytes`; Ghostty has no sixel, so no terminal pane needs video for images.

## Full tables

### vim-typing  (trace 20.2 s, window 0.0–20.2 s, VT 0.01 MB, 124 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 3.1 | 1.5 | 0.32 / 0.34 | 0.00/0.00/0.01/0.32 | 0.0 | 1.9 | 0 | – | – | – | – / – |
| render-delta | 76.2 | 4.2 | 0.71 / 0.82 | 0.00/0.22/0.43/0.02 | 1.5 | 0.1 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 58.8 | 3.6 | 0.67 / 0.86 | 0.00/0.28/0.39/0.01 | 1.8 | 0.1 | 0 | – | – | – | – / – |
| h264-2000k | 88.7 | – | 39.23 / 50.42 | 10.01/20.28/0.04/8.36 | 130.9 | 53.9 | 0 | 0.0 | 0.1 | 36.7 | 5.75 / 16.32 |
| h264-6000k | 89.6 | – | 37.22 / 45.27 | 7.90/20.27/0.05/8.39 | 130.1 | 54.2 | 0 | 0.0 | 0.0 | 37.1 | 5.58 / 15.20 |
| h264-12000k | 89.4 | – | 37.14 / 44.92 | 7.37/20.15/0.05/8.40 | 130.3 | 54.8 | 0 | 0.0 | 0.0 | 37.2 | 5.57 / 15.00 |
| h264-12000k-refresh500ms | 90.4 | – | 37.31 / 44.98 | 7.37/20.19/0.05/8.37 | 143.6 | 60.0 | 0 | 0.0 | 0.0 | 37.4 | 5.51 / 14.89 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 1.4 | 49.2 | 41.5 | 1.84 / 7.52 |

Attach, same screen: GHOSTSNP READY 7543 B (2531 deflated), full render-delta 15835 B (1757 deflated), H.264 IDR 101519 B

### vim-typing-5mbps  (trace 20.2 s, window 0.0–20.2 s, VT 0.01 MB, 124 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 3.1 | 1.5 | 0.34 / 0.37 | 0.00/0.00/0.02/0.32 | 0.0 | 2.0 | 0 | – | – | – | – / – |
| render-delta | 76.2 | 4.2 | 2.12 / 2.46 | 0.00/0.22/1.73/0.02 | 1.5 | 0.1 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 58.8 | 3.6 | 1.85 / 2.47 | 0.00/0.28/1.54/0.01 | 1.9 | 0.1 | 0 | – | – | – | – / – |
| h264-2000k | 88.7 | – | 39.94 / 58.13 | 10.01/20.31/0.18/8.41 | 130.9 | 54.3 | 0 | 0.0 | 0.1 | 36.7 | 5.75 / 16.32 |
| h264-6000k | 89.6 | – | 37.82 / 50.40 | 7.90/20.29/0.22/8.48 | 130.3 | 54.8 | 0 | 0.0 | 0.0 | 37.1 | 5.58 / 15.20 |
| h264-12000k | 89.4 | – | 37.31 / 47.63 | 7.37/20.17/0.20/8.48 | 130.8 | 55.3 | 0 | 0.0 | 0.0 | 37.2 | 5.57 / 15.00 |
| h264-12000k-refresh500ms | 90.4 | – | 37.65 / 45.78 | 7.37/20.23/0.21/8.47 | 144.0 | 60.5 | 0 | 0.0 | 0.0 | 37.4 | 5.51 / 14.89 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 1.4 | 49.2 | 41.5 | 1.84 / 7.52 |

Attach, same screen: GHOSTSNP READY 7543 B (2531 deflated), full render-delta 15835 B (1757 deflated), H.264 IDR 101519 B

### vim-idle  (trace 7.5 s, window 2.0–7.0 s, VT 0.00 MB, 1 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 0.0 | – | 0.30 / 0.30 | 0.00/0.00/0.01/0.28 | 0.0 | 0.0 | 0 | – | – | – | – / – |
| render-delta | 0.0 | – | 0.45 / 0.45 | 0.00/0.18/0.26/0.01 | 0.2 | 0.0 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 0.0 | – | 0.36 / 0.36 | 0.00/0.24/0.12/0.00 | 0.2 | 0.0 | 0 | – | – | – | – / – |
| h264-2000k | 0.0 | – | 63.43 / 63.43 | 30.06/23.85/0.98/8.53 | 9.3 | 5.5 | 0 | 0.0 | 0.0 | 34.9 | 10.12 / 19.60 |
| h264-6000k | 0.0 | – | 62.97 / 62.97 | 30.06/23.47/0.99/8.46 | 9.2 | 5.5 | 0 | 0.0 | 0.0 | 36.0 | 8.92 / 18.66 |
| h264-12000k | 0.0 | – | 46.13 / 46.13 | 13.39/23.41/0.98/8.35 | 8.8 | 5.5 | 0 | 0.0 | 0.0 | 37.0 | 7.96 / 18.35 |
| h264-12000k-refresh500ms | 30.7 | – | 46.45 / 46.45 | 13.39/23.71/1.02/8.34 | 47.3 | 20.3 | 0 | 0.0 | 0.0 | 37.6 | 7.44 / 18.32 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 1.0 | 32.2 | 42.4 | 2.35 / 8.09 |

Attach, same screen: GHOSTSNP READY 5439 B (2067 deflated), full render-delta 13716 B (1348 deflated), H.264 IDR 75218 B

### flood  (trace 5.1 s, window 0.0–5.1 s, VT 395.13 MB, 0 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 624135.4 | 310058.0 | – | – | 0.0 | 206.9 | 0 | – | – | – | – / – |
| render-delta | 7491.0 | 997.4 | – | – | 46.6 | 7.1 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 7050.0 | 977.8 | – | – | 45.9 | 5.9 | 0 | – | – | – | – / – |
| h264-2000k | 2185.4 | – | – | – | 376.3 | 89.6 | 0 | 0.0 | 0.0 | 14.4 | 68.98 / 100.00 |
| h264-6000k | 6208.2 | – | – | – | 875.2 | 249.1 | 0 | 0.0 | 0.0 | 15.7 | 47.34 / 100.00 |
| h264-12000k | 12052.0 | – | – | – | 1653.5 | 492.3 | 0 | 0.0 | 0.0 | 17.9 | 28.76 / 100.00 |
| h264-12000k-refresh500ms | 12052.0 | – | – | – | 1644.8 | 492.4 | 0 | 0.0 | 0.0 | 17.9 | 28.76 / 100.00 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 2.4 | 100.0 | 72.0 | 0.00 / 0.00 |

Attach, same screen: GHOSTSNP READY 8047 B (3518 deflated), full render-delta 7486 B (1265 deflated), H.264 IDR 120612 B

### palette  (trace 0.0 s, window 0.0–0.0 s, VT 0.01 MB, 0 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 12401.3 | 7410.6 | – | – | 0.0 | 19.4 | 0 | – | – | – | – / – |
| render-delta | 10677.1 | 543.7 | – | – | 286.9 | 55.0 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 10529.2 | 456.4 | – | – | 224.9 | 53.1 | 0 | – | – | – | – / – |
| h264-2000k | 0.0 | – | – | – | 3183.9 | 4349.3 | 0 | 0.0 | 1.1 | 30.3 | 9.61 / 20.67 |
| h264-6000k | 0.0 | – | – | – | 3464.9 | 4372.4 | 0 | 0.0 | 1.1 | 30.7 | 8.76 / 19.72 |
| h264-12000k | 0.0 | – | – | – | 3199.9 | 4504.2 | 0 | 0.0 | 1.1 | 31.1 | 8.00 / 18.85 |
| h264-12000k-refresh500ms | 0.0 | – | – | – | 3204.1 | 4498.1 | 0 | 0.0 | 1.1 | 31.1 | 8.00 / 18.85 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 0.7 | 8.6 | 32.3 | 4.30 / 15.71 |

Attach, same screen: GHOSTSNP READY 20028 B (6070 deflated), full render-delta 28542 B (2786 deflated), H.264 IDR 86584 B

`palette` prints once and ends, so its bytes per second are not meaningful; it is here for colour.

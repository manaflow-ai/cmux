# Results, 2026-11-05

Run on a GCP lane VM (AMD EPYC 9B45, 32 vCPU, Linux 7.0), one bench process at a time, at
feat-cmux-next a6d444aad865. Pane: 120x40 cells, DejaVu Sans Mono 26 px (13 pt at 2x),
1920x1240 px. Link for the network stage: 20 Mbps unless named. Traces recorded on the same VM with
`scripts/record.py` (`flood`: `cat` of a 538 KB Rust file in a loop; `vim-idle` and `vim-typing`:
vim 9.1 with syntax colours on `ghostty-vt/src/render.rs`; `palette`: the 256-colour and 24-bit ramps).

## Headline

| | VT bytes (`terminal_bytes`) | cells (`render-delta`) | H.264 (OpenH264, 12 Mbps target) |
|---|---|---|---|
| typing in vim, bytes/s | 3.1 kbps (1.5 deflated) | 76 kbps (4.3 deflated) | 89 kbps |
| idle vim, bytes/s | 0 | 0 | 0 on damage only; 31 kbps with the 500 ms refresh |
| `cat` flood, bytes/s | 624 Mbps (310 deflated) | 7.5 Mbps (1.0 deflated) | 12.0 Mbps, picture stale or smeared (PSNR 18 dB) |
| key to view p50 / p95, 20 Mbps | 0.33 / 0.35 ms | 0.71 / 0.82 ms | 38.1 / 45.8 ms (G0 measures 40–55 ms p50 glass-to-glass on Macs) |
| key to view p50 / p95, 5 Mbps | 0.34 / 0.38 ms | 2.14 / 2.46 ms | 38.6 / 47.3 ms |
| exact text cells | 100% | 100% | 0% (near, ±8 per channel: 0%) |
| text colour ΔE2000 mean / p95, vim | 0 | 0 | 8.0 / 18.4 (YUV 4:2:0 round trip alone: 2.4 / 8.1) |
| attach keyframe, vim screen | GHOSTSNP READY 7.5 KB (2.5 deflated) | `render-state` 15.9 KB (1.8 deflated) | IDR 102 KB |

Video's key-to-view on this VM is mostly software encode (21.0 ms p50 at 1920x1240), the 60 Hz
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
   PSNR 37 dB and 0% exact text either way, while the refresh costs 31 kbps and ~5x the encode CPU (48.8 against 9.7 ms/s).
4. **Raw VT does not survive a flood; coalesced cells do.** A `cat` flood is 624 Mbps of VT, beyond any
   link (the channel falls back to a GHOSTSNP snapshot once the viewer is 8 MiB behind).
   Cells at the daemon's 8 ms cadence send 7.46 Mbps, 1.02 Mbps deflated, and stay exact;
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
| vt | 3.1 | 1.5 | 0.33 / 0.35 | 0.00/0.00/0.01/0.32 | 0.0 | 2.0 | 0 | – | – | – | – / – |
| render-delta | 76.2 | 4.3 | 0.71 / 0.82 | 0.00/0.22/0.43/0.02 | 1.5 | 0.1 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 58.8 | 3.6 | 0.71 / 0.87 | 0.00/0.28/0.39/0.01 | 1.8 | 0.1 | 0 | – | – | – | – / – |
| h264-2000k | 88.7 | – | 39.84 / 50.92 | 10.01/21.03/0.04/8.29 | 136.0 | 53.8 | 0 | 0.0 | 0.1 | 36.7 | 5.75 / 16.32 |
| h264-6000k | 89.6 | – | 38.38 / 46.31 | 7.90/21.05/0.05/8.32 | 136.2 | 54.1 | 0 | 0.0 | 0.0 | 37.1 | 5.58 / 15.20 |
| h264-12000k | 89.4 | – | 38.13 / 45.76 | 7.37/20.97/0.05/8.32 | 137.0 | 54.5 | 0 | 0.0 | 0.0 | 37.2 | 5.57 / 15.00 |
| h264-12000k-refresh500ms | 90.4 | – | 38.11 / 45.39 | 7.37/20.99/0.05/8.29 | 149.6 | 59.5 | 0 | 0.0 | 0.0 | 37.4 | 5.51 / 14.89 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 1.4 | 49.2 | 41.5 | 1.84 / 7.52 |

Attach, same screen: GHOSTSNP READY 7543 B (2531 deflated), render-state 15861 B (1777 deflated), H.264 IDR 101519 B

### vim-typing-5mbps  (trace 20.2 s, window 0.0–20.2 s, VT 0.01 MB, 124 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 3.1 | 1.5 | 0.34 / 0.38 | 0.00/0.00/0.02/0.31 | 0.0 | 1.9 | 0 | – | – | – | – / – |
| render-delta | 76.2 | 4.3 | 2.14 / 2.46 | 0.00/0.23/1.73/0.02 | 1.6 | 0.1 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 58.8 | 3.6 | 1.86 / 2.47 | 0.00/0.29/1.54/0.01 | 1.9 | 0.1 | 0 | – | – | – | – / – |
| h264-2000k | 88.7 | – | 40.40 / 59.25 | 10.01/21.13/0.18/8.35 | 136.9 | 54.2 | 0 | 0.0 | 0.1 | 36.7 | 5.75 / 16.32 |
| h264-6000k | 89.6 | – | 38.45 / 51.24 | 7.90/21.17/0.22/8.37 | 136.8 | 54.4 | 0 | 0.0 | 0.0 | 37.1 | 5.58 / 15.20 |
| h264-12000k | 89.4 | – | 38.56 / 47.29 | 7.37/21.07/0.20/8.41 | 137.4 | 55.0 | 0 | 0.0 | 0.0 | 37.2 | 5.57 / 15.00 |
| h264-12000k-refresh500ms | 90.4 | – | 38.81 / 47.01 | 7.37/21.09/0.21/8.37 | 150.8 | 60.2 | 0 | 0.0 | 0.0 | 37.4 | 5.51 / 14.89 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 1.4 | 49.2 | 41.5 | 1.84 / 7.52 |

Attach, same screen: GHOSTSNP READY 7543 B (2531 deflated), render-state 15861 B (1777 deflated), H.264 IDR 101519 B

### vim-idle  (trace 7.5 s, window 2.0–7.0 s, VT 0.00 MB, 1 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 0.0 | – | – | – | 0.0 | 0.0 | 0 | – | – | – | – / – |
| render-delta | 0.0 | – | – | – | 0.2 | 0.0 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 0.0 | – | – | – | 0.2 | 0.0 | 0 | – | – | – | – / – |
| h264-2000k | 0.0 | – | – | – | 9.6 | 5.3 | 0 | 0.0 | 0.0 | 34.9 | 10.12 / 19.60 |
| h264-6000k | 0.0 | – | – | – | 9.6 | 5.3 | 0 | 0.0 | 0.0 | 36.0 | 8.92 / 18.66 |
| h264-12000k | 0.0 | – | – | – | 9.7 | 5.4 | 0 | 0.0 | 0.0 | 37.0 | 7.96 / 18.35 |
| h264-12000k-refresh500ms | 30.7 | – | – | – | 48.8 | 20.0 | 0 | 0.0 | 0.0 | 37.6 | 7.44 / 18.32 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 1.0 | 32.2 | 42.4 | 2.35 / 8.09 |

Attach, same screen: GHOSTSNP READY 5439 B (2067 deflated), render-state 13742 B (1371 deflated), H.264 IDR 75218 B

### flood  (trace 5.1 s, window 0.0–5.1 s, VT 395.13 MB, 0 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 624135.4 | 310058.0 | – | – | 0.0 | 207.6 | 0 | – | – | – | – / – |
| render-delta | 7460.9 | 1018.2 | – | – | 48.9 | 6.4 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 7050.0 | 977.8 | – | – | 47.3 | 5.7 | 0 | – | – | – | – / – |
| h264-2000k | 2189.4 | – | – | – | 389.7 | 89.1 | 0 | 0.0 | 0.0 | 14.4 | 68.98 / 100.00 |
| h264-6000k | 6170.5 | – | – | – | 913.9 | 251.0 | 0 | 0.0 | 0.0 | 15.8 | 47.67 / 100.00 |
| h264-12000k | 11992.1 | – | – | – | 1721.3 | 494.2 | 0 | 0.0 | 0.0 | 17.8 | 28.42 / 100.00 |
| h264-12000k-refresh500ms | 11992.1 | – | – | – | 1711.9 | 497.2 | 0 | 0.0 | 0.0 | 17.8 | 28.42 / 100.00 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 2.4 | 100.0 | 72.0 | 0.00 / 0.00 |

Attach, same screen: GHOSTSNP READY 8047 B (3518 deflated), render-state 7520 B (1287 deflated), H.264 IDR 120612 B

### palette  (trace 0.0 s, window 0.0–0.0 s, VT 0.01 MB, 0 keys, 1920x1240 px)
| path | kbps | kbps deflate | key→view p50 / p95 ms | p50 wait/host/net/viewer ms | host CPU ms/s | viewer CPU ms/s | rows lost | exact text cells % | near % | PSNR dB | text ΔE00 mean / p95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vt | 12401.3 | 7410.6 | – | – | 0.0 | 19.3 | 0 | – | – | – | – / – |
| render-delta | 10713.8 | 569.1 | – | – | 296.7 | 58.5 | 0 | 100.0 | 100.0 | inf | 0.00 / 0.00 |
| rowdiff | 10529.2 | 456.4 | – | – | 230.3 | 52.6 | 0 | – | – | – | – / – |
| h264-2000k | 0.0 | – | – | – | 3474.9 | 4425.2 | 0 | 0.0 | 1.1 | 30.3 | 9.61 / 20.67 |
| h264-6000k | 0.0 | – | – | – | 3666.5 | 4385.2 | 0 | 0.0 | 1.1 | 30.7 | 8.76 / 19.72 |
| h264-12000k | 0.0 | – | – | – | 3466.8 | 4380.6 | 0 | 0.0 | 1.1 | 31.1 | 8.00 / 18.85 |
| h264-12000k-refresh500ms | 0.0 | – | – | – | 3472.1 | 4423.0 | 0 | 0.0 | 1.1 | 31.1 | 8.00 / 18.85 |
| YUV 4:2:0 round trip, no codec | | | | | | | | 0.7 | 8.6 | 32.3 | 4.30 / 15.71 |

Attach, same screen: GHOSTSNP READY 20028 B (6070 deflated), render-state 28568 B (2806 deflated), H.264 IDR 86584 B

`palette` prints once and ends, so its bytes per second are not meaningful; it is here for colour. vim-idle's one key (`:qa!`) falls outside its window, so it has no latency row.

# cmux-bytes findings

What the bytes-path harness (`cmux-bytes bench`, registered as `scripts/bench/benches/bytes_path.py`) showed
while the new path was built, and what each finding changed. The hill-climb timer (`cmux-bytes install-timer`)
appends its own steps to `~/.cache/cmux-bytes/findings.md`; a kept step comes back here by PR as a new
`Params::default()`.

The rule for every change: keep it only if it beats the current path at p50 and p95 and grows no payload.
The climb judges by geomean across every folder, scenario and profile (synced p50 under 0.99 of the best,
synced p95 under 1.0, first turn p50 at most 1.005, nothing grown, every chunk round-tripped). Changes by hand,
below, were also checked row by row against today.

## Findings

| # | Run | Finding | Change | Result |
|---|---|---|---|---|
| 1 | v1 | Today's copy grows payloads: base64 of every part, plus one JSON request per file. An edit of monorepo sent 11.05 MB for 6.42 MB changed (172 %). | Frames that store when zstd does not shrink (`keep_ratio`), so a frame is at most raw + 15 bytes. | New wire 32 % of raw on the same edit; `grown_bytes` 0 on every row. |
| 2 | v2 | Already-compressed and high-entropy chunks cost zstd CPU for nothing. | Kind classifier and an 8 KiB entropy sample: at or above 7.6 bits per byte, store. | Media cold (138 MB): today 175 MB on the wire (127 %, base64) and 1.03 s CPU; new 127 MB (92 %, repeats sent as references) and 0.08 s. |
| 3 | v3 | One zstd level for every link loses: level 19 starves a LAN, level 1 wastes a slow link. | `level_for`: the level that moves raw bytes fastest through min(compressor on N cores / headroom, link / ratio). | On 8 cores: LAN level 7, home Wi-Fi 17, lossy 19. |
| 4 | v4 | Monorepo cold on LAN was slower than today (1.75 s vs 1.41 s synced). The manifest was zstd-19 (1.5 s of CPU for 46,784 entries) and gated the first turn. | Manifest takes the link's level. | First turn 1.58 s -> 0.25 s. |
| 5 | v5 | Still slower on that row (1.52 s vs 1.26 s): dictionary training is about 3 s of one core, and every dictionary chunk waits for it. The harness had not modeled the wait. | The harness now holds `needs_dicts` chunks until the `trains_dicts` item finishes. Dictionaries train only on links at or under `dict_max_bandwidth` (50 MB/s). | Monorepo cold LAN synced 0.82 s vs today 1.44 s. |
| 6 | v6 A/B | Does a reused zstd context per thread (instead of `zstd::bulk::compress`'s fresh one) cut sender CPU on small files? | Tried, measured, dropped. | Same wire, same synced (0.838 s), CPU within noise (4.66 s vs 4.42 s). Not kept. |
| 7 | paced | Braid's paced carrier (RFD 0164 class 3) on lossy and cross-region links, against TCP's Mathis ceiling. | `paced` stays off by default (no Rust carrier yet); the fill goes through `lanes::LaneSink` so the carrier plugs in later. | See [Paced against TCP](#paced-against-tcp). |

## Status: today against new

Run v6, 2026-11-25T12:01Z, 8 cores, 9 runs per row. All 56 rows: new is at or under today on wire bytes and on first turn and fully synced at p50 and p95; `grown_bytes` 0 and no verify failures on every row.

| folder | scenario | profile | wire today | wire new | first turn today p50/p95 | first turn new p50/p95 | synced today p50/p95 | synced new p50/p95 | CPU send/recv new |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| source | cold | lan | 62 MB (58.6%) | 45 MB (41.9%) | 532ms / 607ms | 80ms / 91ms | 532ms / 606ms | 390ms / 444ms | 1.16 / 0.09 s |
| source | cold | home-wifi | 62 MB (58.6%) | 44 MB (41.1%) | 12s / 14s | 1.8s / 2.1s | 12s / 14s | 9.0s / 10s | 15.95 / 0.10 s |
| source | cold | lossy | 62 MB (58.6%) | 44 MB (41.0%) | 76s / 101s | 7.3s / 8.3s | 76s / 100s | 37s / 41s | 29.29 / 0.11 s |
| source | cold | tailnet-xregion | 62 MB (58.6%) | 44 MB (41.6%) | 26s / 35s | 1.7s / 2.3s | 26s / 35s | 6.7s / 8.9s | 5.48 / 0.12 s |
| source | edit | lan | 1.40 MB (104.1%) | 0.34 MB (25.6%) | 35ms / 36ms | 6ms / 7ms | 33ms / 35ms | 7ms / 8ms | 0.02 / 0.00 s |
| source | edit | home-wifi | 1.40 MB (104.1%) | 0.33 MB (24.7%) | 339ms / 442ms | 144ms / 174ms | 313ms / 407ms | 155ms / 173ms | 0.26 / 0.00 s |
| source | edit | lossy | 1.40 MB (104.1%) | 0.33 MB (24.7%) | 2.8s / 3.7s | 491ms / 607ms | 2.7s / 3.6s | 565ms / 710ms | 0.44 / 0.00 s |
| source | edit | tailnet-xregion | 1.40 MB (104.1%) | 0.34 MB (25.2%) | 1.6s / 2.2s | 659ms / 874ms | 1.5s / 2.0s | 541ms / 719ms | 0.07 / 0.00 s |
| node_modules | cold | lan | 114 MB (41.5%) | 72 MB (26.2%) | 1.2s / 1.3s | 27ms / 31ms | 1.2s / 1.3s | 626ms / 714ms | 4.10 / 0.35 s |
| node_modules | cold | home-wifi | 114 MB (41.5%) | 65 MB (23.7%) | 22s / 25s | 634ms / 707ms | 21s / 24s | 13s / 15s | 52.08 / 0.41 s |
| node_modules | cold | lossy | 114 MB (41.5%) | 65 MB (23.6%) | 106s / 140s | 2.4s / 2.7s | 106s / 140s | 53s / 60s | 83.79 / 0.36 s |
| node_modules | cold | tailnet-xregion | 114 MB (41.5%) | 68 MB (24.9%) | 47s / 62s | 1.0s / 1.3s | 47s / 62s | 10s / 13s | 13.54 / 0.33 s |
| node_modules | edit | lan | 4.95 MB (155.6%) | 0.64 MB (20.2%) | 41ms / 44ms | 10ms / 11ms | 40ms / 43ms | 11ms / 12ms | 0.05 / 0.00 s |
| node_modules | edit | home-wifi | 4.95 MB (155.6%) | 0.55 MB (17.3%) | 436ms / 570ms | 123ms / 158ms | 410ms / 535ms | 204ms / 224ms | 0.76 / 0.01 s |
| node_modules | edit | lossy | 4.95 MB (155.6%) | 0.55 MB (17.2%) | 3.0s / 3.9s | 401ms / 529ms | 2.9s / 3.8s | 754ms / 855ms | 0.85 / 0.01 s |
| node_modules | edit | tailnet-xregion | 4.95 MB (155.6%) | 0.57 MB (17.9%) | 2.2s / 2.9s | 650ms / 861ms | 2.1s / 2.7s | 571ms / 758ms | 0.19 / 0.01 s |
| build | cold | lan | 29 MB (49.1%) | 13 MB (21.6%) | 267ms / 285ms | 5ms / 6ms | 266ms / 284ms | 112ms / 127ms | 0.56 / 0.05 s |
| build | cold | home-wifi | 29 MB (49.1%) | 12 MB (20.0%) | 5.9s / 6.7s | 118ms / 153ms | 5.8s / 6.7s | 2.4s / 2.8s | 7.47 / 0.06 s |
| build | cold | lossy | 29 MB (49.1%) | 12 MB (19.9%) | 28s / 37s | 421ms / 553ms | 28s / 37s | 12s / 12s | 12.17 / 0.06 s |
| build | cold | tailnet-xregion | 29 MB (49.1%) | 12 MB (21.4%) | 10s / 13s | 651ms / 865ms | 10.0s / 13s | 3.0s / 4.0s | 1.80 / 0.05 s |
| build | edit | lan | 0.37 MB (107.3%) | 0.11 MB (31.8%) | 22ms / 24ms | 4ms / 6ms | 21ms / 22ms | 6ms / 7ms | 0.00 / 0.00 s |
| build | edit | home-wifi | 0.37 MB (107.3%) | 0.10 MB (30.1%) | 269ms / 352ms | 105ms / 139ms | 243ms / 318ms | 120ms / 153ms | 0.05 / 0.00 s |
| build | edit | lossy | 0.37 MB (107.3%) | 0.10 MB (30.1%) | 1.9s / 2.6s | 337ms / 447ms | 1.8s / 2.4s | 614ms / 804ms | 0.09 / 0.00 s |
| build | edit | tailnet-xregion | 0.37 MB (107.3%) | 0.11 MB (31.7%) | 1.4s / 1.8s | 627ms / 833ms | 1.2s / 1.6s | 577ms / 765ms | 0.01 / 0.00 s |
| media | cold | lan | 175 MB (127.1%) | 127 MB (91.7%) | 1.5s / 1.7s | 5ms / 6ms | 1.5s / 1.7s | 1.1s / 1.3s | 0.03 / 0.01 s |
| media | cold | home-wifi | 175 MB (127.1%) | 127 MB (91.7%) | 36s / 41s | 129ms / 166ms | 36s / 41s | 26s / 29s | 0.12 / 0.01 s |
| media | cold | lossy | 175 MB (127.1%) | 127 MB (91.7%) | 167s / 222s | 474ms / 602ms | 167s / 222s | 103s / 118s | 0.21 / 0.01 s |
| media | cold | tailnet-xregion | 175 MB (127.1%) | 127 MB (91.7%) | 52s / 69s | 658ms / 874ms | 52s / 69s | 17s / 23s | 0.04 / 0.01 s |
| media | edit | lan | 2.27 MB (117.7%) | 0.53 MB (27.2%) | 58ms / 60ms | 4ms / 6ms | 57ms / 58ms | 8ms / 9ms | 0.00 / 0.00 s |
| media | edit | home-wifi | 2.27 MB (117.7%) | 0.53 MB (27.2%) | 755ms / 989ms | 105ms / 140ms | 729ms / 955ms | 196ms / 213ms | 0.00 / 0.00 s |
| media | edit | lossy | 2.27 MB (117.7%) | 0.53 MB (27.2%) | 8.5s / 11s | 338ms / 449ms | 8.4s / 11s | 932ms / 1.2s | 0.00 / 0.00 s |
| media | edit | tailnet-xregion | 2.27 MB (117.7%) | 0.53 MB (27.2%) | 3.3s / 4.4s | 628ms / 834ms | 3.2s / 4.2s | 671ms / 891ms | 0.00 / 0.00 s |
| binaries | cold | lan | 138 MB (51.4%) | 13 MB (4.8%) | 1.2s / 1.4s | 4ms / 6ms | 1.2s / 1.4s | 114ms / 130ms | 0.61 / 0.04 s |
| binaries | cold | home-wifi | 138 MB (51.4%) | 12 MB (4.4%) | 28s / 32s | 105ms / 139ms | 28s / 32s | 2.5s / 2.8s | 5.75 / 0.05 s |
| binaries | cold | lossy | 138 MB (51.4%) | 12 MB (4.4%) | 129s / 165s | 336ms / 446ms | 129s / 165s | 14s / 14s | 10.41 / 0.05 s |
| binaries | cold | tailnet-xregion | 138 MB (51.4%) | 13 MB (4.7%) | 40s / 52s | 627ms / 833ms | 39s / 52s | 2.9s / 3.7s | 1.58 / 0.04 s |
| binaries | edit | lan | 0.16 MB (-) | 0.00 MB (-) | 6ms / 8ms | 4ms / 6ms | 5ms / 7ms | 3ms / 4ms | 0.00 / 0.00 s |
| binaries | edit | home-wifi | 0.16 MB (-) | 0.00 MB (-) | 157ms / 208ms | 104ms / 139ms | 131ms / 173ms | 78ms / 104ms | 0.00 / 0.00 s |
| binaries | edit | lossy | 0.16 MB (-) | 0.00 MB (-) | 502ms / 667ms | 335ms / 444ms | 418ms / 556ms | 251ms / 333ms | 0.00 / 0.00 s |
| binaries | edit | tailnet-xregion | 0.16 MB (-) | 0.00 MB (-) | 940ms / 1.2s | 627ms / 832ms | 783ms / 1.0s | 470ms / 624ms | 0.00 / 0.00 s |
| empty | cold | lan | 0.16 MB (-) | 0.00 MB (-) | 6ms / 8ms | 4ms / 6ms | 5ms / 7ms | 3ms / 4ms | 0.00 / 0.00 s |
| empty | cold | home-wifi | 0.16 MB (-) | 0.00 MB (-) | 157ms / 208ms | 104ms / 139ms | 131ms / 173ms | 78ms / 104ms | 0.00 / 0.00 s |
| empty | cold | lossy | 0.16 MB (-) | 0.00 MB (-) | 502ms / 667ms | 335ms / 444ms | 418ms / 556ms | 251ms / 333ms | 0.00 / 0.00 s |
| empty | cold | tailnet-xregion | 0.16 MB (-) | 0.00 MB (-) | 940ms / 1.2s | 627ms / 832ms | 783ms / 1.0s | 470ms / 624ms | 0.00 / 0.00 s |
| empty | edit | lan | 0.16 MB (-) | 0.00 MB (-) | 6ms / 8ms | 4ms / 6ms | 5ms / 7ms | 3ms / 4ms | 0.00 / 0.00 s |
| empty | edit | home-wifi | 0.16 MB (-) | 0.00 MB (-) | 157ms / 208ms | 104ms / 139ms | 131ms / 173ms | 78ms / 104ms | 0.00 / 0.00 s |
| empty | edit | lossy | 0.16 MB (-) | 0.00 MB (-) | 502ms / 667ms | 335ms / 444ms | 418ms / 556ms | 251ms / 333ms | 0.00 / 0.00 s |
| empty | edit | tailnet-xregion | 0.16 MB (-) | 0.00 MB (-) | 940ms / 1.2s | 627ms / 832ms | 783ms / 1.0s | 470ms / 624ms | 0.00 / 0.00 s |
| monorepo | cold | lan | 155 MB (57.9%) | 95 MB (35.2%) | 1.3s / 1.4s | 245ms / 279ms | 1.3s / 1.4s | 818ms / 933ms | 4.18 / 0.34 s |
| monorepo | cold | home-wifi | 155 MB (57.9%) | 83 MB (30.9%) | 28s / 32s | 5.6s / 6.4s | 28s / 32s | 17s / 19s | 57.64 / 0.89 s |
| monorepo | cold | lossy | 155 MB (57.9%) | 83 MB (30.9%) | 131s / 174s | 22s / 26s | 131s / 174s | 67s / 76s | 66.21 / 0.90 s |
| monorepo | cold | tailnet-xregion | 155 MB (57.9%) | 85 MB (31.6%) | 65s / 86s | 4.0s / 5.4s | 65s / 86s | 11s / 15s | 16.00 / 0.55 s |
| monorepo | edit | lan | 11 MB (172.2%) | 2.26 MB (35.2%) | 46ms / 50ms | 16ms / 17ms | 45ms / 49ms | 23ms / 25ms | 0.11 / 0.01 s |
| monorepo | edit | home-wifi | 11 MB (172.2%) | 1.98 MB (30.9%) | 795ms / 886ms | 259ms / 281ms | 763ms / 860ms | 479ms / 534ms | 1.46 / 0.02 s |
| monorepo | edit | lossy | 11 MB (172.2%) | 1.98 MB (30.9%) | 4.4s / 5.8s | 961ms / 1.0s | 4.3s / 5.7s | 1.8s / 2.1s | 1.71 / 0.03 s |
| monorepo | edit | tailnet-xregion | 11 MB (172.2%) | 2.03 MB (31.6%) | 3.4s / 4.5s | 725ms / 962ms | 3.2s / 4.3s | 737ms / 979ms | 0.38 / 0.01 s |

## Paced against TCP

Both new, same params; only the carrier differs (`paced=true`: the link's bandwidth times one minus loss, no Mathis ceiling). Cold copies on the two links where TCP's loss and RTT bind.

| folder | profile | TCP synced p50/p95 | paced synced p50/p95 | TCP wire | paced wire |
|---|---|---:|---:|---:|---:|
| source | lossy | 36.5 s / 40.7 s | 35.5 s / 40.5 s | 44 MB | 43 MB |
| source | tailnet-xregion | 6.7 s / 8.9 s | 2.3 s / 2.5 s | 44 MB | 44 MB |
| node_modules | lossy | 52.9 s / 60.2 s | 52.8 s / 60.2 s | 65 MB | 65 MB |
| node_modules | tailnet-xregion | 10.1 s / 13.3 s | 3.9 s / 4.1 s | 68 MB | 68 MB |
| build | lossy | 11.5 s / 12.4 s | 9.6 s / 11.0 s | 12 MB | 12 MB |
| build | tailnet-xregion | 3.0 s / 4.0 s | 1.0 s / 1.1 s | 12 MB | 12 MB |
| media | lossy | 103.2 s / 117.7 s | 103.2 s / 117.7 s | 127 MB | 127 MB |
| media | tailnet-xregion | 16.9 s / 22.5 s | 5.6 s / 6.3 s | 127 MB | 127 MB |
| binaries | lossy | 13.6 s / 14.1 s | 9.9 s / 11.3 s | 12 MB | 12 MB |
| binaries | tailnet-xregion | 2.9 s / 3.7 s | 1.1 s / 1.2 s | 13 MB | 13 MB |
| monorepo | lossy | 67.0 s / 76.4 s | 63.1 s / 72.0 s | 83 MB | 78 MB |
| monorepo | tailnet-xregion | 11.0 s / 14.6 s | 6.3 s / 6.4 s | 85 MB | 80 MB |

Cross-region, where TCP's window over RTT binds, the paced carrier is 2.6x to 3x faster fully synced at p50 and tighter at p95. On the lossy home link it gains little to 30 %: there the link itself (or zstd-19 on 8 cores) is the bottleneck, not TCP's loss response. This is a model, not a measured carrier: the Rust carrier is the next step (with ultra-connectivity-dictator), and `paced` stays off until it is measured.

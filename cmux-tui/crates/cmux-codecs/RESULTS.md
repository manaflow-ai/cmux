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
  `DEFAULT_CODEC`). No switch lands; OpenH264 stays on Linux and Windows hosts, where Media
  Foundation is the next encoder to measure the same way.

## VP9 and AV1 against H.264 (#43051, #43115)

- At H.264's own bitrate, VP9 (libvpx, WebRTC's screen settings) drops most frames: 3.2-28.9
  on-time fps against H.264's 25.1-29.8. With frame dropping off it ties on-time fps but its text
  PSNR is 2.5-12.3 dB lower in 10 of 12 rows. At twice H.264's bitrate it is ahead in 7 of 12.
- The native host matrix (scroll at 2% loss) agrees: H.264 27.4 fps at 2.1 Mbps and 33.2 dB,
  VP9 23.0 fps at 10.4 Mbps and 27.6 dB.
- AV1 (rav1e, speed 10) reaches 0 on-time fps: 22-51 ms per frame to encode.
- Verdict: no VP9 or AV1 setting; H.264 stays.

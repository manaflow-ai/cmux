<!-- cmuxs-Mac-mini (6) (Apple M4 Pro, macOS 27.0.1), fleet step 39becc64970daf4531b6d3dd at feat-cmux-next 3330ea7facf0,
     2026-10-20, cmux NEXT nightly, 3 rounds, no Debug rows (tabswitch=off). A shared CI mini: the 1-minute load
     was 3 to 8 during the run, so these numbers are noisier than cmux20's. -->

# xbench, 2026-10-20: cmux NEXT against Chrome, Helium, Ardia, Dia, Safari

Apple M4 Pro (Mac16,11), 14 cores, 48 GB, macOS 27.0.1 (26A434), host cmux’s Mac mini (6), cmux ref `3330ea7facf0`. Medians over runs (n per cell in results.json, min-max there too). Lower is better.

Versions: cmux NEXT (Chromium tab) 1.0.0-nightly.3946367535401, cmux NEXT (WebKit tab) 1.0.0-nightly.3946367535401, cmux NEXT (terminals) 1.0.0-nightly.3946367535401, Chrome 155.0.8059.85, Helium 0.19.4.1, Ardia 0.2.38, Dia 1.53.0, Safari 27.0.1.

| Metric | cmux NEXT (Chromium tab) | cmux NEXT (WebKit tab) | cmux NEXT (terminals) | Chrome | Helium | Ardia | Dia | Safari | best other | cmux vs best other | Ardia (published, M5 Pro) | Helium (published) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Power, idle, hidden | 2.2 mW | 4.2 mW | 0.1 mW | 0.9 mW | 1.1 mW | – | 4.7 mW | 1.3 mW | 0.9 mW (Chrome) | 16.3x less | 3.9 mW | 3.1 mW |
| Power, idle, in view | 122 mW | 5.9 mW | 17.6 mW | 51.2 mW | 1.3 mW | 1.0 mW | 6.0 mW | 1.6 mW | 1.0 mW (Ardia) | 5.7x MORE | 3.5 mW | 4.0 mW |
| Power, scrolling | 1.5 mW | 14.2 mW | – | 7.7 mW | 11.6 mW | – | 11.0 mW | 13.3 mW | 7.7 mW (Chrome) | 5.1x less | 28.2 mW | 51.9 mW |
| Power, video | 2.1 mW | 30.6 mW | – | 31.6 mW | 33.5 mW | – | 69.3 mW | 7.0 mW | 7.0 mW (Safari) | 3.3x less | 82.0 mW | 90.9 mW |
| Power, switching tabs | 24.6 mW | 24.5 mW | 15.6 mW | 18.1 mW | 17.6 mW | – | 5.3 mW | – | 5.3 mW (Dia) | 3.0x MORE | 136 mW | 173 mW |
| Cold launch, window up | 785 ms | 794 ms | 398 ms | 2,421 ms | 1,272 ms | 1,172 ms | 2,450 ms | 505 ms | 505 ms (Safari) | 1.3x less | 280 ms | 353 ms |
| New tab first paint | – | 143 ms | – | 78.9 ms | 90.1 ms | 56.0 ms | – | 190 ms | 56.0 ms (Ardia) | 2.5x MORE | 54.9 ms | 71.5 ms |
| Wakeups, idle, 20 tabs | 56.5/s | 389.3/s | 6.4/s | 63.5/s | 59.7/s | 50.1/s | 138.7/s | 132.2/s | 50.1/s (Ardia) | 7.8x less | 13.6/s | 28.1/s |
| CPU, idle, 20 tabs | 3.60% | 12.64% | 6.06% | 2.97% | 2.75% | 1.98% | 9.92% | 3.41% | 1.98% (Ardia) | 1.8x MORE | 0.45% | 1.02% |
| Memory, 1 tab | 947 MB | 1,000 MB | 504 MB | 458 MB | 448 MB | 356 MB | 632 MB | 272 MB | 272 MB (Safari) | 1.9x MORE | 298 MB | 374 MB |
| Memory, 10 tabs | 1,176 MB | 1,215 MB | 610 MB | 763 MB | 864 MB | 822 MB | 985 MB | 485 MB | 485 MB (Safari) | 1.3x MORE | 714 MB | 773 MB |
| Memory, 20 tabs | 1,566 MB | 1,468 MB | 705 MB | 908 MB | 1,130 MB | 1,151 MB | 1,328 MB | 672 MB | 672 MB (Safari) | 1.0x MORE | 1,082 MB | 1,121 MB |
| Cold launch, link -> page painted * | – | – | – | 2,409 ms | 1,257 ms | – | – | – | 1,257 ms (Helium) | – | – | – |
| Tab switch -> shown * | – | 42.6 ms | – | 18.8 ms | 20.1 ms | – | – | – | 18.8 ms (Chrome) | 2.3x MORE | – | – |
| Memory, back to 1 tab after 20 * | 998 MB | 1,106 MB | 684 MB | 434 MB | 558 MB | – | 680 MB | – | 434 MB (Chrome) | 1.6x MORE | – | – |
| CPU, idle, 1 tab * | 2.63% | 4.26% | 0.14% | 2.76% | 2.38% | 0.18% | 2.32% | 1.45% | 0.18% (Ardia) | 1.3x less | – | – |
| Wakeups, idle, 1 tab * | 73.0/s | 73.2/s | 5.1/s | 44.8/s | 43.5/s | 4.2/s | 42.9/s | 59.7/s | 4.2/s (Ardia) | 1.2x MORE | – | – |
| Power, idle, in view, 1 tab * | 5.2 mW | 88.0 mW | 0.1 mW | 10.8 mW | 38.0 mW | 0.4 mW | 10.9 mW | 1.6 mW | 0.4 mW (Ardia) | 7.4x less | – | – |
| Power, cmux idle on Home * | – | – | 1.7 mW | – | – | – | – | – | – | – | – | – |
| CPU, cmux idle on Home * | – | – | 0.23% | – | – | – | – | – | – | – | – | – |
| Wakeups, cmux idle on Home * | – | – | 8.6/s | – | – | – | – | – | – | – | – | – |

\* not in Ardia's tweet. "cmux vs best other" uses the best cmux variant of the row. Power is CPU energy (ri_energy_nj) over every process of the browser; GPU and display are not in it. The 10x goal: every cmux cell at a tenth of the best other.

## Rows that could not be measured

- cmux-chromium newtab-paint: no paint within 15 s
- cmux-chromium tab-switch: no visibilitychange seen
- cmux-webkit tab-switch: no visibilitychange seen
- ardia session-error: HTTPError: HTTP Error 404: Not Found
- dia launch-link: no paint within 30 s
- dia newtab-paint: no paint within 15 s
- dia tab-switch: no visibilitychange seen
- safari launch-window: error: Command '['open', '-g', '-a', '/Applications/Safari.app', 'http://127.0.0.1:57954/idle.html?id=launch196']' returned non-zero exit status 1.
- safari session-error: CalledProcessError: Command '['open', '-g', '-a', '/Applications/Safari.app', 'http://127.0.0.1:57954/idle.html?id=s197']' returned non-zero exit status 1.


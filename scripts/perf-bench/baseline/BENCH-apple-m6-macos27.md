<!-- cmux20 (Apple M6, macOS 27.0), fleet step 6dd1020ca6392079a618a734 at feat-cmux-next 3330ea7facf0, 2026-10-20,
     cmux NEXT nightly 3944134600801, 3 rounds. Tab switch rows: tagged Debug build at the same commit. -->

# xbench, 2026-10-20: cmux NEXT against Chrome, Helium, Ardia, Dia, Safari

Apple M6 (Mac18,5), 12 cores, 16 GB, macOS 27.0 (26A425), host cmux20, cmux ref `3330ea7facf0`. Medians over runs (n per cell in results.json, min-max there too). Lower is better.

Versions: cmux NEXT (Chromium tab) 1.0.0-nightly.3944134600801, cmux NEXT (WebKit tab) 1.0.0-nightly.3944134600801, cmux NEXT (terminals) 1.0.0-nightly.3944134600801, Chrome 155.0.8059.85, Helium 0.19.4.1, Ardia 0.2.38, Dia 1.53.0, Safari 27.0.

| Metric | cmux NEXT (Chromium tab) | cmux NEXT (WebKit tab) | cmux NEXT (terminals) | Chrome | Helium | Ardia | Dia | Safari | best other | cmux vs best other | Ardia (published, M5 Pro) | Helium (published) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Power, idle, hidden | 0.6 mW | 0.5 mW | 0.1 mW | 0.2 mW | 0.3 mW | – | 5.2 mW | 0.1 mW | 0.1 mW (Safari) | 1.3x MORE | 3.9 mW | 3.1 mW |
| Power, idle, in view | 105 mW | 0.7 mW | 7.5 mW | 1.1 mW | 1.2 mW | 0.9 mW | 6.0 mW | 0.1 mW | 0.1 mW (Safari) | 8.1x MORE | 3.5 mW | 4.0 mW |
| Power, scrolling | 0.8 mW | 1.2 mW | – | 5.5 mW | 8.3 mW | – | 10.7 mW | 1.0 mW | 1.0 mW (Safari) | 1.3x less | 28.2 mW | 51.9 mW |
| Power, video | 0.8 mW | 0.7 mW | – | 23.2 mW | 23.5 mW | – | 24.2 mW | 0.2 mW | 0.2 mW (Safari) | 3.8x MORE | 82.0 mW | 90.9 mW |
| Power, switching tabs | 9.4 mW | 5.5 mW | 5.0 mW | 6.4 mW | 6.4 mW | – | 5.4 mW | – | 5.4 mW (Dia) | 1.1x less | 136 mW | 173 mW |
| Cold launch, window up | 316 ms | 312 ms | 311 ms | 623 ms | 496 ms | 956 ms | 1,083 ms | 484 ms | 484 ms (Safari) | 1.6x less | 280 ms | 353 ms |
| New tab first paint | – | 259 ms | – | 88.5 ms | 92.2 ms | 67.1 ms | – | 250 ms | 67.1 ms (Ardia) | 3.9x MORE | 54.9 ms | 71.5 ms |
| Wakeups, idle, 20 tabs | 38.4/s | 58.8/s | 7.8/s | 102.8/s | 100.3/s | 87.7/s | 243.5/s | 4.8/s | 4.8/s (Safari) | 1.6x MORE | 13.6/s | 28.1/s |
| CPU, idle, 20 tabs | 2.47% | 0.80% | 7.30% | 1.50% | 1.68% | 1.26% | 7.03% | 0.12% | 0.12% (Safari) | 6.8x MORE | 0.45% | 1.02% |
| Memory, 1 tab | 932 MB | 892 MB | 468 MB | 389 MB | 340 MB | 352 MB | 581 MB | 994 MB | 340 MB (Helium) | 1.4x MORE | 298 MB | 374 MB |
| Memory, 10 tabs | 1,110 MB | 1,020 MB | 565 MB | 578 MB | 688 MB | 648 MB | 926 MB | 377 MB | 377 MB (Safari) | 1.5x MORE | 714 MB | 773 MB |
| Memory, 20 tabs | 1,529 MB | 1,255 MB | 626 MB | 793 MB | 1,022 MB | 1,008 MB | 1,263 MB | 544 MB | 544 MB (Safari) | 1.2x MORE | 1,082 MB | 1,121 MB |
| Cold launch, link -> page painted * | – | – | – | 714 ms | 523 ms | – | – | – | 523 ms (Helium) | – | – | – |
| Tab switch -> shown * | – | – | – | 16.5 ms | 16.5 ms | – | – | – | 16.5 ms (Chrome) | – | – | – |
| Memory, back to 1 tab after 20 * | 955 MB | 941 MB | 504 MB | 373 MB | 371 MB | – | 609 MB | – | 371 MB (Helium) | 1.4x MORE | – | – |
| CPU, idle, 1 tab * | 1.65% | 3.98% | 0.09% | 1.87% | 1.80% | 0.18% | 1.97% | 0.77% | 0.18% (Ardia) | 2.1x less | – | – |
| Wakeups, idle, 1 tab * | 27.8/s | 19.8/s | 7.3/s | 77.1/s | 77.3/s | 6.8/s | 77.1/s | 7.8/s | 6.8/s (Ardia) | 1.1x MORE | – | – |
| Power, idle, in view, 1 tab * | 1.6 mW | 52.9 mW | 0.1 mW | 7.1 mW | 32.2 mW | 0.2 mW | 8.9 mW | 2.6 mW | 0.2 mW (Ardia) | 2.7x less | – | – |
| Power, cmux idle on Home * | – | – | 0.1 mW | – | – | – | – | – | – | – | – | – |
| CPU, cmux idle on Home * | – | – | 0.12% | – | – | – | – | – | – | – | – | – |
| Wakeups, cmux idle on Home * | – | – | 8.3/s | – | – | – | – | – | – | – | – | – |

\* not in Ardia's tweet. "cmux vs best other" uses the best cmux variant of the row. Power is CPU energy (ri_energy_nj) over every process of the browser; GPU and display are not in it. The 10x goal: every cmux cell at a tenth of the best other.

## Tab switch in a real window (cmux NEXT, tagged Debug build)

**Debug only:** these rows come from a tagged Debug build (the timing hooks exist only in Debug), not the Release or nightly build in the table above. Compare them only with other Debug runs.

tab-switch-matrix.py: one pane holding N tabs of a kind, warm; end-to-end = OS input event to the Core Animation commit that shows the tab (p50 / p90 ms); late = switches past their first frame.

| Kind | Tabs | Ctrl-Tab | Cmd-Shift-] | Click | late | per hidden tab |
|---|---|---|---|---|---|---|
| Browser (Chromium) | 2 | 18.4 / 19.8 | 20.4 / 21.7 | 21.3 / 36.1 | 0/5, 0/5, 0/5 | 72.35 MB |
| Browser (Chromium) | 10 | 21.7 / 23.4 | 20.8 / 23.0 | 30.4 / 36.4 | 0/20, 0/20, 0/20 | 44.87 MB |
| Browser (Chromium) | 30 | 21.7 / 33.0 | 22.9 / 29.8 | 29.0 / 35.9 | 0/58, 0/58, 0/52 | 59.05 MB |
| Browser (WebKit) | 2 | 15.6 / 17.7 | 12.0 / 20.0 | 19.6 / 26.1 | 0/5, 1/5, 0/5 | 20.5 MB |
| Browser (WebKit) | 10 | 11.8 / 18.5 | 14.9 / 19.8 | 16.3 / 27.6 | 0/20, 0/20, 0/20 | 4.94 MB |
| Browser (WebKit) | 30 | 19.4 / 27.9 | 16.3 / 25.8 | 18.8 / 28.5 | 0/58, 0/58, 0/52 | 4.12 MB |
| Markdown | 2 | 15.4 / 17.6 | 7.1 / 14.0 | 17.6 / 20.9 | 0/5, 0/5, 0/5 | 14.0 MB |
| Markdown | 10 | 10.9 / 19.5 | 12.1 / 18.4 | 16.5 / 23.5 | 0/20, 0/20, 0/20 | 1.91 MB |
| Markdown | 30 | 13.4 / 21.8 | 13.3 / 21.0 | 16.3 / 22.2 | 0/58, 0/58, 0/52 | 1.12 MB |
| Chat | 2 | 10.2 / 16.6 | 11.8 / 16.5 | 14.7 / 20.1 | 0/5, 0/5, 0/5 | 21.35 MB |
| Chat | 10 | 13.3 / 17.3 | 13.4 / 17.3 | 13.1 / 21.4 | 0/20, 0/20, 0/20 | 5.06 MB |
| Chat | 30 | 15.7 / 25.1 | 13.7 / 24.6 | 17.2 / 24.2 | 0/58, 0/58, 0/52 | 1.6 MB |

## Rows that could not be measured

- cmux-chromium newtab-paint: no paint within 15 s
- cmux-chromium tab-switch: no visibilitychange seen
- cmux-webkit tab-switch: no visibilitychange seen
- ardia session-error: HTTPError: HTTP Error 404: Not Found
- dia launch-link: no paint within 30 s
- dia newtab-paint: no paint within 15 s
- dia tab-switch: no visibilitychange seen
- dia launch-window: no window within 30 s

## Tab switch before and after (cmux20, Debug)

Same host, same matrix, end-to-end p50 / p90 ms. Before: step 914d13021d593bfc1910ebc7 at [e775c2af222](https://github.com/manaflow-ai/cmux/commit/e775c2af222689df9d64549912b3f6f46384e7ce). After: a168's tab-switch rewrite, step 8a623e17ed6f5d146dc9718b at [0bb9f3250e3](https://github.com/manaflow-ai/cmux/commit/0bb9f3250e36a5521114b63beb9476eec1dbfaf4) (Markdown and chat were not in that run). Δ = after p50 − before p50.

| Kind | Tabs | Input | Before | After | Δ p50 |
|---|---|---|---|---|---|
| Browser (Chromium) | 2 | Ctrl-Tab | 14.7 / 18.3 | 15.9 / 18.6 | +1.2 |
| Browser (Chromium) | 2 | Cmd-Shift-] | 15.5 / 17.9 | 14.6 / 15.4 | -0.9 |
| Browser (Chromium) | 2 | Click | 23.7 / 25.0 | 26.9 / 28.9 | +3.2 |
| Browser (Chromium) | 10 | Ctrl-Tab | 17.7 / 21.5 | 15.6 / 18.7 | -2.0 |
| Browser (Chromium) | 10 | Cmd-Shift-] | 19.4 / 21.4 | 17.2 / 21.1 | -2.2 |
| Browser (Chromium) | 10 | Click | 27.9 / 32.4 | 25.5 / 30.6 | -2.4 |
| Browser (Chromium) | 30 | Ctrl-Tab | 22.9 / 33.2 | 27.0 / 36.1 | +4.1 |
| Browser (Chromium) | 30 | Cmd-Shift-] | 26.9 / 39.0 | 27.5 / 37.5 | +0.6 |
| Browser (Chromium) | 30 | Click | 34.0 / 40.4 | 32.9 / 40.7 | -1.2 |
| Browser (WebKit) | 2 | Ctrl-Tab | 15.0 / 19.1 | 11.0 / 13.7 | -3.9 |
| Browser (WebKit) | 2 | Cmd-Shift-] | 15.0 / 20.0 | 13.7 / 17.7 | -1.3 |
| Browser (WebKit) | 2 | Click | 19.0 / 22.8 | 17.2 / 19.4 | -1.9 |
| Browser (WebKit) | 10 | Ctrl-Tab | 17.7 / 20.6 | 14.8 / 21.6 | -2.9 |
| Browser (WebKit) | 10 | Cmd-Shift-] | 14.6 / 18.3 | 14.6 / 21.7 | +0.0 |
| Browser (WebKit) | 10 | Click | 18.6 / 24.4 | 18.4 / 24.9 | -0.1 |
| Browser (WebKit) | 30 | Ctrl-Tab | 20.3 / 26.0 | 19.2 / 26.5 | -1.0 |
| Browser (WebKit) | 30 | Cmd-Shift-] | 19.8 / 24.4 | 17.7 / 25.8 | -2.1 |
| Browser (WebKit) | 30 | Click | 22.6 / 26.8 | 22.1 / 27.5 | -0.5 |

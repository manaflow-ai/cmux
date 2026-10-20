<!-- cmux20 (Apple M6, macOS 27.0), fleet step 914d13021d593bfc1910ebc7 at feat-cmux-next e775c2af2226, 2026-10-20.
     Main table: cmux NEXT nightly, terminals only, 1 round (launch rows skipped); other browsers were not in this run.
     Tab switch: tagged Debug build at the same commit. -->

# xbench, 2026-10-20: cmux NEXT against Chrome, Helium, Ardia, Dia, Safari

Apple M6 (Mac18,5), 12 cores, 16 GB, macOS 27.0 (26A425), host cmux20, cmux ref `e775c2af2226`. Medians over runs (n per cell in results.json, min-max there too). Lower is better.

Versions: cmux NEXT (terminals) 1.0.0-nightly.3939848657701.

| Metric | cmux NEXT (terminals) | best other | cmux vs best other | Ardia (published, M5 Pro) | Helium (published) |
|---|---|---|---|---|---|
| Power, idle, hidden | 0.1 mW | – | – | 3.9 mW | 3.1 mW |
| Power, idle, in view | 1.7 mW | – | – | 3.5 mW | 4.0 mW |
| Power, switching tabs | 14.2 mW | – | – | 136 mW | 173 mW |
| Wakeups, idle, 20 tabs | 9.0/s | – | – | 13.6/s | 28.1/s |
| CPU, idle, 20 tabs | 1.65% | – | – | 0.45% | 1.02% |
| Memory, 1 tab | 443 MB | – | – | 298 MB | 374 MB |
| Memory, 10 tabs | 483 MB | – | – | 714 MB | 773 MB |
| Memory, 20 tabs | 532 MB | – | – | 1,082 MB | 1,121 MB |
| Memory, back to 1 tab after 20 * | 478 MB | – | – | – | – |
| CPU, idle, 1 tab * | 0.08% | – | – | – | – |
| Wakeups, idle, 1 tab * | 7.2/s | – | – | – | – |
| Power, idle, in view, 1 tab * | 0.1 mW | – | – | – | – |
| Power, cmux idle on Home * | 0.1 mW | – | – | – | – |
| CPU, cmux idle on Home * | 0.12% | – | – | – | – |
| Wakeups, cmux idle on Home * | 8.1/s | – | – | – | – |

\* not in Ardia's tweet. "cmux vs best other" uses the best cmux variant of the row. Power is CPU energy (ri_energy_nj) over every process of the browser; GPU and display are not in it. The 10x goal: every cmux cell at a tenth of the best other.

## Tab switch in a real window (cmux NEXT, tagged Debug build)

**Debug only:** these rows come from a tagged Debug build (the timing hooks exist only in Debug), not the Release or nightly build in the table above. Compare them only with other Debug runs.

tab-switch-matrix.py: one pane holding N tabs of a kind, warm; end-to-end = OS input event to the Core Animation commit that shows the tab (p50 / p90 ms); late = switches past their first frame.

| Kind | Tabs | Ctrl-Tab | Cmd-Shift-] | Click | late | per hidden tab |
|---|---|---|---|---|---|---|
| Browser (Chromium) | 2 | 14.7 / 18.3 | 15.5 / 17.9 | 23.7 / 25.0 | 0/5, 0/5, 0/5 | 251.65 MB |
| Browser (Chromium) | 10 | 17.7 / 21.5 | 19.4 / 21.4 | 27.9 / 32.4 | 0/20, 0/20, 0/20 | 77.04 MB |
| Browser (Chromium) | 30 | 22.9 / 33.2 | 26.9 / 39.0 | 34.0 / 40.4 | 0/58, 0/58, 0/51 | 68.0 MB |
| Browser (WebKit) | 2 | 15.0 / 19.1 | 15.0 / 20.0 | 19.0 / 22.8 | 0/5, 0/5, 0/5 | 193.0 MB |
| Browser (WebKit) | 10 | 17.7 / 20.6 | 14.6 / 18.3 | 18.6 / 24.4 | 0/20, 0/20, 0/20 | 40.43 MB |
| Browser (WebKit) | 30 | 20.3 / 26.0 | 19.8 / 24.4 | 22.6 / 26.8 | 0/58, 0/58, 0/52 | 16.05 MB |
| Markdown | 2 | 11.9 / 18.0 | 10.9 / 13.1 | 9.4 / 21.5 | 0/5, 0/6, 0/5 | 194.4 MB |
| Markdown | 10 | 12.4 / 19.3 | 13.4 / 17.8 | 13.6 / 21.5 | 0/20, 0/20, 0/20 | 38.12 MB |
| Markdown | 30 | 14.4 / 18.9 | 13.8 / 19.4 | 15.6 / 21.8 | 0/58, 0/58, 0/52 | 12.68 MB |
| Chat | 2 | 7.8 / 17.1 | 13.5 / 16.8 | 19.1 / 21.1 | 0/5, 0/5, 0/5 | 195.15 MB |
| Chat | 10 | 9.2 / 15.3 | 11.4 / 19.1 | 14.9 / 21.1 | 0/20, 0/20, 0/20 | 38.31 MB |
| Chat | 30 | 14.7 / 25.1 | 14.8 / 24.1 | 18.5 / 24.7 | 0/58, 0/58, 0/52 | 12.78 MB |


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

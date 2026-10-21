# Tab switch: baseline and after (a168, u2873)

Design: [DESIGN.md](DESIGN.md).

## 1. In-process switch path (fleet, same host A/B)

`TabSwitchPathBench`: a real `PaneController` in a window with N warm page tabs.
"apply" is `applySelection` (the focus applier's call, which includes the
synchronous show). "turn" adds the window layout, display and Core Animation
commit. Host aws-m4pro-5, base [a9439ce7ac3](https://github.com/manaflow-ai/cmux/commit/a9439ce7ac3),
after [d5015b6596b](https://github.com/manaflow-ai/cmux/commit/d5015b6596b).

| Tabs | apply p50 before | apply p50 after | apply p90 before | apply p90 after | turn p50 after |
|---|---|---|---|---|---|
| 2 | 0.085 ms | 0.079 ms | 0.10 ms | 0.090 ms | 0.12 ms |
| 10 | 0.11 ms | 0.101 ms | 0.12 ms | 0.119 ms | 0.17 ms |
| 30 | 0.21 ms | 0.146 ms | 0.31 ms | 0.239 ms | 0.26 ms |
| 60 | 0.42 ms | 0.312 ms | 0.47 ms | 0.335 ms | 0.49 ms |

At every count, before and after: 0 view moves, 0 strip snapshots per switch,
exactly 1 shown view.

Where the time goes after the change, mean us per switch at 60 tabs
(`TAB-SWITCH-PATH-STAGES`): showSelected 178 = strip 104 + view 54 + present 15
+ select 9 + withdraw 3 + invariant 2.

Strip steps (`TabStripSelectionBench`, us at 60 tabs, strip overflows at about 60
tabs in 1400 pt): full separator pass 43 -> lines around the old and new tab 2.9
(constant at every count); occlusion 60 -> 0 at rest (it runs only while a move is
in flight). The rest of `sync` (107) is reveal: when the strip overflows, the
scroll spring runs `applyFrames` over every cell. Step 2 of the design's next steps
removes it.

Row passes per switch (`TabSwitchWorkBudgetTests`, 2 switches per tab):

| Tabs | occlusion passes before | separator passes before | after (both) |
|---|---|---|---|
| 2 | 3 | 3 | 0 |
| 10 | 19 | 19 | 0 |
| 30 | 59 | 59 | 0 |

## 2. Real window (Ctrl-Tab, Cmd-Shift-], click; every tab kind; 2/10/30/60 tabs)

Harness: `scripts/measure/tab-switch.sh --matrix` -> `scripts/cmux-next/tab-switch-matrix.py`
on an owned mini (AWS minis cannot open apps). e2e = input event age + intent to
Core Animation commit; `content_frame_ms` = the page's own first frame after it
becomes visible (Chromium and WebKit); idle CPU and footprint per hidden tab.

Status: queued on cmux8s for base 7e8bbaaa3c7 and after d5015b6596b. The numbers go
here when the steps finish.

## 3. What the in-process numbers say

The in-process path was already 0.1-0.5 ms (a118's ffe13a1eae3 removed the parked
view cap that cost 170-215 ms per WebKit re-attach). A 100x cut from 0.4 ms is not
the user's lag. The user's nightly already has ffe13a1eae3 and still feels lag, so
the lag is in what this bench does not see: the out-of-process content frame
(Chromium GPU process, WebKit web content process, terminal renderer resume) and
the real-window input path. Section 2 measures these.

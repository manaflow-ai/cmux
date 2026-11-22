# cmux NEXT browser vs Edge: idle cost at 1, 10 and 50 tabs

Each browser gets the same pages, then sits idle while the run samples memory (summed physical
footprint of every process), CPU and wakeups. The harness is `scripts/perf-bench/xbench.py`, the
`tabs` suite.

## Baseline (before any fix)

Run on an M5 Mac with 24 GB, against the NIGHTLY of 2026-11-21.

| Tabs | Edge memory | Edge CPU | cmux memory | cmux CPU |
|---:|---:|---:|---:|---:|
| 1 | 270 MB | 1.57% | 1,805 MB | 8.12% |
| 10 | 603 MB | 2.09% | 1,909 MB | 4.93% |
| 50 | 1,558 MB | 3.20% | 4,780 MB | 5.54% |

## One window per pane instead of one per tab (#49684)

Every web tab had its own Chromium window, so each one had its own compositor and GPU surfaces.
Now a pane's tabs share one window. Before is base 18d1584cb; after adds 5ded21f44d67. Both legs
ran on the same M5 Mac with 24 GB, `tabs` suite, cmux-chromium, two rounds each. CPU was noisy
because the machine load went from 29 to 13.6 during the run; memory was consistent between rounds.

| Tabs | Memory before → after | CPU % | Wakeups/s | GPU process CPU % |
|---:|---:|---:|---:|---:|
| 1 | 1,486 → 1,486 MB | 29.7 → 28.0 | 72.9 → 75.3 | 0.67 → 0.68 |
| 10 | 2,330 → 2,037 MB | 25.6 → 15.1 | 82.6 → 74.4 | 0.80 → 0.74 |
| 50 | 4,887 → 2,823 MB | 17.8 → 10.2 | 98.2 → 76.1 | 1.08 → 0.72 |

- At 50 tabs the GPU process drops from 1,612 MB to 167 MB (rounds 1,654 and 1,570, then 171 and
  164), and it no longer grows with the tab count.
- Renderers use 372 MB less and the main process 168 MB less.
- Only the after leg shows MTLCompilerService, at 18 to 27 MB.

## What is still above Edge

cmux is still above Edge at every tab count: 2,823 MB against 1,558 MB at 50 tabs. The roots that
remain:

1. Hidden web tabs are never trimmed.
2. Fixed costs at 1 tab: the spare windows, the New Tab spare chat page that is forced visible,
   uBlock, and WebKit.
3. Idle CPU spent decoding agent daemon traffic.

# Terminal-spam lag on macOS 15 Sequoia (and 14, 26)

Report (msg 4628, 2026-10-20): "cmux next gets extremely laggy on sequoia, like
spamming a lot of new terminals". Follow-up: measure every supported macOS
(the floor is macOS 14, `Package.swift`; 13 cannot launch), before and after
the fix, and guard it on each version.

## Method

- One DEV build per commit from the fleet (`cmux-ci build cmux`), run in
  disposable Tart VMs on aws-m4pro-6 (the fleet's Tart host) from the pinned
  images in `scripts/fuzz/macos-matrix/images.json`: 14.8.7, 15.7.7, 26.6.2,
  4 vCPU each, one VM at a time under the host lock.
- The former Tart stress probe:
  - 10 rounds of Cmd-N, Cmd-T, Cmd-T, Cmd-D, Cmd-Shift-D through the real key
    path (`debug.new_tab bench_create`): key, first-visible and
    daemon-confirmed times; one `debug.new_terminal_trace` per round (time to
    a new shell's first prompt). 55 tabs at the end.
  - A burst: 20 Cmd-T keys back to back, no wait (the "spamming"); 75 tabs.
  - 15 s idle with everything open.
  - Every 0.5 s: %CPU and RSS of the app, its child processes, WindowServer,
    WebKit's web content processes (launchd's children, not the app's) and
    every process together. Every main-thread stall from the 50 ms watchdog
    (`debug.hangs`), with the full stack of each stall of 150 ms or more.
- Two window configurations: the default (opaque), and glass
  (`background-opacity = 0.8`, `background-blur = macos-glass-regular`):
  before macOS 26 the glass styles fall back to a WindowServer frost
  (`WindowBackdrop.glassFallbackBlurRadius`), the only OS-gated rendering path
  that touches terminals.
- Its report helper printed the tables below.

## Before (feat-cmux-next ea0892a84de)

| run | macOS | Cmd-T tab visible p50/p90 ms | split p50/p90 ms | workspace p50/p90 ms | first prompt p50 ms | 20x Cmd-T burst: all tabs s | burst stalls n / total ms / max ms | WebContent processes (55 / 75 tabs) | WebContent RSS MB (55 tabs) | all-process CPU % (rounds, of 400) | WindowServer % (rounds) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| default | 14 (14.8.7) | 18.8 / 42.1 | 18.0 / 47.8 | 81.1 / 181.8 | 523 | 1.08 | 20 / 2841 / 594 | 54 / 75 | 4728 | 280.1 | 9.7 |
| default | 15 (15.7.7) | 18.0 / 26.8 | 21.4 / 58.5 | 83.6 / 163.1 | 461 | 0.89 | 16 / 2728 / 563 | 54 / 73 | 3756 | 289.4 | 8.5 |
| default | 26 (26.6.2) | 24.8 / 60.5 | 47.9 / 77.1 | 64.6 / 128.9 | 552 | 1.04 | 22 / 2758 / 333 | 53 / 73 | 4357 | 251.9 | 9.4 |
| glass | 14 (14.8.7) | 21.4 / 32.4 | 39.0 / 74.4 | 97.0 / 149.4 | 571 | 1.06 | 16 / 2742 / 804 | 54 / 75 | 4726 | 289.7 | 10.3 |
| glass | 15 (15.7.7) | 20.0 / 35.0 | 30.4 / 41.1 | 94.2 / 166.9 | 588 | 0.85 | 19 / 2717 / 515 | 54 / 75 | 3703 | 290.2 | 9.7 |
| glass | 26 (26.6.2) | 30.6 / 55.1 | 33.2 / 606.1 | 101.0 / 214.3 | 616 | 1.15 | 17 / 3492 / 897 | 55 / 75 | 4446 | 245.5 | 10.6 |

The glass rows match the default ones; WindowServer costs 10-11 % on 14 and 15
(frost fallback) as on 26 (Liquid Glass).

What the numbers say:

1. **No macOS 15-only cost in the VMs.** A tab or split shows in 20-50 ms and
   a workspace in 65-100 ms on 14, 15 and 26 alike; a new shell's first prompt
   takes 460-600 ms on all three. The glass fallback costs WindowServer the
   same as Liquid Glass.
2. **Every new tab starts a WebKit web content process.** 55 tabs ran 53-54
   WebContent processes with 3.8-4.7 GB RSS; after the 20x Cmd-T burst, 73-75.
   Together they kept the 4-core VM at 250-290 % CPU through the rounds, on
   every version.
3. **The burst holds the main thread 2.7-2.8 s** (16-22 stalls, the longest
   330-600 ms) on every version. The stall stacks are WebKit IPC on the main
   thread (sending each new page its scripts, `URLSchemeTaskDidReceiveData`,
   `kevent` pokes to busy processes) plus app work that waits for a CPU (sidebar
   row patch, layout, daemon model writes): a saturated machine.

## Root cause

Cmd-T, Cmd-D, Cmd-Shift-D and Cmd-N each open the New Tab page, an agent pane
(`AgentPaneView`) with its own `WKWebView`. All agent pages share one
`WKProcessPool` (`AgentPaneView.processPool`), but a shared pool does not share
processes: WebKit starts a web content process per web view. So each new tab
paid a process launch, about 70 MB, and a full parse and compile of the 4 MB
pane bundle (`pane.js`, `highlight-worker.js`, `index.html`, first chunks),
and kept the process. Spamming new terminals is spamming new processes.

Why users see it as "Sequoia": the cost is RAM and CPU, so it hits smaller
and older Macs first, and those are the ones still on macOS 15. 75 tabs need
about 5 GB in web content processes alone; on an 8 GB Mac that is memory
pressure and swap, and the whole system lags. The VMs show the same process
count on 14, 15 and 26. Not covered: a real Sequoia Mac's GPU (the VMs use
paravirtualized graphics and no fleet Mac runs macOS 15 on bare metal), so a
GPU-only Sequoia regression would not show in this harness.

Ruled out on the way (measured, no OS difference): the ObservationStream
fallback (every OS takes the same `withObservationTracking` path), the glass
frost fallback, per-terminal display links (the app has one per window,
none per terminal), and serving the scheme handler's files in 256 KB slices
(tried on the scratch branch scratch/sequoia-lag-root-cause: no change in the
burst, because the cost is the processes, not the copy).

## Fix

`WebProcessGroups` (CmuxNextAgentPane) makes every agent page's web view with
the current group's first page as its related web view (`_relatedWebView`, the
WebKit SPI Safari uses for `window.open`), so up to 8 pages share one web
content process. A closed first page, a full group, or another process pool
or data store starts the next group. 8 bounds what one web content crash takes
down (each page reloads itself, `AgentPaneNavigation`) and how many pages share
one process's main thread.

Tests (`WebProcessGroupsTests`, red commit first): pages 2-3 of a group of 3
relate to page 1 and page 4 starts the next group; another data store or pool
starts its own group; a closed first page starts a new group; two grouped
pages that loaded report the same `_webProcessIdentifier`.

## After

Same probe, same host, build 3771da82519 (fleet job 5e4275170565f60136cce331):

| run | macOS | Cmd-T tab visible p50/p90 ms | split p50/p90 ms | workspace p50/p90 ms | first prompt p50 ms | 20x Cmd-T burst: all tabs s | burst stalls n / total ms / max ms | WebContent processes (55 / 75 tabs) | WebContent RSS MB (55 tabs) | all-process CPU % (rounds, of 400) | WindowServer % (rounds) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| default | 14 (14.8.7) | 15.8 / 23.7 | 21.5 / 47.8 | 81.9 / 189.0 | 368 | 0.62 | 17 / 1405 / 111 | 10 / 12 | 2800 | 291.7 | 9.9 |
| default | 15 (15.7.7) | 17.9 / 28.1 | 29.0 / 52.2 | 71.2 / 170.5 | 412 | 0.78 | 14 / 1420 / 238 | 10 / 12 | 2703 | 296.9 | 9.3 |
| default | 26 (26.6.2) | 19.7 / 82.7 | 25.1 / 49.6 | 59.8 / 145.3 | 468 | 0.73 | 15 / 1453 / 234 | 10 / 12 | 2828 | 283.5 | 12.9 |
| glass | 14 (14.8.7) | 18.7 / 35.6 | 22.7 / 32.7 | 85.9 / 138.5 | 496 | 0.7 | 13 / 1175 / 145 | 10 / 12 | 2701 | 297.2 | 10.8 |
| glass | 15 (15.7.7) | 22.9 / 38.3 | 23.2 / 34.1 | 106.9 / 153.0 | 434 | 0.75 | 10 / 1075 / 176 | 10 / 12 | 2570 | 292.3 | 10.2 |
| glass | 26 (26.6.2) | 24.9 / 91.5 | 40.9 / 64.2 | 77.2 / 145.4 | 485 | 0.7 | 18 / 1578 / 286 | 10 / 12 | 2666 | 236.0 | 10.2 |

Before to after, on every version and both window configurations:

- WebContent processes: 53-55 to 10 at 55 tabs, 73-75 to 12 at 75 tabs.
- Their RSS at 55 tabs: 3.7-4.7 GB to 2.6-2.8 GB.
- The 20x Cmd-T burst: summed main-thread stalls 2.7-3.5 s to 1.1-1.6 s, the
  longest 333-897 ms to 111-286 ms; all 20 tabs exist after 0.62-0.78 s
  instead of 0.85-1.15 s.
- A new shell's first prompt (p50): 461-616 ms to 368-496 ms.
- Unchanged: tab, split and workspace first-visible times (already 20-100 ms),
  and the all-process CPU during the rounds (the stress creates tabs as fast as
  the app takes them, so the 4 vCPUs stay busy either way).

## Guard

- The former launch-and-stress gate ran after the launch probe in each Tart VM.
  It is retained here as historical evidence only; it is no longer an active
  cmux-next check.
- The nightly `macos-matrix-fuzz.yml` workflow that failed on `STRESS-FAIL` was
  retired with Tart (2026-10-21). The standalone fuzzer remains available at
  `scripts/fuzz/macos-matrix/vm.sh`.

## Left for the owners

- The New Tab spare pool keeps one prewarmed page and builds the next one
  after 750 ms of quiet input, so a burst still builds cold pages (now in
  shared processes). A New Tab page that is never used could also release its
  web view (new-tab.md owners).
- Sidebar row patch on each workspace insert (`SidebarListView.patchRows`):
  a207 / a98.
- The Recently Closed push renders the same JSON (favicon data URLs included)
  once per open New Tab page (`NewTabClosed.wire` sets `recentlyClosed` on
  every view): O(pages) per close.
- `PageWebView` pages (Settings, History, Cloud) still get one process each;
  they are few, so not grouped here.

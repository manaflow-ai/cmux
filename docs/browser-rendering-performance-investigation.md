# Embedded Browser Rendering Performance Investigation

## Summary

The embedded browser had four independent lifecycle costs on its main-thread resize path:

1. A portal geometry notification could schedule the same external synchronization twice.
2. Each synchronization synchronously forced AppKit layout and display through the WebKit container and window hierarchy.
3. A presentation refresh ran immediately, on the next main-queue turn, and again after 30 ms.
4. Closing a browser pane stopped WebKit navigation but left discard-manager timers and observers tied to the panel lifecycle.

The change removes the duplicate geometry request, replaces synchronous display flushing with coalesced invalidation, performs one synchronous presentation repair inside the owning portal synchronization for bind, reveal, and forced-refresh transitions, skips the deferred all-entry pass when the primary browser is the only portal entry, and synchronously tears down browser-pane lifecycle resources on close.

The measured result is less portal work and stable responsiveness across repeated resize probes. Whole-window AppKit and SwiftUI layout still dominate sustained live resize, so this report does **not** claim that every long animation frame or all historical memory growth is eliminated.

## Scope and environment

- Source baseline: upstream `main` before this change.
- Test machine: Apple Silicon laptop running macOS 15.7.5.
- Browser workload: one local, deterministic HTML page with 160 colored bands, continuous vertical scrolling, a changing fixed marker, and `requestAnimationFrame` timing.
- Resize workloads:
  - 180 deterministic window-frame changes through the debug automation API.
  - 10-second continuous Accessibility-driven window resizing while the page scrolled.
  - A second 220-sample Accessibility run alternating the window by 150 × 90 points.
- Memory workload: load 12 additional browser surfaces, close them, and sample the attributed process tree for 24 seconds.
- Profiling: a five-second `sample` capture during continuous resize.

All pages were local fixtures. The report contains no account, browsing-history, host, or user-identifying data.

## Root-cause findings

### 1. Duplicate geometry synchronization

The external geometry callback invalidated the browser portal directly and then queued another invalidation for the same event-loop turn. In a baseline trace, 203 external-geometry callbacks accompanied 180 requested frame changes.

The corrected path has one coalescing boundary. A single primary browser synchronizes immediately from its anchor and no longer schedules a redundant all-entry pass. Multiple-browser reconciliation remains deferred; lifecycle transitions request presentation recovery through the owning synchronization rather than a second caller-side refresh.

### 2. Synchronous rendering flushes

The portal called `layoutSubtreeIfNeeded()` and `displayIfNeeded()` across the WebKit view, its container, ancestors, and window after geometry changes. Both APIs are synchronous. Repeating them inside a resize callback makes the pointer or automation request wait for work AppKit could otherwise coalesce.

The corrected geometry path updates frames inside a disabled-animation Core Animation transaction and marks affected views dirty. AppKit performs layout and display on its normal event-loop cadence.

### 3. Repeated presentation recovery

The old recovery helper performed three refreshes: immediate, next-turn, and delayed. This was appropriate as a defensive workaround for stale WebKit hosted layers, but it was also used during ordinary frame churn.

The corrected helper performs one synchronous presentation repair from the portal synchronization that owns the transition. Reveal, same- and new-anchor rebind, reattach, hosted-inspector adjustment, and explicit force-refresh paths still request the WebKit rendering-state repair exactly once; pure geometry changes only invalidate layout and display.

### 4. Browser-pane close lifecycle

Pane close previously depended on later deinitialization for some cleanup. The discard manager now has a synchronous main-actor shutdown that cancels its timer, clears its delegate, and removes policy and sleep/wake observers. Browser close is idempotent, detaches the old presentation hierarchy from either portal or local inline hosting, clears callbacks and delegates, cancels viewport restoration, and replaces the loaded view with one unloaded view so the panel's non-optional view contract does not retain the old WebContent ownership tree.

## Regression coverage

The focused regression suite covers:

1. One external geometry callback producing one coalesced portal invalidation.
2. Geometry-only synchronization invalidating direct and active-viewport-hosted browsers without synchronous AppKit display flushes.
3. Initial bind, reveal, and explicit force refresh producing one synchronous call to each required WebKit rendering-state selector with no next-turn duplicate.
4. Same- and new-anchor rebinds refreshing a replaced host exactly once.
5. Hosted-inspector divider adjustment honoring one explicit forced refresh without a caller-side duplicate.
6. First-sized reveal retaining its one-shot size nudge while presentation recovery remains synchronous.
7. Single-browser portal synchronization avoiding a redundant deferred all-entry pass.
8. Bounded transient-anchor recovery hiding a genuinely detached stale slot after exhaustion while preserving an off-window drag reparent until rebind.
9. Discard-manager shutdown clearing its timer and delegate synchronously.
10. Closing a committed local page while the panel remains retained, including detachment from the local inline host and replacement with an unloaded view.

## CI and build evidence

The first complete code-and-test checkpoint, `772dacfd9e`, was validated on GitHub-hosted macOS:

- [macOS Compatibility run 30210823264](https://github.com/usr-bin-roygbiv/cmux/actions/runs/30210823264) checked out that exact commit and compiled the application and test targets. On macOS 15, the active-viewport, external-split, workspace-rebind, portal-anchor, and single-entry lifecycle regressions all passed. The two arm64 jobs continued into the repository-wide suite until the 60-minute job limit, and the Intel macOS 14 job could not start because that runner class was unavailable under the account spending limit. The run therefore is not presented as a full-suite green result; unrelated suites also reported failures before timeout.
- [Tagged application build 30213748000](https://github.com/usr-bin-roygbiv/cmux/actions/runs/30213748000) successfully built the exact final code and test commit as `cmux DEV browser-perf-final-772dacf` on macOS 15.
- [Standard CI run 30210826433](https://github.com/usr-bin-roygbiv/cmux/actions/runs/30210826433) remained pending without creating a job and was canceled after the compatibility and tagged-build paths supplied the available macOS evidence.

## Measurements

### Deterministic frame-change probe

| Metric | Baseline run 1 | Baseline run 2 | Candidate run 1 |
|---|---:|---:|---:|
| Idle rAF median / p95 | 17 / 19 ms | 17 / 19 ms | 17 / 19 ms |
| Resize rAF median / p95 | 15 / 55 ms | 16 / 55 ms | 15 / 55 ms |
| Resize intervals > 33 ms | 181 | 182 | 181 |
| Resize RPC median / p95 | 57.868 / 78.623 ms | 58.602 / 80.562 ms | 57.809 / 81.884 ms |
| App CPU during resize | 1.77% | 1.78% | 1.76% |

This probe deliberately waits for each synchronous `setFrame(display: true)` request. Its approximately 58 ms median is primarily window-server and whole-window layout pacing; it did not distinguish the portal optimization by itself.

### Continuous live resize

Two independently implemented Accessibility resize loops produced directionally different RPC timing but the same central result: portal work fell, rendered-frame behavior improved modestly, and long frames remained because the full window still lays out on every accepted size.

| Metric | Baseline | Candidate |
|---|---:|---:|
| Applied samples in 10 s | 216 | 220 |
| rAF samples | 452 | 501 |
| rAF median / p95 | 18 / 48 ms | 17 / 46 ms |
| rAF intervals > 33 ms | 218 | 216 |
| Browser RPC median / p95 | 425.872 / 539.717 ms | 247.809 / 527.019 ms |
| App CPU | 2.41% | 2.38% |

A repeated 220-sample run used a slower, synchronous Accessibility command loop. It produced 1,394 baseline and 1,409 candidate rAF samples, a p95 of 58 vs. 57 ms, and 153 vs. 127 intervals over 50 ms. Median browser RPC was 22.482 vs. 23.082 ms. This run showed fewer severe frame stalls, while the slower median RPC demonstrates run-to-run variability and rules out presenting the result as a universal speedup.

### Portal trace counts

| Trace event | Baseline | Candidate before single-entry follow-up | Change |
|---|---:|---:|---:|
| Geometry invalidations | 383 | 180 | -53% |
| Full presentation refreshes | 47 | 2 | -96% |
| External-geometry callbacks | 203 | 4 | -98% |
| Deferred all-entry schedule/tick pairs | 193 | 174 | Single-entry follow-up removes the remaining redundant anchor-driven requests |

The candidate still logged 1,239 synchronization results because the benchmark also exercises normal per-anchor synchronization. The important reduction is in duplicate invalidation and forced presentation recovery, not an artificial suppression of required geometry updates.

### Main-thread sample

During a five-second continuous candidate resize:

- 2,034 of 2,766 main-thread samples were below `CmuxMainWindow.setFrame`.
- 1,499 samples included AppKit layout.
- 852 samples included SwiftUI `NSHostingView.layout`.
- Immediate browser-portal synchronization appeared in 31 samples.
- Deferred browser-portal synchronization appeared in one sample.

These stacks overlap, so the counts are not additive percentages. They establish that remaining live-resize pacing is mostly whole-window layout rather than the removed synchronous WebKit display flush.

### Browser process reclamation

| Metric | Baseline range (2 runs) | Candidate run 1 | Final reviewed-head run |
|---|---:|---:|---:|
| WebKit processes after loading surfaces | 15 | 15 | 15 |
| WebKit processes after close and settle | 4 | 3 | 3 |
| WebKit footprint loaded | 262.1–266.3 MB | 253.0 MB | 253.2 MB |
| WebKit footprint settled | 87.4–92.3 MB | 83.2 MB | 83.3 MB |
| Attributed tree footprint reclaimed | 191.1–196.0 MB | 151.2 MB | 182.9 MB |

Gross reclaimed bytes depend on the loaded starting footprint, so the bounded signal is process and settled-footprint behavior rather than the delta alone. The 12 closed surfaces did not leave 12 WebContent processes alive: both candidate runs and the final reviewed-head run returned to three processes; the latest run settled at 83.3 MB of WebKit footprint.

An earlier tagged-app probe repeated three cycles of opening and closing eight additional browser surfaces. Every cycle loaded 11 WebKit processes and settled at three. The cycles reclaimed 117.3, 112.3, and 117.2 MB of WebKit footprint; their settled footprints were 41.4, 46.9, and 46.3 MB. All lifecycle assertions passed. The final reviewed-head probe then repeated the larger 12-surface cycle above. These short synthetic tests do not replace a day-long soak for the broad reports in #4188 and #5305.

### Final tagged-app resize validation

The repository's release workflow produced an app from reviewed code-and-test commit `e779b88e3c`, which was then exercised as an installed app rather than an in-tree executable. Activation, browser loading, scrolling, screenshots, resizing, close, and process reclamation all passed.

| Metric | Deterministic probe | 220-sample live-resize probe |
|---|---:|---:|
| rAF median / p95 | 16 / 56 ms | 17 / 54 ms |
| rAF intervals > 33 ms | 182 of 627 | 222 of 1,525 |
| Browser RPC median / p95 | 59.030 / 84.691 ms | 23.180 / 60.900 ms |
| Browser RPC errors | 0 | 0 |
| App CPU during resize | 1.73% | 1.05% |

The deterministic probe also measured idle rAF at 17 / 18 ms median / p95 and 0.19% app CPU. The live-resize probe applied all 220 requested 150 × 90-point changes and produced a valid 15.5 KB browser-owned PNG.

## Visual validation and capture limitation

The browser automation screenshot API produced valid PNGs during the resize probes (11–16 KB in the scrolling fixture). Screen-level compositor capture on this macOS configuration omitted the hosted WebKit surface and returned black/protected pixels for the browser region. Therefore:

- Browser content, scrolling, and changed rendering were verified through the browser-owned screenshot API and DOM/rAF instrumentation.
- Direct pixel comparison of a torn intermediate compositor frame was not possible.
- The evidence supports removing synchronous and repeated refresh work that can destabilize frame pacing; it does not prove that no compositor tear can ever occur.

## Related issue audit

| Item | Current state | Relevance |
|---|---|---|
| [#1114](https://github.com/manaflow-ai/cmux/issues/1114) | Open | Direct report of inconsistent browser drag/resize lag. |
| [#1118](https://github.com/manaflow-ai/cmux/pull/1118) | Open, merge-conflicted | Earlier 270-line throttling approach. The current change uses a smaller coalescing boundary and avoids mouse-event heuristics. |
| [#4188](https://github.com/manaflow-ai/cmux/issues/4188) | Open | Broad retained-WebKit and helper-process memory report. This change covers browser-pane teardown only. |
| [#5305](https://github.com/manaflow-ai/cmux/issues/5305) | Open | Broad long-session CPU/memory audit; remains larger than this change. |
| [#5303](https://github.com/manaflow-ai/cmux/issues/5303) | Closed | Prior browser render loop. Idle CPU remained 0.17–0.19% in this investigation, so that loop did not reproduce. |
| [#3085](https://github.com/manaflow-ai/cmux/issues/3085) | Open | Ghost WebKit layer across workspaces. The retained portal recovery behavior remains covered; this change does not claim to close it. |
| [#4287](https://github.com/manaflow-ai/cmux/issues/4287) | Closed, not planned | Blank flash on WebKit reattach. Reveal still receives one explicit rendering-state recovery pass. |
| [#4539](https://github.com/manaflow-ai/cmux/issues/4539) | Closed | Hidden-browser retention policy. The close cleanup complements, rather than replaces, hidden-surface discard. |
| [#7895](https://github.com/manaflow-ai/cmux/issues/7895) | Closed | Initial scrollability after first-sized reveal. The one-shot size nudge remains, without synchronous display flushing. |

## API rationale

- [`NSView.displayIfNeeded()`](https://developer.apple.com/documentation/appkit/nsview/displayifneeded()) synchronously displays invalid regions.
- [`NSView.setNeedsDisplay(_:)`](https://developer.apple.com/documentation/appkit/nsview/setneedsdisplay(_:)) invalidates content for AppKit to display on its normal pass.
- [`NSView.layoutSubtreeIfNeeded()`](https://developer.apple.com/documentation/appkit/nsview/layoutsubtreeifneeded()) performs pending layout synchronously.

The implementation uses invalidation for ordinary geometry and reserves explicit WebKit rendering-state recovery for lifecycle transitions.

## Remaining risk

- Whole-window SwiftUI/AppKit layout still produces long rAF intervals during aggressive resize.
- Screen capture cannot directly score intermediate hosted-layer tearing on the test system.
- The memory probe is bounded and synthetic, not a multi-hour workload with arbitrary websites, media, extensions, or developer tools.
- Multi-browser portal reconciliation remains intentionally deferred and needs continued regression coverage because it cannot use the single-entry fast path.

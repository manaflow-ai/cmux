# p07-memory: Memory like Chrome's Memory Saver, performance_manager and memory coordinator

Fault F8 in `plans/cmux-next/perf-lead.md`. Checkout read: `/Users/lawrence/fun/wt/chrome-parity` at
`772cdfc45ac` (perf/chrome-parity = origin/feat-cmux-next). This spec is the design after three
adversarial reviews. Every review claim used here was checked in the checkout with rg; counts below
are from that checkout.

Goal: cmux discards hidden pages, hidden workspaces and hidden terminal render state by Chrome's
rules. It sets memory budgets per subsystem from physical memory, handles memory pressure through
one coordinator per process with Chrome's consumer traits, limits renderer processes from physical
memory, and measures memory per process, subsystem, tab and workspace. It goes past Chrome where
cmux has more kinds of content (terminals, daemons, agents, native pages).

---

## 1. Chrome reference

Each item cites the Chromium source that the design copies.

1. **Renderer process limit.** `content/browser/renderer_host/render_process_host_impl.cc`
   `GetMaxRendererProcessCount()`: `kEstimatedWebContentsMemoryUsage` = 85 MB (64-bit);
   max = physical MiB / 2 / 85, clamped to [3, platform max]; the upper clamp is 82 on macOS.
   4 GB gives 24; 16 GB gives 96, then 82. `SetMaxRendererProcessCount()` lowers it at runtime and
   calls `CleanupSpares`. Above the limit Chrome reuses a same-site renderer and never mixes sites.
   Under site isolation the limit is soft: a process locked to a site never takes another site, so
   with more sites than the limit Chrome has more processes than the limit. Below the limit,
   `kProcessPerSiteUpToMainFrameThreshold` shares one renderer between at most 2 main frames of a site.
   `HasEnoughMemoryForAnotherMainFrame` lets a main frame join only while the process PMF plus the
   estimate is under `kProcessPerSiteMainFrameTotalMemoryLimit`; a subframe joins only while the
   process is under 512 MB. `ChromeContentBrowserClient::ShouldUseProcessPerSite` gives NTP/WebUI
   one process per site.
2. **Discard eligibility.** `chrome/browser/performance_manager/policies/` (74 files).
   `cannot_discard_reason.h` has 30 reasons (kNotATab, kAlreadyDiscarded, kDiscardAttempted,
   kNoMainFrame, kVisible, kAudible, kRecentlyAudible, kRecentlyVisible, kPictureInPicture, kPdf,
   kNotWebOrInternal, kInvalidURL, kOptedOut, kNotificationsEnabled, kExtensionProtected,
   kCapturingVideo/Audio/Window/Display, kBeingMirrored, kConnectedToBluetooth/USB, kActiveTab,
   kPinnedTab, kDevToolsOpen, kBackgroundActivity, kFormInteractions, kUserEdits, kGlicShared,
   kWebApp). `discard_eligibility_policy.h`: CanDiscardResult {kEligible, kProtected, kDisallowed};
   kTabAudioProtectionTime 1 min; kNonVisiblePagesUrgentProtectionTime 10 min on desktop.
   kNotificationsEnabled, kBackgroundActivity and kGlicShared protect only from PROACTIVE and
   SUGGESTED discards. EXTERNAL and FROZEN_WITH_GROWING_MEMORY are always allowed. The worst result
   wins. `page_discarding_helper.cc`: a page whose discard was attempted gets a DiscardAttemptMarker
   and is kDisallowed after that. `DiscardAPage` passes `discard_protected_tabs=false`: a protected
   page is never discarded by urgent or proactive discards.
3. **Memory Saver timing.** `memory_saver_mode_policy.cc`: one timer per hidden tab; conservative
   6 h, medium 4 h, aggressive 2 h (revisit rules); LiveTicks (suspend-aware); reason PROACTIVE.
4. **Urgent discards.** `urgent_page_discarding_policy.cc`: a memory consumer that acts only when
   `memory_limit() <= CriticalPressureThreshold`; one page per event on macOS; with
   kSustainedPMUrgentDiscarding one more every 5 s while pressure lasts. Traits: kLarge, kLossy,
   kAsynchronous, IsStateful::kNo. At moderate pressure Chrome only stops background tab loading.
   `kSkipModerateMemoryPressureLevelMac` exists because macOS WARN is noisy.
5. **Memory coordinator.** `base/memory_coordinator/` (memory_consumer.h, traits.h,
   memory_limit.h, registry, `async_memory_consumer_registration.h`). `OnUpdateMemoryLimit()` must
   not free; `OnReleaseMemory()` frees above `memory_limit()`. The limit is a percentage; the
   consumer defines 100 %. RAII registration. Traits: EstimatedMemoryUsage, ReleaseMemoryDataAccess
   (none / reads / readsAndWritesToDisk), InformationRetention, ExecutionType, SupportsMemoryLimit,
   InProcess, RecreateMemoryCost, ReleaseGCReferences, GarbageCollectsV8Heap, IsStateful,
   RecoveryBehavior, ReleaseMemoryCpuCost. `memory_saver_memory_coordinator_policy.h` scales managed
   consumers (stateful and supporting a limit, `ShouldManageConsumer`) by mode: conservative 75 %,
   medium 50 %, aggressive 25 %, off = default 100 %. `content/browser/memory_coordinator/README.md`:
   the browser owns policy for child-process consumers through `ChildMemoryConsumerRegistryHost`;
   the most restrictive limit wins.
6. **macOS pressure source.** `components/memory_pressure/system_memory_pressure_evaluator_mac.cc`:
   one `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source (WARN|CRITICAL|NORMAL). On each event it ignores
   the event data and re-reads `kern.memorystatus_vm_pressure_level`; it sets the initial vote in the
   constructor; it votes only on change; no timer. `content/browser/browser_main_loop.cc`
   `CreateMemoryPressureMonitor()` makes a `MultiSourceMemoryPressureMonitor` and calls
   `MaybeStartPlatformVoter()` on IS_APPLE; voters are aggregated (max).
7. **Hidden render state.** `components/viz/client/frame_eviction_manager.cc`: saved frames of
   hidden views at most min(5, 2 + physical MiB / 256); `kScalableFrameEviction`; OnReleaseMemory culls
   unlocked frames; periodic culling of old frames. cc releases tiles of hidden layer trees.
   `WebContentsOcclusionCheckerMac` (content/app_shim_remote_cocoa) adds Chrome's own occlusion checks
   on top of `NSWindow.occlusionState`.
8. **Freezing.** `components/performance_manager/freezing/freezing_policy.cc`: never freezes a page
   with kNotificationPermission, kHoldingWebLock, kHoldingBlockingIndexedDBLock, kLoading or kWebUI;
   freezes or thaws the whole browsing instance (opener and popups) together; discards a browsing
   instance whose frozen PMF grows by more than `kFreezingMemoryGrowthThresholdToDiscardKb`, measured
   every `kCPUMeasurementInterval` through resource attribution.
9. **Background loading.** `BackgroundTabLoadingPolicy`: at most clamp(cores / 2, 1, 4) loads at once
   (`kCoresPerSimultaneousTabLoad` 2), stops at moderate pressure, needs free memory.
10. **Crashed subframes.** `discard_page_with_crashed_subframe_policy.cc` discards a hidden page whose
    subframe crashed.
11. **Architecture.** `components/performance_manager/README.md`: one graph of Page/Frame/Process/
    Worker nodes; decorators measure; aggregators sum; policies decide; mechanisms act;
    chrome://discards shows each tab's state.
12. **Measurement.** `docs/memory/key_concepts.md` (vmmap is the Darwin reference);
    `base/trace_event/memory_dump_provider.h` (each subsystem reports its own bytes);
    `process_memory_metrics_emitter.cc` (PMF UMA histograms); the Task Manager; the Memory Saver chip.
13. **Spares and discardable memory.** `SpareRenderProcessHostManager` makes no new spare under pressure
    and keeps an existing one (`kKillSpareRenderOnMemoryPressure` is off by default; p13-webui.md section 1).
    Decoded image caches live in discardable memory, so the kernel takes pages back with no browser
    wakeup. `sql::Database::TrimMemory()` calls `sqlite3_db_release_memory` per connection.
    Low-memory devices turn the back-forward cache off (`BackForwardCacheMemoryControls`).
    Blink's MemoryPurgeManager purges V8, PartitionAlloc and Skia some minutes after a renderer is
    backgrounded or frozen. On macOS Chrome relies on the kernel compressor for idle pages and does
    not compress its own state in user space.

---

## 2. cmux today

Paths are under `Packages/macOS/CmuxNext/Sources` unless named.

### Measured numbers

- perf-lead.md rows 15/17/F8 and speed-of-sound-DESIGN.md (cmux20, Release): Home idle 793 MB whole
  tree (floor 70); app 361 MB with hidden tabs; heavy session (150 ws, 20 terminals, 20 hidden
  Chromium tabs) 3,538 MB, 392 processes, 3,300 threads (daemon 797, app 91).
- Per hidden Chromium tab 55 MB, WebKit tab 29 MB, agent chat page about 75 MB. Per workspace 8.2 MB.
- First Chromium tab 196 MB. Home starts 3 Chromium renderers (185 MB) before any browser tab.
  #20856: 60 CEF tabs 11.8 GB, Chrome 7.4 GB.
- resource-efficiency-DESIGN.md: per agent about 24 MB in acpmux plus 40 MB of sidecars
  (`__agent-host` 9.2, `mcp serve` 21.6, `subsession-mcp` 4.7, `secret-mcp` 4.6).

### Memory pressure

- 3 Swift kernel sources: `CmuxNextCompat/KernelMemoryPressureSource.swift:31` (shared),
  `CmuxNextTabs/TabHoverCard.swift:78`, `CmuxNextHostPressure/HostPressureMonitor.swift:130`.
  1 Rust source: `cmux-tui-core/src/mux/terminal_work/standby_host.rs:169/209`.
- In-process CEF runs Chromium's own `MultiSourceMemoryPressureMonitor` with its own kernel source in
  the app process; its listeners run on the CEF UI thread, which is cmux main.
- `KernelMemoryPressureSource.swift:34-35` maps `source.data` (the OR of coalesced events), never
  re-reads the sysctl and never reads the level at start. A WARN then NORMAL pair can read as warning
  until the next event.
- `memoryPressure.observe` has 3 real subscribers (BrowserHibernation.swift:156,
  PageHostPool+Build.swift:74, NewTabSparePool.swift:342) plus a doc-comment hit at
  MemoryPressureEvents.swift:14. `AppServices+Hibernation.memoryPressureDidChange` sets the warm set
  and calls `releaseParked` at critical.
- acpmux only warns on pressure (`host_pressure.rs`). acpmux does not depend on cmux-tui-core or
  cmux-tui-platform (acpmux/Cargo.toml).
- No consumer registry, traits, limit percentage, sliced release or mode scaling.

### Caches

- Union cache query (MQ-CACHE below): 86 files. 55 + 6 in CmuxNext, 20 in
  Packages/Shared/CmuxMessagesLab, 3 in CmuxHomeRender, 2 in CmuxHomeCore (these ship in the app
  through CmuxNextHome). The old query saw 50.
- Largest decoded-bitmap holders, none pressure-aware: CmuxHomeRender `RowBitmaps.swift:24-25`
  (500 rows, 96 MB per HomeScene); MessagesLab `RowDrawing.swift:881` byteBudget 160 MB,
  MediaCache 96 MB, TileCache 48 MB, SidebarBitmapCache 40 MB per sidebar. Together about 440 MB.
- `OndineMermaidRenderer.swift:41-42` `renders`/`images` grow without bound; the JSContext lives for
  the process.
- Byte-capped today: PreviewImageCache 32 MB, pageThumbnails 16 MB, HibernationSnapshots 64 MB,
  TabThumbnailCache 24/48 MB, Favicon 1 MB per image; Ghostty `cmuxDefaultImageStorageBytes`
  5,000,000 per surface (`GhosttyRuntime+ImageStorage.swift:8`). Widened cap query: 34 hits.
- `physicalMemory` is read in 2 places: WarmSetBudget.swift and HangReports/HardwareClass.swift.
- 9 `bufferingPolicy: .unbounded` AsyncStreams (PTY output, daemon events, loopback Data).

### Discards

- Browser tabs: HibernationPlanner.swift (19 exemptions; Pace normal 2/5 s, warning 1/15 s min hidden
  60 s, critical 3/3 s min hidden 10 s), BrowserHibernation.swift (710 lines), freeze after 30 s
  (`freezePlan`, HibernationPlanner.swift:152, checks only devtools, capture, lease, excluded host,
  pinned), default 30 min, snapshots, wake 41 ms p50.
- 13 BrowserTab conformers. Only WebKitTab and CEFTab are BrowserHibernationSource
  (BrowserHibernationSupport.swift:21,50); BrowserHibernation.swift:529 gives the rest
  canRestore=false. Never discarded: HistoryPageTab, BookmarkPageTab, VaultPageTab,
  ScreenshotsPageTab, AgentActivityPageTab (cmux pages in browser tabs), RemoteViewPageTab,
  RemoteBrowserTab, MachineBrowserPageTab (streams).
- Agent pages: AgentPageHibernation.swift, timeout only.
- No discard: 33 InternalPageID pages (InternalPageTabStore keeps the view until close), top pages
  (TopPageHost: kept for the window's life), conversations, right sidebar sections
  (`RightSidebarView.swift:14`, 6 modes), Home dock modes, overlay pages (IconPickerService `warm`,
  UpdateSurfaceIsland, extensions panel), tabs in minimized or occluded windows.
- `InternalPageTabStore.swift:18` holds `[String: WindowController]` strongly per page tab.
- Parked workspaces: `WindowController+Parking.swift` keeps every workspace mounted (decision
  6f04ec90105, 2026-10-17); `releaseParked` tears all down in one main-thread turn at critical.
  tab-lifecycle.md:71 still says at most 8.

### Terminal render state

- WarmSetBudget: normal min(24, max(8, phys/64/48 MiB)), warning 6, critical 0; 48 MB per surface.
- TerminalLastFrames keeps up to 24 volatile last frames (purgeable, outside phys_footprint).
- `ghostty_surface_set_occlusion` only pauses drawing; GPU drawables stay.
- Daemon: `DEFAULT_SCROLLBACK_LIMIT_BYTES` 10 MB per terminal; `output_store/memory_budget.rs`
  already has a total (`terminal.scrollback.maxTotalMemoryBytes`, 256 MiB, LRU shrink, 80 % restore)
  and segment files in full mode. Kitty: `MAX_KITTY_IMAGE_BYTES` 10,000,000 per terminal; the two
  decoded pixel maps (`render.rs:242`, `terminal.rs:391`) retain current generations only
  (kitty.rs:826), so the unbounded axis is per-terminal storage times terminal count.
- Daemon threads per terminal: `surface-{id}-reader` (spawn.rs:325), `-wait` (spawn.rs:433),
  `-host` (surface.rs:901). Holder rings: 1 MiB ring + 1 MiB link queue per terminal (holder.rs).
- 36 `Connection::open` sites in non-test Rust files; none trims SQLite caches.

### Chromium processes

- No `renderer-process-limit` switch; Chromium uses /2 (82 at 16 GB) and does not count terminals.
- Renderer sharing blocked while a DevTools agent is attached; the fork switch needs fork API 29,
  the tip pins a lower API. F1 and F2 also wait on new pins.
- Spares: NewTabSparePool, PageHostPool, CEFSpareWindow, ChromiumWarmup, plus Chromium's own
  SpareRenderProcessHostManager.
- WebKit cmux pages: `PageWebView+Pooled.swift:26` uses `PageProcessPool.shared` with no related
  view, so each page starts its own WebContent process. Agent pages use `WebProcessGroups`
  (`_relatedWebView`, `pagesPerProcess: Int = 8`).
- `CEFTab+Freeze.swift:20-22`: `WasHidden` does nothing for windowed Chrome-style browsers.
- PartitionAlloc is the app's malloc while CEF is in-process (`CmuxNextMallocZone/early_zone.c`).

### Measurement

- bench_memory.py, bench_hibernation.py, bench_renderer_sharing.py, scripts/measure/*, Task Manager
  (CmuxNextResources), ProcessUsage.swift, debug.surfaces, debug.hibernation.pressure.
- Missing: Release debug.memory, per-subsystem bytes, heap breakdown of the app, per-workspace
  attribution, JS heap per page, field data.

---

## 3. Target design

### A. Coordinator per process (port of base/memory_coordinator)

- **Placement.** `MemoryLimit`, `MemoryConsumerTraits`, the `MemoryConsumer` protocol, the RAII
  `MemoryConsumerRegistration` and `AsyncMemoryConsumerRegistration` live in `CmuxNextCompat/Memory/`
  (79 targets already depend on CmuxNextCompat: no new edges, no incremental-build cost).
  `MemoryCoordinator`, `SubsystemBudget`, `MemoryReport` and the release sink live in the new leaf
  target `CmuxNextMemory`, imported only by CmuxNextApp.
- **Consumer.** `updateMemoryLimit(_:)` (no freeing), `releaseMemory(within:)` (sliced), `memoryUsage`
  (footprintBytes, volatileBytes, entries; nil = unknown). Main-actor by default; consumers on other
  actors use `AsyncMemoryConsumerRegistration` (Chrome's async registration): one enqueue per call,
  weak hop. Value-type caches register through their owner. Shared packages that iOS builds
  (CmuxHomeRender, CmuxMessagesLab, CmuxHomeCore) expose an engine-neutral `bytes`/`trim(toFraction:)`
  API; a macOS adapter in CmuxNextHome registers it (`// memory: consumer via <adapter>`).
- **Modes.** Chrome's four: `memory.saver` = off / conservative / medium / aggressive with shares
  100 / 75 / 50 / 25 %. Default medium (it maps to today's 30 min browser timeout).
- **Limits.** Managed consumers are `isStateful && supportsMemoryLimit` (Chrome's ShouldManageConsumer).
  - Normal pressure: 100 % in every mode. cmux difference from Chrome: SubsystemBudget is already
    sized from RAM, and scaling at normal would cut hit rates of visible content with no pressure.
    The mode changes only discard timeouts at normal.
  - Warning: only consumers with dataAccess none and recreateCost cheap get mode share x 1/2. Others
    keep 100 %. No lossy action of a new kind at warning (Chrome acts lossily only at critical; macOS
    WARN is noisy). The existing browser warning pace stays until task 075 measures WARN frequency.
  - Critical: managed consumers go to 0, except their working set.
  - Working set: entries used in the last 2 s are never released by a lossless consumer.
  - Hysteresis: after a fall to normal, limits come back only after 30 s at normal (one DemandTimer
    one-shot).
  - A consumer that registers gets the current limit synchronously.
- **Release.** Order: dataAccess none and cheap first, then reads, lossy planners last. Slices of at
  most 2 ms on main; when no cmux window is visible, 8 ms back-to-back slices, back to 2 ms at once on
  input. The first slice runs on the frame after the level change, so it never shares a turn with
  Chromium's own pressure listeners. A slice only unlinks objects; the release sink drops the last
  references on a utility-QoS serial queue, and after a critical pass calls
  `malloc_zone_pressure_relief(nil, 0)` once there (PartitionAlloc purge through the fork when present).
- **Event-driven only**: no Timer, no polling, 0 periodic wakeups.
- **Kernel source** (one per process): re-reads `kern.memorystatus_vm_pressure_level` on each event,
  reads it at start, delivers only on change, exposes `currentLevel`.
- **Chromium.** In-process Chromium keeps its own platform voter. cmux adds one cmux-owned
  `MemoryPressureVoter` through a fork API; the coordinator votes the debug override and the cmux
  level; Chromium's aggregator takes the max. This is the accepted second source in the app.
- **Daemons.** New leaf Rust crate `cmux-tui/crates/cmux-memory` (libc only): consumer registry,
  macOS dispatch source (moved from standby_host.rs), Linux PSI trigger (`/proc/pressure/memory`,
  POLLPRI), `DaemonBudget`. Used by cmux-tui-core and acpmux. The app pushes
  `memory.limit {level, mode, override}` to the daemon and acpmux on each change; each daemon takes the
  max of its own level and the app's (Chrome's ChildMemoryConsumerRegistryHost).

### B. Budgets from physical memory

`SubsystemBudget.forMemory(physicalBytes:)`, M = physical MiB. Literal test values are in task 003.

| Field | Formula | 8 GB | 16 GB | 64 GB |
| --- | --- | --- | --- | --- |
| chromiumRendererLimit | clamp(M/3/85, 3, 82) | 32 | 64 | 82 |
| warmTerminalSurfaces (GPU release available) | clamp(M/1024, 4, 32) | 8 | 16 | 32 |
| warmTerminalSurfaces (no GPU release API) | today: min(24, max(8, M/64/48)) | 8 | 8 | 21 |
| parkedWorkspaces | clamp(M/2048, 4, 16) | 4 | 8 | 16 |
| parkedIdleTimeout | 15 min | | | |
| imageCacheBytes (all macOS decoded image caches) | M/128 MiB | 64 MiB | 128 MiB | 512 MiB |
| homeRenderBitmapBytes (Home transcript and lab caches) | clamp(M/64, 64, 256) MiB | 128 MiB | 256 MiB | 256 MiB |
| hibernationSnapshotBytes | M/256 MiB | 32 MiB | 64 MiB | 256 MiB |
| liveHiddenAgentPages | clamp(M/8/75, 4, 32) | 13 | 27 | 32 |
| liveHiddenInternalPages | clamp(M/4096, 2, 8) | 2 | 4 | 8 |
| kittyImageBytesPerSurface (app Ghostty) | clamp(M/4096, 2, 8) x 1,250,000 | 2.5 MB | 5 MB | 10 MB |
| webProcessPagesPerGroup | 8 | | | |

Terminal last frames stay volatile at the warm-set count (purgeable memory is outside phys_footprint;
the kernel takes it). Only non-volatile saved bytes are capped, at 0. This differs from Chrome's
FrameEvictionManager on purpose: Chrome's frames are not purgeable.

`DaemonBudget::for_memory(hw.memsize)` (Rust): scrollback_total (default for
`maxTotalMemoryBytes`), cold_scrollback_after 10 min, kitty_total, holder_ring_bytes.

Renderers get one third of RAM, not Chrome's half, because terminals and daemons share the Mac.

### C. One discard planner for every kind of content

- `ContentDiscardPlanner` (generalized HibernationPlanner) with one file per rule (`DiscardRule`).
- Kinds: browser (CEF/WebKit and the 8 other BrowserTabs), agentPage, internalPage, topPage,
  conversation, terminalSurface, parkedWorkspace, overlayPage, sidebarSection.
- Results: eligible, protected(reason), disallowed(reason). Protected is never discarded by urgent
  or proactive reasons (Chrome's discard_protected_tabs=false); only external and the lead-rule
  exceptions apply.
- Reasons: Chrome's 30 mapped, the existing cmux exemptions, unsavedEdits, runningCommand,
  discardAttempted (clears on show).
- Discard reasons: proactive, urgent, external, frozenWithGrowingMemory.
- New rules: recently audible 60 s; background activity protects from proactive only; frozen with
  growing memory (cmux threshold max(50 MB, 25 %), sampled at one-shot points +5, +30, +120 min after
  freeze; the opener group goes together); crashed subframe in a hidden page is discarded.
- Freeze rules: Chrome's CannotFreezeReasons and per browsing instance freezing.
- Urgent pace for new kinds: Chrome's one per event plus one every 5 s while critical. The browser's
  3/3 s pace stays until task 114 measures both.
- Lead rule (stricter than Chrome): audio, capture, form input, a download or a beforeunload that asks
  are never discarded at any pressure.
- Minimized, other-Space or occluded windows count as hidden (Visibility::OCCLUDED), with Chrome's
  occlusion-checker rules.
- Discarded objects keep a small record (URL/title/icon/history, a view-state record) and a picture.
  Pictures are counted in hibernationSnapshotBytes (neighbors and the N most recent only).
- Wake admission: wakes nobody asked for run at most clamp(cores/2, 1, 4) at once, are dropped at
  warning, never start under 150 MB free. A person's show is never queued.
- Hidden workspace past the parked budget or idle timeout: WorkspaceContentController is torn down
  to a WorkspaceViewRecord (about 1 KB), one teardown per release slice.
- Every new lossy kind ships behind a default-off Debug toggle (`memory.discard.<kind>`); turning a
  default on is its own PR after DC14 and Nightly dogfood.

### D. Terminal render state

- New ghostty-next API `ghostty_surface_set_gpu_resident`. A hidden paused surface outside the
  keep-alive band releases its swap chain and drawables; a terminal in a window off screen for 30 s
  does the same. Show sets it back before the first draw; the last frame covers the gap. A
  GPU-released surface parks its renderer thread: the thread stays, blocked in its event loop, with
  no frame, blink, display-link or animation work. It does not exit, because rebuilding the event
  loop, mailbox and Metal objects on every show would add thread creation to a show that must land
  in 10 ms. Chromium also keeps the renderer's compositor thread for hidden tabs and frees only
  their GPU resources (content/renderer/render_thread_impl.cc compositor thread,
  cc LayerTreeHostImpl::SetVisible).
- The warm set grows only in the commit that turns GPU release on.
- App-side scrollback paging is PL-ghostty's (F11); p07 depends on it.
- Fork state (task 036): ghostty-next branch `cp/p07-memory-036` (commits `bcc291d1e` and
  `6c6f34e53` on `723c4ab93`, the current pin), draft pull request
  https://github.com/manaflow-ai/ghostty-next/pull/56. Rules 037 builds on: the layer is empty from
  the release call on (cover the view with the app's last frame); the renderer thread parks; as
  for a hidden surface, output wakes it only until its scrollback compression timer is armed, and
  that timer and the release retry (16 ms doubling to 1 s) still run; a restore decodes a
  background image from bytes kept at load (no file I/O); `ghostty_surface_render_counters` gains
  `gpu_releases` (only releases that freed something) and `gpu_restores` at its end.
- Pin bump (task 036a): the `ghostty-next` gitlink and the GhosttyNextKit pin
  (`Packages/Shared/CmuxGhosttyKit/Package.swift`) stay at `723c4ab93` until pull request 56 is on
  ghostty-next `main` and a GhosttyNextKit release of that commit is published. Then one commit
  moves both. 037 depends on 036a and calls `ghostty_surface_set_gpu_resident` directly; it does
  not probe for the symbol. The library is linked statically, and the pinned `ghostty.h` does not
  declare the function, so a check at run time or compile time cannot work before the bump.
- Test gap (036): the Zig tests check what a release frees and a restore rebuilds on the CPU side
  (Kitty image state and placements, the background image, the residency epoch). Only the fleet
  iOS smoke check `gpu` (glyphs and a Kitty image, identical IOSurface bytes) checks drawn pixels,
  because no headless GraphicsAPI exists. That smoke has not run yet.
- Conflict surface for later ghostty-next work: `include/ghostty.h` (render counters struct, the
  new export), `src/apprt/embedded.zig`, `src/Surface.zig`, `src/renderer.zig`,
  `src/renderer/{Residency,Thread,generic,Metal,message,mailbox}.zig`,
  `src/renderer/metal/IOSurfaceLayer.zig`, `next/ios-smoke/main.swift`,
  `next/ios-render-smoke.sh`, `NEXT.md`. Keep: draws, display passes and the display link check the
  residency before the draw lock; a release never waits for the GPU under the draw lock; the main
  thread clears the layer in the call and the main-queue present drops frames after a release.

### E. Chromium and WebKit processes

- `renderer-process-limit` from the budget; one shared fork build and pin bump for all programs
  (fork API >= 29) turns on per-site sharing with DevTools, the cmux page-scheme process-per-site
  switch (with Chrome's PMF cap), the cmux pressure voter, BFCache flush and the PA purge.
- WebKit cmux pages share WebContent processes through WebProcessGroups (no fork). Same-site WebKit
  browser tabs share a process above the renderer limit.
- No page renderer before first show; overlay pages released 5 min after close.
- Spares key on pressure level (no spare at warning or critical); at most one Chromium-side spare.
  PL-memory hand-off from p13-webui-047: every web object is a coordinator consumer (WebUIHost's preload
  slot is the spare `webui-preload`; no `memoryPressure.observe` is left in the p13 D7 scope).
  `SpareMemoryConsumer.Closing` says when untaken spares close: page pools at any pressure, Chromium's spare
  windows only at critical (warning keeps them and refuses new ones, Chrome's default, see section 1.13).
  Critical then runs BrowserHibernation's one ranked pass on the next release slice.
- Hidden Chromium pages flush BFCache at freeze and at warning; Page lifecycle hide in occluded
  windows at once.
- With F2 the Chromium host exits 5 min after its last live page.

### F. Daemon and agents

- output_store memory_budget default from RAM and registered; kitty storage share across terminals;
  SQLite `sqlite3_db_release_memory` per connection under pressure; holder rings madvise
  MADV_FREE_REUSABLE after ack when cold; cold-scrollback codec only if the kernel compressor gap is
  over 2x; one reader loop and one kqueue proc watcher instead of 3 threads per terminal.
- acpmux: consumers and a memory section in `daemon status`; subsession/secret MCP served from the
  daemon; one MCP catalog per Mac with a stdio relay per agent.
- Leftover daemons exit after 10 min with no client, no live agent, no live PTY, no owning app.

### G. Measurement (F8)

- `debug.memory` (Release, read-only, local owner only, denied over relays, no URLs or titles):
  pressure, mode, budget, consumers (footprint/volatile/entries), processes by kind, tabs,
  workspaces, terminal GPU bytes, spares, pressure history, local histograms.
- `debug.discards` (chrome://discards analog) for every kind; daemon `memory-report`.
- memory-report.py (footprint/vmmap joined with consumers; unattributed <= 10 %), memory-soak.py
  (2 h STRESS, slopes, growing heap classes), page-heap-report.py (JS heap per page), bench_memory
  phases for hidden workspaces, pressure (override and kernel), hidden-CEF backgrounding and cold
  scrollback.
- Task Manager shows memory saved per discarded item.
- Field upload is deferred until after the push; histograms stay local in debug.memory.
- No CI gates, budgets rows or perf-gate rows. Agents run every check on the fleet.

---

## 4. Rules

1. Event-driven only. A new `Timer`, `DispatchSourceTimer`, `Task.sleep` loop or poll in any p07 file
   is a review reject. Deadlines use one DemandTimer one-shot per owner.
2. Main thread: a release slice does at most one teardown or eviction; no dealloc of large objects on
   main (release sink); no disk I/O or lock wait. Handlers use `registry.bindEffect` and return an
   `ActionEffect`.
3. No CI gates: memory-queues.sh is local; thresholds live in memory-DESIGN.md and perf-lead.md.
   Decision made: no pre-push cache guardrail (CLAUDE.md, Lawrence 2026-10-23).
4. Every fix commits its failing regression test first and records red and green from the fleet.
5. Risk tiers: lossy discard kinds, socket methods, the pin bump, idle exit of daemons and the MCP
   credential scoping are risk:high (independent `Review (<reviewer>): SHIP at <sha>` receipt).
   Docs/scripts are risk:low. The rest are risk:normal.
6. Take-back: task 032 takes back 6f04ec90105; its PR body says `Takes back 6f04ec90105: <why>` with
   a bench-tab-switch A/B (light and STRESS).
7. Fork-dependent Swift lands behind fork API version checks and is a no-op on old forks. No program
   bumps the pin alone (task 074).
8. Lead rule: audio, capture, form input, a download or an asking beforeunload are never discarded.
9. A `// memory: fixed <reason>` mark must prove a bounded key space; a cache over 1 MB at STRESS may
   not use it.
10. Owners: tell PL-memory (CmuxNextMemory, new OWNERS.md entry), PL-ghostty (036, 037, 097, F11),
    PL-daemon (holder, 095), PL-acpmux (064, 091-093), PL-cefhost (050, 074), the idle program
    (HostPressureMonitor timer stays) per OWNERS.md.
11. Shared package edits (CmuxHomeRender, CmuxMessagesLab, CmuxHomeCore) must keep iOS building: no
    AppKit or CmuxNext types in their public memory API.
12. Composition wiring goes only into `AppServices+Memory.swift` (append-only, sorted).
13. Decisions made (no question to Lawrence; memory says decide): local queues only; new lossy kinds
    default off behind Debug toggles; RAM/3 renderer share; Chrome's four modes with 100 % at normal;
    field upload deferred; app scrollback paging left to PL-ghostty. Outside step: the R2 upload of the
    fork artifact (task 074) needs a person with R2 access.

---

## 5. Done checks

All runs are fleet runs (cmux-ci), Release, cmux20 class unless named; recorded in perf-lead.md F8
and memory-DESIGN.md with host, SHA and step IDs. Measurement windows run during the push, not only
at the end; the hour-0 baseline (075) gives every "today" value.

- **DC1 caches.** `scripts/cmux-next/memory-queues.sh caches` (MQ-CACHE) prints 0 files (today 86).
  Every cache that memory-report.py or debug.memory shows above 1 MB at STRESS is a registered
  consumer, not a `memory: fixed` mark.
- **DC2 one source per process.** `rg -l 'makeMemoryPressureSource' Packages/macOS/CmuxNext/Sources`
  lists only CmuxNextCompat/KernelMemoryPressureSource.swift (today 3 files).
  `rg -l '_dispatch_source_type_memorypressure' cmux-tui/crates` lists only
  cmux-memory/src/pressure_macos.rs. `rg -n --pcre2 '^(?!\s*///).*memoryPressure\.observe'
  Packages/macOS/CmuxNext/Sources --type swift` hits only CmuxNextMemory (today 3). The in-process
  Chromium platform voter (`SystemMemoryPressureEvaluatorMac`, started by
  content/browser/browser_main_loop.cc `CreateMemoryPressureMonitor`) is the one accepted second
  source in the app; no search above counts it, as it lives in the Chromium framework. cmux reaches
  Chromium's `MultiSourceMemoryPressureMonitor` only through its own voter (051: fork
  `cmux_memory_pressure_vote`, `CEFMemoryPressureVote`), which votes the debug override and the cmux
  level (section 3.A; Chromium's aggregator takes the max); nothing in cmux calls `NotifyMemoryPressure`.
- **DC3 budgets from RAM.** `rg -n 'physicalMemory' Packages/macOS/CmuxNext/Sources` hits only
  CmuxNextMemory/SubsystemBudget.swift and CmuxNextHangReports/HardwareClass.swift. MQ-CAPS has 0 hits
  outside SubsystemBudget.swift (today 34). MQ-RUST-CAPS literals live only in
  cmux-memory/src/budget.rs or are derived from it (today 37 hits). SubsystemBudgetTests and the
  DaemonBudget table test pass for 8/16/24/32/64/128 GB.
- **DC4 every kind discardable.** `ContentDiscardPlannerTests|InternalPageDiscardPolicyCoverageTests`
  pass; the coverage test fails for any of the 33 InternalPageIDs, the 7 TabContent cases, the 13
  BrowserTab conformers (MQ-BROWSERTAB), overlay pages or sidebar sections with no declared policy.
  With all discard toggles on, a STRESS session idle 35 min with every tab hidden shows 0
  `debug.discards` rows with state=live, eligibility=eligible and hidden_for > timeout.
- **DC5 hidden content after discard.** bench_hibernation.py and bench_memory.py --pressure: per hidden
  Chromium tab, WebKit tab, agent page, internal page and cmux page tab <= 0.1 MB excluding its picture
  (today 55 / 29 / 75 MB). Pictures stay within hibernationSnapshotBytes.
- **DC6 hidden workspace.** `bench_memory.py --hidden-workspaces 100 --grace 960` with the holder model
  on (`CMUX_TUI_TERMINAL_HOST_MODEL=holder` until PL-daemon makes it default; the run says so):
  per hidden workspace app <= 0.1 MB, daemon <= 0.3 MB, no cmux process added (today 8.2 MB total).
- **DC7 Home idle.** 0 Chromium renderers and 0 WebKit WebContent processes for cmux pages not shown,
  at most 1 renderer for all shown cmux pages, no icon-picker page, at most 1 spare Chromium renderer.
  Interim target with in-process CEF: the 075 baseline minus every p07 item removed, recorded. Final
  target after F2 and the shared pin: whole tree <= 250 MB, app <= 120 MB (today 793 / 361).
- **DC8 heavy session.** perf-stress-session.py 60 ws STRESS and budgets-heavy 150 ws, 35 min idle,
  all discard toggles on: cmux-owned footprint (shells and agent harnesses excluded) <= 600 MB (today
  3,538 MB whole tree). Threads <= 300, each share with its owner (bench_memory.py prints them as
  "threads by owner (DC8)"): daemon, terminal hosts and holders from task 095 with PL-daemon; the app
  (Ghostty's renderer and IO thread per surface included) from task 078, PL-memory; Chromium helpers
  PL-cefhost; acpmux PL-acpmux; WebKit processes PL-webui.
- **DC9 renderer limit.** `bench_renderer_sharing.py --tabs 100 --sites 20` (hibernation off):
  renderers <= max(SubsystemBudget.chromiumRendererLimit, distinct site locks), reported next to the
  site-lock count; <= 2 same-site main frames per renderer below the limit. `--engine webkit` gives the
  same rule for WebKit. `bench_memory.py --tabs 60 --urls local`: cmux total <= Chrome total on the
  same host (#20856: Chrome 7.4 GB, cmux 11.8 GB).
- **DC10 pressure response.** `bench_memory.py --pressure critical` (override) and
  `--kernel-pressure critical` (`/usr/bin/memory_pressure` where allowed): within 5 s the app
  footprint falls by >= 80 % of the managed consumers' footprintBytes reported before (volatile bytes
  excluded); every managed consumer is at its critical limit within 1 s with a visible window and 2 s
  hidden; MainFrameBudget shows 0 turns > 4 ms from release work and 0 dropped frames; the daemon and
  acpmux release their lossless consumers within 1 s of `memory.limit critical`.
- **DC11 terminal GPU.** On a fork with `ghostty_surface_set_gpu_resident`: with 30 hidden terminals
  and one minimized window of 6 terminals, `terminal.hidden_nonvolatile_iosurface_bytes == 0`.
- **DC12 leaks.** `scripts/measure/memory-soak.sh` (2 h STRESS churn): slope <= 5 MB/h app, <= 5 MB/h
  daemon, <= 2 MB/h acpmux; renderer total within 5 % of start; MQ-LEAK empty.
- **DC13 idle.** 60 s idle: WakeupLedger shows 0 wakeups owned by MemoryCoordinator,
  ContentDiscardPlanner or any consumer; daemon idle_wakeups and acpmux daemon_idle tests green.
- **DC14 latency (not worse).** Browser wake p95 <= 100 ms with a picture in the first frame;
  discarded internal page, conversation, sidebar section or top page shows its picture or record in
  the first frame (key to frame p99 <= 16.7 ms); unmounted workspace key to first frame p99 <= 16.7 ms
  and remount p95 <= 50 ms (bench-tab-switch.sh and anim ws-switch, light and STRESS).
- **DC15 attribution.** `memory-report.py --pid <app>`: unattributed <= 10 % of app phys_footprint.
- **DC16 macOS 14/15.** `scripts/cmux-next/os-matrix.sh --build JOB --os 14,15` runs the coordinator,
  kernel source, hibernation, purgeable IOSurface and parked-workspace suites and passes.
- **DC17 flapping.** Debug override toggling warning/normal 20 times a minute: at most 1 release pass
  per consumer per minute and 0 dropped frames in an anim sidebar run.
- **DC18 per agent.** `scripts/measure/acpmux-overhead.sh` with 100 fake agents: acpmux <= 2 MB per
  agent, sidecar relays <= 1 MB each, process count per agent down by 2, total per agent <= 8 MB
  (today about 64 MB).

---

## 6. Machine queues

Each hit is one task or one line in a batch task. Run from the checkout root. `memory-queues.sh`
prints each queue with a count; it is never wired into CI or the hook.

- **MQ-CACHE (86 files today; tasks 052-060, 080-083, 107, 115, 116).** P = Packages/macOS/CmuxNext/Sources
  plus Packages/Shared/{CmuxHomeRender,CmuxHomeCore,CmuxMessagesLab,CmuxVNC,CmuxScreenKit}/Sources.
  ```
  { rg -l --pcre2 '(var|let)\s+\w+\s*(:\s*)?[^=\n]*\[[^\]\n]+:\s*\(?(CGImage|NSImage|UIImage|Data|TabImage|IOSurface|CTLine|NSAttributedString|CALayer|CGPath|MTLTexture|CVPixelBuffer|\w*Image|\w*Bitmap|Rendered)\b[^\]\n]*\]' $P -g '!**/Tests/**' -g '!**/Mock*' -g '!**/*Fixture*';
    rg -l --pcre2 '(class|struct|actor|enum) \w*(Cache|LRU|Memo)\b' $P -g '!**/Tests/**';
    rg -l --pcre2 '^\s{4}(@\w+\s+)*(private(\(set\))?\s+|fileprivate\s+)?(static\s+)?var\s+\w+\s*:\s*\[[^\]]+:\s*(CGImage|NSImage|Data|TabImage|\[CGImage\]|IOSurface|CGRect)\b[^\]]*\]' Packages/macOS/CmuxNext/Sources; } \
    | sort -u | xargs rg --files-without-match 'MemoryConsumer|memory: fixed|memory: consumer via'
  ```
  Batches run in order of measured bytes (memory-report.py, task 014), largest first.
- **MQ-PRESSURE (4 hits today; tasks 005, 006, 042, 068).**
  `rg -n 'makeMemoryPressureSource|_dispatch_source_type_memorypressure|DISPATCH_SOURCE_TYPE_MEMORYPRESSURE' Packages/macOS/CmuxNext/Sources cmux-tui/crates`
  (doc comments excluded) — every hit except KernelMemoryPressureSource.swift and
  cmux-memory/src/pressure_macos.rs is one task.
- **MQ-OBSERVE (3 hits today; task 047, BrowserHibernation in 017).**
  `rg -n --pcre2 '^(?!\s*///).*memoryPressure\.observe' Packages/macOS/CmuxNext/Sources --type swift`.
- **MQ-PAGES (33 hits today; tasks 024-029).**
  `rg -n 'static let \w+ *= *InternalPageID\(' Packages/macOS/CmuxNext/Sources`.
- **MQ-CONTENT (7 cases; tasks 017, 022, 030, 100).**
  `rg -n '^    case \w+\(' Packages/macOS/CmuxNext/Sources/CmuxNextApp/TabContent.swift`.
- **MQ-BROWSERTAB (13 conformers, 8 without hibernation; tasks 084, 085).**
  `rg -n 'final class \w+: BrowserTab\b|class \w+: (\w+, )*BrowserTab[ ,{]' Packages/macOS/CmuxNext/Sources`
  — every conformer other than Mock/Hibernated/Deferred has BrowserHibernationSource or
  `// discard: never <why>`.
- **MQ-CAPS (34 hits today; tasks 035, 058, 080-083, 087, 105).**
  `rg -n --pcre2 '(capacityBytes|maxBytes|byteBudget|terminalCostBytes|ImageStorageBytes)[^\n]*(\d+\s*<<\s*20|\d+_000_000)|capacity\s*=\s*\d{2,}|pagesPerProcess: Int = \d+' $P`.
- **MQ-RUST-CAPS (37 hits today; tasks 073, 089, 094).**
  `rg -n 'MAX_KITTY_IMAGE_BYTES|DEFAULT_SCROLLBACK_LIMIT_BYTES|RING_BYTES|LINK_QUEUE_BYTES' cmux-tui/crates --type rust`.
- **MQ-RUST-CACHE (2 hits today; task 073).**
  `rg -n --pcre2 '\w*cache\w*\s*:\s*(HashMap|BTreeMap|IndexMap)<|struct \w*(Cache|Lru)\w*\((HashMap|BTreeMap)' cmux-tui/crates --type rust -g '!*test*'`.
- **MQ-PHYS (2 hits today).** `rg -n 'physicalMemory' Packages/macOS/CmuxNext/Sources`.
- **MQ-STREAM (9 hits today; task 098).**
  `rg -n 'bufferingPolicy:\s*\.unbounded' Packages/macOS/CmuxNext/Sources` — each has a byte bound with
  backpressure or `// memory: bounded-by <limit>`.
- **MQ-PAGEVIEW (23 construction sites; tasks 048, 086).** `rg -n 'PageWebView\(' Packages/macOS/CmuxNext/Sources`
  joined with debug.memory tabs rows where state=live and shown_ever=false at Home idle.
- **MQ-PROC (runtime; tasks 061, 062, 113).** `bench_memory.py --app BUNDLE --workspaces 1 --settle 30 --top 50`
  at Home idle — each process kind no visible feature needs is one start-on-first-use task.
- **MQ-LEAK (runtime; task 015).** memory-soak top 30 growing heap classes; each class > 1,000
  instances or > 1 MB per hour is one fix task with a weak-reference regression test.
- **MQ-UNATTRIBUTED (runtime; task 014).** memory-report.py; each category > 5 MB with no owner is one
  task.
- **MQ-JSHEAP (runtime; task 102).** page-heap-report.py; each page with JS heap > 20 MB or growth > 5 MB
  over 50 navigations is one webviews/ fix task.

---

## 7. Risks

1. **Fork dependencies.** 036 (ghostty-next), 046, 049, 051, 101, 111 and the PA purge need fork builds.
   One shared build and pin (074) starts at hour 0; the R2 upload is an outside step. Swift sides land
   behind version checks. If the pin misses 72 h, DC7 final, DC9 sharing with DevTools and DC11 stay
   open and are reported as not run.
2. **F2 dependency.** 050 and the final DC7 numbers need the out-of-process browser host.
3. **Data loss from new discard kinds.** Missing keepReasons or view-state can lose drafts, scroll or
   edits. Every kind has keepReasons, a red-first round-trip test, a default-off toggle and risk:high
   review. Coverage test 029 rejects a default policy without a reason.
4. **Latency coupling.** Unmount and GPU release add rebuild work on show. Every path shows a picture
   or record in the first frame (DC14). 032 measures 12-pane remount first; if p95 > 50 ms it ships
   the LRU without the 15 min timeout until replay is faster.
5. **WARN noise.** 8 GB Macs sit at WARN for hours. Mitigated by the warning rule (cheap/none only),
   the working set and hysteresis (070); 075 measures WARN frequency.
6. **Chromium double handling.** Chromium's own listeners run on cmux main; the coordinator starts a
   frame later (002) and 068/051 keep one aggregated level.
7. **Renderer share RAM/3** sends more same-site tabs to one renderer above the limit; a crash reloads
   more tabs of that site. Sites never mix; 111 adds Chrome's PMF cap.
8. **More aggressive than Chrome on purpose:** default 30 min browser timeout and the existing urgent
   minimum hidden 10-60 s. 114 measures Chrome's urgent pace against cmux's.
9. **Overlap with other programs:** PL-ghostty (F11 app scrollback, removed from p07 as old task 038),
   PL-daemon (holder default, threads), PL-acpmux, PL-cefhost, idle program. Tasks 095 and 117/118 must
   be checked against the other programs' queues before start; whichever program starts first owns
   the files.
10. **Measurement noise.** Fleet minis have no lit display; 14/15 only in Tart (not perf evidence);
    PartitionAlloc is the malloc while CEF is in-process. The exclusive queue p90 was 5.2 h; 075
    reserves measurement windows.
11. **Generated files.** memory.saver changes settings-schema.json and docs/mdm; never hand-edit them.
12. **False positives in MQ-CACHE.** Reviewers reject a `memory: fixed` mark that hides a growing
    cache.
13. **Parallel conflicts.** 017 is one file per rule and 077 is append-only, so 018-021 and the cache
    batches add files and lines rather than edit the same lines.

---

## 8. Task table

Removed from the reviewed design, with reasons: old 038 (app scrollback hot window) moves to
PL-ghostty F11, which owns double parse; old 043 (kitty_pixel_cache LRU) is replaced by 073 because
both pixel maps already retain only current generations (kitty.rs:826) and the real axis is
per-terminal storage times terminal count; review task "Task Manager page policy" is merged into 024;
review task "leaf Rust crate" is merged into 042; review task "kernel pressure test" is merged into 068.

| ID | Title | Size | Risk | Depends on | Queue |
| --- | --- | --- | --- | --- | --- |
| 001 | Memory protocol types in CmuxNextCompat; CmuxNextMemory target | M | normal | - | |
| 002 | MemoryCoordinator: limits, working set, sliced ordered release | M | normal | 001, 068 | |
| 003 | SubsystemBudget from physical RAM | S | normal | 001 | MQ-PHYS |
| 004 | Composition root: one coordinator; debug override feeds it | S | normal | 002, 003, 077 | |
| 005 | TabHoverCard: drop its source; register caches | S | normal | 004 | MQ-PRESSURE |
| 006 | HostPressureMonitor uses shared events | S | normal | 004 | MQ-PRESSURE |
| 007 | memory-DESIGN.md and doc fixes | S | low | 003 | |
| 008 | memory-queues.sh | S | low | 007 | all static |
| 009 | MemoryReport snapshot | S | normal | 002 | |
| 010 | debug.memory (Release, read-only) | M | high | 004, 009 | |
| 011 | debug.discards for every kind | M | high | 017 | MQ-CONTENT |
| 012 | Task Manager: memory saved per discard | M | normal | 017, 010 | |
| 013 | bench_memory hidden-workspace and pressure phases | M | low | 010 | |
| 014 | memory-report.py | M | low | 010 | MQ-UNATTRIBUTED |
| 015 | memory-soak | M | low | 010 | MQ-LEAK |
| 016 | Local memory histograms in debug.memory (no upload) | S | normal | 010 | |
| 017 | ContentDiscardPlanner with one file per rule | L | normal | - | MQ-CONTENT |
| 018 | Recently audible 60 s | S | normal | 017 | |
| 019 | Background activity protects from proactive | S | normal | 017 | |
| 020 | Frozen with growing memory | S | normal | 017 | |
| 021 | Occluded windows count as hidden | M | normal | 017 | |
| 022 | Internal page discard framework | L | high | 017 | MQ-CONTENT |
| 023 | TopPageHost discards hidden top pages | M | high | 022, 003 | |
| 024 | Page policies batch 1 (+taskManager) | S | high | 022 | MQ-PAGES |
| 025 | Page policies batch 2 | S | high | 022 | MQ-PAGES |
| 026 | Page policies batch 3 | S | high | 022 | MQ-PAGES |
| 027 | Page policies batch 4 | S | high | 022 | MQ-PAGES |
| 028 | Page policies batch 5 | S | high | 022 | MQ-PAGES |
| 029 | Discard policy coverage test | S | low | 024-028 | MQ-PAGES, MQ-CONTENT, MQ-BROWSERTAB |
| 030 | Conversation tabs release transcript | M | high | 017 | MQ-CONTENT |
| 031 | Agent page live cap from RAM | S | normal | 003, 004 | |
| 032 | Parked workspace budget and idle timeout | M | high | 033, 096, 003, 004 | |
| 033 | WorkspaceViewRecord | M | normal | - | |
| 034 | Unmounted workspace leaves no objects | M | normal | 032, 015 | MQ-LEAK |
| 035 | Terminal last frames: volatile at warm count, 0 non-volatile | S | normal | 003, 004 | MQ-CAPS |
| 036 | ghostty_surface_set_gpu_resident | L | normal | - | |
| 036a | ghostty-next pin bump for set_gpu_resident | S | normal | 036 | |
| 037 | Hidden surfaces drop GPU residency; warm set gated | M | normal | 036a, 035, 096 | |
| 039 | Glyph atlas sharing measurement | S | low | 014 | MQ-UNATTRIBUTED |
| 039a | Shared glyph atlas texture in ghostty-next | M | normal | 039 | MQ-UNATTRIBUTED |
| 040 | Cold-scrollback codec (gated) | L | normal | 112 | |
| 041 | Compress cold scrollback (gated) | M | normal | 040, 072 | |
| 042 | cmux-memory leaf crate: registry, macOS and Linux sources | M | normal | - | MQ-PRESSURE |
| 044 | Daemon memory-report | M | high | 042 | |
| 045 | renderer-process-limit from RAM | S | normal | 003 | |
| 046 | Renderer sharing with DevTools (pin) | S | normal | 045, 074 | |
| 047 | Spare pools key on pressure level | M | normal | 004 | MQ-OBSERVE |
| 048 | No cmux page renderer before first show (both engines) | M | normal | 010 | MQ-PAGEVIEW |
| 049 | One Chromium renderer for cmux pages | L | normal | 048, 074 | |
| 050 | Chromium host idle exit (F2) | M | normal | 047 | |
| 051 | cmux MemoryPressureVoter into Chromium | M | normal | 004, 074 | MQ-PRESSURE |
| 052 | Caches batch: CmuxNextTabs | M | normal | 004, 077 | MQ-CACHE |
| 053 | Caches batch: CmuxNextDesign | M | normal | 004, 077 | MQ-CACHE |
| 054 | Caches batch: CmuxNextSidebar | S | normal | 004, 077 | MQ-CACHE |
| 055 | Caches batch: Browser and BrowserCore | M | normal | 004, 077 | MQ-CACHE |
| 056 | Caches batch: CmuxNextApp part 1 | M | normal | 004, 077 | MQ-CACHE |
| 057 | Caches batch: CmuxNextApp part 2 | S | normal | 004, 077 | MQ-CACHE |
| 058 | Preview, thumbnail, snapshot caches by budget | M | normal | 003, 004 | MQ-CAPS, MQ-CACHE |
| 059 | Caches batch: Files, FileGrid, Apps, Home, HomeEngine | M | normal | 004, 108 | MQ-CACHE |
| 060 | Caches batch: AgentPane ... Daemon | L | normal | 004, 108 | MQ-CACHE |
| 061 | MediaRemoteAdapter on first need | S | normal | - | MQ-PROC |
| 062 | Other launch helpers on first use | M | normal | 061 | MQ-PROC |
| 063 | Leftover daemons idle exit | M | high | - | |
| 064 | acpmux per-session budget | L | normal | 091 | MQ-LEAK |
| 065 | memory.saver setting and Debug toggles | M | normal | 004 | |
| 066 | macOS 14/15 run | S | low | 037, 032, 022, 068 | |
| 067 | Done-check run, numbers in F8 | S | low | 013, 014, 015, 058, 037, 032, 075 | |
| 068 | Kernel source re-reads sysctl; initial level; kernel bench | S | normal | - | MQ-PRESSURE |
| 069 | Release sink: volatile split, off-main dealloc, heap relief | M | normal | 002 | |
| 070 | Working set and hysteresis | M | normal | 002 | |
| 071 | Hidden-app release budget | S | normal | 002 | |
| 072 | Daemon scrollback total from RAM, registered | M | normal | 042, 089 | |
| 073 | Daemon kitty storage share across terminals | M | normal | 042, 089 | MQ-RUST-CACHE, MQ-RUST-CAPS |
| 074 | One shared CEF fork build and pin bump | S | high | - | |
| 075 | Hour-0 baseline and WARN frequency | S | low | - | |
| 076 | Socket and relay policy for memory methods | S | high | 010, 011, 044 | |
| 077 | AppServices+Memory.swift append-only | S | normal | - | |
| 078 | App threads per hidden surface | M | normal | 037 | |
| 079 | Widen the static queues | S | low | 008 | MQ-CACHE, MQ-CAPS, MQ-RUST-* |
| 080 | CmuxHomeRender caches as consumers | M | normal | 004, 003 | MQ-CACHE |
| 081 | MessagesLab big caches as consumers | M | normal | 080 | MQ-CACHE |
| 082 | OndineMermaidRenderer bounds and JSContext release | S | normal | 004 | MQ-CACHE |
| 083 | Small missed app stores | S | normal | 003, 004 | MQ-CACHE, MQ-CAPS |
| 084 | cmux page browser tabs discardable | M | high | 017, 022 | MQ-BROWSERTAB |
| 085 | Remote view tabs pause and discard | M | high | 084 | MQ-BROWSERTAB |
| 086 | Overlay and prewarmed pages released | M | normal | 017 | MQ-PAGEVIEW |
| 087 | WebKit cmux pages share process groups | S | normal | 003 | MQ-CAPS |
| 088 | WebKit same-site process reuse above limit | M | normal | 045 | |
| 089 | DaemonBudget table | S | normal | 042 | MQ-RUST-CAPS |
| 090 | SQLite page caches trimmed under pressure | S | normal | 042 | |
| 091 | acpmux consumers and status memory | M | normal | 042 | |
| 092 | Subsession and secret MCP in the acpmux daemon | L | high | - | |
| 093 | One MCP catalog per Mac | L | normal | 092 | |
| 094 | Holder ring pages released when cold | M | normal | 089 | MQ-RUST-CAPS |
| 095 | Daemon: one reader loop, one proc watcher | L | normal | - | |
| 096 | Sliced release of parked and warm set | M | normal | 002, 004 | |
| 097 | Occluded windows: GPU release and Chromium hide | M | normal | 037, 021 | |
| 098 | Unbounded AsyncStreams bounded | M | normal | - | MQ-STREAM |
| 099 | InternalPageTabStore weak windows | S | normal | - | MQ-LEAK |
| 100 | Right sidebar sections and dock modes released | S | high | 017 | MQ-CONTENT |
| 101 | BFCache flush for hidden tabs | M | normal | 004, 074 | |
| 102 | JS heap report per page | M | low | 010 | MQ-JSHEAP |
| 103 | Freeze eligibility: CannotFreezeReasons, groups | M | normal | 017 | |
| 104 | Discard-attempt marker | S | normal | 017 | |
| 105 | Wake admission control | M | normal | 017 | |
| 106 | Discard hidden pages with crashed subframe | S | normal | 017 | |
| 107 | Purgeable backing for decoded image caches | M | normal | 058 | MQ-CACHE |
| 108 | AsyncMemoryConsumerRegistration | S | normal | 001 | |
| 109 | App pushes memory.limit to daemon and acpmux | M | high | 042, 004, 091 | |
| 110 | Prove hidden CEF pages are backgrounded | S | low | 013 | MQ-UNATTRIBUTED |
| 111 | Memory cap on shared renderers | M | normal | 049 | |
| 112 | Kernel compressor measurement gates the codec | S | low | - | |
| 113 | One Chromium-side spare | S | normal | 010, 047 | MQ-PROC |
| 114 | Urgent pace A/B: Chrome 1/event + 5 s | S | normal | 017, 013 | |
| 115 | Caches batch: MessagesLab and HomeCore remainder | M | normal | 080 | MQ-CACHE |
| 116 | Caches batch: CmuxNext remainder | S | normal | 004, 108 | MQ-CACHE |

Test phase notation: "fleet swift test X" means
`cmux-ci run --class isolated --ref SHA --script 'cd Packages/macOS/CmuxNext && ../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --filter X'`;
"fleet cargo test X" means `cmux-ci run --class isolated --ref SHA --script 'cd cmux-tui && cargo test X'`;
"fleet exclusive" means `cmux-ci run --class exclusive --measurement --label measure --ref SHA --script ...`.
All IDs below are `p07-memory-NNN`.

### 001 Memory protocol types in CmuxNextCompat; CmuxNextMemory target
- Files: CmuxNextCompat/Memory/MemoryLimit.swift, MemoryConsumerTraits.swift, MemoryConsumer.swift,
  MemoryConsumerRegistration.swift; Packages/macOS/CmuxNext/Package.swift (new CmuxNextMemory target,
  depends only on CmuxNextCompat); Tests/CmuxNextCompatTests/MemoryLimitTests.swift.
- Change: MemoryLimit (percent, scale, default 100, critical threshold); traits with Chrome's names
  (estimatedUsage small/medium/large, dataAccess none/reads/readsAndWritesDisk, retention
  lossy/lossless, recreateCost cheap/expensive/notApplicable, releaseCPUCost, isStateful,
  supportsMemoryLimit); MemorySaverMode off/conservative/medium/aggressive with shares 100/75/50/25;
  MemoryUsage {footprintBytes, volatileBytes, entries}; @MainActor MemoryConsumer with
  updateMemoryLimit, releaseMemory(within:) -> ReleaseProgress, memoryUsage; RAII token. DocC cites
  base/memory_coordinator files.
- Acceptance: CmuxNextMemory depends only on CmuxNextCompat; no caseless namespace enum or all-static
  public type; tests cover scale, default, mode shares and teardown.
- Test: fleet swift test MemoryLimitTests.

### 002 MemoryCoordinator
- Files: CmuxNextMemory/MemoryCoordinator.swift, MemoryReleaseOrder.swift,
  Tests/CmuxNextMemoryTests/MemoryCoordinatorTests.swift.
- Change: inputs MemoryPressureEvents (currentLevel), mode, debug override. Managed = isStateful &&
  supportsMemoryLimit. Normal 100 %; warning: dataAccess none and cheap consumers get share x 1/2,
  others 100 %; critical 0; lossy consumers get the level only. Release order none/cheap, reads, lossy.
  Slices <= 2 ms through an injected slicer; first slice on the frame after the level change. New
  registrant gets the current limit synchronously. No calls for an unchanged level.
- Acceptance: no Timer/DispatchSourceTimer/Task.sleep/poll in the file. Fake-clock tests: order by
  traits; no slice over budget; no calls for a repeated level; critical then normal makes 0 release
  calls; registrant mid-release gets the current limit at once; first slice is not in the event turn.
- Test: fleet swift test MemoryCoordinatorTests (red before, green after).

### 003 SubsystemBudget
- Files: CmuxNextMemory/SubsystemBudget.swift, Tests/CmuxNextMemoryTests/SubsystemBudgetTests.swift.
- Change: forMemory(physicalBytes:gpuResidentAvailable:) with the fields of section 3.B. DocC cites
  render_process_host_impl.cc and frame_eviction_manager.cc and states the cmux differences.
- Acceptance: table test with literals at 8/16/24/32/64/128 GB (16 GB: renderer 64, warm 16 with GPU
  release and 8 without, parked 8, imageCache 128 MiB, homeRender 256 MiB, snapshots 64 MiB, agent
  pages 27, internal pages 4); a test that the 16 GB image shares are >= today's literals (32 + 16 +
  48 MB). Instance surface.
- Test: fleet swift test SubsystemBudgetTests.

### 004 Composition root
- Files: CmuxNextApp/AppServices+Memory.swift, AppServices+Hibernation.swift,
  Control/DebugHibernationControl.swift, Package.swift.
- Change: one `MemoryCoordinator(pressure:budget:)` next to memoryPressure; debug.hibernation.pressure
  sets the coordinator override; memoryPressureDidChange keeps its calls until 037 and 096 move them.
- Acceptance: exactly one `MemoryCoordinator(` in Sources; a test shows the override changes
  coordinator.level and BrowserHibernation.pressure together.
- Test: fleet swift test 'DebugHibernation|MemoryCoordinator'.

### 005 TabHoverCard
- Files: CmuxNextTabs/TabHoverCard.swift, its construction site, Tests/CmuxNextTabsTests/TabHoverCardMemoryTests.swift.
- Change: remove the source at :78; register thumbnails and lastReports as one lossless small consumer
  (dataAccess none, bytes from bytesPerRow x height).
- Acceptance: 0 makeMemoryPressureSource hits in CmuxNextTabs; at 0 % both maps empty, 0 bytes.
- Test: fleet swift test TabHoverCard.

### 006 HostPressureMonitor
- Files: CmuxNextHostPressure/HostPressureMonitor.swift, the app wiring file, its tests.
- Change: replace the source at :130 with an injected subscription to MemoryPressureEvents; the 15 s
  load timer stays (idle program).
- Acceptance: 0 makeMemoryPressureSource hits in CmuxNextHostPressure; existing tests green; no new timer.
- Test: fleet swift test HostPressure.

### 007 memory-DESIGN.md and doc fixes
- Files: plans/cmux-next/memory-DESIGN.md, tab-lifecycle.md, perf-lead.md, OWNERS.md.
- Change: this spec as the design (Chrome mapping, budget table, kinds, reasons, release rules,
  JSON of debug.memory/debug.discards, DC1-DC18, decisions). Fix tab-lifecycle.md:71. Link F8. Add the
  PL-memory owner of CmuxNextMemory and cmux-memory.
- Acceptance: numbers equal SubsystemBudgetTests literals; plain English per STYLE.md.
- Test: python3 scripts/verify-local.py docs lane.

### 008 memory-queues.sh
- Files: scripts/cmux-next/memory-queues.sh.
- Change: subcommands caches, pressure, observe, pages, content, browsertab, caps, rust-caps,
  rust-cache, phys, stream, pageview; each prints hits and a count. Local only.
- Acceptance: `bash -n`; scoped paths only; not in CI or hooks.
- Test: run read-only in the checkout (today caches 86, pressure 4, observe 3, pages 33, caps 34).

### 009 MemoryReport
- Files: CmuxNextMemory/MemoryReport.swift, MemoryCoordinator.swift, tests.
- Change: Codable report: per consumer name, traits, limit, footprint/volatile bytes, entries; level,
  mode, budget. O(consumers); async consumers report their last value.
- Acceptance: Codable round trip; nil bytes shows unknown, not 0.
- Test: fleet swift test MemoryReportTests.

### 010 debug.memory
- Files: CmuxNextApp/Control/DebugMemoryControl.swift, the control registration list,
  Usage/AppResourceSource.swift, tests.
- Change: Release read-only method with pressure, mode, budget, consumers, processes (kind, pid,
  phys_footprint), tabs, workspaces, terminal GPU bytes, spares, last 32 pressure changes. Async, off
  main for sampling; Release output has no URLs, titles or paths.
- Acceptance: no disk I/O or blocking on main; JSON keys as in memory-DESIGN.md; redaction tested.
- Test: fleet swift test DebugMemoryControlTests; `CMUX_TAG=mem scripts/cmux-debug-cli.sh debug.memory`.

### 011 debug.discards
- Files: CmuxNextApp/Control/DebugDiscardsControl.swift, CmuxNextHibernation/ContentDiscardPlanner.swift, tests.
- Change: rows per content (all 9 kinds): kind, visible, hidden_for, state, eligibility and reason,
  last discard reason, wake count, from the planner's last inputs.
- Acceptance: a reason whenever not eligible; the test covers all kinds.
- Test: fleet swift test DebugDiscards.

### 012 Task Manager memory saved
- Files: CmuxNextResources/TaskManager/TaskManagerModel.swift, TaskManagerRow.swift,
  TaskManagerView.swift, TaskManagerStrings.swift, Resources/Localizable.xcstrings.
- Change: discarded rows show "Discarded, saved about N MB"; footer "Memory Saver freed N MB".
- Acceptance: TypeScale fonts, no raw animation, localization audit, capture or `No capture: <why>`.
- Test: fleet swift test TaskManager; `cmux-ci capture SHA --state scene:task-manager --pr N`.

### 013 bench_memory phases
- Files: scripts/cmux-next/bench_memory.py, scripts/measure/perf-10x-idle.sh.
- Change: `--hidden-workspaces N --grace S`; `--pressure warning|critical` (released_mb, release_s,
  managed footprint before); graceful on builds without debug.memory.
- Acceptance: `python3 -I -m py_compile`; --help documents both; no budgets.json rows.
- Test: fleet exclusive bench_memory --hidden-workspaces 100 --grace 960.

### 014 memory-report.py
- Files: scripts/cmux-next/memory-report.py, scripts/measure/memory-report.sh.
- Change: footprint -j and vmmap --summary grouped by category (PartitionAlloc, DefaultMallocZone,
  IOSurface, IOAccelerator, CG image, stacks, __DATA, frameworks), joined with consumers; unattributed
  % and MQ-UNATTRIBUTED lines; also orders MQ-CACHE by bytes.
- Acceptance: python -I; works without debug.memory; table plus JSON.
- Test: fleet exclusive at Home idle and STRESS.

### 015 memory-soak
- Files: scripts/cmux-next/memory-soak.py, scripts/measure/memory-soak.sh.
- Change: 2 h STRESS churn of tabs, workspaces, splits, hibernate/wake, switches; 5-min samples per
  process kind; slopes; heap -s start/end top 30 classes as MQ-LEAK lines.
- Acceptance: python -I; exit 0 always.
- Test: fleet exclusive memory-soak.sh.

### 016 Local memory histograms
- Files: CmuxNextMemory/MemoryHistogram.swift, Control/DebugMemoryControl.swift.
- Change: bucketed local histograms (app PMF, renderer PMF total, discards per hour by kind, wake
  latency, minutes at warning and critical, WARN events per hour) in debug.memory. No upload during
  the push (risk:high telemetry deferred).
- Acceptance: no network code; buckets only; O(1) record per event.
- Test: fleet swift test MemoryHistogram.

### 017 ContentDiscardPlanner
- Files: CmuxNextHibernation/ContentDiscardPlanner.swift, CannotDiscardReason.swift, DiscardRule.swift,
  Rules/ (one file per existing exemption group), HibernationPlanner.swift, BrowserHibernation.swift
  (observe -> coordinator lossy registration), tests.
- Change: kinds of section 3.C; DiscardReason; CanDiscardResult; reasons mapped from Chrome plus cmux
  ones; protected never discarded by urgent/proactive; HibernationPlanner.plan wraps it with the same
  Pace. Rules are `DiscardRule` values, one per file, registered in one list.
- Acceptance: red commit records >= 40 browser candidate sets; plan() output identical after;
  debug.surfaces exemption raw values unchanged; BrowserHibernation's memoryPressure.observe gone.
- Test: fleet swift test 'ContentDiscardPlanner|HibernationPlanner'.

### 018 Recently audible
- Files: Rules/RecentlyAudibleRule.swift, BrowserHibernation.swift (lastAudibleAt).
- Change: protected(recentlyAudible) for 60 s after audio ends, all reasons; the deadline joins nextCheck.
- Acceptance: 30 s ago protected, 61 s eligible; no new timer.
- Test: fleet swift test ContentDiscardPlanner.

### 019 Background activity
- Files: Rules/BackgroundActivityRule.swift, BrowserHibernation.swift, TabContentCache+Omnibox.swift.
- Change: title or favicon change while hidden protects from proactive only; show clears it.
- Acceptance: proactive protected, urgent eligible, show clears.
- Test: fleet swift test ContentDiscardPlanner.

### 020 Frozen with growing memory
- Files: Rules/FrozenGrowthRule.swift, BrowserHibernation.swift.
- Change: bytes at freeze; samples at one-shot +5, +30, +120 min after freeze (3 wakeups per frozen
  page, max) and at existing planner passes; growth >= max(50 MB, 25 %) discards the whole opener group
  with frozenWithGrowingMemory. DocC cites kFreezingMemoryGrowthThresholdToDiscardKb and says the value
  is a cmux choice. Lead rule kept.
- Acceptance: growth over threshold gives due; with formInput kept; opener and popup discarded
  together; no periodic sampling.
- Test: fleet swift test 'BrowserHibernation|ContentDiscardPlanner'.

### 021 Occluded windows count as hidden
- Files: TabContentCache+Lifecycle.swift, CmuxNextDesign/Windows/WindowDrawPolicy.swift,
  BrowserHibernation.swift, Tests/CmuxNextAppTests/OccludedWindowDiscardTests.swift.
- Change: off-screen windows give hiddenSince for proactive discards. Read
  web_contents_occlusion_checker_mac.mm and copy its rules (a cmux window covered by another cmux
  window), or write in the commit why AppKit's state is enough.
- Acceptance: minimized window due after timeout, never while visible; covered-by-own-window test;
  no polling.
- Test: fleet swift test OccludedWindowDiscard.

### 022 Internal page discard framework
- Files: InternalPages/InternalPage.swift, InternalPageView.swift, InternalPageTabStore.swift,
  InternalPageTabStore+Show.swift, TabContentCache+Lifecycle.swift, tests.
- Change: provider discardPolicy (default afterHidden 10 min), keepReasons, saveViewState/restore;
  hibernate/restore effects; picture from the previews cache; behind `memory.discard.internalPages`.
- Acceptance: past policy the PageWebView weak ref is nil and scroll restores; keepReason blocks;
  one-shot deadline; red-first round-trip test.
- Test: fleet swift test InternalPageDiscard.

### 023 TopPageHost
- Files: TopPages/TopPageHost.swift, TopPages.swift, Windows/WindowController+TopPage.swift, tests.
- Change: provider discardPolicy replaces window-life keeping; TopPageViewState (scroll, search, draft);
  liveHiddenInternalPages LRU across windows.
- Acceptance: released after timeout, draft and scroll restored; LRU applies.
- Test: fleet swift test TopPageDiscard.

### 024 Page policies batch 1
- Files: InternalPage.swift, Focus/Keybindings/KeybindingsPage.swift, Pages/ChangelogPageTab.swift,
  Pages/StatsPage.swift, TopPages/WhatsNewPage.swift, Settings/SettingsWindowService.swift,
  TaskManager/TaskManagerPageService.swift.
- Change: explicit policies; keybindings keeps while recording; settings while editing; taskManager
  afterHidden 1 min (it samples while shown), saves sort and scroll.
- Acceptance: every ID explicit; coverage passes for these IDs.
- Test: fleet swift test InternalPageDiscardPolicyCoverageTests.

### 025 Page policies batch 2
- Files: TopPages/BrowserAppTopPages.swift, Passwords/PasswordsPage.swift, Stash/StashTopPage.swift,
  Tasks/TasksPageService.swift, Checklist/WorkspaceTodoPageService.swift.
- Change: passwords discarded at hide + 60 s (no revealed secret in a hidden renderer); todo keeps
  while editing.
- Acceptance: explicit policy per ID; passwords test.
- Test: fleet swift test InternalPageDiscardPolicyCoverageTests.

### 026 Page policies batch 3
- Files: Pages/FileTree/FileTreePageService.swift, FilesPane/FilesPaneService.swift,
  FileExplorer/FindPaneService.swift, Pages/Files/FilePageKind.swift, Pages/Diff/DiffPageService.swift.
- Change: editor keepReason unsavedEdits; markdown/diff save anchor and hunks; find saves query and cursor.
- Acceptance: explicit policies; dirty editor never discarded at any pressure.
- Test: fleet swift test 'InternalPageDiscardPolicyCoverageTests|EditorDiscard'.

### 027 Page policies batch 4
- Files: Pages/ChiefViewsPageTab.swift, Pages/ChiefUsagePage.swift, Handlers/ChiefMemoryPageService.swift,
  Handlers/ChiefInspectorPage.swift, Pages/HomeChannelsPage.swift, TopPages/HomePageTab.swift,
  Home/HomeDockTab.swift.
- Change: chiefMemory keeps while an edit sheet is open; homeTab/homeDock keep the draft in view state.
- Acceptance: explicit policies; draft round trip.
- Test: fleet swift test InternalPageDiscardPolicyCoverageTests.

### 028 Page policies batch 5
- Files: Apps/AppsService.swift, Apps/CodeRouterPageTab.swift, Cloud/CloudPageService.swift,
  Pages/MobilePairing/MobilePairingPage.swift, MacScreen/MacScreenPageService.swift, Phone/PhonePage.swift,
  Feed/FeedPageService.swift.
- Change: mobilePairing keeps while pairing; macScreen and phone released at hide; cloud keeps while a
  create is in flight.
- Acceptance: explicit policies.
- Test: fleet swift test InternalPageDiscardPolicyCoverageTests.

### 029 Coverage test
- Files: Tests/CmuxNextAppTests/InternalPageDiscardPolicyCoverageTests.swift,
  Control/DebugHomeNativeFixture.swift.
- Change: fails for any InternalPageID on the default policy without `// discard: default <why>`, any
  TabContent case not mapped to a kind (placeholder, notice: never, tiny), and any BrowserTab conformer
  outside Mock/Hibernated/Deferred without BrowserHibernationSource or `// discard: never <why>`.
- Acceptance: red before 024-028 and 084-085, green after; no new CI job.
- Test: fleet swift test InternalPageDiscardPolicyCoverageTests.

### 030 Conversation tabs
- Files: TabContent.swift, TabContentCache+Lifecycle.swift, CmuxNextHome/NativeTranscript/HomeNativeTranscriptView.swift, tests.
- Change: hidden past 10 min or at critical: drop laid-out rows, images, diagrams; keep index, anchor,
  draft, unread; show re-lays out about 40 rows. Behind `memory.discard.conversations`.
- Acceptance: row cache 0 after release; anchor restored; draft never lost.
- Test: fleet swift test ConversationDiscard.

### 031 Agent page live cap
- Files: Hibernation/AgentPageHibernation.swift, tests.
- Change: beyond liveHiddenAgentPages release the least recently shown eligible hidden page;
  minimumHidden 10 s; agentBusy and agentTurnsUnknown rules stay.
- Acceptance: budget 4, 6 idle pages: 2 oldest released; busy never.
- Test: fleet swift test AgentPageHibernation.

### 032 Parked workspace budget
- Files: Windows/WindowController+Parking.swift, Windows/WindowController.swift,
  AppServices+Hibernation.swift, tests.
- Change: LRU of parkedWorkspaces across windows; 15 min idle timeout through one DemandTimer one-shot;
  critical 0 through the sliced consumer (096); exempt multiView on screen and the workspace under a top
  page; WorkspaceViewRecord on teardown. Measure 12-pane remount first; if p95 > 50 ms ship LRU only.
  Behind `memory.discard.parkedWorkspaces`. PR body: `Takes back 6f04ec90105: <why>`.
- Acceptance: fake-clock LRU, timeout and pressure tests; no polling; tab-lifecycle.md matches code.
- Test: fleet swift test ParkedWorkspaceBudget; bench-tab-switch.sh before and after (light, STRESS).

### 033 WorkspaceViewRecord
- Files: CmuxNextApp/WorkspaceViewRecord.swift, WorkspaceContentController.swift, tests.
- Change: save strip and column scroll, selected tab per pane, focused pane, screen bar scroll; apply
  before the first frame commits.
- Acceptance: round trip equal; record <= 2 KB for 12 panes.
- Test: fleet swift test WorkspaceViewRecord.

### 034 Unmounted workspace leaves no objects
- Files: WorkspaceContentController.swift, tests.
- Change: fix retain paths from MQ-LEAK classes matching Workspace|Pane|Strip|Tab|Layout.
- Acceptance: weak refs to controller, layout view, pane controllers, strip views nil after teardown
  plus one run-loop turn.
- Test: fleet swift test UnmountedWorkspaceLeavesNoObjects; bench_memory hidden-workspace app delta.

### 035 Terminal last frames
- Files: CmuxNextTerminal/TerminalLastFrames.swift, TabContentCache.swift, TabContentCache+Lifecycle.swift.
- Change: keep volatile frames at the warm-set count; any non-volatile saved frame is made volatile or
  dropped; critical drops all; register lossless consumer (dataAccess none) reporting volatileBytes.
  DocC states why cmux differs from FrameEvictionManager (purgeable memory).
- Acceptance: non-volatile saved bytes 0; critical drops all; memoryUsage splits volatile bytes.
- Test: fleet swift test TerminalLastFrames.

### 036 ghostty_surface_set_gpu_resident
- Files: ghostty-next include/ghostty.h, src/apprt/embedded.zig, src/renderer/Metal.zig,
  src/renderer/metal/*, src/renderer/Thread.zig; parent submodule pointer and fork notes.
- Change: false releases swap chain, drawable pool, per-surface buffers and parks the renderer thread
  (section D says why it does not exit); keeps state and the shared atlas; true recreates before the
  next frame; release after the in-flight frame's completion handler; idempotent.
- Acceptance: cmux-ghostty skill followed (fork branch pushed first); Zig test false-then-true renders
  identical cells; no shortcut change.
- Test: fleet GhosttyKit build, ghostty unit test, `cmux-ci build cmux --ref SHA`.

### 036a ghostty-next pin bump for set_gpu_resident
- Files: `ghostty-next` gitlink, Packages/Shared/CmuxGhosttyKit/Package.swift (URL and checksum).
- Change: after ghostty-next pull request 56 merges and its GhosttyNextKit release is published, move
  the gitlink and the pin to that commit in one commit (cmux-ghostty skill: commit on main first).
- Acceptance: gitlink and pin name the same commit, reachable from ghostty-next main; the pinned
  ghostty.h declares ghostty_surface_set_gpu_resident.
- Test: fleet `cmux-ci build cmux --ref SHA`; next/ios-render-smoke.sh check gpu on the fleet.

### 037 Hidden surfaces drop GPU residency
- Files: CmuxNextTerminal/TerminalSurfaceView.swift, TerminalSession.swift, CmuxNextBridge/WarmSetBudget.swift,
  AppServices+Hibernation.swift.
- Change: outside the keep-alive band call set_gpu_resident(false) after the pause frame commits (next
  to :459); true before the first draw on show. Warm set capacity from SubsystemBudget with
  gpuResidentAvailable; capacity rises only in this commit. Warm-set pressure path becomes the sliced
  consumer (096).
- Acceptance: fake seam: hidden paused gives false, show gives true before render, keep-alive never
  called. Lands after the pin bump (036a); no symbol probe.
- Test: fleet swift test 'TerminalSurface|WarmSet'; bench_memory per terminal; bench-tab-switch.

### 039 Glyph atlas sharing
- Files: scripts/cmux-next/memory-report.py; ghostty-next only if needed.
- Change: IOAccelerator/IOSurface bytes per added visible terminal; fix per-surface atlas if found.
- Acceptance: atlas_bytes_per_extra_terminal recorded in memory-DESIGN.md.
- Test: fleet exclusive.
- Status: open, waiting on the fleet run. The measurement tool is in (`memory-report.py`), but the
  acceptance is not met: no fleet `ATLAS` line is recorded yet, and memory-DESIGN.md (task 007) is not
  on perf/chrome-parity. The fork fix is task 039a below, opened now from the source evidence.
- Measurement: `memory-report.py --phases home,atlas` (fleet: `scripts/measure/memory-report.sh
  --arg=--phases=home,atlas`; never in the same launch as `stress`, which the tool refuses: the grown
  atlas stays grown and would inflate every STRESS terminal) prints `ATLAS ...
  atlas_bytes_per_extra_terminal=N verdict=...`. It samples the GPU groups at 1..4 visible terminals
  tiling the STRESS window in a 2 x 2 grid, then shows a sheet of CJK glyphs in each, then samples again
  while the panes close (each close is checked in the topology before its sample). N is the change in
  GPU bytes per extra terminal that the atlas growth caused: 0 when shared, `unknown` when the verdict
  is `unmeasured` (the raw slope change is then only in `gpu_slope_change_bytes`).
- Sheet size: the STRESS virtual display is 1x (`scripts/ci/frame-pacing/vdisplay.m` sets
  `settings.hiDPI = 0`). At 1x and the default font a two-cell CJK glyph takes about 16 x 17 px with
  padding (about 340 px). The tool reads the window's backing scale (`debug.pane_chrome`
  windows[].scale) and sizes the sheet to 2 M px at that scale: 6,169 glyphs at 1x, 1,543 at 2x. That
  passes 1024 x 1024 (1 M px) and stays inside 2048 x 2048 (4 M px), so the grayscale atlas doubles
  twice, 512 -> 1024 -> 2048 R8, at either scale. The "did not grow" threshold is 512 KiB on one
  terminal: two thirds of the smallest real growth of a shared texture (one doubling, 1024 x 1024 -
  512 x 512 R8 = 768 KiB).
- Expected from the ghostty-next source at 723c4ab9 (no fleet number yet): per surface. The CPU atlas
  is shared: one grayscale and one color atlas per font configuration, both starting at 512 x 512
  (`src/font/SharedGridSet.zig`, `src/font/SharedGrid.zig:92`). But each surface's swap chain has
  `swap_chain_count = 3` frames (`src/renderer/Metal.zig:40`), and each frame has its own grayscale
  and color `MTLTexture` copied from that atlas (`FrameState` and `syncAtlasTexture` in
  `src/renderer/generic.zig`). So every visible terminal holds 3 copies. With the sheet above the atlas
  grows to 2048 x 2048 R8 at 1x, and the predicted value is 3 x (4 MiB - 256 KiB) = 11.25 MiB more per
  extra visible terminal. Hidden surfaces free their swap chain (`setVisible(false)`,
  `generic.zig:1321`), so the cost applies only to visible terminals. Chrome uses one glyph atlas in the
  GPU process for all renderers. Skia's `GrDrawOpAtlas`
  (third_party/skia/src/gpu/ganesh/GrDrawOpAtlas.cpp) tracks the last use of each plot with a token, so
  an upload never overwrites a region that a frame in flight still reads.
- Record: copy the fleet `ATLAS` line (host, SHA, step ID) to memory-DESIGN.md section 7. If task 007
  has not landed then, create the section 7 stub in memory-DESIGN.md with that line. Then mark 039 done.

### 039a Shared glyph atlas texture in ghostty-next (opened from 039's source evidence)
- Files: ghostty-next `src/renderer/generic.zig` (FrameState, syncAtlasTexture), `src/renderer/Metal.zig`,
  `src/font/SharedGrid.zig`; the ghostty-next submodule pointer in cmux.
- Change: one grayscale and one color atlas `MTLTexture` per atlas per device, shared by every surface,
  in place of the per-frame copies in each surface's 3-frame swap chain. Uploads track use the way
  Skia's `GrDrawOpAtlas` does: each region records the token of the last frame that drew from it, and a
  frame in flight never sees a region overwritten (a grow makes a new texture; the old one is freed when
  the last frame that read it completes).
- Acceptance: the fleet `ATLAS` line reads `verdict=shared` with `atlas_bytes_per_extra_terminal` near
  0, against about 11.25 MiB before; no glyph corruption with 4 visible terminals drawing the 039 sheet.
- Test: ghostty-next renderer tests for the use tokens; fleet exclusive `memory-report.sh
  --arg=--phases=home,atlas` before and after.
- Depends on: 039's fleet run confirming `verdict=per_surface` (the source already predicts it).

### 040 Cold-scrollback codec (gated by 112)
- Files: cmux-tui/crates/ghostty-vt/src/cold_pages.rs, lib.rs, tests/cold_pages.rs.
- Change: only if 112 shows a gain over the kernel compressor >= 2x: serialize pages with the deflate
  in deps and restore exactly.
- Acceptance: round trip on terminal_corpus and kitty fixtures; ratio >= 8x; SAFETY notes.
- Test: fleet cargo test -p ghostty-vt cold_pages.
- Measured against libghostty-vt's own page compression (`ghostty_terminal_compress`, FULL; LZ4 per
  history page, restored on access), filled 10 MB scrollback at 120x40, release build on Linux
  (`cold_pages_compare_with_native_page_compression`, 2026-10-26):

  | Content | Live resident | Native resident (compressed part) | Codec held | Codec over native |
  | --- | --- | --- | --- | --- |
  | terminal corpus text | 9.67 MB | 1.01 MB (0.61 MB) | 0.21 MB | 4.9x |
  | varied log lines | 9.63 MB | 2.18 MB (1.78 MB) | 0.39 MB | 5.6x |

  Native: compress 5-9 ms, viewport read 30-40 us, full history read 11-13 ms. Codec: freeze
  50-90 ms, thaw 9-10 ms, and nothing reads the terminal while cold. The codec passes the 2x bar over
  native, so it stays; 112 must still show it against WKdm. Native compression keeps the terminal
  live (no thaw, tracked points and instance kept, no Kitty refusals), so 041 should run it at the idle
  step and freeze with this codec only at the cold deadline.
- Kitty limit: libghostty-vt reads only the active screen's Kitty state and its replay encoder sends
  only placements that show, so the codec refuses an image on the inactive screen, a placement only
  in scrollback and an image without a placement (cheap checks before any encode). Removing these
  refusals needs a ghostty-next change: an encoder mode that sends every image with pixels and every
  placement (scrollback pins included) and counts what it dropped. Follow-up, not done in 040.

### 041 Compress cold scrollback (gated by 112)
- Files: cmux-tui-core/src/surface.rs, mux cold policy module, surface/tests/cold_scrollback.rs.
- Change: for terminals without full-mode segments: no viewer and no output for cold_scrollback_after
  compresses at utility priority; one deadline per mux; attach/read/search/resize/output decompress
  first. Never compress at warning (it reads possibly swapped pages).
- Acceptance: read-scrollback byte-identical; idle_wakeups green.
- Test: fleet cargo test -p cmux-tui-core cold_scrollback; idle_wakeups.

### 042 cmux-memory leaf crate
- Files: cmux-tui/crates/cmux-memory/{Cargo.toml, src/lib.rs, src/pressure_macos.rs,
  src/pressure_linux.rs}, cmux-tui/Cargo.toml, cmux-tui-core/src/memory.rs,
  cmux-tui-core/src/mux/terminal_work/standby_host.rs.
- Change: libc-only crate: registry (name, lossless/lossy, bytes fn, release fn), macOS source moved
  from standby_host.rs (re-reads the sysctl, initial read, change-only), Linux PSI trigger
  ('some 150000 1000000', POLLPRI). Standby host is the first consumer.
- Acceptance: `rg -l _dispatch_source_type_memorypressure cmux-tui/crates` lists only
  pressure_macos.rs; Linux fake-fd test; no tokio; no thread per consumer.
- Test: fleet cargo test -p cmux-memory (macOS and Linux builder); cargo test -p cmux-tui-core standby_host.

### 044 Daemon memory-report
- Files: cmux-tui-core/src/server/memory_report.rs, control dispatch, cmux-tui-platform/src/process_resources.rs.
- Change: per-terminal scrollback live/compressed bytes, holder ring bytes, kitty bytes, consumers,
  footprint; read-only, owner-only, denied on relays.
- Acceptance: socket test with 3 terminals; owner check.
- Test: fleet cargo test -p cmux-tui-core memory_report.

### 045 renderer-process-limit
- Files: CmuxNextBrowser/CEF/CEFSwitches.swift, CEF/ChromiumHost/ChromiumHostConfiguration.swift, tests.
- Change: `renderer-process-limit=<chromiumRendererLimit>` in both process models; value passed in.
- Acceptance: 4 GB 16, 8 GB 32, 16 GB 64, 32 GB 82; switch present in both models.
- Test: fleet swift test CEFSwitches; bench_renderer_sharing with a forced limit of 6.

### 046 Renderer sharing with DevTools
- Files: CmuxNextChromiumRuntime/ChromiumRuntimePin.swift (through 074), CEF/CEFSwitches.swift.
- Change: rendererPaths turns on cmux-process-reuse-per-renderer-devtools when the fork API >= 29.
- Acceptance: <= 2 same-site main frames per renderer with an agent CDP session open.
- Test: fleet scripts/measure/renderer-sharing.sh.

### 047 Spare pools key on pressure level
- Files: NewTab/NewTabSparePool.swift, CmuxNextPages/PageHostPool.swift, PageHostPool+Build.swift,
  CEF/CEFSpareWindow.swift, CmuxNextChromiumWarmup/ChromiumWarmup.swift.
- Change: replace memoryPressure.observe with a lossy registration; no spare at warning or critical,
  no refill until normal (Chrome's spare rule); normal keeps one spare in every mode.
- Acceptance: MQ-OBSERVE 0 in these files; PageHostPoolMemoryPressureTests adapted; test: medium mode
  at normal keeps one spare; no refill at warning.
- Test: fleet swift test 'PageHostPool|NewTabSpare|ChromiumWarmup'.

### 048 No cmux page renderer before first show
- Files: CmuxNextPages/PageWebView.swift, PageHostPool+Build.swift, each MQ-PAGEVIEW site made before show.
- Change: pages made at launch or prewarm for unshown pages become lazy under a stand-in, both engines.
- Acceptance: debug.memory at Home idle shows Chromium renderers and WebKit WebContent equal to visible
  pages; a test per change asserts no PageWebView before the show event.
- Test: fleet bench_memory Home row; swift test PageLaziness.
- As built (differs from the change above): the PageWebView is made at open, as before; what
  waits for the first show is its renderer. Until then the view makes no engine call: no load, no
  script, no function call or picture, so WebKit launches no WebContent process and no Chromium page
  is asked for. This is Chrome's split for a tab that has not shown: the WebContents exists, its
  renderer starts at `WasShown` (`NavigationControllerImpl::SetNeedsReload`, `LoadIfNecessary`).
  A stand-in would give the 23 MQ-PAGEVIEW callers, which set routes, handlers and appearance on
  the returned view at once, a type that is not the page. "Shown" is the page's node in the
  visibility tree: its tab's node once a pane shows it (tab, pane, workspace, window, app), else
  its window's node (occlusion and minimize included); a page with no tab node counts by its
  window and its own `isHidden`, not by a walk of its ancestors. The acceptance test is therefore "no
  renderer, no engine call before the show event" (PageLazinessTests: no load, no script at the
  bridge, `_webProcessIdentifier` 0, no Chromium page). The in-app cost of an unstarted
  PageWebView (WKWebView with no process, its configuration and user scripts, router, bridge) is
  not measured yet; the fleet bench_memory Home row with and without `pageRendererAtFirstShow`
  measures it.

### 049 One Chromium renderer for cmux pages
- Files: cef-cmux fork (ShouldUseProcessPerSite for the page scheme behind
  cmux-page-scheme-process-per-site), CEF/CEFSwitches.swift, CEFShim/src/shim_client.mm.
- Change: cmux pages share one renderer when the fork API reports it.
- Acceptance: Home with 3 cmux pages shows 1 renderer; a page crash reloads all (PageCrashReloads).
- Test: fleet bench_memory Home; cmux-ci build.

### 050 Chromium host idle exit
- Files: CEF/ChromiumHost/*, CmuxNextChromiumWarmup/ChromiumWarmup.swift.
- Change: with F2, no live Chromium page for 5 min exits the host; restart under a stand-in.
- Acceptance: fake host exit and restart; kqueue watch, no orphan.
- Test: fleet bench_memory first-Chromium-tab row reaches 0 after the deadline.

### 051 cmux MemoryPressureVoter into Chromium
- Files: cef-cmux fork (cmux_memory_pressure_vote via MultiSourceMemoryPressureMonitor::CreateVoter),
  CEFShim/src/shim_process.mm, CEF/CEFEngine.swift, memory-DESIGN.md.
- Change: one cmux-owned voter; the coordinator votes override and level; NONE when the override
  clears; no direct NotifyMemoryPressure. Signpost Chromium listener time on main.
- Acceptance: version-gated; one vote per change; DC2 names the Chromium source.
- Test: fleet bench_memory --pressure critical: renderer PMF falls and stays down after a kernel
  NORMAL event while the override holds; listener time and coordinator slices in separate turns.

### 052-057, 059, 060 Cache batches
- Files: as listed in the reviewed design: 052 CmuxNextTabs (TabUserIcon, TabThumbnailCache,
  TabSymbolCache, TabPackIconCache, TabAgentMarkCache); 053 CmuxNextDesign (NativeSpinnerImage,
  BrailleSpinnerImage, ChromeLabel, ChromeTextLayer, BackdropImageStore); 054 CmuxNextSidebar
  (SidebarEmojiGlyphView, SidebarGroupLineViews, SidebarGlyphInk, SidebarDocProjectionCache); 055
  Browser (BrowserContextMenuImages, ExtensionIconCache, ExtensionManifestCache, FaviconLoader,
  BrowserCore LRUCache, CEFOmniboxKeywords, CEFSpareWindow, WebKitDownloads); 056 App part 1
  (AgentPaneLaunchImages, SidebarAccount, MuseumArtSession, ScreenEmojiIcon, RightSidebarSections,
  IconAssetImages); 057 App part 2 (SettingsBackdropThumbnails, AppsGlyphResource,
  NotificationCenterService+ProgramStatus, SpaceSectionsCache, WindowManager, TabContentCache); 059
  FilesUI FileIconProvider, FileGrid ThumbnailCache, Apps AppSceneBundleImage, Home
  HomeRecipientAvatarView, HomeEngine HomeAttachmentCache, HomeSidebarLaunchCache; 060 AgentPane
  (NewTabFrame, TailCache, ProjectIcon), PaletteLayout, LinkMenuAppCache, QRCodeImage,
  ImportAppIconCache, ScreenContentView+Dock, GhosttyHostKeybinds, ControlWorkspaceInfoCache,
  ControlIdempotencyCache, LoginEnvironmentCache, LegacyChannelSession. Each batch also adds its lines
  to AppServices+Memory.swift.
- Change: each cache registers a consumer (bytes, limit-scaled bound, release) or carries
  `// memory: fixed <proof of bounded keys>`; value-type caches register through their owner; actor
  caches use AsyncMemoryConsumerRegistration (108); each batch says which registration each file uses.
  Batches start in byte order from 014.
- Acceptance: MQ-CACHE prints none of the batch files; per consumer: limit 0 holds 0 entries and a hit
  after release recomputes; no fixed mark on a cache > 1 MB at STRESS. Split 060 if > 400 lines.
- Test: fleet swift test for each package's tests.

### 058 Preview, thumbnail, snapshot caches
- Files: CmuxNextBridge/PreviewImageCache.swift, TabContentCache.swift, Hibernation/HibernationSnapshots.swift,
  Hibernation/BrowserHibernation+Restore.swift.
- Change: previews and thumbnails take shares of imageCacheBytes; snapshots take
  hibernationSnapshotBytes and keep neighbors and the N most recent pictures; all register (snapshots
  released last, recreateCost expensive).
- Acceptance: MQ-CAPS 0 in these files; limit 50 % halves capacity; limit 0 empties previews and keeps
  only neighbor snapshots; 16 GB shares >= old literals.
- Test: fleet swift test 'PreviewImageCache|HibernationSnapshots'; bench_hibernation picture count unchanged.

### 061 MediaRemoteAdapter on first need
- Files: CmuxNextNowPlaying/MediaRemoteAdapter.swift, SystemNowPlaying.swift.
- Change: start on first Now Playing surface or media playback; stop 60 s after unneeded (one-shot).
- Acceptance: fake launcher: no launch at init, launch on need, stop after deadline.
- Test: fleet swift test NowPlaying; bench_memory Home process list without perl.

### 062 Other launch helpers on first use
- Files: per MQ-PROC hit (sh wrappers, cmux-agent-screen-detection x2, open/save panel and QuickLook
  XPC prewarm sites).
- Change: start on first use, stop after unused; one PR per kind.
- Acceptance: kind gone from Home idle list; test asserts no launch at start.
- Test: fleet bench_memory --workspaces 1 --top 50 before and after.

### 063 Leftover daemons idle exit
- Files: cmux-tui/crates/acpmux daemon lifecycle, cmux-tui headless server lifecycle.
- Change: exit after 10 min with no client, no live agent, no live PTY (own or holder-owned) and no
  owning app; behind a default-off setting; update path reconnects within the grace.
- Acceptance: fake clock: exit after grace; stay with a client, a live agent or a live PTY.
- Test: fleet cargo test -p acpmux idle_exit; cargo test -p cmux-tui idle_exit.

### 064 acpmux per-session budget
- Files: acpmux session state, scripts/measure/acpmux-overhead.sh.
- Change: profile 100 fake streaming agents; trim per-session state to transcript tail plus state
  (about 1 MB); register trims (through 091).
- Acceptance: acpmux <= 2 MB per agent at 100 agents; test bounds per-session bytes.
- Test: fleet exclusive acpmux-overhead.sh.

### 065 memory.saver setting and Debug toggles
- Files: CmuxNextSettings setting definitions and Localizable.xcstrings, app actions
  (memory.saver.off|conservative|medium|aggressive via registry.bindEffect), AppServices+Hibernation.swift.
- Change: memory.saver (default medium) drives mode and the timeouts of new kinds; browser.hibernation
  stays the browser override; Debug toggles `memory.discard.<kind>` (default off) for internal pages,
  top pages, conversations, parked workspaces, sidebar sections, cmux page tabs, remote tabs, terminal
  GPU release.
- Acceptance: generated schema files not hand-edited; localization audit; actions return .done < 10 ms.
- Test: fleet swift test 'MemorySaverSetting|Settings'.

### 066 macOS 14/15 run
- Files: none.
- Change: coordinator, kernel source, hibernation, purgeable IOSurface, parked suites and a wake in Tart.
- Acceptance: pass on 14 and 15, written in the PR.
- Test: scripts/cmux-next/os-matrix.sh --build JOB --os 14,15.

### 067 Done-check run
- Files: plans/cmux-next/perf-lead.md, memory-DESIGN.md.
- Change: run DC1-DC18 (light and STRESS, same base A/B as 075) and record numbers, host, SHA, steps.
- Acceptance: every DC has a number or an Observed / Not run reason.
- Test: fleet exclusive runs of section 5.

### 068 Kernel source: sysctl re-read, initial level, kernel bench
- Files: CmuxNextCompat/KernelMemoryPressureSource.swift, MemoryPressureEvents.swift,
  Tests/CmuxNextCompatTests/KernelMemoryPressureSourceTests.swift, scripts/cmux-next/bench_memory.py.
- Change: ignore `source.data`; read `kern.memorystatus_vm_pressure_level` (1/2/4) through an injected
  reader on each event and at start; deliver only on change; add `currentLevel`. Add
  `bench_memory.py --kernel-pressure warn|critical` (`/usr/bin/memory_pressure -S -l`), degrading with
  a message when it needs root.
- Acceptance: handler does not read `source.data`; tests: coalesced data with sysctl 1 gives normal;
  initial 4 gives critical before any event; repeated level no delivery; no timer.
- Test: fleet swift test KernelMemoryPressureSource; one exclusive --kernel-pressure critical run.

### 069 Release sink
- Files: CmuxNextMemory/MemoryReleaseSink.swift, MemoryCoordinator.swift, CmuxNextMallocZone/early_zone.c
  (PA purge entry if present), tests.
- Change: slices only unlink; a utility-QoS serial queue drops the last references; after a critical
  pass one `malloc_zone_pressure_relief(nil, 0)` there and the PA purge where available; DC10 counts
  footprintBytes only.
- Acceptance: deinit probe never runs on main; one relief per escalation to critical, none at a repeated
  level or warning.
- Test: fleet swift test MemoryReleaseSink; bench_memory --pressure critical.

### 070 Working set and hysteresis
- Files: CmuxNextMemory/MemoryCoordinator.swift, CmuxNextCompat/Memory/MemoryLimit.swift, tests.
- Change: entries used in the last 2 s stay; limits rise only after 30 s at normal (one-shot).
- Acceptance: 20 flaps in 60 s give <= 1 release pass per consumer; a recently used entry is never
  released at warning; no periodic timer.
- Test: fleet swift test MemoryCoordinatorHysteresis; anim sidebar run with override flaps (DC17).

### 071 Hidden-app release budget
- Files: CmuxNextMemory/MemoryCoordinator.swift, tests.
- Change: no visible cmux window: 8 ms slices back to back on main-queue turns; input returns 2 ms.
- Acceptance: hidden mode releases a 500-entry consumer in < 1 s fake time; visible keeps 2 ms; no timer.
- Test: fleet swift test MemoryCoordinatorHiddenApp; bench_memory --pressure critical with app hidden.

### 072 Daemon scrollback total from RAM
- Files: cmux-tui-core/src/output_store/memory_budget.rs, output_store.rs, memory.rs, tests.
- Change: default maxTotalMemoryBytes from DaemonBudget; register: warning lowers to 50 % LRU-first,
  critical to the 16 MiB floor; segments are the cold store in full mode; normal restores below 80 %.
- Acceptance: warning lowers LRU-first, normal restores under 80 %; writer thread only; idle_wakeups green.
- Test: fleet cargo test -p cmux-tui-core memory_budget.

### 073 Daemon kitty storage share
- Files: ghostty-vt/src/terminal.rs, render.rs, kitty.rs, cmux-tui-core/src/mux/kitty_budget.rs,
  cmux-tui-core/src/surface.rs.
- Change: one process-wide kitty total (DaemonBudget.kitty_total); over it, lower
  set_kitty_image_storage_limit of the least recently shown terminals; register both pixel maps for
  clear on critical (`clear_kitty_graphics_cache`).
- Acceptance: 50 terminals x 10 MB stay under the total; most recent keeps its images; visible
  placements render.
- Test: fleet cargo test -p cmux-tui-core kitty_budget; cargo test -p ghostty-vt kitty.

### 074 One shared CEF fork build and pin bump
- Files: CmuxNextChromiumRuntime/ChromiumRuntimePin.swift, the runtime pack metadata, perf-lead.md.
- Change: collect fork changes from every program (p07: 046, 049, 051, 101, 111, PA purge; F1; F2) into
  one build and one pin; start at hour 0; one R2 upload request.
- Acceptance: one pin commit lists fork API, features per program and checksum; no other pin bumps.
- Test: fleet cmux-ci build cmux --ref SHA; scripts/measure/renderer-sharing.sh.

### 075 Hour-0 baseline
- Files: plans/cmux-next/perf-lead.md (run only for scripts).
- Change: run bench_memory (Home idle, --tabs 60 --urls local, heavy), bench_hibernation,
  bench_renderer_sharing, acpmux-overhead at the base SHA on reserved exclusive minis; log WARN events
  per hour on two fleet hosts for 24 h through the existing pressure log.
- Acceptance: F8 row has base numbers with host, SHA, step IDs before any p07 source change lands.
- Test: fleet exclusive at base.

### 076 Socket and relay policy for memory methods
- Files: Control/DebugMemoryControl.swift, Control/DebugDiscardsControl.swift,
  cmux-tui-core/src/server/memory_report.rs, tests.
- Change: classify in socket policy (off-main parse, no focus change); deny over any remote relay;
  local owner only; Release redaction.
- Acceptance: policy tests (relay denied, owner allowed, redaction); PR has the relay analysis.
- Test: fleet swift test DebugMemoryPolicy; cargo test -p cmux-tui-core memory_report.

### 077 AppServices+Memory.swift
- Files: CmuxNextApp/AppServices+Memory.swift, AppServices.swift.
- Change: one `registerMemoryConsumers()` call in AppServices; one sorted line or small function per
  package.
- Acceptance: exactly one call in AppServices.swift; later batches touch only this file and their package.
- Test: fleet cmux-ci build cmux --ref SHA.

### 078 App threads per hidden surface
- Files: scripts/cmux-next/bench_memory.py, CmuxNextTerminal/TerminalSurfaceView.swift.
- Change: report app threads per hidden terminal; check that a GPU-released surface's renderer thread
  parks (036): it stays, with no wakeups while idle.
- Acceptance: bench reports threads per hidden terminal before and after; a GPU-released surface's
  renderer thread has 0 wakeups while idle once its compression timer is armed.
- Test: fleet exclusive bench_memory --workspaces 60.
- Status: bench side in. Every sample counts threads per process kind and owner; each --workspaces count
  gives app threads per added terminal; `--hidden-workspaces N --gpu-release off|on` gives app threads per
  hidden terminal after --settle and after the grace, and how many hidden renderer and IO threads woke in
  `--thread-window` idle seconds (a thread whose CPU time grew woke). A hidden terminal is told apart from
  a shown one by thread identity: its threads are the ones new since the phase's base read, a handle
  counting as the same thread only under the same name (a thread handle is a pthread address that a
  later thread can reuse). `--gpu-release` sets the debug tunable `memory.discard.terminalGPURelease` in
  a tunables file named by `CMUX_NEXT_DEBUG_TUNABLES_FILE`, so the run needs a bench build of a .dev or
  .debug bundle. Swift: a parked terminal no longer takes scale and display calls on a backing change
  (they wake its renderer thread); it applies them when shown. Open: the fleet run, which needs the 036a
  pin for the "on" half.

### 079 Widen the static queues
- Files: scripts/cmux-next/memory-queues.sh, plans/cmux-next/memory-DESIGN.md.
- Change: MQ-CACHE union with Shared paths; MQ-CAPS, MQ-RUST-CAPS, MQ-RUST-CACHE, MQ-BROWSERTAB,
  MQ-STREAM as in section 6.
- Acceptance: caches prints 86 (or current); every example file (RowBitmaps.swift, RowDrawing.swift,
  OndineMermaidRenderer.swift, terminal.rs:391) appears; local only.
- Test: run read-only and paste counts.

### 080 CmuxHomeRender caches
- Files: Packages/Shared/CmuxHomeRender/Sources/CmuxHomeRender/Drawing/RowBitmaps.swift,
  Media/MediaStore.swift, Transcript/MeasureCache.swift, Public/HomeController.swift,
  CmuxNextHome/HomeRenderMemoryConsumer.swift, Packages/Shared/CmuxHomeRender/Tests/CmuxHomeRenderTests/RowBitmapTests.swift.
- Change: engine-neutral `memoryBytes`, `trim(toFraction:)`, `releaseHidden()`; maxBytes from the caller;
  one lossless consumer per live controller (large, cheap); budget from homeRenderBitmapBytes; hidden
  transcript trims to 0.
- Acceptance: MQ-CAPS 0 in RowBitmaps.swift; trim 0.5 leaves half, 0 leaves 0, later request
  re-renders; iOS still builds.
- Test: fleet swift test CmuxHomeRender and the CmuxNextHome consumer test; bench_memory Home row.

### 081 MessagesLab big caches
- Files: Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/RowDrawing.swift,
  MediaCache.swift, TiledBubble.swift, MessagesLabSidebar/Vendor/appkit-native/SidebarDrawing.swift,
  MessagesLabHome/Cmux/HomeMarkdownLineCache.swift, CmuxNextHome/HomeRenderMemoryConsumer.swift.
- Change: setBudget(bytes:), trim(toFraction:), bytes on each; one consumer group with shares of
  homeRenderBitmapBytes; trim to 0 when no Home window shows for 60 s (DemandTimer one-shot); lab flags
  still override.
- Acceptance: MQ-CACHE prints none; limit 0 holds 0 bytes; later draw has an equal bitmap hash.
- Test: fleet swift test CmuxMessagesLab and CmuxNextHome; bench_memory Home idle after Home use.

### 082 OndineMermaidRenderer
- Files: CmuxNextHome/NativeTranscript/Diagrams/OndineMermaidRenderer.swift, tests.
- Change: byte-capped LRU for images, entry cap for renders; warning drops images; critical or 10 min
  without a diagram drops the JSContext; prewarm only when a transcript holds a mermaid block.
- Acceptance: 1,000 sources stay under cap; context nil after critical; next layout gives the same size.
- Test: fleet swift test OndineMermaidMemory.

### 083 Small missed app stores
- Files: CmuxNextTerminal/TerminalLaunchFrames.swift, CmuxNextApp/AgentTabs+LaunchImages.swift,
  CmuxNextDesign/GlassLens/GlassBackdropImages.swift, CmuxNextUpdater/ReleaseNotes/ReleaseMediaStore.swift,
  CmuxNextTerminal/GhosttyRuntime+ImageStorage.swift.
- Change: launch frames and images dropped after LaunchSettle; GlassBackdropImages and ReleaseMediaStore
  register; image-storage-limit from kittyImageBytesPerSurface, lowered at warning.
- Acceptance: 0 images after LaunchSettle; MQ-CAPS 0 in GhosttyRuntime+ImageStorage.swift; bytes reported.
  The Ghostty image budget is not a consumer, so "bytes reported" does not apply to it: libghostty reports
  no image bytes, and the budget is a cap Ghostty enforces, not a store cmux releases. It follows the
  coordinator's level (`GhosttyImageStorageBudget`) and rises only after `limitRiseDelay` at normal.
- Test: fleet swift test 'TerminalLaunchFrames|GlassBackdrop|ReleaseMedia'.

### 084 cmux page browser tabs discardable
- Files: CmuxNextBrowser/Engine/BrowserHibernationSupport.swift, History/HistoryPageTab.swift,
  Bookmarks/BookmarkPageTab.swift, Vault/VaultPageTab.swift, Screenshots/ScreenshotsPageTab.swift,
  AgentActivity/AgentActivityPageTab.swift, tests.
- Change: conform to BrowserHibernationSource (cmux:// URL, rebuild on restore, view state via 022);
  AgentActivity stops its model on discard. Behind `memory.discard.pageTabs`.
- Acceptance: per type: becomes HibernatedBrowserTab, old contentView weak ref nil, same URL and scroll
  on show.
- Test: fleet swift test PageBrowserTabDiscard; bench_hibernation one tab per type.

### 085 Remote view tabs
- Files: CmuxNextRemoteViewSessions/RemoteViewPageTab.swift, CmuxNextRemoteBrowser/Tab/RemoteBrowserTab.swift,
  RemoteView/MachineBrowserPageTab.swift, BrowserHibernationSupport.swift, tests.
- Change: pause the stream at hide (no hidden decode); past the timeout or at critical discard to a
  HibernatedBrowserTab with the last frame; reconnect on show.
- Acceptance: fake transport: hide stops frames within one turn; decoder weak ref nil after discard;
  last frame in the first draw; MQ-BROWSERTAB empty after 084 and 085.
- Test: fleet swift test RemoteTabDiscard.

### 086 Overlay and prewarmed pages
- Files: IconPicker/IconPickerService.swift, Pages/UpdateSurfaceIsland.swift,
  CmuxNextBrowser/UI/ExtensionsMenu/ExtensionsMenuController.swift, CmuxNextDesign/MadeAheadPanelStore.swift, tests.
- Change: ContentKind.overlayPage: release 5 min after close or at warning (lossy, recreate expensive);
  prewarm only after first use in a session.
- Acceptance: after close plus deadline isWarm false and page weak ref nil; next open works (timed by
  IconPickerOpenTiming); no icon-picker page at Home idle.
- Test: fleet swift test OverlayPageRelease; bench_memory Home WebContent count.

### 087 WebKit cmux pages share process groups
- Files: CmuxNextAgentPane/WebProcessGroups.swift (moved to CmuxNextPages/WebProcessGroups.swift),
  CmuxNextPages/PageWebView.swift, PageWebView+Pooled.swift, CmuxNextAgentPane/AgentPaneView.swift.
- Change: one group for trusted cmux pages per data store; size from webProcessPagesPerGroup.
- Acceptance: second page gets the first as related view; other data store starts a new group; MQ-CAPS
  0 in WebProcessGroups; crash reloads the group.
- Test: fleet swift test WebProcessGroups; bench_memory Home with browser.defaultEngine=webkit.

### 088 WebKit same-site reuse above the limit
- Files: CmuxNextBrowser/WebKit/WebKitEngine.swift, WebKit/WebKitTab.swift, tests.
- Change: at or above chromiumRendererLimit live WebKit processes, a new same-site tab gets a live tab as
  _relatedWebView; never mixes sites or profiles; old behavior when the SPI is missing.
- Acceptance: under limit no related view; over limit same-site related, cross-site not; incognito never
  relates to non-incognito.
- Test: fleet swift test WebKitProcessReuse; bench_renderer_sharing.py --engine webkit --tabs 60 --sites 10.

### 089 DaemonBudget
- Files: cmux-tui/crates/cmux-memory/src/budget.rs, cmux-tui-core/src/surface.rs, surface/options.rs.
- Change: for_memory(hw.memsize) with scrollback_total, cold_scrollback_after, kitty_total,
  holder_ring_bytes; per-terminal maximums become fields.
- Acceptance: literal table at 8/16/32/64/128 GB; read-scrollback under the total byte-identical.
- Test: fleet cargo test -p cmux-memory budget; cargo test -p cmux-tui-core scrollback.

### 090 SQLite trim
- Files: cmux-tui-core/src/workspace_registry/registry_connection.rs, conversation_store.rs,
  chief_registry.rs, apps/storage.rs, cmux-history/src/visits.rs, search_index.rs,
  CmuxNextHistory/HistorySQLite.swift.
- Change: long-lived connections register lossless consumers; warning and critical call
  sqlite3_db_release_memory on the owning thread, never under a request lock.
- Acceptance: after a 10k-row query SQLITE_DBSTATUS_CACHE_USED near 0 after release; thread asserted.
- Test: fleet cargo test -p cmux-tui-core sqlite_trim; swift test HistorySQLite.

### 091 acpmux consumers and status memory
- Files: acpmux/src/hub/pool/auth.rs, live_models/mod.rs, login_env.rs, tui/render/cache.rs,
  host_pressure.rs, daemon_status.rs.
- Change: register caches with cmux-memory; warning empties lossless ones; critical trims sessions to
  their tail; `daemon status` memory section (footprint, consumers, top 20 sessions).
- Acceptance: fake source: warning empties caches; status shows bytes; daemon_idle test green.
- Test: fleet cargo test -p acpmux memory; daemon_idle.

### 092 Subsession and secret MCP in the daemon
- Files: acpmux/src/subsession_mcp.rs, agent_tools.rs, agent_host/mod.rs, tests/agent_tools.rs.
- Change: serve both tool sets from the daemon scoped by the session credential; stdio harnesses get a
  byte-copy relay (no tokio, < 1 MB).
- Acceptance: tools listed and called through the daemon; other session's credential refused; 20 fake
  agents drop 2 processes each; relay <= 1 MB.
- Test: fleet cargo test -p acpmux agent_tools; exclusive acpmux-overhead.sh.

### 093 One MCP catalog per Mac
- Files: cmux-tui/src/cli/mcp.rs, cli/mcp/upstream.rs, cli/mcp/transport.rs, tests/mcp_footprint.rs.
- Change: catalog in the daemon once; per-agent process is a stdio relay.
- Acceptance: mcp_footprint budget 10 MB to 2 MB; tools/list equal for the 1051-action fixture.
- Test: fleet cargo test -p cmux-tui mcp_footprint.

### 094 Holder ring release
- Files: cmux-tui/crates/cmux-holder/src/ring.rs, holder.rs, cmux-tui-core/src/holder_runtime/sink.rs.
- Change: after ack and cold time, madvise(MADV_FREE_REUSABLE) on the confirmed part; ring size from
  holder_ring_bytes; no wire change (std + libc).
- Acceptance: write 1 MiB, ack, cold: footprint drops >= 900 KiB; holder crash replay loses no byte;
  RING_VERSION unchanged.
- Test: fleet cargo test -p cmux-holder; holder_terminals on macOS 26 and 27.

### 095 Daemon threads per terminal
- Files: cmux-tui-core/src/surface/spawn.rs, surface.rs, mux/terminal_work.rs.
- Change: PTY reads on the kqueue TerminalWorkPool; one EVFILT_PROC watcher for child waits; the host
  thread joins the pool. Check the threading and PL-daemon queues first.
- Acceptance: 50 terminals add <= 2 threads; idle_wakeups green; output order unchanged.
- Test: fleet cargo test -p cmux-tui-core surface; perf-10x-idle.sh counts=100 thread column.

### 096 Sliced release of parked workspaces and warm set
- Files: Windows/WindowController+Parking.swift, AppServices+Hibernation.swift, TabContentCache.swift, tests.
- Change: both become consumers whose releaseMemory(within:) does one teardown or one surface close per
  slice; hidden before visible-adjacent.
- Acceptance: 150 parked and 30 warm at critical: <= 1 teardown per slice, all released within N
  slices; no turn > 4 ms from release.
- Test: fleet swift test SlicedRelease; bench_memory --pressure critical with a 150 ws STRESS session.

### 097 Occluded windows: GPU release and Chromium hide
- Files: CmuxNextTerminal/TerminalSurfaceView.swift, CmuxNextDesign/Windows/WindowDrawPolicy.swift,
  CmuxNextBrowser/CEF/CEFTab+Freeze.swift, tests.
- Change: visible terminals in a window off screen 30 s release GPU residency; back before first draw;
  hidden Chromium pages in occluded windows get the Page lifecycle hide at once.
- Acceptance: fake seams: off screen 30 s gives false, visible gives true before render; minimized window
  of 6 terminals gives hidden_nonvolatile_iosurface_bytes 0.
- Test: fleet swift test OccludedGPUResidency; bench_memory with a minimized window.

### 098 Unbounded AsyncStreams
- Files: CmuxNextTerminal/LocalPTYTerminalIO.swift, TerminalSession.swift,
  CmuxNextDaemon/Connection/DaemonConnection.swift, RemoteView/MachineLoopbackCarrier.swift,
  CmuxNextDaemon/Loopback/LoopbackStream.swift, CmuxNextControl/ControlConnection.swift,
  CmuxNextRemoteView/Transport/RemoteRdStreamTransport+Service.swift, CmuxNextPopups/WebAuth/WebAuthSessionHandler.swift.
- Change: byte bound with backpressure to the producer (stop reading the fd or socket) or
  `// memory: bounded-by <limit>`.
- Acceptance: MQ-STREAM clean; flood test per bounded site: stalled consumer and 100 MB producer stay
  under the bound with no lost byte.
- Test: fleet swift test 'LocalPTYTerminalIO|DaemonConnection|MachineLoopback'.

### 099 InternalPageTabStore weak windows
- Files: InternalPages/InternalPageTabStore.swift, tests.
- Change: weak box for windows (line 18); look up again when needed.
- Acceptance: red first: close a second window with a page tab, one run-loop turn, WindowController weak
  ref nil; theme scope still resolves for live windows.
- Test: fleet swift test InternalPageWindowRetention (red on base, green after).

### 100 Right sidebar sections and dock modes
- Files: RightSidebar/RightSidebarView.swift, CmuxNextHome/Dock/HomeDockSwitchView.swift, tests.
- Change: ContentKind.sidebarSection: hidden 10 min or hidden at critical releases with a view-state
  record; shown section never released. Behind `memory.discard.sidebarSections`.
- Acceptance: weak ref nil after 10 min fake clock; scroll and expanded rows restored; one-shot.
- Test: fleet swift test RightSidebarSectionRelease.

### 101 BFCache flush for hidden tabs
- Files: cef-cmux fork (cmux_flush_back_forward_cache), CEFShim/src/shim_client.mm,
  CEF/CEFTab+Freeze.swift, Hibernation/BrowserHibernation.swift.
- Change: flush at freeze and for every hidden tab at warning; no-op on old forks.
- Acceptance: shim fake: one flush per freeze and per hidden tab at warning, none for visible.
- Test: fleet swift test CEFTabFreeze; bench_memory --tabs 20 navigate-5 phase.

### 102 JS heap report per page
- Files: scripts/cmux-next/page-heap-report.py, scripts/measure/page-heap-report.sh.
- Change: per PageDescriptor: Runtime.getHeapUsage and a heap summary over CDP, WebContent footprint for
  WebKit; MQ-JSHEAP lines.
- Acceptance: python -I; exit 0; table and JSON; no-CDP build handled.
- Test: fleet exclusive at Home idle and after 50 chat switches.

### 103 Freeze eligibility
- Files: CmuxNextHibernation/HibernationPlanner.swift, PageProbe.swift, Hibernation/BrowserHibernation.swift, tests.
- Change: never freeze with notifications allowed, a held Web Lock (probe navigator.locks.query()), an
  open IndexedDB connection (until a fork hook), loading; freeze an opener group only when all are due.
  Write the reason for the 30 s timer in memory-DESIGN.md.
- Acceptance: tests per reason; opener with one visible member not frozen; existing freeze tests unchanged.
- Test: fleet swift test 'FreezePlan|HibernationPlanner'.

### 104 Discard-attempt marker
- Files: ContentDiscardPlanner.swift, Rules/DiscardAttemptedRule.swift, BrowserHibernation.swift, tests.
- Change: refused freeze, asking beforeunload, failed restore or throwing teardown sets the marker;
  disallowed until next show.
- Acceptance: after a failure plan() returns disallowed(discardAttempted); another candidate takes the slot.
- Test: fleet swift test ContentDiscardPlanner.

### 105 Wake admission control
- Files: Hibernation/BrowserHibernation+Restore.swift, Hibernation/AgentPageHibernation.swift,
  Hibernation/WakeAdmission.swift, tests.
- Change: unrequested wakes at most clamp(cores/2, 1, 4) at once; dropped at warning with a typed
  deferred result; none under 150 MB free; a person's show never queued.
- Acceptance: 10 agent wakes on 8 cores start <= 4; warning drops queued agent wakes; show never queued.
- Test: fleet swift test WakeAdmission.

### 106 Crashed subframe discard
- Files: Hibernation/BrowserHibernation.swift, CEF/CEFTab.swift, tests.
- Change: a hidden page with a crashed OOPIF is discarded with reason external.
- Acceptance: hidden tab discarded; visible tab untouched.
- Test: fleet swift test CrashedSubframeDiscard.

### 107 Purgeable backing for image caches
- Files: CmuxNextBridge/PreviewImageCache.swift, CmuxNextTabs/TabThumbnailCache.swift,
  Hibernation/HibernationSnapshots.swift, CmuxNextTerminal/TerminalFramePurgeability.swift (helper moved
  to a shared package).
- Change: bitmaps in volatile IOSurfaces or VM_PURGABLE regions, locked only while drawn; purged hit
  rebuilds or drops.
- Acceptance: purged entry gives a miss, not a blank draw; volatile and locked bytes reported apart; no
  per-draw CGImage copy on main.
- Test: fleet swift test 'PreviewImageCache|TabThumbnailCache|HibernationSnapshots'; bench_memory --pressure critical release_s.

### 108 AsyncMemoryConsumerRegistration
- Files: CmuxNextCompat/Memory/AsyncMemoryConsumerRegistration.swift, tests.
- Change: actor-isolated registration; calls are posted to the consumer's actor with a weak hop.
- Acceptance: consumer on a custom actor gets calls there; dropped registration not called; one enqueue
  per main slice.
- Test: fleet swift test AsyncMemoryConsumerRegistration.

### 109 App pushes memory.limit to the daemons
- Files: CmuxNextDaemon control client (memory.limit), AppServices+Memory.swift,
  cmux-tui-core/src/memory.rs, control dispatch, acpmux control dispatch.
- Change: `memory.limit {level, mode, override}` on each change; daemons take the max with their own
  level; owner-only, denied on relays.
- Acceptance: critical makes the daemon release lossless consumers within 1 s; relay denied; no new
  thread or timer.
- Test: fleet cargo test -p cmux-tui-core memory_limit; bench_memory --pressure critical daemon row.

### 110 Prove hidden CEF pages are backgrounded
- Files: scripts/cmux-next/bench_hibernation.py, plans/cmux-next/memory-DESIGN.md.
- Change: renderer PMF and task role at 0 s, 30 s, 5 min, 10 min after hide, freezing on and off; file a
  shim visibility fix if PMF does not fall.
- Acceptance: bench prints per_hidden_tab_pmf_mb at four points and the task role; result in the doc.
- Test: fleet exclusive.

### 111 Memory cap on shared renderers
- Files: cef-cmux fork (reuse check for the page scheme), CEF/CEFSwitches.swift,
  CmuxNextMemory/SubsystemBudget.swift (sharedRendererMemoryCapBytes, from Chrome's parameter values).
- Change: Chrome's HasEnoughMemoryForAnotherMainFrame check for cmux page sharing and per-site sharing.
- Acceptance: a page grown past the cap sends the next same-site page to a new renderer.
- Test: fleet scripts/measure/renderer-sharing.sh.

### 112 Kernel compressor measurement gates the codec
- Files: scripts/cmux-next/bench_memory.py, plans/cmux-next/memory-DESIGN.md.
- Change: 100 cold terminals x 10 MB scrollback at 0, 10, 30 min with `footprint -j` (dirty and
  compressed); go for 040/041 only if deflate gains >= 2x over WKdm.
- Acceptance: bytes per cold terminal and the go/no-go decision recorded.
- Test: fleet exclusive.
- Also record libghostty-vt's page compression (`ghostty_terminal_compress`) in the same table: 040
  measured that the codec holds 4.9-5.6x less than it (see 040), so the comparison that gates 041
  is the codec vs WKdm vs native page compression.

### 113 One Chromium-side spare
- Files: CEF/CEFSwitches.swift, CEF/CEFSpareWindow.swift, Control/DebugMemoryControl.swift.
- Change: report each spare with process and bytes; keep one Chromium-side spare (turn off Chromium's
  spare or the about:blank placeholder), with the reason in the commit.
- Acceptance: debug.memory lists spares; Home idle has <= 1 spare Chromium renderer.
- Test: fleet bench_memory Home row.

### 114 Urgent pace A/B
- Files: CmuxNextHibernation/HibernationPlanner.swift, ContentDiscardPlanner.swift, tests.
- Change: measure relief and wake churn with the current 3/3 s critical pace against Chrome's one per
  event plus one per 5 s (bench_memory --pressure critical, 60 tabs); keep the one with lower churn at
  equal relief within 30 s; new kinds use Chrome's pace.
- Acceptance: numbers in the commit; golden table updated only if the pace changes.
- Test: fleet exclusive bench_memory --pressure critical --tabs 60; swift test HibernationPlanner.

### 115 Caches batch: MessagesLab and HomeCore remainder
- Files: Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Store/HomeCache.swift, HomeClientViewCache.swift;
  Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/{ChatController+ReplyQuote,
  ComposeInlineAttachmentView, HomeMarkdownPolicy, HomeTopFadeView, HomeVideo, MenuGlyphs}.swift;
  MessagesLabHome/Vendor/appkit-native/{HeaderBar, SwipeReply}.swift;
  MessagesLabHome/Vendor/catalyst/{ComposeAttachments, Layout, LongText, MarkdownLayout, Shapes,
  Transcript}.swift; MessagesLabSidebar/Vendor/appkit-native/SidebarView.swift.
- Change: trim API registered through the 080 adapter (`// memory: consumer via HomeRenderMemoryConsumer`)
  or a fixed mark with proof; iOS still builds.
- Acceptance: MQ-CACHE prints none of these files.
- Test: fleet swift test CmuxMessagesLab and CmuxHomeCore.

### 116 Caches batch: CmuxNext remainder
- Files: CmuxNextApp/Control/DebugHoverSweep.swift, CmuxNextBrowser/CEF/CEFHostView.swift,
  CmuxNextDaemon/Store/SnapshotMemo.swift, CmuxNextDesign/ColorTransition/ThemeRepaint.swift,
  CmuxNextHangReports/HangReportBuilder.swift, CmuxNextSidebar/Views/Sections/SidebarRegionView.swift,
  CmuxNextTabs/TabMotion.swift.
- Change: same rule as 052.
- Acceptance: MQ-CACHE prints none of these files.
- Test: fleet swift test for each package.

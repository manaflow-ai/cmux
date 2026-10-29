# cmux NEXT memory: Memory Saver, budgets from RAM, one coordinator per process

Owner: PL-memory ([OWNERS.md](OWNERS.md)). Fault F8 in [perf-lead.md](perf-lead.md): hidden things keep
their full cost (a hidden Chromium tab 55 MB, Home idle 793 MB against a floor of about 70 MB, a heavy
session 3,538 MB). The full task list, the static machine queues and the measured "today" values are in
the program spec [chrome-parity/p07-memory.md](chrome-parity/p07-memory.md); this file is the design the
code must match. Browser hibernation details (keep rules, freeze, neighbors, wake) stay in
[tab-lifecycle.md](tab-lifecycle.md) section 3. Freezing hidden pages (task 103) and the hidden-page
measurement (task 110) follow section 7.

After this work, cmux discards hidden pages, hidden workspaces and hidden terminal render state by
Chrome's rules, sizes every memory budget from physical memory, answers memory pressure through one
coordinator per process, limits renderer processes from physical memory, and measures memory per
process, subsystem, tab and workspace. It goes past Chrome where cmux has more kinds of content
(terminals, daemons, agents, native pages).

## 1. Chrome mapping

| Chrome piece | Chromium source | cmux piece | cmux difference |
| --- | --- | --- | --- |
| Memory consumers, traits, limit percentage, RAII registration | `base/memory_coordinator/memory_consumer.h`, `traits.h`, `memory_limit.h`, `async_memory_consumer_registration.h` | `CmuxNextCompat/Memory/` (`MemoryLimit`, `MemoryConsumerTraits`, `MemoryConsumer`, `MemoryConsumerRegistration`, `AsyncMemoryConsumerRegistration`) | Same split: `updateMemoryLimit` never frees, `releaseMemory(within:)` frees in time slices |
| Memory Saver modes scale managed consumers | `chrome/browser/performance_manager/policies/memory_saver_memory_coordinator_policy.h` | `MemoryCoordinator` in the leaf target `CmuxNextMemory` | The mode scales limits only under warning; at normal every mode keeps 100 % (section 4) |
| Child-process consumers, most restrictive limit wins | `content/browser/memory_coordinator/README.md` (`ChildMemoryConsumerRegistryHost`) | `memory.limit {level, mode, override}` pushed from the app to the daemon and acpmux | Each daemon takes the max of its own kernel level and the app's |
| macOS pressure source | `components/memory_pressure/system_memory_pressure_evaluator_mac.cc` | `CmuxNextCompat/KernelMemoryPressureSource.swift`; Rust `cmux-tui/crates/cmux-memory/src/pressure_macos.rs` | Same rules: re-read `kern.memorystatus_vm_pressure_level` on each event, read it at start, deliver only on change, no timer |
| Pressure voters, aggregated by max | `content/browser/browser_main_loop.cc` (`CreateMemoryPressureMonitor`, `MultiSourceMemoryPressureMonitor`) | One cmux-owned `MemoryPressureVoter` in the CEF fork | In-process Chromium keeps its own platform voter; the cmux voter adds the debug override and the cmux level |
| Discard eligibility, 30 reasons, protected vs disallowed | `chrome/browser/performance_manager/policies/cannot_discard_reason.h`, `discard_eligibility_policy.h`, `page_discarding_helper.cc` | `CmuxNextHibernation/ContentDiscardPlanner.swift`, one `DiscardRule` per file | One planner for nine kinds of content, not only tabs; a stricter lead rule (section 5) |
| Memory Saver timer per hidden tab | `memory_saver_mode_policy.cc` | One DemandTimer one-shot per planner (earliest deadline) | Browser default 30 min, not Chrome's 4 h (existing cmux decision) |
| Urgent discards | `urgent_page_discarding_policy.cc` (one page per event on macOS, one more every 5 s while critical) | Urgent pass of `ContentDiscardPlanner` | New kinds use Chrome's pace; the browser keeps 3 per 3 s until task 114 measures both |
| Freezing rules and growing frozen pages | `components/performance_manager/freezing/freezing_policy.cc` | `HibernationPlanner.freezePlan`, `Rules/FrozenGrowthRule.swift` | Growth threshold is a cmux choice: max(50 MB, 25 %) |
| Background tab loading | `BackgroundTabLoadingPolicy` (`kCoresPerSimultaneousTabLoad`) | `Hibernation/WakeAdmission.swift` | Same clamp(cores / 2, 1, 4); applies to agent wakes too |
| Crashed subframe | `discard_page_with_crashed_subframe_policy.cc` | `Hibernation/BrowserHibernation.swift` | Same |
| Renderer process limit | `content/browser/renderer_host/render_process_host_impl.cc` (`GetMaxRendererProcessCount`, `kEstimatedWebContentsMemoryUsage` 85 MB) | `renderer-process-limit` switch from `SubsystemBudget.chromiumRendererLimit` | One third of RAM, not one half: terminals and daemons share the Mac |
| Process per site for WebUI | `ChromeContentBrowserClient::ShouldUseProcessPerSite`, `HasEnoughMemoryForAnotherMainFrame` | Fork switch `cmux-page-scheme-process-per-site` with Chrome's memory cap | WebKit cmux pages share through `WebProcessGroups` (no fork) |
| Hidden frame eviction | `components/viz/client/frame_eviction_manager.cc` | `WarmSetBudget`, `TerminalLastFrames`, `ghostty_surface_set_gpu_resident` | Last frames are purgeable (outside phys_footprint), so cmux keeps them volatile at the warm-set count instead of evicting them |
| Occlusion | `content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm` | `CmuxNextDesign/Windows/WindowDrawPolicy.swift` | Minimized, other-Space and occluded windows count as hidden |
| Spare renderer | `SpareRenderProcessHostManager` | Spare pools (`NewTabSparePool`, `PageHostPool`, `CEFSpareWindow`, `ChromiumWarmup`) | At most one Chromium-side spare; none at warning or critical |
| Graph, decorators, policies, chrome://discards | `components/performance_manager/README.md` | `debug.discards`, `debug.memory` (section 7) | Every kind of content, not only tabs |
| Memory dump providers, PMF metrics | `base/trace_event/memory_dump_provider.h`, `process_memory_metrics_emitter.cc`, `docs/memory/key_concepts.md` | `MemoryUsage` per consumer, `memory-report.py` (footprint and vmmap) | Histograms stay local in `debug.memory`; no upload in this program |
| SQLite trim | `sql::Database::TrimMemory()` | `sqlite3_db_release_memory` per long-lived connection | Same |

## 2. Budgets from physical memory

`SubsystemBudget.forMemory(physicalBytes:gpuResidentAvailable:)` in `CmuxNextMemory/SubsystemBudget.swift`.
M is physical memory in MiB; divisions are integer divisions. Every number in the table below is a
literal in `SubsystemBudgetTests` (task 003). If one of them changes, the test and this table change in
the same commit.

| Field | Formula | 8 GB | 16 GB | 24 GB | 32 GB | 64 GB | 128 GB |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `chromiumRendererLimit` | clamp(M / 3 / 85, 3, 82) | 32 | 64 | 82 | 82 | 82 | 82 |
| `warmTerminalSurfaces`, GPU release available | clamp(M / 1024, 4, 32) | 8 | 16 | 24 | 32 | 32 | 32 |
| `warmTerminalSurfaces`, no GPU release API | min(24, max(8, phys / 64 / 48 MiB)), today's `WarmSetBudget` | 8 | 8 | 8 | 10 | 21 | 24 |
| `parkedWorkspaces` | clamp(M / 2048, 4, 16) | 4 | 8 | 12 | 16 | 16 | 16 |
| `parkedIdleTimeout` | 15 min | 15 min | 15 min | 15 min | 15 min | 15 min | 15 min |
| `imageCacheBytes` (all macOS decoded image caches) | M / 128 MiB | 64 MiB | 128 MiB | 192 MiB | 256 MiB | 512 MiB | 1024 MiB |
| `homeRenderBitmapBytes` (Home transcript and lab caches) | clamp(M / 64, 64, 256) MiB | 128 MiB | 256 MiB | 256 MiB | 256 MiB | 256 MiB | 256 MiB |
| `hibernationSnapshotBytes` | M / 256 MiB | 32 MiB | 64 MiB | 96 MiB | 128 MiB | 256 MiB | 512 MiB |
| `liveHiddenAgentPages` | clamp(M / 8 / 75, 4, 32) | 13 | 27 | 32 | 32 | 32 | 32 |
| `liveHiddenInternalPages` | clamp(M / 4096, 2, 8) | 2 | 4 | 6 | 8 | 8 | 8 |
| `kittyImageBytesPerSurface` (app Ghostty) | clamp(M / 4096, 2, 8) x 1,250,000 | 2,500,000 | 5,000,000 | 7,500,000 | 10,000,000 | 10,000,000 | 10,000,000 |
| `webProcessPagesPerGroup` | 8 | 8 | 8 | 8 | 8 | 8 | 8 |

Checks the test also makes: at 4 GB the renderer limit is 16 (task 045); at 16 GB the image shares
(128 MiB) are at least today's literals together (PreviewImageCache 32 MB + pageThumbnails 16 MB +
TabThumbnailCache 48 MB).

Why these shares:

- Renderers get one third of RAM, not Chrome's half, because terminals, the daemon and agents share
  the Mac. The upper clamp 82 is Chrome's macOS platform maximum.
- The warm set grows (the GPU row) only in the commit that turns GPU release on (task 037). Until then
  the "no GPU release API" row is the live formula, and it is also the fallback on forks without
  `ghostty_surface_set_gpu_resident`.
- Terminal last frames stay volatile at the warm-set count. Purgeable memory is outside
  phys_footprint and the kernel takes it with no wakeup. Only non-volatile saved frame bytes are
  capped, at 0. Chrome's FrameEvictionManager evicts instead because its frames are not purgeable.

`DaemonBudget::for_memory(hw.memsize)` in `cmux-tui/crates/cmux-memory/src/budget.rs` (task 089) holds
`scrollback_total` (the default of `terminal.scrollback.maxTotalMemoryBytes`), `cold_scrollback_after`
(10 min), `kitty_total` and `holder_ring_bytes`. Its literal table test covers 8, 16, 32, 64 and 128 GB;
the values are added here when task 089 lands.

## 3. Consumers and modes

A consumer is anything that holds memory it can give back: a cache, a pool, a planner, a parked
workspace set. It registers with an RAII token and reports `memoryUsage` (`footprintBytes`,
`volatileBytes`, `entries`; nil means unknown, never 0).

Traits keep Chrome's names: `estimatedUsage` (small, medium, large), `dataAccess` (none, reads,
readsAndWritesDisk), `retention` (lossless, lossy), `recreateCost` (cheap, expensive, notApplicable),
`releaseCPUCost`, `isStateful`, `supportsMemoryLimit`. A consumer is managed when it is
`isStateful && supportsMemoryLimit` (Chrome's `ShouldManageConsumer`).

Placement:

- Protocol types live in `CmuxNextCompat/Memory/`, which 79 targets already import: no new package
  edges.
- `MemoryCoordinator`, `SubsystemBudget`, `MemoryReport` and the release sink live in the leaf target
  `CmuxNextMemory`, which only `CmuxNextApp` imports.
- Main-actor consumers register directly. Consumers on other actors use
  `AsyncMemoryConsumerRegistration`: one enqueue per call, through a weak reference.
- Value-type caches register through their owner.
- Shared packages that iOS also builds (CmuxHomeRender, CmuxMessagesLab, CmuxHomeCore) expose only
  `bytes` and `trim(toFraction:)`. A macOS adapter in CmuxNextHome registers them and the file says
  `// memory: consumer via <adapter>`.
- All composition goes in `CmuxNextApp/AppServices+Memory.swift`, append-only and sorted.

Modes are Chrome's four, set by `memory.saver` (default medium):

| `memory.saver` | Share of a managed consumer's limit | Timeout factor for new kinds |
| --- | --- | --- |
| off | 100 % | no proactive discard (urgent discards still run) |
| conservative | 75 % | x 1.5 |
| medium (default) | 50 % | x 1 |
| aggressive | 25 % | x 0.5 |

The timeout factors are Chrome's ratios (6 h, 4 h and 2 h in `memory_saver_mode_policy.cc`). The
browser keeps its own `browser.hibernation` setting (default 30 min) as the override for browser tabs.

## 4. Release rules

| Level | Managed consumers with `dataAccess` none and `recreateCost` cheap | Other managed consumers | Lossy consumers (discard planners, spare pools) |
| --- | --- | --- | --- |
| normal | 100 % in every mode | 100 % | get the level; proactive timeouts by mode |
| warning | half the mode share: off 50 %, conservative 37.5 %, medium 25 %, aggressive 12.5 % | 100 % | get the level; no new lossy action at warning; the browser keeps its existing warning pace (1 page per 15 s, hidden at least 60 s) until task 075 measures WARN frequency; spares stop |
| critical | 0 %, except the working set | 0 %, except the working set | urgent discards: Chrome's one per event plus one every 5 s for new kinds; the browser keeps 3 per 3 s, hidden at least 10 s, until task 114 |

Why the mode does not scale limits at normal: `SubsystemBudget` is already sized from RAM, and a cut
with no pressure would only lower hit rates of visible content. At normal the mode changes discard
timeouts and nothing else. Why warning releases only cheap consumers: Chrome acts lossily only at
critical, and macOS WARN is noisy (8 GB Macs sit at WARN for hours; Chrome has
`kSkipModerateMemoryPressureLevelMac` for the same reason).

Rules every consumer gets from the coordinator:

- **Working set.** An entry used in the last 2 s is never released by a lossless consumer, at any
  level.
- **Hysteresis.** After a fall to normal, limits come back only after 30 s at normal, through one
  DemandTimer one-shot. Toggling warning and normal 20 times a minute gives at most one release pass
  per consumer per minute.
- **Current limit on registration.** A consumer that registers mid-pressure gets the current limit
  in the same call.
- **No call for an unchanged level.** A repeated level makes no consumer call.
- **Order.** `dataAccess` none and cheap first, then `reads`, then lossy planners last.
- **Slices.** At most 2 ms of release work per main-thread turn. When no cmux window is visible,
  8 ms slices run back to back; input sets 2 ms again at once. A slice does at most one teardown or
  eviction of a large object.
- **First slice a frame later.** The first slice runs on the frame after the level change, so it never
  shares a turn with in-process Chromium's own pressure listeners.
- **Release sink.** A slice only unlinks objects. A utility-QoS serial queue drops the last
  references, so no large object deallocates on main. After a critical pass that queue calls
  `malloc_zone_pressure_relief(nil, 0)` once, and the PartitionAlloc purge through the fork when
  present; none at warning or a repeated level.
- **Event-driven only.** No `Timer`, `DispatchSourceTimer`, `Task.sleep` loop or poll. Deadlines are
  DemandTimer one-shots, one per owner. 0 periodic wakeups when idle.

Pressure sources: one kernel source per process. In the app, in-process Chromium's own platform voter
is the one accepted second source; the cmux voter feeds it the coordinator's level and the debug
override, and Chromium's aggregator takes the max. The daemon and acpmux use `cmux-memory` (macOS
dispatch source, Linux PSI trigger `some 150000 1000000` on `/proc/pressure/memory` with POLLPRI) and
take the max of their own level and the app's `memory.limit`.

## 5. Discards

`ContentDiscardPlanner` decides for every kind of content. Each rule is a `DiscardRule` value in its
own file under `CmuxNextHibernation/Rules/`, registered in one list.

Results are Chrome's: `eligible`, `protected(reason)`, `disallowed(reason)`. The worst result wins. A
protected item is never discarded by a proactive or urgent discard (Chrome's
`discard_protected_tabs=false`); only an external discard (the Hibernate Tab action) and the reasons
Chrome lists as proactive-only apply.

Discard reasons: `proactive` (timeout), `urgent` (critical pressure), `external` (a person or a
script asked), `frozenWithGrowingMemory`.

### Kinds and timeouts

Timeouts are for medium mode at normal pressure (section 3 scales them). Every new lossy kind ships
behind a default-off Debug toggle `memory.discard.<kind>`; turning a default on is its own PR after
DC14 and Nightly dogfood.

| Kind | What is released | Proactive timeout | Budget | Toggle |
| --- | --- | --- | --- | --- |
| browser (CEF, WebKit and the other BrowserTab conformers) | engine page, renderer share | `browser.hibernation`, default 30 min | `chromiumRendererLimit` | existing setting; cmux page tabs `memory.discard.pageTabs`, remote tabs `memory.discard.remoteTabs` |
| agentPage | the page's web view | existing agent timeout | LRU of `liveHiddenAgentPages`, hidden at least 10 s | existing |
| internalPage (33 InternalPageIDs) | the page view | provider policy; default 10 min; task manager 1 min; passwords 60 s | LRU of `liveHiddenInternalPages` | `memory.discard.internalPages` |
| topPage | the top page view | provider policy, default 10 min | shared LRU of `liveHiddenInternalPages` across windows | `memory.discard.topPages` |
| conversation | laid-out rows, images, diagrams (index, anchor, draft and unread stay) | 10 min | none | `memory.discard.conversations` |
| terminalSurface | GPU swap chain and drawables (the daemon keeps the terminal) | hidden outside the keep-alive band; a window off screen 30 s | `warmTerminalSurfaces` | `memory.discard.terminalGPU` |
| parkedWorkspace | `WorkspaceContentController` down to a `WorkspaceViewRecord` (about 1 KB) | 15 min idle | LRU of `parkedWorkspaces` across windows | `memory.discard.parkedWorkspaces` |
| overlayPage (icon picker, update island, extensions panel) | the page view | 5 min after close, or at warning | none | none (lossless to the person) |
| sidebarSection (right sidebar modes, Home dock modes) | the section view, with a view-state record | 10 min hidden, or hidden at critical | none | `memory.discard.sidebarSections` |

Minimized, other-Space and occluded windows count as hidden (Chrome's `Visibility::OCCLUDED`, with the
occlusion checker's rule that a cmux window covered by another cmux window is hidden).

A discarded item keeps a small record (URL, title, icon, history, or a view-state record) and a
picture. Pictures count in `hibernationSnapshotBytes`; only neighbors and the most recent ones keep
theirs. Showing a discarded item draws its picture or record in the first frame.

### Reasons it cannot be discarded

Chrome's 30 `CannotDiscardReason` values map one to one where cmux has the signal (`visible`,
`audible`, `recentlyAudible`, `pictureInPicture`, `pdf`, `capturing*`, `connectedTo*`, `pinnedTab`,
`devToolsOpen`, `formInteractions`, `userEdits`, `notificationsEnabled`, `backgroundActivity`,
`alreadyDiscarded`, `discardAttempted` and the rest). cmux adds its existing exemptions (raw values
unchanged in `debug.surfaces`): `disabled`, `excluded`, `unsupported`, `web_audio`, `before_unload`,
`web_rtc`, `connected_device`, `unreadable_frame`, `agent_busy`, `agent_turns_unknown`,
`form_submission`, `agent_driving`, `neighbor`, `unanswered`, `downloading`, `agent_lease`; and two new
ones, `unsavedEdits` (a dirty editor) and `runningCommand`.

| Rule | Result | Applies to |
| --- | --- | --- |
| Lead rule: audio, capture, form input, a running download, a `beforeunload` that asks | protected | every discard reason, every pressure (stricter than Chrome) |
| Recently audible: 60 s after audio ends | protected | all reasons (Chrome's `kTabAudioProtectionTime`) |
| Notifications, background activity (title or favicon change while hidden) | protected | proactive only; urgent and external still apply (Chrome's rule) |
| Discard attempted: a refused freeze, an asking `beforeunload`, a failed restore or a throwing teardown | disallowed | until the item shows again (Chrome's `DiscardAttemptMarker`) |
| Frozen with growing memory: growth of max(50 MB, 25 %) since freeze, sampled at one-shots +5, +30 and +120 min after freeze | eligible with `frozenWithGrowingMemory` | the whole opener group together; the lead rule still holds |
| Crashed subframe in a hidden page | eligible with `external` | browser kind |

Freeze rules are Chrome's `CannotFreezeReasons`: never freeze with notifications allowed, a held Web
Lock, an open IndexedDB connection or while loading; an opener group freezes only when every member is
due.

Wakes nobody asked for (agent wakes, prefetch) run at most clamp(cores / 2, 1, 4) at once, are dropped
at warning with a typed deferred result, and never start with less than 150 MB free. A person's show
is never queued.

## 6. Processes and terminal render state

- `renderer-process-limit=<chromiumRendererLimit>` in both Chromium process models. Above it, same-site
  tabs share a renderer; sites never mix. WebKit uses the same limit for same-site reuse.
- WebKit cmux pages share WebContent processes through `WebProcessGroups`, 8 pages a group per data
  store.
- No page renderer starts before its page first shows. Overlay pages leave 5 min after close.
- Spares follow the level: one spare at normal in every mode, none at warning or critical, no refill
  until normal. At most one Chromium-side spare.
- Hidden Chromium pages flush the back-forward cache at freeze and at warning.
- `ghostty_surface_set_gpu_resident(false)` on a hidden paused surface outside the keep-alive band
  releases its swap chain and drawables and stops its renderer thread; `true` comes back before the
  first draw on show, and the last frame covers the gap. App-side scrollback paging is PL-ghostty's
  (F11).
- Daemon: scrollback total from `DaemonBudget` and registered (warning lowers to 50 % least recently
  used first, critical to the 16 MiB floor, normal restores below 80 %); one kitty total across
  terminals; SQLite `sqlite3_db_release_memory` per long-lived connection on its own thread; cold
  holder rings get `madvise(MADV_FREE_REUSABLE)` after ack.

## 7. Measurement

All three methods are read-only, local owner only, and denied over any remote relay. Release builds
answer them, with no URLs, titles or paths: items are opaque IDs. Keys are snake_case. Byte values are
integers; an unknown value is `null`, never 0.

### `debug.memory`

```json
{
  "pressure": { "level": "warning", "kernel_level": "warning", "override": null, "since_ms": 41250 },
  "mode": "medium",
  "budget": {
    "physical_bytes": 17179869184,
    "chromium_renderer_limit": 64,
    "warm_terminal_surfaces": 8,
    "parked_workspaces": 8,
    "parked_idle_timeout_s": 900,
    "image_cache_bytes": 134217728,
    "home_render_bitmap_bytes": 268435456,
    "hibernation_snapshot_bytes": 67108864,
    "live_hidden_agent_pages": 27,
    "live_hidden_internal_pages": 4,
    "kitty_image_bytes_per_surface": 5000000,
    "web_process_pages_per_group": 8
  },
  "consumers": [
    {
      "name": "tab_thumbnails",
      "traits": { "estimated_usage": "medium", "data_access": "none", "retention": "lossless",
                  "recreate_cost": "cheap", "is_stateful": true, "supports_memory_limit": true },
      "managed": true,
      "limit_percent": 25,
      "footprint_bytes": 8388608,
      "volatile_bytes": 0,
      "entries": 41,
      "last_release": { "level": "warning", "released_bytes": 25165824, "slices": 3, "at_ms": 41266 }
    }
  ],
  "processes": [
    { "kind": "app", "pid": 501, "phys_footprint_bytes": 361000000 },
    { "kind": "chromium_renderer", "pid": 812, "phys_footprint_bytes": 62000000 }
  ],
  "tabs": [
    { "id": "6F1C...", "kind": "browser", "engine": "cef", "state": "frozen", "visible": false,
      "shown_ever": true, "footprint_bytes": 55000000 }
  ],
  "workspaces": [
    { "id": "A20B...", "mounted": true, "parked": true, "panes": 3, "terminal_surfaces": 2,
      "gpu_resident_surfaces": 0, "app_bytes": null }
  ],
  "terminal": { "warm_capacity": 8, "warm_count": 6, "gpu_resident_count": 4,
                "hidden_nonvolatile_iosurface_bytes": 0, "last_frames_volatile_bytes": 31457280 },
  "spares": [ { "pool": "new_tab", "process_kind": "chromium_renderer", "pid": 830, "bytes": 41000000 } ],
  "pressure_history": [ { "at_ms": 41250, "level": "warning", "source": "kernel" } ],
  "histograms": { "app_pmf_mb": { "buckets": [64, 128, 256, 512, 1024], "counts": [0, 3, 9, 1, 0] } }
}
```

`processes[].kind` is one of `app`, `chromium_browser`, `chromium_renderer`, `chromium_gpu`,
`chromium_utility`, `webkit_webcontent`, `webkit_networking`, `daemon`, `acpmux`, `holder`,
`agent_sidecar`, `other`. `pressure_history` keeps the last 32 changes; `source` is `kernel`,
`override` or `daemon`. Histograms are local buckets only (app PMF, renderer PMF total, discards per
hour by kind, wake latency, minutes at warning and critical, WARN events per hour).

### `debug.discards` (chrome://discards for every kind)

```json
{
  "rows": [
    {
      "id": "6F1C...",
      "kind": "internalPage",
      "visible": false,
      "hidden_for_ms": 734000,
      "state": "live",
      "eligibility": "protected",
      "reason": "unsaved_edits",
      "timeout_ms": 600000,
      "toggle": "memory.discard.internalPages",
      "toggle_on": false,
      "last_discard_reason": null,
      "wake_count": 2
    }
  ]
}
```

`kind` is one of the nine kinds in section 5. `state` is `live`, `frozen` or `discarded`.
`eligibility` is `eligible`, `protected` or `disallowed`, and `reason` is set whenever it is not
`eligible`. `last_discard_reason` is `proactive`, `urgent`, `external`, `frozen_with_growing_memory`
or `null`.

### Daemon `memory-report`

```json
{
  "level": "normal", "app_level": "warning", "footprint_bytes": 98000000,
  "consumers": [ { "name": "scrollback", "retention": "lossless", "footprint_bytes": 41943040, "limit_percent": 100 } ],
  "terminals": [ { "id": "t-12", "scrollback_live_bytes": 2097152, "scrollback_compressed_bytes": 0,
                   "holder_ring_bytes": 1048576, "kitty_bytes": 0 } ]
}
```

acpmux shows the same `consumers` list and its top 20 sessions in a memory section of `daemon status`.

## Freezing hidden pages

### Why 30 seconds

A hidden Chromium page freezes after `browser.freezeHiddenTabs` seconds, 30 by default
(`BrowserHibernationSetting.defaultFreezeSeconds`). The timer is a power choice, not a memory one: a
frozen page keeps its memory and its state.

- A hidden page keeps its renderer awake about 0.5 to 1.5 times a second (msg 2654). Freezing it cut the
  renderer's energy by about 90 % on cmux14, and hibernation closes a page only after 60 minutes hidden.
  Chrome's own throttling of hidden pages (one wake-up a second at once, intensive throttling after 5
  minutes, `kIntensiveWakeUpThrottling`) leaves those wake-ups; a frozen page has none.
- 30 seconds is long enough for the work a page starts as the person leaves it (a send, a save, an
  upload's last request) to end, and for a quick look at another tab and back to find a live page.
  Pages the person switches to with one key (`browser.keepNeighborTabsAwake`) and a hovered tab stay
  awake whatever the timer, so the timer does not decide the cost of the next switch.
- Chrome's `FreezingPolicy` freezes hidden pages under its battery saver, pages above its high-CPU
  proportion (`kFreezingHighCPUProportion`); cmux freezes every hidden page that can freeze, since cmux keeps many more
  hidden pages (agents' pages, dashboards) than a person keeps background tabs. Energy Saver freezes a
  CPU-heavy hidden page before the delay (`SaverCPUFreeze`).

### What never freezes

Chrome's `CannotFreezeReason`s (`components/performance_manager/freezing/freezing_policy.cc`), behind
feature `memoryFreezeEligibility` (`FreezeEligibility`, `HibernationPlanner.freezePlan`): never freeze a
page whose site may show notifications, that holds a Web Lock or an open IndexedDB connection (Chrome:
a blocking IndexedDB lock; cmux has no engine hook for that yet, so any open connection counts), or that
still loads. The page's recorder counts the locks this document holds (`BrowserPageBusy`), as Chrome
counts them per frame; `navigator.locks.query()` would list every page of the origin. A page kept for its
load, or that starts to load before its freeze probe answers, is planned again when the load ends (an
observation, no timer).

An opener and the pages it opened freeze only when every one of them is due, and thaw together, as
Chrome freezes a browsing instance as a whole; the hibernation of one member thaws that page alone, as
Chrome discards a frozen page without unfreezing its group. The links are read once per plan, only when
a due page asks for its group. cmux's own reasons stay: pinned tabs, Never Hibernate
hosts, DevTools, capture, an agent's lease, background activity, playing media, Web Audio, WebRTC and
open devices.

## Hidden Chromium pages: backgrounded and purged

Question: does a hidden Chromium page in cmux give back memory the way a hidden tab does in Chrome,
before any hibernation closes it?

### What Chrome does

1. A renderer process whose frames are all hidden, with no audio, capture or foreground worker, gets
   `Priority::kBestEffort`: `RenderProcessHostImpl::UpdateProcessPriority`
   (`content/browser/renderer_host/render_process_host_impl.cc`). On macOS `Process::SetPriority`
   (`base/process/process_mac.cc`) then sets the task role `TASK_BACKGROUND_APPLICATION` and a
   `TASK_SUPPRESSION_POLICY` (low CPU priority, timer and throughput throttling), and
   `TASK_FOREGROUND_APPLICATION` with no suppression again when a frame shows.
2. The renderer learns it is backgrounded (`RenderThreadImpl::OnRendererBackgrounded`) and
   `blink::MemoryPurgeManager` (`third_party/blink/renderer/core/timing/memory_purge_manager.cc`) purges
   V8, PartitionAlloc and Skia memory at a random time 1 to 4 minutes later, and at once when all of its
   pages are frozen.
3. A frame is hidden when its `WebContents` is hidden: `WebContentsImpl::UpdateWebContentsVisibility`
   (`content/browser/web_contents/web_contents_impl.cc`), fed on macOS by the view's hide and by window
   occlusion (`content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm`).

In cmux, `CefBrowserHost::WasHidden` does nothing for a windowed Chrome-style browser
(`CEFTabNodeVisibility.swift`). If Chromium never counts a hidden cmux page as hidden, step 1 never
runs, the renderer keeps its foreground role, and step 2 never purges. Freezing
(`browser.freezeHiddenTabs`) then saves CPU but not memory. The fork's `cmux_tab_set_visibility`
(fork API 37, p06-scheduler-212) sends a tab's hide to `UpdateWebContentsVisibility`, but only with
the default-off feature `chromiumTabVisibility` and a fork pin at API 37 or later. So the bench runs
twice: with the feature off (what people get today) and on.

### The measurement

`scripts/cmux-next/bench_hibernation.py --background-timeline 0,30,300,600`. Hibernation is off for
the run, so every page stays loaded. For each freeze mode (`off`, then `on` at `--freeze` seconds) the
bench opens `--tabs` Chromium pages, each its own site (`tN.localhost`, so each has its own renderer
under site isolation), and hides them behind one shown tab. The timeline's `--heap-mb` is 0 by
default: a live array is memory no purge can free, so a pinned heap (the other phases use 40 MB)
would make a correct purge fall by less than 10 % of the 0 s PMF.
At 0 s, 30 s, 5 min and 10 min after the hide it reads, for each hidden page, the footprint of the
renderer that hosts that page and no other (from the app's `resources` report), and that renderer's
task role.

- PMF is `phys_footprint` from `proc_pid_rusage`, the number Chrome reports as private memory footprint
  on macOS (`components/metrics/process_memory_metrics_emitter.cc`).
- The task role is read the way the idle audit reads it (`idle-budget.py` `observed_role` over
  `scripts/perf-bench/procs.py` `priorities`, same user, no task port): `darwinbg` (the kernel's
  darwin-background bit), `suppressed` (a base priority below `BASEPRI_DEFAULT` 31: the suppression
  policy's low CPU priority, App Nap or a positive nice) or `default` (not lowered). The role itself
  changes thread QoS, not the base priority (xnu `osfmk/kern/task_policy.c`), so Chrome's background
  renderer shows as `suppressed` or `darwinbg`, a foreground one as `default`. The raw base priorities
  are printed too.

The bench first prints `PERF-HIBERNATE-BACKGROUND-START chromiumTabVisibility=<state> fork_api=<n>
heap_mb=<n>` (the state from `features.list`, the API from `debug.cef`). Below fork API 37 the feature makes no
call, so a run with it on measures the same as off. Then one line per mode and point:

```text
PERF-HIBERNATE-BACKGROUND freeze=off at_s=300 measured_at_s=300.0 per_hidden_tab_pmf_mb=... max_hidden_tab_pmf_mb=...
    renderer_task_role=suppressed:6 renderer_base_priority=4,4,4,4,4,4 front_task_role=default frozen=0/6 measured=6/6
```

then one `PERF-HIBERNATE-BACKGROUND-SUMMARY` line per mode (`measured`, PMF at the four points,
`fell_mb`, `fell_pct`, `backgrounded`, the roles at 30 s), and a verdict:

- `measured`: at 30 s at least one hidden renderer has a role read and none is `unread`, and the
  per-page PMF has a value at 0 s and at 10 min. It is false when the `resources` report failed,
  when every hidden page shares its renderer, or when the task priorities could not be read.
- `backgrounded`: every measured hidden renderer has the `suppressed` or `darwinbg` role at 30 s.
- `pmf_falls`: the per-page PMF at 10 min is at least 10 % below the PMF at 0 s.
- `follow_up=unmeasured` when no mode ran or a mode is not `measured`: the run says nothing about
  Chromium. Find the cause in the run's stderr, then run it again. File no follow-up.
- Else `follow_up=none` when `backgrounded` and `pmf_falls` are true in every mode, and
  `follow_up=shim-visibility` when not.

The bench's last script call into each page starts the 30 s agent grace, so with freezing on a page
freezes at the later of `--freeze` and 30 s; the `frozen=` count at each point shows when. The run
writes the report (`--out FILE.json`, key `background`) and no result-v1 series.

Commands (fleet, exclusive; one run is about 21 min: two freeze modes of 10 min each):

```bash
cmux-ci run --class exclusive --measurement --label measure --ref SHA \
  --script 'scripts/cmux-next/bench_hibernation.py --app BUNDLE --background-timeline 0,30,300,600 --tabs 6 --heap-mb 0 --out background-off.json'
cmux-ci run --class exclusive --measurement --label measure --ref SHA \
  --script 'scripts/cmux-next/bench_hibernation.py --app BUNDLE --background-timeline 0,30,300,600 --tabs 6 --heap-mb 0 --feature chromiumTabVisibility=on --out background-on.json'
```

### Result

Not run yet. The lead's fleet measurement round records host, SHA, step ID, `fork_api` and the
numbers here.

| chromiumTabVisibility | Freeze | 0 s PMF MB | 30 s | 5 min | 10 min | Role at 30 s | Frozen at 10 min | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| off | off | | | | | | | |
| off | on | | | | | | | |
| on | off | | | | | | | |
| on | on | | | | | | | |

### Follow-up when the PMF does not fall

Read the two runs together. If one of them gives `follow_up=unmeasured`, run it again and file
nothing until both are measured.

- Off gives `follow_up=shim-visibility` and on gives `follow_up=none` (fork API 37 or later): the fix
  exists. File a p07-memory task to turn `chromiumTabVisibility` on by default with these numbers,
  and tell its owner (PL-cef-tab).
- Both give `follow_up=shim-visibility`, or the pin is below API 37: file this task in p07-memory.
  - Title: hidden Chromium pages reach Chromium as hidden.
  - Files: the cef-cmux fork (`cmux_tab_set_visibility` reaches
    `WebContentsImpl::UpdateWebContentsVisibility` for a windowed Chrome-style browser, and the
    renderer's priority follows it as in `RenderProcessHostImpl::UpdateProcessPriority`),
    `CEF/Shim/cmux_cef_shim.h`, `CEFTabNodeVisibility.swift` and `CEFPaneHost.swift` (hidden and shown
    from the tab's visibility node, occlusion from `WindowDrawPolicy`), behind a fork API check.
  - Acceptance: this bench shows `backgrounded=True` at 30 s and `pmf_falls=True` in both freeze
    modes; the shown tab's renderer stays `default`; a shown tab paints its first frame within the
    tab-switch budget (`bench-tab-switch.sh`, not worse).
  - Test: fleet exclusive, this bench before and after.

## 8. Done checks

Host classes:

- **checkout**: any trusted checkout, no build, read-only.
- **isolated**: a fleet test run, `cmux-ci run --class isolated --ref SHA --script ...`.
- **exclusive**: a fleet measurement run on a cmux20-class mini, Release build,
  `cmux-ci run --class exclusive --measurement --label measure --ref SHA --script ...`.
- **Linux**: a Linux builder for the PSI path.
- **Tart 14/15**: `scripts/cmux-next/os-matrix.sh --build JOB --os 14,15` (not perf evidence).

Every run records host, SHA and step IDs in perf-lead.md F8 and here. "Today" values come from the
hour-0 baseline (task 075). None of these checks is a CI gate.

- **DC1 caches.** Threshold: 0 files, and every cache above 1 MB at STRESS is a registered consumer,
  not a `memory: fixed` mark (today 86 files). Command: `scripts/cmux-next/memory-queues.sh caches`,
  then `memory-report.py` at STRESS. Host: checkout, then exclusive.
- **DC2 one pressure source per process.** Threshold: `makeMemoryPressureSource` only in
  `CmuxNextCompat/KernelMemoryPressureSource.swift` (today 3 files); `_dispatch_source_type_memorypressure`
  only in `cmux-memory/src/pressure_macos.rs`; `memoryPressure.observe` only in CmuxNextMemory (today
  3). Command: `scripts/cmux-next/memory-queues.sh pressure` and `observe`. Host: checkout.
- **DC3 budgets from RAM.** Threshold: `physicalMemory` only in `CmuxNextMemory/SubsystemBudget.swift`
  and `CmuxNextHangReports/HardwareClass.swift`; MQ-CAPS 0 hits outside SubsystemBudget.swift (today
  34); MQ-RUST-CAPS literals only in `cmux-memory/src/budget.rs` or derived from it (today 37); the
  table tests pass at 8, 16, 24, 32, 64 and 128 GB. Command: `memory-queues.sh phys`, `caps`,
  `rust-caps`; `swift test --filter SubsystemBudgetTests`; `cargo test -p cmux-memory budget`. Host:
  checkout, then isolated.
- **DC4 every kind discardable.** Threshold: the coverage test fails for any of the 33
  InternalPageIDs, 7 TabContent cases, 13 BrowserTab conformers, overlay pages or sidebar sections with
  no declared policy; with every discard toggle on, a STRESS session idle 35 min with every tab hidden
  shows 0 `debug.discards` rows with `state` live, `eligibility` eligible and `hidden_for_ms` past
  `timeout_ms`. Command: `swift test --filter 'ContentDiscardPlannerTests|InternalPageDiscardPolicyCoverageTests'`;
  `debug.discards` after the idle run. Host: isolated, then exclusive.
- **DC5 hidden content after discard.** Threshold: each hidden Chromium tab, WebKit tab, agent page,
  internal page and cmux page tab costs at most 0.1 MB without its picture (today 55, 29 and 75 MB);
  pictures stay within `hibernationSnapshotBytes`. Command: `bench_hibernation.py`,
  `bench_memory.py --pressure critical`. Host: exclusive.
- **DC6 hidden workspace.** Threshold: per hidden workspace app at most 0.1 MB, daemon at most 0.3 MB,
  no added cmux process (today 8.2 MB together), run with `CMUX_TUI_TERMINAL_HOST_MODEL=holder` until
  it is the default (the run says so). Command: `bench_memory.py --hidden-workspaces 100 --grace 960`.
  Host: exclusive.
- **DC7 Home idle.** Threshold: 0 Chromium renderers and 0 WebKit WebContent processes for cmux pages
  not shown, at most 1 renderer for all shown cmux pages, no icon-picker page, at most 1 spare
  Chromium renderer. Interim with in-process CEF: the 075 baseline minus every removed item, recorded.
  Final after F2 and the shared pin: whole tree at most 250 MB, app at most 120 MB (today 793 and
  361 MB). Command: `bench_memory.py --app BUNDLE --workspaces 1 --settle 30 --top 50` and
  `debug.memory`. Host: exclusive.
- **DC8 heavy session.** Threshold: cmux-owned footprint (shells and agent harnesses excluded) at most
  600 MB after 35 min idle with every discard toggle on (today 3,538 MB whole tree); at most 300
  threads. Command: `perf-stress-session.py` 60 workspaces STRESS and budgets-heavy 150 workspaces.
  Host: exclusive.
- **DC9 renderer limit.** Threshold: renderers at most max(`chromiumRendererLimit`, distinct site
  locks), printed next to the site-lock count; at most 2 same-site main frames per renderer below the
  limit; the same rule for WebKit; with 60 local tabs, cmux total at most Chrome's total on the same
  host (#20856: Chrome 7.4 GB, cmux 11.8 GB). Command: `bench_renderer_sharing.py --tabs 100 --sites 20`
  (hibernation off), the same with `--engine webkit`, `bench_memory.py --tabs 60 --urls local`. Host:
  exclusive.
- **DC10 pressure response.** Threshold: within 5 s the app footprint falls by at least 80 % of the
  managed consumers' `footprint_bytes` before (volatile bytes excluded); every managed consumer is at
  its critical limit within 1 s with a visible window and 2 s hidden; 0 main-thread turns over 4 ms
  from release work and 0 dropped frames; the daemon and acpmux release their lossless consumers within
  1 s of `memory.limit critical`. Command: `bench_memory.py --pressure critical` (override) and
  `--kernel-pressure critical` (`/usr/bin/memory_pressure` where allowed). Host: exclusive.
- **DC11 terminal GPU.** Threshold: with 30 hidden terminals and one minimized window of 6 terminals,
  `terminal.hidden_nonvolatile_iosurface_bytes` is 0, on a fork with `ghostty_surface_set_gpu_resident`.
  Command: `bench_memory.py` with a minimized window, then `debug.memory`. Host: exclusive.
- **DC12 leaks.** Threshold: slope at most 5 MB/h app, 5 MB/h daemon, 2 MB/h acpmux; renderer total
  within 5 % of start; MQ-LEAK empty. Command: `scripts/measure/memory-soak.sh` (2 h STRESS churn).
  Host: exclusive.
- **DC13 idle.** Threshold: in 60 s idle, 0 wakeups owned by MemoryCoordinator, ContentDiscardPlanner
  or any consumer in WakeupLedger; daemon `idle_wakeups` and acpmux `daemon_idle` tests green. Command:
  `perf-10x-idle.sh` with the WakeupLedger dump; `cargo test -p cmux-tui-core idle_wakeups`;
  `cargo test -p acpmux daemon_idle`. Host: exclusive, then isolated.
- **DC14 latency, not worse.** Threshold: browser wake p95 at most 100 ms with a picture in the first
  frame; a discarded internal page, conversation, sidebar section or top page shows its picture or
  record in the first frame (key to frame p99 at most 16.7 ms); an unmounted workspace's key to first
  frame p99 at most 16.7 ms and remount p95 at most 50 ms. Command: `bench-tab-switch.sh` and the anim
  `ws-switch` run, light and STRESS. Host: exclusive.
- **DC15 attribution.** Threshold: unattributed memory at most 10 % of the app's phys_footprint.
  Command: `memory-report.py --pid <app>`. Host: exclusive.
- **DC16 macOS 14 and 15.** Threshold: the coordinator, kernel source, hibernation, purgeable IOSurface
  and parked-workspace suites pass on both. Command: `scripts/cmux-next/os-matrix.sh --build JOB --os 14,15`.
  Host: Tart 14/15.
- **DC17 flapping.** Threshold: with the debug override toggling warning and normal 20 times a
  minute, at most 1 release pass per consumer per minute and 0 dropped frames in an anim sidebar run.
  Command: `swift test --filter MemoryCoordinatorHysteresis`, then the anim sidebar run with override
  flaps. Host: isolated, then exclusive.
- **DC18 per agent.** Threshold: with 100 fake agents, acpmux at most 2 MB per agent, sidecar relays at
  most 1 MB each, 2 fewer processes per agent, total at most 8 MB per agent (today about 64 MB).
  Command: `scripts/measure/acpmux-overhead.sh`. Host: exclusive.

## 9. Rules for code in this program

1. Event-driven only (section 4). A new timer or poll in a memory file is a review reject.
2. Main thread: one teardown or eviction per slice, no large dealloc on main, no disk I/O or lock
   wait. Action handlers use `registry.bindEffect` and return an `ActionEffect`.
3. No CI gates, budget rows or perf-gate rows. `memory-queues.sh` is local. Thresholds live here and
   in perf-lead.md.
4. Every fix commits its failing regression test first and records red and green from the fleet.
5. Lossy discard kinds, socket methods, the pin bump, daemon idle exit and MCP credential scoping are
   risk:high. Docs and scripts are risk:low. The rest are risk:normal.
6. A `// memory: fixed <reason>` mark must prove a bounded key space. A cache over 1 MB at STRESS may
   not use it.
7. Shared packages that iOS builds keep AppKit and CmuxNext types out of their memory API.
8. Fork-dependent Swift lands behind fork API version checks and does nothing on old forks.

## 10. Decisions made

Made by PL-memory under the standing "decide, do not ask" rule; each is open to a later PR with data.

- Renderers get RAM / 3, not Chrome's RAM / 2.
- Chrome's four modes, default medium; 100 % at normal in every mode; the mode scales limits only for
  cheap consumers at warning.
- Every new lossy kind ships default off behind a Debug toggle.
- Browser timeout stays `browser.hibernation` (default 30 min), more aggressive than Chrome's 4 h.
- The browser keeps its current warning and critical paces until tasks 075 and 114 measure them; new
  kinds use Chrome's pace.
- Terminal last frames stay purgeable at the warm-set count instead of Chrome-style eviction.
- Field upload of memory histograms is deferred; they stay local in `debug.memory`.
- App-side scrollback paging is left to PL-ghostty (F11).
- No pre-push cache guardrail (Lawrence 2026-10-23: no new gates); the machine queues are local.
- Parked workspaces: task 032 takes back 6f04ec90105 (every workspace kept mounted) with an LRU of
  `parkedWorkspaces` and a 15 min idle timeout, behind `memory.discard.parkedWorkspaces`, after a
  bench-tab-switch A/B. If a 12-pane remount p95 is over 50 ms it ships the LRU without the timeout.

Outside step: the R2 upload of the shared CEF fork build (task 074) needs a person with R2 access.

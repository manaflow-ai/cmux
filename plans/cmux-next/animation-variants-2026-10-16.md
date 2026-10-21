# CMUX Next animation variants — 2026-10-16

This pass adds opt-in Debug Settings variants. Production defaults remain unchanged.

| Surface | Debug Settings key | Choices | Default | What changes |
| --- | --- | --- | --- | --- |
| Pane close and expand | `motion.pane.variant` | `standard`, `crisp`, `softLanding` | `standard` | Reuses the existing pane geometry and fixed-size host behavior; `crisp` shortens the structural response and `softLanding` adds a small settle treatment. |
| Sidebar collapse | `sidebar.collapseMotion` | `slide`, `slideFade` | `slide` | `slideFade` fades the sidebar panel while the width follows the same transition. Geometry is unchanged. |
| Tab loading indicator | `tabs.loadingAnimation` | `instant`, `fade`, `fadeScale`, `fadeSlide` | `instant` | Loading indicators enter/leave without changing tab measurements. The fade variants retain the layer until the exit animation completes. |
| Workspace / agent title arrival | `sidebar.workspaceTitleMotion` | `instant`, `crossfade`, `lift` | `crossfade` | Keeps the existing title slot and transitions only the glyphs when a new workspace or chat receives its generated display title. |

## Naming reference and design decision

The current CMUX path resolves a row title as `page.title ?? workspace.displayName` in
`SidebarMapping`, then assigns it directly to `WorkspaceRowView.title`. That makes a late
agent-derived or browser-derived name appear as a synchronous text replacement. The new
prototype keeps the row geometry stable and uses the existing Motion fade tokens for the
title layer transition. A blank placeholder remains static while generation is pending; when
the live row receives its first title, the title layer and placeholder bar share the same
post-layout crossfade or lift so the loading state does not vanish before the name appears.
The daemon allocation name (`workspace-N`) is treated as empty display content, so it stays
behind that loading state instead of flashing into the sidebar.

The reference behavior is consistent across the public product surfaces: Claude documents
conversation names as a user-visible title that can be renamed from the conversation header,
while Codex generates a concise title from the first message in a background title-generation
request. The UI implication is to keep a stable provisional label while generation is pending,
then replace it once, in place, with a short crossfade or lift rather than flashing “New chat”
and the final title as separate layouts.

## Focused verification

All commands ran from `Packages/macOS/CmuxNext` on the animation worktree.

- `swift test --filter PaneMotionVariantTests` — 5 tests passed.
- `swift test --filter SidebarCollapseMotionTests` — 2 tests passed.
- `swift test --filter TabLoadingAnimationTests` — 3 tests passed.
- `swift test --filter WorkspaceRowHoverMotionTests` — 1 test passed.
- `scripts/cmux-next/check-motion.sh Packages/macOS/CmuxNext` — passed.
- `swiftc -frontend -parse` over all edited Swift sources — passed.
- `git diff --check` — passed.

The tab suite caught two implementation issues during this pass: the tab source needed `QuartzCore` for its completion transaction, and the exit path needed to consult the selected variant after the item state changed to idle. Both were fixed before the final passing run.

## Comparison recipe

1. Open Debug Settings and select one key at a time.
2. Run the matching action repeatedly, including an interruption halfway through:
   - split, close, zoom, and unzoom for pane variants;
   - collapse and expand the sidebar;
   - start and finish a loading tab.
3. Use `debug.motion` with `start`, reproduce the action, then `stop` to capture span duration, frame samples, and display-link count.
4. Compare each variant against its default and repeat with `debug.motion speed` set to `fast`, `normal`, and `off`, plus `debug.motion reduce` set to `true`.

The initial focused pass did not include a live tagged app recording; the focused suites
validated the geometry, layer lifetime, default/reset behavior, and reduced-motion paths.
The tagged dogfood and extended naming reel are recorded below.

## Tagged dogfood — 2026-10-16

Fleet job `ce8602e70ddc5f56f205da3c` built PR #21242 as tag `cmux-anim-20261016`. The tagged app was launched with its own bundle ID and socket. Captures were made with `debug.window_record` and `debug.motion` at fast speed.

- Pane `standard`, `crisp`, and `softLanding` all preserved fixed host geometry and directional split/close motion. The side-by-side reel is `artifacts/animation-recordings-20261016/pane-side-by-side.mp4`.
- Sidebar `slideFade` initially stretched the reveal to about 345 ms and kept two display links alive. That was visibly slower than `slide` (~189 ms), so the fade leg was separated onto the fast fade tokens.
- Fleet job `c7582966fac0653ca613b195` rebuilt the repair as tag `cmux-anim-20261016b`. The repaired `slideFade` recorded `timed.fadeOut` 133.8 ms, `timed.fadeIn` 133.2 ms, with width legs 166.5/167.7 ms and one display link. The corrected reel is `artifacts/animation-recordings-20261016b/sidebar-side-by-side.mp4`.
- Tab loading recordings for `instant`, `fade`, `fadeScale`, and `fadeSlide` were captured in `artifacts/animation-recordings-20261016/tab-*`; the tab loading test passed after fixing exit-state ownership.
- Naming variants were rebuilt at fleet job `95001aa9c1e6727bbfc0d9dd` as tag `cmux-anim-naming-20261017`. The extended reel is `artifacts/animation-recordings-20261017/naming-variants-side-by-side-extended.mp4`; the reviewed default is `crossfade`.

The captures are local review evidence and are intentionally not committed as source artifacts. The PR description and follow-up comment carry the fleet job IDs and reviewed conclusions.

## Efficiency receipt — 2026-10-18

The isolated tagged build was measured with 100 sidebar workspaces and 10 ticking rows for 5
seconds. The row-feed path did 220 ticks with zero structural rebuilds and zero list reloads;
182 row configures matched 182 row patches. Main-thread work averaged 435 microseconds per
tick, and debug-call latency was 1.09 ms p50 / 4.99 ms p95 / 9.14 ms max, with no over-frame
calls. The idle scroll pass had no missed frames. The ticking scroll pass had 9 missed frames
and 18 input calls over one frame, which is the next performance target. Receipt:
`artifacts/perf-sidebar-20261018/summary-naming-default.json`.

## Ticking-scroll efficiency follow-up — 2026-10-18

Time Profiler showed tick work was only 172–435 microseconds per tick, with no busy runs over
30 ms and no structural rebuilds. The clear low-risk hot path was repeated hover-card source
hit-testing during scroll realization while no card was active. `SidebarListView.updateHover`
now skips that geometry hit test in that state while preserving row hover updates and active-card
tracking.

The baseline aggregate had 9 missed frames during ticking scroll; the tagged after run had 1.
One repetition still spiked to 30 missed frames, so variance remains. Receipts are
`artifacts/perf-sidebar-20261018/summary-naming-default.json` and
`artifacts/perf-sidebar-20261018/summary-naming-after.json`.

## Scroll hot-path follow-up — 2026-10-18

The next profile found a second avoidable scan: `SidebarView.clipBoundsChanged` refreshed every
window hover target on each list bounds notification. The list already reconciles moving row hover
in `realizeVisibleRows`, so the global refresh was removed from the scroll callback. The tagged
fleet build is job `34479e838483fbb78598cdda`, tag `cmux-scroll-perf-20261018-v2`, head
`e14dec174c0c5e9486b9280911081f0e1e2b10ef`, artifact SHA-256
`9bb7ad40c49856cfae7c936d3c6b89fa04da4b657c1f7ba53e3c43c50555aace`.

After the ticking rows settled, a direct 120-event trackpad pass recorded 451 display frames,
zero missed frames, zero over-frame updates, zero list reloads and zero structural rebuilds. The
scroll RPC was 3.73 ms p50 / 21.28 ms p95 / 42.50 ms max; the counters recorded 55 realization
passes and six row configures. A nine-second Time Profiler capture showed 220 main-thread samples,
no busy run over 30 ms, and no sidebar Swift frame in the top stack; the remaining samples were
Core Animation display-link work and the synthetic debug transport. The first run overlapped row
startup and was discarded (three rebuilds and a 3.5 s frame), so it is not part of the receipt.
The raw profile is `artifacts/perf-sidebar-20261018/traces/manual-scroll-time-v2-correct.trace`.

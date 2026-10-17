# CMUX Next animation variants — 2026-10-16

This pass adds opt-in Debug Settings variants. Production defaults remain unchanged.

| Surface | Debug Settings key | Choices | Default | What changes |
| --- | --- | --- | --- | --- |
| Pane close and expand | `motion.pane.variant` | `standard`, `crisp`, `softLanding` | `standard` | Reuses the existing pane geometry and fixed-size host behavior; `crisp` shortens the structural response and `softLanding` adds a small settle treatment. |
| Sidebar collapse | `sidebar.collapseMotion` | `slide`, `slideFade` | `slide` | `slideFade` fades the sidebar panel while the width follows the same transition. Geometry is unchanged. |
| Tab loading indicator | `tabs.loadingAnimation` | `instant`, `fade`, `fadeScale`, `fadeSlide` | `instant` | Loading indicators enter/leave without changing tab measurements. The fade variants retain the layer until the exit animation completes. |

## Focused verification

All commands ran from `Packages/macOS/CmuxNext` on the animation worktree.

- `swift test --filter PaneMotionVariantTests` — 5 tests passed.
- `swift test --filter SidebarCollapseMotionTests` — 2 tests passed.
- `swift test --filter TabLoadingAnimationTests` — 3 tests passed.
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

No live tagged app recording was made in this pass; the focused suites validate the geometry, layer lifetime, default/reset behavior, and reduced-motion paths. The branch is ready for a tagged dogfood recording.

## Tagged dogfood — 2026-10-16

Fleet job `ce8602e70ddc5f56f205da3c` built PR #21242 as tag `cmux-anim-20261016`. The tagged app was launched with its own bundle ID and socket. Captures were made with `debug.window_record` and `debug.motion` at fast speed.

- Pane `standard`, `crisp`, and `softLanding` all preserved fixed host geometry and directional split/close motion. The side-by-side reel is `artifacts/animation-recordings-20261016/pane-side-by-side.mp4`.
- Sidebar `slideFade` initially stretched the reveal to about 345 ms and kept two display links alive. That was visibly slower than `slide` (~189 ms), so the fade leg was separated onto the fast fade tokens.
- Fleet job `c7582966fac0653ca613b195` rebuilt the repair as tag `cmux-anim-20261016b`. The repaired `slideFade` recorded `timed.fadeOut` 133.8 ms, `timed.fadeIn` 133.2 ms, with width legs 166.5/167.7 ms and one display link. The corrected reel is `artifacts/animation-recordings-20261016b/sidebar-side-by-side.mp4`.
- Tab loading recordings for `instant`, `fade`, `fadeScale`, and `fadeSlide` were captured in `artifacts/animation-recordings-20261016/tab-*`; the tab loading test passed after fixing exit-state ownership.

The captures are local review evidence and are intentionally not committed as source artifacts. The PR description and follow-up comment carry the fleet job IDs and reviewed conclusions.

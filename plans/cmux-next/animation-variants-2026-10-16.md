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

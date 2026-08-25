# Performance incident: History menu idle rebuild

Symptom: An idle cmux process holds 48–56% of one core while SwiftUI repeatedly rebuilds the History command graph.
User impact: Sustained CPU, energy use, animation/display-link churn, and periodic hangs in long-lived multi-workspace sessions.
Source: https://github.com/manaflow-ai/cmux/issues/10348 and its attached `top`/`sample` evidence.
Target surface: macOS app, SwiftUI/AppKit main menu.
Build/version/tag: branch `issue-10348-idle-history-menu-rebuild`, tagged Debug build `i10348-history`.
Repro workload: 20 additional terminal workspaces emitting alternating OSC titles every 70 ms, followed by an idle CPU sample.
Expected bad behavior: History projection or `history.menu.appear` work repeats while the History menu is closed.

Owner: `HistoryMenuCoordinator` owns the immutable menu projection; `FocusHistoryModel` and `ClosedItemHistoryStore` remain domain sources of truth.
Invariant: terminal-title churn never mutates the menu projection; main-menu tracking refresh resolves current labels and binds row actions to the same active manager.
Why the old path failed: the `CommandMenu` body walked both focus-history directions during unrelated app-body evaluations, and the first cache attempt mirrored titles without a menu-open freshness boundary.
Fix shape: revision-keyed `@Observable` projection, forced equal-suppressing refresh on actual menu appearance, one action-routing owner, and a rendered-row resolution cap.
Proof that closes it: cloud compile, focused cloud tests, operation-count assertions, a 20-surface remote CPU/sample capture, and DEBUG probe counts before/after opening History once.

## Remote result

- Fleet slot: `cmuxs-mac-mini-2-1.1`, macOS fleet GUI account `cmux`.
- Workload: 41 workspaces total, including 20 unnamed terminals continuously alternating OSC titles every 70 ms (stronger than the reported 7-workspace/20-surface case).
- Steady tagged-app CPU: 4.4–6.3% across the non-sampling `top` intervals; the final 14.4% interval overlapped the `sample` capture.
- Five-second sample: no `HistoryMenu`, `historyMenu`, `focusHistory`, `CommandMenu`, `AppBodyAccessor`, `makeMainMenu`, or `ViewGraphRootValueUpdater` frames matched.
- DEBUG appearance probe: one initial command-graph realization, then no additional events throughout sustained title churn and the sampling window.
- CUA verification: the installed Cua provider could front/key-drive the tagged app, but screen capture was unapproved, the terminal window exposed no AX elements, and the desktop pixel-click path closed the CUA daemon connection. No shared-host TCC permissions were changed. The final implementation uses AppKit's process-level `NSMenu.didBeginTrackingNotification` boundary (the same tested pattern as `CommandPaletteInteractionMonitor`), covered by `testHistoryMenuCoordinatorRefreshesTitlesWhenMainMenuBeginsTracking` and user dogfood.

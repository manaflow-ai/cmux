# Acceptance criteria: cmux iOS miniature-first pane/tab hub

Branch: `feat-ios-pane-tab-redesign` (based on `529531b99d`). Design is locked per owner interview (`docs/ios-pane-tab-redesign.md`); this document defines what "done" means and what evidence proves it. Code anchors: `TerminalPickerMenu` + `WorkspaceDetailView.terminalPickerToolbarButton` (Packages/iOS/CmuxMobileShellUI), `MobileWorkspacePreview.terminals: [MobileTerminalPreview]` (flat, no topology), Mac-side `MobileWorkspaceListObserver` (topic `workspace.updated`, keyed off `paneLayoutVersionPublisher`, `panelsPublisher`, `$panelTitles`, `$panelCustomTitles`), `MobileTerminalRenderObserver.emitRenderGrid` (emits `terminal.render_grid` for ALL registered surfaces once any client subscribes), `MobileHostService.mobileHostCapabilities`, `MobileShellComposite+TerminalOutputDelivery.terminalByteContinuationsBySurfaceID` (single mounted sink today), `BrowserSurfaceStore` (phone-local, one browser per workspace), `MobileTerminalRenderGridFrame.activeScreen` / `stateSeq`.

## 1. User-visible behavior that must pass

### A. Navigation shell (workspace list → hub → pane → tab)

1. Tapping a workspace row in the existing workspace list pushes the LIVE MINIATURE HUB for that workspace. The workspace list itself is unchanged (rows, groups, pinning, unread dots, Mac avatars all identical to `main`).
2. The hub renders the Mac's real split-pane layout for that workspace as a proportionally correct miniature: pane rectangles match the Mac's split axes, nesting, and size ratios to within 5% of each pane's relative width/height (evidence: side-by-side screenshot comparison, Mac screenshot vs phone hub).
3. Tapping a pane rectangle in the hub pushes the full-screen view of that pane's ACTIVE tab (the tab currently selected in that pane on the Mac at entry time). Terminal input, keyboard, composer, safe-area behavior in full-screen match the current `WorkspaceDetailView` terminal experience (mounted via `GhosttySurfaceRepresentable`, identity keyed by terminal id).
4. iOS interactive back-swipe (edge swipe) and the toolbar back button from full-screen return to the hub, hub → workspace list. Exactly three levels; no route skips a level, including push-notification deep links (a deep link to a terminal lands on full-screen with back returning to that workspace's hub, not to the list).
5. Panes in the hub are selectable only. There is no horizontal or vertical pane-paging gesture anywhere: swiping left/right in full-screen must NOT switch panes (test: horizontal swipe in terminal content area changes nothing navigationally).
6. `TerminalPickerMenu` no longer appears in the workspace toolbar. Every action it carried is rehomed and reachable: New Workspace, New Terminal, New Browser, View as Text, Send Feedback, and DEBUG Copy Debug Logs (name the new homes in the PR description). No orphaned accessibility ids: `MobileTerminalDropdown` / `MobileTerminalMenuItem-*` UI tests updated or replaced.

### B. Miniature hub liveness and layout correctness

7. Each pane in the miniature shows LIVE content rendered client-side from `terminal.render_grid` frames (text_vt fidelity accepted, see section 6). With `yes`/a counter running in a pane on the Mac, the corresponding miniature region visibly changes at least once per second.
8. Mac layout changes propagate to the hub without user action, within 2 s of the Mac-side change, for each of: split added, split removed (pane closed), split resized (divider drag; ratios update), tab created, tab closed, tab renamed (`panelCustomTitles` path), tabs drag-reordered (the `paneLayoutVersionPublisher` path), workspace renamed. This requires the new topology RPC; a new capability string (e.g. `workspace.topology.v1`) must be added to `MobileHostService.mobileHostCapabilities` and feature-detected on the phone.
9. Against a Mac that does not advertise the topology capability (use the existing `CMUX_DEBUG_SUPPRESS_MOBILE_CAPS` DEBUG hook), the phone shows a defined degraded state: a single-pane hub listing the flat `terminals` array as tab cards, never a blank/crashed hub, plus the existing Mac-update hint pathway.
10. The pane containing the Mac's focused surface is visibly indicated in the hub; indication updates when Mac focus moves.

### C. Pane full-screen: bottom thumbnail strip

11. The strip shows one card per tab in the entered pane, in the Mac's spatial tab order (`orderedPanelIds` order as serialized by the workspace list observer). A Mac-side reorder re-sorts the strip within 2 s while the strip is visible.
12. Each card shows a live thumbnail rendered from that surface's `terminal.render_grid` frames, plus the tab's displayed title (custom rename respected). Live means: two cards whose Mac terminals are both producing output visibly change concurrently (this is the key multi-surface proof; today `MobileShellComposite` opens one byte sink per mounted terminal, so this criterion proves the new multi-surface consumption works).
13. Tap card = switch the full-screen view to that tab, within 300 ms perceived (old surface torn down, new one mounted; no keyboard steal on switch, matching the current `selectTerminalFromChrome` autofocus-suppression contract).
14. Auto-hide: the strip hides within 500 ms of (a) the first keystroke into the terminal, or (b) the start of a terminal scroll gesture. A thin persistent handle remains; tapping or dragging the handle re-reveals the strip. Revealing must not dismiss the keyboard; hiding must return the reclaimed height to the terminal grid (no dead letterbox band).
15. Strip visibility state does not leak across panes/workspaces incorrectly: entering a pane always starts with the strip visible (or a single documented default), and the handle is always reachable.
16. The selected tab's card is visibly distinguished, and the strip auto-scrolls to keep the selection visible when selection changes.

### D. Attention shelf toggle

17. A toggle control sits at the left edge of the strip. OFF (default): cards in Mac order. ON: cards needing attention sort to the front, stable Mac order within each partition (attention set, then the rest).
18. "Needs attention" = agent session waiting for user input, plus unread/bell state for that surface; the exact predicate must be written in the PR description and covered by a unit test on the sorting function (pure function in CmuxMobileShellModel, testable without UI).
19. Toggling animates the reorder; toggling back restores exact Mac order. The toggle state persists across app relaunch (one global setting; document if per-workspace instead). No other mechanism reorders cards (no recency reordering while the toggle is off, no pinning anywhere).
20. Attention state changes while the shelf is ON re-sort live, but never mid-touch (no card moves out from under a finger between touch-down and touch-up).

### E. Browser and chat cards

21. A Mac browser pane/tab in the workspace appears in the hub/strip as a normal card with a live visual preview, via the new mirror RPC/stream. Tapping it opens the mirrored Mac browser view full-screen.
22. The phone-local browser (`BrowserSurfaceStore`, one per workspace, DuckDuckGo default) still works from its rehomed "New Browser" action and appears as a card visually distinguished from mirrored Mac browser cards (explicit badge or label; section 2 case 2 tests the confusion case).
23. An agent-chat session appears as its OWN card (not merely a mode toggle on the terminal card). Tapping it opens the chat full-screen (`ChatConversationStore`-backed). The chat card shows agent state (running/waiting) and its terminal binding remains intact: chat card and its bound terminal card coexist without duplicating the conversation.
24. The alternate-screen notice (`store.isAlternateScreen` + `AltScreenNoticeButton`) still surfaces in full-screen terminal view.

### F. Keyboard interactions

25. With the keyboard up, the strip handle (and the strip when revealed) sits above the keyboard/accessory bar, never occluded and never double-counting keyboard height (the `ignoresSafeArea(.keyboard)` + `keyboardHeight` contract in `GhosttySurfaceRepresentable` must not regress: no gap between grid and keyboard, no hidden last row).
26. Typing latency in the full-screen terminal is unchanged while the strip streams live thumbnails: key-to-echo p50 within 10% of `main` baseline on the same simulator.
27. Switching tabs from the strip while the keyboard is up keeps the keyboard up and routes subsequent input to the newly selected tab.

### G. Reconnect, offline, lifecycle

28. Mac disconnect while on any of the three levels shows the existing recovery affordances (`TerminalDisconnectedOverlay` / `mobileConnectionRecoveryOverlay` / `MobileMacConnectionStatusPill` or their successors); the hub does not render stale miniatures as if live: a disconnected state is visually flagged within 3 s.
29. On reconnect (including Mac app relaunch), topology re-syncs and every visible preview refreshes; no thumbnail remains frozen at pre-disconnect content past 5 s post-reconnect (the render-grid replay/`stateSeq` baseline path must reset per surface; watch the "waiting_for_baseline" delivery states in `MobileShellComposite+TerminalOutputDelivery`).
30. Backgrounding the phone app stops render-grid consumption (no growing buffers); foregrounding restores live previews within 3 s at whichever level the user left. Mac-side demand follows subscriptions: with no phone subscribed, `MobileTerminalRenderObserver` releases frame+tick demand (existing `debugIsRetainingNotificationDemandForTesting` hook must stay true only while subscribed).

### H. iPad

31. iPad (full screen and Split View/Slide Over widths): hub scales to width, cards keep readable aspect ratios, strip does not collide with the pointer/keyboard toolbars, and nothing renders in the phone-width layout stretched. One recorded pass on an iPad simulator in 1/2 Split View is required; pixel-perfection tuning beyond non-broken is not gated for v1 unless the owner flags it in dogfood.

### I. Localization and accessibility

32. Every new user-facing string is localized via `String(localized:)` with en + ja entries in `Resources/Localizable.xcstrings` (repo policy).
33. New interactive elements have accessibility identifiers (pattern like existing `MobileTerminalMenuItem-<id>`) sufficient for the XCUITests in section 4.

## 2. Negative and edge cases (fail the task if broken)

1. Single-pane workspace: the hub still renders one full-width live miniature card with the workspace name; one tap enters it. The hub is NOT auto-skipped (uniform back-swipe topology), and it must not look broken or empty. If the team instead ships an auto-enter fast path, back-swipe from full-screen must still land on the hub, and the choice must be stated in the PR description.
2. Phone-local browser vs mirrored Mac browser open in the same workspace: both cards visible, visually distinct, tapping each opens the right one; closing the phone-local browser never closes the Mac's browser and vice versa.
3. Workspace with exactly 1 tab in a pane: strip shows one card plus the attention toggle; toggle is inert but not broken; no reorder animations fire.
4. 10+ tabs in one pane: strip scrolls horizontally with no visible hitches; offscreen thumbnails do not each consume a full-rate stream (down-throttle or pause offscreen cards; mechanism named in PR).
5. 6+ panes, nested splits: every pane in the miniature remains individually tappable (minimum 44 pt hit target even when the drawn rect is smaller; hit-area inflation allowed) and labels truncate rather than overlap.
6. Zoomed pane on the Mac (bonsplit zoom) and alternate-screen TUIs (vim/htop): thumbnails and miniature render the alternate screen content (`MobileTerminalRenderGridFrame.activeScreen == .alternate` handled), not a blank or primary-screen ghost; behavior for Mac pane zoom is defined and consistent (mirror the zoom or show underlying layout, stated in PR).
7. Terminal input latency and scroll in full-screen are unaffected by N live thumbnails streaming (see metrics); a failing Instruments comparison fails the task.
8. No touch stealing: taps and drags inside full-screen terminal content go to the terminal; the strip/handle only consumes touches on itself; back-swipe triggers only from the leading screen edge (system edge-pan), so a scroll or selection drag starting >~24 pt from the left edge never navigates back.
9. Stale previews after reconnect (G.29) explicitly re-tested with a Mac relaunch, not just a network blip.
10. Rapid churn: creating and closing splits/tabs on the Mac in quick succession (5 ops in 5 s) never crashes the phone, never leaves ghost cards for closed surfaces, and settles to the correct final topology within 3 s of the last op.
11. Two workspaces open in sequence: entering workspace B's hub after A never shows A's thumbnails (surface-id keying; no continuation leaks in `terminalByteContinuationsBySurfaceID`'s successor).
12. Mac app with the feature but phone talking to a second, older Mac in the aggregated list: per-Mac capability gating, not global (workspace rows carry `macDeviceID`; the degraded state of B.9 applies per Mac).

## 3. Platform matrix

| Surface | Required | Notes |
|---|---|---|
| iOS Simulator (iPhone, current iOS) | PRIMARY. All section 1/2 criteria verified here. | Unique per-session simulator, booted with `-CurrentDeviceUDID` (repo isolation policy). |
| iPad Simulator | One pass: H.31. | Split View + full screen. |
| macOS Mac side | Must not regress. Topology RPC + multi-surface streaming land in `Sources/Mobile/`; desktop terminal behavior with NO phone attached must be untouched (demand-release contract, G.30). Mac unit tests for the new observer/serializer run in CI. Tagged build only (`./scripts/reload-cloud.sh --tag <tag>`); tests on `cmux-aws-m4pro` or GitHub Actions, never local `xcodebuild test`. |
| Physical iPhone | Explicitly NOT required this round. | Owner decision; note it in the handoff. |

## 4. Required evidence

Per group; all artifacts attached to the PR or a linked evidence page.

VIDEO with frame splits (verify-ui-video pattern) is mandatory for anything temporal:

- V1 Navigation: one continuous recording of list → hub → pane → tab-switch → back-swipe → hub → back → list (A.1-A.5). Frame split proves no intermediate blank frames >2 frames at transition boundaries.
- V2 Live-update proof: split-screen recording (Mac screen capture + simulator recording, wall clock visible in both) with two Mac panes running distinct counters; both phone thumbnails visibly change concurrently (C.12, B.7). This is the single most load-bearing artifact.
- V3 Topology liveness: on camera, add a split, resize a divider, close a tab, rename a tab, drag-reorder tabs on the Mac; hub/strip follows each within 2 s (B.8, C.11).
- V4 Auto-hide/reveal: typing hides strip, handle reveals it, with keyboard up (C.14, F.25); frame split proves timing bound.
- V5 Attention shelf: toggle on/off reorder animation; then an agent flips to waiting-for-input mid-recording and the card moves front (D.17-D.20).
- V6 Reconnect: kill/relaunch tagged Mac app; recovery overlay, then refreshed previews (G.28-29).
- V7 iPad Split View pass (H.31).

SCREENSHOTS: Mac layout vs hub miniature side-by-side for 2-pane, 4-pane nested, and 6+-pane cases (B.2, edge 5); degraded no-capability state (B.9); browser vs mirrored-browser card distinction (E.22); alt-screen thumbnail (edge 6); ja locale spot-check of new screens (I.32).

LOGS: DEBUG `MobileDebugLog` excerpts showing `sync.render_grid_*` delivery lines for ≥2 surfaces concurrently; Mac `cmuxDebugLog` `mobile.render_grid surface=… seq=…` for multiple surface ids; `mobile.observer EMIT workspace.updated` on each topology mutation in V3.

TESTS (must be green in CI; new test files wired per repo pbxproj/SPM rules):
- Unit (CmuxMobileShellModel or new package): topology DTO decode + tree layout math; attention-shelf sort (predicate, stability, toggle-off restore); strip order = Mac order under reorder payloads; capability gating fallback.
- Unit (Mac, cmuxTests): topology serializer emits correct tree for nested splits; emission hash re-fires on split/resize/reorder; render-observer demand release retained.
- Unit (CmuxMobileShell): multi-surface render-grid fan-out delivers frames to N registered sinks, baseline reset on reconnect.
- XCUITest (iOS, simulator): navigation path A.1-A.4 via accessibility ids; strip tap-to-switch; toggle persistence across relaunch. Runs via the repo's CI path, not local `xcodebuild test`.

INSTRUMENTS traces: section 5 artifacts (.trace files or exported summaries) for baseline vs feature.

## 5. Performance risks and metrics

Risks: (a) `MobileTerminalRenderObserver` already emits frames for ALL surfaces to the topic; the phone consuming all of them multiplies decode + SwiftUI invalidation work per frame; (b) per-thumbnail view invalidation storming the main thread (repo has a documented history of LazyVStack invalidation livelocks; the snapshot-boundary rule applies to the strip and hub); (c) Mac-side emission cost when a hub subscribes with many surfaces; (d) memory growth from N retained grid states/rendered images; (e) strip scroll hitches while thumbnails update.

Pass thresholds (iPhone simulator on the dev Mac, 8 live surfaces across 4 panes, all producing output):

1. Typing latency: key-to-echo p50 within 10% of `main` baseline, measured with Time Profiler + os_signpost during active thumbnail streaming.
2. Hitches: Instruments "Animation Hitches" during strip scroll and hub display: hitch time ratio < 5 ms/s, zero hitches > 100 ms.
3. Main thread: Time Profiler steady state (previews updating, no user input) main-thread utilization < 30%; no single update pass > 8 ms.
4. SwiftUI template: per render-grid frame, view body re-evaluations scoped to the affected card only (no whole-strip or whole-hub invalidation; verify update counts in the SwiftUI instrument).
5. Memory: phone app growth < 150 MB over baseline with 12 live thumbnails; stable (no monotonic growth) over a 10-minute soak.
6. Mac side: cmux process CPU with one phone subscribed to hub view < baseline + 15 percentage points (Time Profiler on the tagged Mac build); zero measurable Mac cost with no phone attached (demand released).
7. Throttle contract: thumbnail update rate is bounded (state the cap, e.g. ≤ 4 fps per thumbnail) and documented; "visibly live" per B.7 still holds at the cap.

Templates: Time Profiler, SwiftUI, Animation Hitches (or Hangs), Allocations/Leaks for the soak. Attach baseline (`main`) and feature traces for 1-3.

## 6. Explicitly out of scope (accepted for v1)

1. Horizontal tab-paging gesture in full-screen: dropped (gesture conflicts). Its absence is REQUIRED (A.5), not merely unshipped.
2. Per-tab pinning: no pin concept anywhere in the new UI; only the attention shelf reorders.
3. Physical iPhone verification: not required this round; simulator evidence suffices.
4. Full-color styled-cell preview fidelity: previews may be text_vt fidelity (layout-correct, monochrome/default-styled). A styled exporter is in scope only if trivially available; otherwise state text_vt in the PR. B.7/C.12 liveness still applies at this fidelity.
5. Multi-tab phone-local browser and deep browser mirroring interactions (navigation control of the Mac browser from the phone beyond viewing) unless the mirror RPC lands them for free.
6. iPad pixel-perfection beyond H.31 non-broken.
7. Old-Mac feature parity: degraded state per B.9 is the contract, not a reimplementation of the picker.

## Dogfood gate

No dogfood handoff until the full three-level experience passes sections 1-2 on the simulator; "pixel-perfect, interaction-perfect" means V1-V5 videos show no visual glitches (misaligned cards, flash-of-empty, jumping layout) at frame granularity, and any deviation is either fixed or explicitly owner-waived before merge.

# Portal Anchor-Churn Lifecycle Spec (Living)

Status: Implemented on `task-white-rect-frame-cmd-d-ctrl-d`  
Last updated: 2026-02-25  
Scope: `Sources/TerminalWindowPortal.swift`, `Sources/BrowserWindowPortal.swift`, close/unmount call sites

## Problem
When split/workspace structure changes, SwiftUI/Bonsplit can temporarily replace anchor views.  
Today, portal prune can detach a still-live hosted view during that transient anchor gap, then rebind it a frame later.

Observed symptom:
- one-frame flash/jank
- log pattern: `portal.detach` + `surface.view.windowMove inWindow=0` followed by `portal.bind` + `inWindow=1` within ~1 frame

## Definitions
- Anchor: placeholder AppKit view from SwiftUI used for geometry (`HostContainerView` in `GhosttyTerminalView`).
- Hosted view: real portal-hosted heavy view (`GhosttySurfaceScrollView` / browser slot+`WKWebView`).
- Entry: portal record keyed by hosted-view identity.
- Anchor churn: anchor identity changes while hosted view and panel are still logically alive.

## Goals
1. Prevent transient detach/rebind for alive, visible hosted views during anchor churn.
2. Keep real teardown correct: closed/unmounted panels must be detached promptly.
3. Apply the same lifecycle semantics to terminal and browser portals.
4. Avoid timing hacks tied to a specific interaction (`Ctrl+D`, resize, drag).

## Non-goals
1. Eliminate all SwiftUI/Bonsplit rebuilds.
2. Redesign Bonsplit tree model as a prerequisite.
3. Special-case a single branch/path.

## Core Invariants
1. Hosted-view ownership is keyed by hosted identity, not anchor identity.
2. Anchor loss alone is not sufficient to detach a visible, still-live hosted view.
3. Detach is immediate only for explicit teardown or definitively dead entries.
4. Reconcile can move/resize/hide; prune may retire entries, but only under lifecycle rules.

## Lifecycle Model
Entry states:
- `bound_visible`
- `bound_hidden`
- `orphan_visible_no_replacement`
- `detached`

Transitions:
1. `bind(anchor, visible=true)` -> `bound_visible`
2. `bind(anchor, visible=false)` -> `bound_hidden`
3. `anchor_missing` while `visible=true` and no overlap replacement -> `orphan_visible_no_replacement` (stay attached)
4. `overlap_replacement_detected` while orphaned -> `detached`
5. `anchor_reappears` while orphaned -> back to `bound_visible`/`bound_hidden`
6. `explicit_detach` (tab/panel/workspace teardown) -> `detached` immediately

## Implemented Behavior
1. Prune for visible orphaned entries is deterministic:
   - if no overlapping alive replacement exists: keep attached
   - if overlapping alive replacement exists: detach immediately
2. Hidden/non-visible orphaned entries detach immediately on first stale pass.
3. Sync does not force-hide visible entries for transient:
   - missing anchor/window
   - anchor window mismatch
   - host-bounds-not-ready
   This preserves last-good frame during churn.
4. Explicit teardown is immediate:
   - added `TerminalWindowPortalRegistry.detach(hostedView:)`
   - `TerminalPanel.close()` calls explicit detach
   - `TerminalSurface.deinit` also detaches as a final cleanup path
5. Browser portal behavior is kept symmetrical with terminal.

## General Algorithm
Maintain a monotonic `reconcilePass` in each portal.

During prune/reconcile:
1. If hosted view is gone: detach now.
2. If explicit teardown requested: detach now.
3. If anchor invalid:
   - if `visibleInUI == false`: detach now.
   - if `visibleInUI == true` and an overlapping alive replacement exists: detach now.
   - if `visibleInUI == true` and no replacement exists: keep attached.
4. If anchor valid: synchronize frame/visibility.

## Explicit Teardown Contract
Anchor-churn handling must not leak stale views after real close/unmount.

Required detach events:
1. Panel/tab close path (terminal and browser) should request explicit portal detach.
2. Workspace unmount/hide paths that are terminal/browser-specific should mark non-visible and/or explicit detach according to intended persistence.
3. Window close already tears down registry and remains immediate.

## Cross-Portal Consistency
Terminal and browser portals should follow the same lifecycle semantics:
- same state model
- same prune rules
- same logging vocabulary

Implementation can be duplicated first, then extracted into shared helper once behavior stabilizes.

## Optional Bonsplit Improvement (Not Required for Correctness)
Bonsplit can further reduce churn by preserving stable host wrapper identity by pane id during certain subtree collapses.  
This is an optimization, not the primary correctness fix.

## Observability
Add structured logs:
- `portal.lifecycle state=<from->to> reason=<...> hosted=<...> anchor=<...> pass=<n>`
- `portal.prune.defer ... replacement=none`
- `portal.prune.detach ... explicit=<0|1> visible=<0|1>`

Primary success metric in logs:
- no non-explicit `detach -> bind` bounce for same hosted view within 1 frame.

## Acceptance Criteria
1. Closing bottom-right split no longer emits one-frame detach/rebind bounce for surviving right hosted view.
2. Resize under split churn does not produce transient right-side disappearance.
3. Real tab/panel close still detaches immediately and does not leave stale hosted overlays.
4. Browser portal behavior remains symmetric with terminal portal behavior.

## Regression Tests To Add
Terminal portal (`cmuxTests/CmuxWebViewKeyEquivalentTests.swift` in `TerminalWindowPortalLifecycleTests`):
1. `testPruneDeadEntriesKeepsVisibleAnchorlessHostedViewWithoutReplacement` (added)
2. `testPruneDeadEntriesDetachesVisibleAnchorlessHostedViewWhenReplacementAppears` (added)
3. `testPruneDeadEntriesDetachesHiddenAnchorlessHostedViewImmediately` (added)
4. `testRegistryDetachRemovesPortalHostedTerminalView` (added)

Browser portal:
1. `testPruneDeadEntriesKeepsVisibleAnchorlessWebViewWithoutReplacement` (added)
2. `testPruneDeadEntriesDetachesVisibleAnchorlessWebViewWhenReplacementAppears` (added)
3. `testPruneDeadEntriesDetachesHiddenAnchorlessWebViewImmediately` (added)

## Rollout Plan
1. Implement lifecycle fields + prune algorithm in terminal portal. Done.
2. Add/green terminal tests. Done.
3. Mirror algorithm/tests in browser portal. Done.
4. Validate with debug logs for `Ctrl+D` and resize churn. Next runtime validation step.
5. If needed, apply optional Bonsplit identity optimization as a follow-up.

## Open Questions
1. Whether to extract shared lifecycle helper now or after both portals are stable.

## Decision Log
- 2026-02-25: Choose lifecycle-based detach policy over interaction-specific guards.
- 2026-02-25: Make explicit teardown authoritative; anchor loss alone is non-authoritative for visible entries.

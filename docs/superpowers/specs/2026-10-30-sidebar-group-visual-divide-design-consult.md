# Design Deliberation: Sidebar workspace groups — header band and indent guide

**Source:** docs/superpowers/specs/2026-10-30-sidebar-group-visual-divide-design.md
**Date:** 2026-10-30
**Rounds:** 4 (max)
**Mode:** converge
**Personas:** devils-advocate, pragmatist, simplifier, user, astra (GPT-6, repo-grounded), sol (GPT-5.6, repo-grounded)
**Final verdict:** Needs Work — all structural defects resolved; the remaining items are two bounded edge cases (documented/optional), two concrete must-dos now folded into the final document, and one unresolved product decision (on-by-default) that is a fixed brainstorming choice.

Note on method: every code claim from the repo-grounded reviewers (astra, sol) was verified against the working tree before being folded in. All of their claims across all four rounds checked out. Two claims the design author (Claude) introduced in revisions were later found wrong by the reviewers and corrected (see Round 4). The fixed brainstorming decisions (treatment B + D, color wash, on-by-default with one switch, build approach 1) were treated as requirements and never revised away.

## Round 1: Initial Critiques

### Dr. Scrutiny (devils-advocate)
**Verdict:** needs_work | **Confidence:** 0.75

Comprehensive and clear; treatment B+D and build approach 1 well-reasoned and fit the codebase. Wants: thorough scenario testing; careful coordination with the two in-flight upstream PRs; concern that builder-left opacity values add variability; no explicit treatment of AppKit row-height-cache / cell-recycle performance; a UX/accessibility expert review.

### Reginald 'Rex' Mondo (pragmatist)
**Verdict:** approve | **Confidence:** 0.95

Exceptionally well-researched; proactively mitigates real risks. Praises the dual-renderer constraint handling via shared metrics + precomputed data, the explicit performance/drag/height-cache mitigations, the in-row painting choice that contains complexity, the upstream-conflict strategy, and the exhaustive edge-case/test coverage.

### Professor Simplex (simplifier)
**Verdict:** approve | **Confidence:** 0.95

Enhances group visibility with minimal complexity; leverages existing row elements; centralizes color resolution; configurable; on-by-default with revert.

### Marcus 'Mark' Iterate (user)
**Verdict:** needs_work | **Confidence:** 0.70

A solution for a problem most users don't have; risks visual clutter; might make them avoid group colors; noise for small/short groups; another default to hunt down and disable; existing indentation already conveys membership.

### Astra (astra, repo-grounded)
**Verdict:** reject | **Confidence:** 0.97

Per-row approach fits the repo, but five code-level defects:
1. Drop-hit change targets `SidebarWorkspaceGroupHeaderMetrics.dropTargetHeight`, which has no callers; the real targets are table row rects (AppKit) / SwiftUI anchors, and `SidebarWorkspaceReorderDropResolver` also treats an empty header's upper half as an adopt target in the right half — so growing the header doesn't guarantee the gap means "before this group." Test empty-header gap drops on both halves.
2. `isFirstRow` is derived from `sidebarReorderIds` (empty outside a drag); reusing it for `topGap` gives the first header a gap at rest and shifts heights during drags. Use a `workspaceRenderItems`-derived fact.
3. Contrast flooring can't be delivered by the named helper: `contrastFloored` returns a fully opaque color when the floor is unreachable; equal-to-backdrop stays invisible. Specify a decorative target, opacity limits, and a luminance/neutral fallback; test equal fg/bg.
4. `showOptimisticDeselection()` paints `NSColor.clear` and runs on deselect before the authoritative render; omitting it flashes the band away. Fold it into the shared band path and test preview/rollback.
5. The schema has a generated embedded copy (`CmuxConfigSchema.generated.swift`) that must be regenerated; without it CLI `cmux set` rejects the key and verify-local's drift check fails.

### Sol (sol, repo-grounded)
**Verdict:** reject | **Confidence:** 0.98

1. First-row exemption mis-wired (`sidebarReorderIds` transient); derive from `workspaceRenderItems.first`.
2. `dropTargetHeight` is not in either renderer's drop-hit path; the resolver splits the actual frame at its midpoint.
3. Height-cache "lockstep" claim wrong: the estimate uses global magnification, authoritative uses `model.fontScale`; make the estimate model-aware incl. `topGap` and first-row.
4. Omitted optimistic-deselection paint path.
5. Settings search is curated; the entry belongs with the curated entries + the hand-maintained anchor contract, not only the named app index.
6. Resolver signature must include the backdrop and `brightenInDarkMode`.

## Design Lead Revision (after Round 1)

### Rationale
All five astra claims and all six sol claims were verified true in the repo (dropTargetHeight has exactly one reference — its definition; `sidebarReorderIds` built from the drag; `showOptimisticDeselection` paints clear and is invoked by the table controller; the generated schema + generator exist; the curated search files exist; `contrastFloored` goes opaque; estimate vs authoritative use different fontScale sources) and folded in.

### Key Changes
- Rewrote drag-and-drop around the real row-frame midpoint split; removed reliance on `dropTargetHeight`; added the empty-group right-half adopt exception.
- Added a separate stable `isFirstRenderedRow` fact from `workspaceRenderItems.first`.
- Specified a capped decorative-separation target + neutral fallback instead of the text floor; added backdrop + `brightenInDarkMode` to the resolver inputs.
- Made `showOptimisticDeselection()` paint the idle band via the shared helper.
- Expanded the Setting into a full consumer list: schema regeneration + curated search + anchor contract + native declared-path test.
- Made the height estimate model-aware (no first-row settle).
- Added recorded concerns (user clutter; builder opacity latitude) and a guide-view-recycling note.

## Round 2: Deliberation

### Dr. Scrutiny (devils-advocate)
**Verdict:** approve | **Confidence:** 0.90 | **Changed from Round 1:** needs_work → approve. Rationale adequately addresses prior concerns; still wants a UX/accessibility pass.

### Reginald 'Rex' Mondo (pragmatist)
**Verdict:** approve | **Confidence:** 0.98 | **Changed:** 0.95 → 0.98. The code-grounded corrections (drop resolution, optimistic deselection, height caching) and process requirements (schema regen, curated search) materially de-risk the build.

### Professor Simplex (simplifier)
**Verdict:** approve | **Confidence:** 0.95 | **Unchanged.** Rationale addresses prior concerns including code-claim verification.

### Marcus 'Mark' Iterate (user)
**Verdict:** needs_work | **Confidence:** 0.80 | **Changed:** 0.70 → 0.80. Acknowledges the concern is understood but deprioritized by keeping the feature on by default; the mitigations don't remove the friction for simple setups.

### Astra (astra)
**Verdict:** reject | **Confidence:** 0.95 | **Changed:** confirmed the Round 1 structural fixes landed, raised new issues.
- Contrast contract still fails when terminal-match is off: the sidebar can have a separate material/tint policy (`SidebarBackdropSettingsSnapshot`), so differently-tinted sidebars give identical resolver inputs; neutral label tint isn't universally distinguishable; scheme is declared, not luminance-derived.
- **Factual error:** the header name does NOT use `readableSecondaryColor` — it paints `Color.primary`/`labelColor` at 0.9. "Retaining today's foreground" doesn't establish legibility over the new band; specify a text-over-band check.
- Member-guide drag-dim parity gap: AppKit dims the whole cell (guide dims); SwiftUI's drag opacity is inside `TabItemView` while the guide overlay is outside it (guide wouldn't dim).

### Sol (sol)
**Verdict:** reject | **Confidence:** 0.98 | **Changed:** confirmed prior corrections, raised new issues.
- `workspaceRenderItems.first` isn't the first rendered row (items dropped on snapshot-cache miss).
- Settings search file list wrong: entry → `CuratedSettingEntry+Default.swift`; alias → `Sources/SettingsSearchAliases.swift`.
- Header name uses primary/label at 0.9, not `readableSecondaryColor` (same as astra).
- Noncontiguous legacy group runs: one per-group last member can't terminate a split guide.
- `groupGuide` on the row model would trigger height-cache remeasures unless excluded from height equivalence.

## Design Lead Revision (after Round 2)

### Rationale
All six new claims verified true: header text is `Color.primary`/`labelColor` at 0.9 (my earlier claim retracted); `workspaceRowInput` returns nil on cache miss and renderers compactMap it out; the curated/alias files are as sol described; the render item list tolerates split runs; `hasHeightEquivalentContent` excludes only `index`/`isFirstRow`; AppKit cell dims whole-cell while SwiftUI opacity is inside `TabItemView`; `SidebarBackdropSettingsSnapshot` carries the sidebar's own material/tint.

### Key Changes
- Corrected the header-text claim; kept today's paint; added a text-over-band legibility check.
- First-rendered-row computed from the rendered projection.
- Fixed the settings-search file list (curated entry + alias + anchor).
- Made the guide run-aware (per-run boundaries by rendered adjacency); renamed the fact.
- Specified `groupGuide` as paint-only, normalized out of member height equivalence; added an anti-goal.
- SwiftUI guide overlay applies the same `isBeingDragged` opacity; added a dragged-member parity test.
- Set the resolver backdrop to the "effective sidebar backdrop" (terminal, else sidebar material/tint); neutral fallback validated against it; custom-tint + scheme-mismatch tests.

## Round 3: Deliberation

### Dr. Scrutiny (devils-advocate)
**Verdict:** approve | **Confidence:** 0.90 | **Unchanged.** Same approving points; standing UX/accessibility suggestion.

### Reginald 'Rex' Mondo (pragmatist)
**Verdict:** approve | **Confidence:** 1.0 | **Changed:** 0.98 → 1.0. "Low-risk blueprint"; remaining risk is execution (developer expertise, timeline).

### Professor Simplex (simplifier)
**Verdict:** approve | **Confidence:** 0.95 | **Unchanged.** Still simple enough; rationale adequate.

### Marcus 'Mark' Iterate (user)
**Verdict:** needs_work | **Confidence:** 0.85 | **Changed:** 0.80 → 0.85. The "one-line change to flip the default" admission underscores that the default friction is avoidable; objection stands.

### Astra (astra)
**Verdict:** reject | **Confidence:** 0.96 | **Changed:** confirmed primary-text and dragged-guide fixes; new issues.
- "Fully label-colored opaque sidebar is not a real configuration" is false: schema permits tint + `tintOpacity = 1`; the compositing formula preserves equal fg/bg RGB at every alpha, so a higher-opacity same-color fallback stays invisible. Need a contrasting fallback; test neutral-equals-backdrop.
- Effective backdrop underspecified: `SidebarBackdropSettingsSnapshot` is a material policy, not final RGB; only `sidebarReadabilityBackdrop` is plumbed and it's nil over material. Specify the approximation/propagation.
- **Importer omitted:** `SidebarSettingsFileMapping.booleanSettings` + `parseSidebarSection` import only registered booleans; without registration the app ignores a CLI-written value.
- Height-cache correction incomplete: the member model retains the whole settings snapshot (so a toggle still remeasures) and header configs use full-model equality (bandStyle not excluded).

### Sol (sol)
**Verdict:** reject | **Confidence:** 0.99 | **Changed:** confirmed Round 2 fixes; new issues.
- Effective backdrop not a concrete color when terminal-match off (dynamic material + translucent tint; opaque only under Reduce Transparency); row env carries only terminal backdrop or nil.
- Guide-run boundaries must use the filtered projection too (same cache-miss problem).
- Header `bandStyle` not excluded from AppKit header height equivalence (full-model equality).

## Design Lead Revision (after Round 3)

### Rationale
All verified: `readabilityBackdropHex` is nil over material; `cmuxCompositedNSColor` preserves equal fg/bg RGB; `SidebarSettingsFileMapping`/`parseSidebarSection` import only registered booleans; header configs use full-model height equality. Adopted a simpler backdrop model.

### Key Changes
- Backdrop: run the contrast check + neutral fallback ONLY when a concrete backdrop exists; over a material draw at table opacities (no check), like existing sidebar colors — no new plumbing.
- Neutral fallback shifts luminance (not opacity); test neutral-equals-backdrop; documented best-effort limit.
- Added the JSON→UserDefaults importer (`SidebarSettingsFileMapping.booleanSettings`) to scope; parse test exercises the real importer.
- Height equivalence: member rows also ignore the `showsGroupDividers` flag; header gets its own height-equivalence ignoring `bandStyle` but keeping topGap/first-row/font size.
- Guide run boundaries computed from the filtered projection; cache-miss boundary test.

## Round 4: Deliberation (final)

### Dr. Scrutiny (devils-advocate)
**Verdict:** approve | **Confidence:** 0.95 | **Changed:** 0.90 → 0.95. Concerns addressed; on-by-default recorded with cheap reversal noted.

### Reginald 'Rex' Mondo (pragmatist)
**Verdict:** approve | **Confidence:** 1.0 | **Unchanged.** Simplified backdrop + settings-import + parity details; remaining risk is execution expertise/timeline.

### Professor Simplex (simplifier)
**Verdict:** approve | **Confidence:** 0.95 | **Unchanged.** Still leverages existing elements; centralized logic; configurable.

### Marcus 'Mark' Iterate (user)
**Verdict:** needs_work | **Confidence:** 0.90 | **Changed:** 0.85 → 0.90. On-by-default remains; "one-line reversal" reads as expecting negative feedback and making users unwilling testers.

### Astra (astra)
**Verdict:** reject | **Confidence:** 0.98 | **Changed:** confirmed importer, rendered-adjacency, optimistic-paint, member-flag fixes; two residual + one scope note.
- Reduce Transparency does NOT supply `readabilityBackdropHex` (`guard unifySurfaceBackdrops else { return nil }`); the opaque composite is in `policy(for:)`, not exported. The Round 3 "concrete backdrop under Reduce Transparency" branch never fires without new plumbing.
- The no-backdrop branch's "always visible" is false: an opaque custom tint (`tintOpacity = 1`, terminal-match off) equal to the group color with brightening off yields an invisible band; the luminance fallback never runs (no backdrop). Define opaque-tint plumbing or explicitly accept the failure.
- Height equivalence incomplete at the configuration boundary: `hasEquivalentHeightContent` gates on `environment.hasEquivalentPresentation` (which includes `readabilityBackdropHex`), so a backdrop-only change still remeasures regardless of the model comparator.

### Sol (sol)
**Verdict:** reject | **Confidence:** 0.99 | **Changed:** confirmed the filtered-projection fix; three residual.
- Reduce Transparency doesn't produce a non-nil `readabilityBackdropHex` (same as astra).
- Ignoring bandStyle/groupGuide in model equality doesn't prevent backdrop/accessibility-only remeasure (environment gate includes `displayAccessibility`, `readabilityBackdropHex`).
- The header carries only `fontScale`; the 11↔12.5 toggle needs an explicit height-bearing name-size field (topGap can't disambiguate; bandStyle must stay paint-only).
- Settings search also has a legacy app-target index + path-to-anchor mapping (`Sources/SettingsSearchIndex.swift`); add the key there too or retire that contract.

## Convergence Trace

| Round | devils-advocate | pragmatist | simplifier | user | astra | sol | Consensus? |
|-------|---|---|---|---|---|---|---|
| 1 | needs_work (0.75) | approve (0.95) | approve (0.95) | needs_work (0.70) | reject (0.97) | reject (0.98) | No |
| 2 | approve (0.90) | approve (0.98) | approve (0.95) | needs_work (0.80) | reject (0.95) | reject (0.98) | No |
| 3 | approve (0.90) | approve (1.0) | approve (0.95) | needs_work (0.85) | reject (0.96) | reject (0.99) | No |
| 4 | approve (0.95) | approve (1.0) | approve (0.95) | needs_work (0.90) | reject (0.98) | reject (0.99) | No |

Trend: the three non-code reviewers converged to approve by Round 2 and stayed. The two repo-grounded reviewers rejected every round but each round (a) confirmed the prior round's fixes had landed correctly and (b) found a new, narrower layer — structural (R1) → integration (R2) → edge/consistency (R3) → backdrop-plumbing + cache-boundary edges (R4). The user persona's needs_work is a product/taste stance on the on-by-default decision, with confidence rising as it went explicitly unaddressed (by design — it is a fixed decision).

## Final Synthesis

### Issues That Converged (all rounds agreed)
- The per-row build approach (approach 1) fits the codebase; shared metrics + facts-before-the-list-boundary is the right structure (pragmatist, simplifier, both repo reviewers implicitly, every round).
- Every visual change must land identically in both renderers, including drag state (goal held throughout; drove the parity fixes).

### Issues That Were Resolved (addressed by revision, verified in-repo)
- Drop hit-testing uses the real row-frame midpoint split, not `dropTargetHeight` (R1); empty-group right-half adopt exception documented and tested.
- Top-gap exemption uses a stable first-rendered-row fact from the filtered projection, not the drag-only `isFirstRow` (R1, R2).
- `showOptimisticDeselection()` paints the idle band via the shared helper (R1).
- Schema regeneration (`CmuxConfigSchema.generated.swift`) and the JSON→UserDefaults importer (`SidebarSettingsFileMapping`/`parseSidebarSection`) are in scope (R1, R3).
- Settings search routed through the curated entry, alias registry, anchor contract, and legacy app-target index (R1, R2, R4).
- Header name text paint correctly described (primary/label at 0.9), with a text-over-band legibility check (R2).
- Guide is run-aware off the filtered projection (R2, R3).
- `groupGuide` + `showsGroupDividers` excluded from member height equivalence; header gets bandStyle-excluding height equivalence; explicit height-bearing name-size field (R2, R3, R4).
- Dragged-member guide parity between renderers (R2).
- Height estimate made model-aware; no first-row settle (R1).

### Remaining Contentious Points
1. **On by default (user persona, all four rounds, unresolved).** The one issue no revision could close because it contradicts a fixed brainstorming decision. The design mitigates (wash not fill, very quiet neutral tint, one switch to restore today's look) and notes the default is a cheap one-line reversal. This is a product call for Nathaniel, not a code defect.
2. **Invisible band for an opaque custom tint equal to the group color, brightening off (astra, R3–R4).** Over the nil-backdrop branch there is no backdrop to measure against, so the luminance fallback can't run. Folded into the final document as an accepted, documented edge, with optional opaque-tint plumbing offered as the fix. Low real-world likelihood (requires terminal-match off + a fully opaque custom sidebar tint exactly equal to a group's color + brightening disabled).
3. **Backdrop-change remeasure (astra, sol, R4).** `hasEquivalentHeightContent` gates on the environment (incl. `readabilityBackdropHex`), so toggling terminal-match remeasures rows regardless of the model comparator. The no-remeasure promise is scoped to a group recolor with unchanged environment; closing the toggle case is an optional environment-height-equivalence refinement (the toggle is rare).

### Recommended Actions (for the builder)
1. Add an explicit height-bearing name-size field (or `showsGroupDividers`) to the header snapshot/model and compare it in header height equivalence; do not rely on `topGap` or `bandStyle` to encode the 11↔12.5 change.
2. Register `sidebar.groupDividers` in `SidebarSettingsFileMapping.booleanSettings` and make the settings test exercise `parseSidebarSection` and assert the resulting `sidebarGroupDividers` default — not just schema acceptance.
3. Update all Settings-search surfaces for the key: curated entry (`CuratedSettingEntry+Default.swift`), alias (`Sources/SettingsSearchAliases.swift`), the legacy app-target index + path-to-anchor mapping (`Sources/SettingsSearchIndex.swift`), and the anchor contract test — or explicitly retire the legacy table.
4. Compute both the first-rendered-row fact and the guide run-boundaries from the same filtered rendered projection (post snapshot-cache-miss), with a cache-miss boundary test.
5. Keep the contrast check on the concrete-backdrop branch only; over a material draw at table opacities. Decide explicitly whether to add opaque-tint/Reduce-Transparency backdrop plumbing (closes contentious point 2) or ship the documented edge.
6. Exclude paint-only fields (`groupGuide`, member `showsGroupDividers`, header `bandStyle`) from height equivalence; optionally add environment-height-equivalence ignoring `readabilityBackdropHex` (closes contentious point 3).
7. Run the full test and screenshot matrix in the document, including the empty-group gap drop on both halves, the dragged-member guide parity, the neutral-equals-backdrop appearance case, and a human UX/accessibility pass on the tagged build.
8. Surface the on-by-default decision to Nathaniel once more before merge (contentious point 1); ship behind the setting regardless.

### Deferred
- Routing the header name through a backdrop-aware foreground (only if the text-over-band check fails).
- Full opaque-material backdrop plumbing (optional; only to close the invisible-band edge).
- Environment-height-equivalence excluding `readabilityBackdropHex` (optional; only to avoid the rare backdrop-toggle remeasure).
- Upstream merge-conflict resolution with the configurable-indent and color-rail PRs (strategy documented; executed when one lands).

## Appendix: Final Revised Document

The document below folds in every verified correction from all four rounds, including the Round 4 factual corrections (Reduce Transparency does not export a backdrop; the nil-backdrop branch is not unconditionally visible; the environment-boundary height gate; the explicit name-size field; the legacy search tables). It is the version the parent should fold into the original.

---

# Sidebar workspace groups: header band and indent guide

Design for the epic "Give workspace groups a more visually distinctive divide in the sidebar".
Brainstormed 2026-10-30 with mockups; Nathaniel chose the treatment, the color behaviour,
the default and the build approach recorded below. Revised 2026-10-30 after three repo-grounded
review rounds (see "Review corrections").

## Intent

Workspace groups in the left sidebar are marked only by a collapsible header row. With
several groups the list reads as flat: the header name is set smaller than the workspace
titles under it (11 pt against 12.5 pt), members are indented 12 pt, and the gap between
one group's last member and the next group's header is the same 2 pt that separates any
two rows. Nathaniel's own sidebar is the hard case: 9 groups holding 44 of 45 workspaces,
each row three or four lines tall, so a header is often off screen while its members fill
the viewport.

The change gives each group two marks that work together:

- A **header band**: the header row sits on a full-width tinted band with air above it,
  so the start of a group is obvious while scrolling.
- An **indent guide**: a thin vertical line in the member gutter from the header down to
  the last member, so any row inside a long group shows which group it belongs to even
  when the header is off screen.

Both take the group's color when it has one and fall back to a neutral tint otherwise.

## Goals

- A group boundary is visible at a glance in light and dark appearance, at any sidebar
  font size, with or without Increase Contrast.
- A member row shows its group membership without the header being on screen.
- A group with a color is recognisable by that color on its header and its guide.
- On by default, with one setting that restores today's look exactly.
- Identical appearance in both sidebar renderers (the AppKit table, which is the default,
  and the SwiftUI lazy stack fallback) — including the dragged-row state.

## Non-goals

- User-inserted divider rows between arbitrary workspaces (upstream feature request for
  lightweight divider rows). This change marks groups only.
- Sticky or floating group headers.
- Changing member indent, member row colors, or group color editing. Two open upstream
  pull requests cover a configurable member indent and members inheriting the group color
  as a left rail; this design is compatible with both and depends on neither.
- Any change to ungrouped workspace rows.
- iOS sidebar.

## Anti-goals

- Changing row geometry in a way that breaks drag and drop, drop indicators, keyboard
  navigation or workspace numbering.
- Reading observable stores below the lazy-list boundary, or measuring whole-list
  geometry. Both have caused main-thread spin loops in this sidebar before.
- A look so loud that nine colored groups turn the sidebar into a rainbow. The band is a
  wash, not a fill.
- Triggering AppKit row-height remeasures for a paint-only change (see "Snapshot and model
  fields").

## Constraints

- Two renderers draw the same rows from one flat render-item list
  (`SidebarWorkspaceRenderItem`): the AppKit table under `Sources/Sidebar/AppKitList/`
  and the SwiftUI `LazyVStack` in `ContentView.swift`. Every visual change lands in both,
  from shared metrics and shared color resolution. A `.workspace` render item is dropped
  from the rendered rows on a snapshot-cache miss (`workspaceRowInput(...)` returns nil and
  both renderers `compactMap` it out), so "the first render item" and "the first rendered
  row" are not the same thing (see "Facts computed before the list boundary").
- Rows receive immutable snapshots plus action closures. New facts a row needs are
  computed before the list boundary and carried on the snapshot/model.
- Group header sizes come from `SidebarWorkspaceGroupHeaderMetrics`, scaled by the sidebar
  font scale. Member indent comes from `SidebarWorkspaceGroupingMetrics.memberIndent`.
- Drop indicators paint into the inter-row gap at half the row spacing from each row's
  edge, in both renderers. The AppKit cells set `masksToBounds = false` for this.
- The AppKit table caches row heights. A header's cached estimate
  (`estimatedGroupHeaderHeight`) and its authoritative height
  (`SidebarGroupHeaderRowView.preferredHeight(model:)`) must agree **on the same inputs**.
  Today the estimate is fed only global font magnification
  (`SidebarWorkspaceTableRowConfiguration.swift`, around `globalFontMagnificationPercent / 100`)
  while the authoritative path uses `model.fontScale`; this design does not widen that gap
  (see "AppKit header cell"). Member-row height equivalence
  (`SidebarWorkspaceRowModel.hasHeightEquivalentContent`) normalizes out only `index` and
  `isFirstRow` today and remeasures when any other field differs, so new paint-only inputs
  must be normalized out too. Group-header configurations use **full model equality** for
  height equivalence (`isHeightEquivalentValue = isEquivalentValue` in
  `SidebarWorkspaceTableRowConfiguration`), so a header's paint-only band change would also
  remeasure unless the header gets its own height-equivalence (see "Snapshot and model
  fields").
- App code stays Swift 6.0 compatible.
- A new setting needs the schema, **the regenerated embedded schema copy**, docs, Settings
  search entries (**the curated entry, the localized alias, and the anchor contract**) and
  the localization audit (`cmux-localization` skill); user-facing strings ship in all
  catalog locales. See "Setting" for the full consumer list.

## Approaches

### Treatment (what the user sees)

Four directions were mocked up over the real sidebar slice and shown side by side:

| | Treatment | Trade-off |
| --- | --- | --- |
| A | Tinted group block: header and members on one rounded lighter block | Strong containment, but paints behind every member row and competes with selection and custom row colors |
| B | Header band with air above it | Strong boundary; mid-group membership still rests on the indent alone |
| C | Hairline and extra space before each header | Quietest; says where a group ends but not which one you are in |
| D | Indent guide down the member gutter | Membership mid-group with no new background; weak boundary on its own |

**Chosen: B + D.** The band marks the start, the guide carries membership down the group.
Three ways for a group's color to land on the band were then shown: a low-opacity wash,
a solid color fill with white text, and a neutral band with a colored left edge.
**Chosen: the wash.** It keeps the name readable over any palette color and stays quiet
when many groups are colored.

### Build

| | Approach | Trade-off |
| --- | --- | --- |
| 1 | Paint inside existing rows: the header row grows by the top gap and paints its own band; each member row paints a short guide segment that overlaps the row gap so segments join | Fits the snapshot rule and both renderers; segment joins must land on exact points at every font scale; the header row frame changes height, which the drop resolver and the height cache both observe |
| 2 | One overlay per group drawn from measured row frames | Cleanest line, but needs every visible row's frame: in SwiftUI that is the preference reader the sidebar enables only during drags because it defeats virtualization, and in AppKit it means re-measuring on every scroll and cell recycle |
| 3 | A new spacer render item above each header | Isolates the geometry, but a new row kind touches drag/drop targeting, numbering, keyboard navigation, the height cache and both list paths for a 10 pt gap |

**Chosen: 1.** Nathaniel's framing: new "render group" and "group color" properties on the
individual row elements, shaped however the code is organised.

## The design

### Header band

- Every group header draws a band behind its content: the existing header background
  rectangle (corner radius 4, inset by the row outer padding on both sides) filled with
  the band color whenever the header is idle.
- The band color is the group's color as a wash when the group has one, else a neutral
  tint. Color resolution is the one the header icon already uses: the group's own custom
  color, else the color from the matching per-directory workspace-group config, else none.
  Band and icon therefore always start from the same color; the icon draws it as is,
  the band brightens it for dark appearance and applies opacity.
- A **top gap** of 10 pt at the default font size (scaled by the sidebar font scale) sits
  above the band, inside the header row. The first *rendered* row of the list gets no top
  gap, so the pinned Home group stays flush under the title bar. "First rendered row" is a
  stable list-position fact computed from the rendered projection (see "Facts computed
  before the list boundary"), not the drag-only `isFirstRow` the drop indicators use.
- The **header name** moves from 11 pt to 12.5 pt, the workspace title size, with the
  existing semibold weight. No uppercase, no heavier weight. **Its text paint is
  unchanged:** SwiftUI keeps `Color.primary` (0.9 opacity when idle, full when active) and
  AppKit keeps `labelColor` at 0.9. The header name is *not* routed through the
  secondary-text `readableSecondaryColor` resolver (the header never used it; that helper
  is for secondary labels and icons). Because the band is a low-opacity wash (capped; see
  "Colors") the name's contrast over it is not materially reduced from today's contrast
  over the sidebar backdrop; the appearance/screenshot evidence includes a text-over-band
  legibility pass for a saturated group color and for the neutral fallback. If that pass
  ever fails, routing the name through a backdrop-aware foreground is a follow-up with its
  own snapshot plumbing, not part of this change.
- When the header's anchor workspace is **active**, the existing selection fill replaces
  the band. When it is **multi-selected**, the existing multi-selection style replaces the
  band. The subtle-selection hairline keeps working as today.
- **Idle paint has two AppKit entrypoints, not one.** Besides `applyModel`, the header cell
  exposes `showOptimisticDeselection()` (`SidebarGroupHeaderRowView.swift`), which the table
  controller calls on a previously selected header during a plain click, before the
  authoritative render arrives (`SidebarWorkspaceTableController.swift`). Today that method
  paints `NSColor.clear`; left unchanged it would flash the band away when you click off an
  active group. Both idle-paint entrypoints resolve the band through the same shared helper,
  and `showOptimisticDeselection()` paints the idle band (not clear) for a header that has
  one. `restoreStoredModelPaint()` already reapplies the full model, so rollback is covered.
- Hover, the plus button, the shortcut hint pill, the unread badge and the compact status
  glyph are unchanged.
- Collapsed and empty groups get the band and the top gap. The Chief Home group is an
  ordinary group header and gets the band.

### Indent guide

- Each **member row** of an expanded group paints a vertical guide segment in the member
  gutter: 2 pt wide, centered in the indent (x = row outer padding + member indent / 2),
  square ends.
- A segment runs from half a row spacing above the row's top edge to half a row spacing
  below its bottom edge, so adjacent segments meet in the inter-row gap and the first
  member of a run's segment starts at the midpoint of the gap under the header. The segment
  that **ends a run** (the next rendered row is not a member of the same group) stops 4 pt
  (scaled) above its bottom edge instead of overlapping the gap.
- **The guide follows rendered adjacency, not a single per-group last member.** The render
  item list can, in a legacy reorder state, leave one group's members in two runs separated
  by other rows (`SidebarWorkspaceRenderItem.swift` emits the header once and tolerates
  split runs). Each contiguous run therefore terminates its own segment, and a row between
  two runs draws no guide. A member's "ends the run" fact is decided by whether the
  immediately following rendered row is a member of the same group (see "Facts computed
  before the list boundary").
- The guide color is the group's color at a higher opacity than the band when the group
  has one, else a neutral tint stronger than the neutral band.
- No guide is drawn for a collapsed group (its members are not rendered), for an empty
  group, or for a group whose only rendered row is the header. Ungrouped rows never draw
  one.
- If the member indent is ever narrower than 6 pt (the upstream configurable-indent
  change allows 0), the guide is not drawn.
- The guide dims with the dragged row (see "Renderers") so the two renderers match.

### Colors

All color math lives in one place next to the existing row background resolver in
`Sources/Sidebar/SidebarAppearanceSupport.swift`, returning the existing
`SidebarWorkspaceRowBackgroundStyle` (color plus opacity) for the band and an `NSColor`
for the guide. **Full resolver inputs:** optional group color hex, color scheme, Increase
Contrast, the **optional concrete backdrop** (`readabilityBackdropHex`, non-nil today only
for terminal-match; nil otherwise — including over a material and under Reduce Transparency —
means "no contrast check"), and
the `workspaceColors.brightenInDarkMode` flag (the band/guide brighten exactly as
`WorkspaceTabColorSettings.displayNSColor` does).

**When there is a concrete backdrop, and when there is not.** The sidebar does not always
draw over a known opaque color. The existing contract
(`WindowAppearanceSnapshot.sidebarReadabilityBackdrop`, surfaced to rows as
`readabilityBackdropHex`) today gives an opaque backdrop hex in **one** case and `nil`
otherwise:

- `sidebarMatchTerminalBackground` on (`unifySurfaceBackdrops`): the composited terminal
  background. This is the only path that currently exports a concrete backdrop to rows.
- Otherwise — including **Reduce Transparency** — `sidebarReadabilityBackdrop` returns `nil`
  (`guard unifySurfaceBackdrops else { return nil }`). Under Reduce Transparency the sidebar
  material *does* resolve to a deterministic opaque composite, but that lives in the backdrop
  **policy** (`policy(for:)`) and is **not** exported through `sidebarReadabilityBackdrop`,
  so rows never see it today.
- The common default is a dynamic `NSVisualEffectView` material plus a translucent tint
  (`SidebarBackdropSettingsSnapshot`), which has no fixed RGB this code can read;
  `readabilityBackdropHex` is `nil`, and the existing comment is explicit that over a
  material "AppKit already keeps readable" the sidebar's colors.

The band and guide follow that same contract rather than inventing a composited-material
color:

- **Concrete backdrop present** (hex non-nil — today, terminal-match on): run the
  decorative-separation check below against it, with the neutral fallback.
- **No concrete backdrop** (`nil` — material, custom tint, or Reduce Transparency): draw the
  band and guide at their table opacities with no contrast check — exactly as the existing
  selection fills and sidebar tints do over the same material, reusing `readabilityBackdropHex`
  and treating `nil` as "no check", with no new plumbing. Over a translucent material a
  low-opacity wash is visible. **Honest limitation:** this branch is *not* unconditionally
  visible — a custom opaque tint (`tintOpacity = 1`, terminal-match off) hides the blur and
  still reports `nil`, so a group color equal to that tint with brightening disabled yields an
  invisible band and guide, and the luminance-shifted fallback never runs because there is no
  backdrop to measure against. This is an accepted edge of the nil-backdrop branch. A builder
  who wants to close it exports the opaque composite — the Reduce-Transparency
  `policy(for:)` result and/or a fully opaque custom tint — into the render context as a
  concrete backdrop so those configurations take the check branch; that is bounded extra
  plumbing (a new field alongside `readabilityBackdropHex`), explicitly optional here.
- The color scheme is the one already resolved for the sidebar (an opaque terminal keeps
  its declared scheme rather than a luminance-derived one); the resolver uses the scheme it
  is given.

| Element | Group has a color | Neutral |
| --- | --- | --- |
| Band, dark | display color (brightened for dark appearance, as workspace colors already are) at 0.24 | label color at 0.09 |
| Band, light | display color at 0.16 | label color at 0.07 |
| Guide, dark | display color at 0.60 | label color at 0.18 |
| Guide, light | display color at 0.55 | label color at 0.20 |

**Decorative contrast, not the text floor (concrete-backdrop case only).** When a concrete
backdrop is present, the band and guide still do **not** reuse `readableSecondaryColor`'s
3.5:1 text floor. That helper delegates to `WindowChromeColorResolver.contrastFloored`,
which returns a **fully opaque** color when the target contrast is unreachable at the capped
alpha — the opposite of a wash. Instead:

- The band uses a low decorative-separation target against the concrete backdrop, met only
  by raising opacity **within a hard cap** equal to the table value plus the
  Increase-Contrast bump (so the band never exceeds ~0.34 and never becomes a solid fill).
- When a group's color cannot be told apart from the backdrop within that cap, the band and
  guide **fall back to the neutral tint**. The fallback shifts the neutral toward the
  opposite luminance from the backdrop (a lighter wash over a dark backdrop, a darker wash
  over a light one) — **not** a higher opacity of a neutral that equals the backdrop, which
  the compositing formula (`cmuxCompositedNSColor` = fg·α + bg·(1−α)) leaves invisible at
  every alpha when foreground and background RGB are equal. The schema permits a sidebar
  tint and `tintOpacity` that make the backdrop equal to the label color, so the test covers
  neutral-equals-backdrop and asserts the luminance-shifted fallback separates it; if a
  pathological backdrop defeats even that (foreground forced equal at both luminance poles),
  the band is best-effort and may be invisible, which is documented, not promised away.
- The header name's own paint is unchanged (see "Header band"); legibility over the
  composited band is checked in the appearance/screenshot evidence, not assumed.

The named value for the decorative target and the exact fallback are left to the builder
within these rules; the appearance tests below pin the neutral-equals-backdrop case, a
match-terminal saturated backdrop, the no-concrete-backdrop material case (table opacities,
no check), and a scheme/background mismatch.

Increase Contrast adds 0.10 to every opacity (within the band's hard cap). The brightening
rule is the one `WorkspaceTabColorSettings.displayNSColor` applies to workspace colors,
honouring the existing `workspaceColors.brightenInDarkMode` setting. These opacities were
chosen on the mockups and may be tuned within ±0.05 after the first tagged build is
screenshotted; the builder records the final values in the metrics type.

### Setting

- Key `sidebar.groupDividers`, boolean, default `true`, user-defaults key
  `sidebarGroupDividers`, in `SidebarCatalogSection`.
- Off restores today's look exactly: no band, no top gap, no guide, header name back
  at 11 pt. The baseline look is therefore testable as "setting off".
- Exposed in the Settings window's Sidebar appearance section as a toggle labelled
  "Group dividers" with the description "Tint each group's header and run a guide down
  its members", following the compact agent status row.
- **Full consumer list** (a new key must satisfy all of these or it half-works):
  - The JSON schema `web/data/cmux.schema.json` (description in every `web/messages` locale)
    and its **regenerated embedded copy**
    `Packages/macOS/CmuxFoundation/.../CmuxConfigSchema.generated.swift`, produced by
    `scripts/generate-cmux-config-schema.py`. The native config loader reads the embedded
    copy (`CmuxParsedConfigSchema`), and a CLI `cmux set` of a path missing from it is
    rejected by `CmuxSettingChangePlanner`; `verify-local.py`'s schema-drift check fails if
    the generated file is stale. Regenerate it as part of this change.
  - A supported-paths entry, a template default, a line in `docs/configuration.md` and in
    the settings skill's all-keys reference (`skills/cmux-settings/references/all-keys.md`).
  - **The app's JSON-to-UserDefaults importer.** Register the key in
    `SidebarSettingsFileMapping.booleanSettings` (`Sources/CmuxSettingsJSONPathSupport.swift`,
    as `sidebar.compactAgentStatus` is), because `parseSidebarSection`
    (`Sources/KeyboardShortcutSettingsFileStore.swift`) imports only registered sidebar
    booleans into the defaults the app reads. Without this, the CLI accepts and writes
    `sidebar.groupDividers` but the app ignores it — the setting half-works. The settings
    parse test must exercise this real importer and assert the resulting `sidebarGroupDividers`
    defaults value, not merely that the schema accepts the key.
  - **Settings search** (several cooperating pieces, as Compact Agent Status has — add the
    key to all of them or it is unreachable in one surface):
    the curated entry in `CmuxSettingsUI`'s `CuratedSettingEntry+Default.swift`
    (section `.sidebarAppearance`, with `paths: ["sidebar.groupDividers"]` and synonyms) —
    the package `SettingsSearchIndex.swift` is a generic builder that consumes curated
    entries, not a per-setting registry, so nothing is added there; the localized app alias
    in `Sources/SettingsSearchAliases.swift`, whose alias index is injected into every app
    search entry; the **legacy app-target search index** and its **path-to-anchor mapping**
    in `Sources/SettingsSearchIndex.swift` (Compact Agent Status has both a searchable entry
    and an anchor there), updated for `sidebar.groupDividers` — or that legacy contract is
    explicitly retired in this change, not silently left without an entry; and the
    hand-maintained anchor contract covered by `SettingsRowAnchorResolutionTests`, updated so
    the new row resolves in every surface.
- The flag reaches rows through `SidebarTabItemSettingsSnapshot`, like the other sidebar
  row settings, so it reloads live.

### Drag and drop

Drop behaviour has two independent pieces: the **visual indicator** (where the line is
painted) and the **hit geometry** (which drop the resolver picks for a pointer). The top
gap changes the header row's real frame, which both pieces observe; neither reads
`SidebarWorkspaceGroupHeaderMetrics.dropTargetHeight` (that property has no callers today
and is not the hit mechanism — see "Review corrections").

- **Visual indicator.** The header's top drop indicator (drop before this group) centers in
  the visual gap between the previous row and the band. In SwiftUI,
  `SidebarWorkspaceTopDropIndicator` gains a `topInset` so the line sits in the gap; in
  AppKit the indicator paints at `(topGap - rowSpacing) / 2 - thickness / 2` from the cell
  top. For the first rendered row there is no gap and nothing changes. The header's bottom
  drop indicator (append into the group) is unchanged. Member row drop indicators are
  unchanged; the guide segment is painted beneath them.
- **Hit geometry.** Both renderers hand the resolver the header's **actual row frame** — in
  AppKit the table row rect (`SidebarWorkspaceTableController`), in SwiftUI the measured
  anchor frame (`ContentView.swift`) — and `SidebarWorkspaceReorderDropResolver` splits that
  frame at its midpoint. Because the top gap grows the frame at the top and the content is
  offset down by the gap, the gap falls in the header's **upper half**, which the resolver
  already reads as "before this group" for a normal (non-empty) header. No change to
  `dropTargetHeight` is needed or sufficient.
- **Empty-group exception.** For an **empty** group header the resolver deliberately treats
  the upper half as an *adopt* target when the pointer is in the sidebar's right half
  (`SidebarWorkspaceReorderDropResolver`, the empty-header branch). The top gap does not
  override this: a right-half drop in an empty group's gap keeps today's adopt-into-group
  behaviour; a left-half drop reads as "before this group". This is an accepted, pre-existing
  rule, called out here so it is tested rather than discovered. (A non-empty header's gap
  always reads "before this group".)
- The header's dragged-row dimming (`isBeingDragged`) applies to the band as it does to the
  rest of the header today, and the member guide dims with its dragged row (below).

## How it fits the code

### Shared metrics

- `SidebarWorkspaceGroupHeaderMetrics`: `baseNameFontSize` becomes 12.5 when dividers are
  on (11 when off; the metrics type takes the flag or exposes both and the views pick);
  new `baseTopGap = 10` and scaled `topGap`. `dropTargetHeight` is **not** repurposed as the
  hit mechanism (it has no callers); the hit geometry is the real row frame the resolver
  already splits (see "Drag and drop").
- `SidebarWorkspaceGroupingMetrics`: new `guideWidth = 2`, `guideCenterX` (outer padding
  plus half the indent), `guideEndRunBottomInset = 4`, `guideMinimumIndent = 6`.

### Facts computed before the list boundary

- **First rendered row.** The top-gap exemption needs a stable list-position fact. The
  existing `isFirstRow` the header builders pass
  (`VerticalTabsSidebar+WorkspaceGroups.swift`) is derived from
  `renderContext.sidebarReorderIds.first`, and `sidebarReorderIds` is empty except during an
  active drag (`ContentView.swift`) — so it is false for every header at rest and shifts
  with the drag scope mid-drag. Reusing it would give the real first header a gap at rest and
  change header heights during a drag. Instead compute a separate fact once per refresh from
  **the rendered projection** — the first render item that actually yields a row (a
  `.workspace` item whose snapshot is cache-missing is dropped, so it is not simply
  `workspaceRenderItems.first`). Carry the resulting first-rendered-row id on the header
  snapshot, and leave the drag-only `isFirstRow` to the drop indicators it already serves.
- **Group color by group id.** The expression both header builders already use
  (`group.customColor ?? resolvedConfig?.color`) is factored into one helper that returns
  the effective color hex per group, computed once per sidebar refresh and stored on
  `WorkspaceListRenderContext` as `groupColorHexByGroupId`. Header icon, band and guide
  read the same value. If the upstream members-take-group-color change lands, its
  appearance helper replaces this one.
- **Guide run boundaries.** A pure static helper marks each member row with whether it
  **ends its run** (the next row is not a member of the same group) for expanded groups,
  so a group left in two runs terminates each run correctly and a row between runs is never
  mistaken for a member. It walks the **same filtered projection that first-rendered-row
  uses** — the items that actually yield rows, after snapshot-cache misses are dropped — not
  the raw `workspaceRenderItems`. Otherwise a cache-missing member between a visible member
  and a root row would make the visible member wrongly continue its guide across the gap. A
  `.workspace` item carries no group id, so the membership map
  (`workspaceGroupIdByWorkspaceId`), not list position, decides membership. Stored on the
  render context (e.g. `guideRunEndWorkspaceIds`). Both renderers already derive their rows
  from this projection, so the fact and the rows see the same list.

### Snapshot and model fields

- Group header (`SidebarWorkspaceGroupRowSnapshot`, `SidebarGroupHeaderRowModel`,
  `SidebarWorkspaceGroupHeaderView`): `bandStyle: SidebarWorkspaceRowBackgroundStyle?`
  (nil when the setting is off), `topGap: CGFloat` (0 for the first rendered row or when
  off), `isFirstRenderedRow: Bool` (the stable fact above, feeding `topGap`), and an
  **explicit height-bearing name-size input** — a `nameFontSize` (or a `showsGroupDividers`
  flag the metrics turn into 11 vs 12.5). The header model/snapshot today carry only
  `fontScale` and derive the name size from it, so there is no field that distinguishes the
  11↔12.5 change; `topGap` cannot stand in (it is 0 both when dividers are off and for the
  first header when on) and `bandStyle` must stay paint-only. `topGap`, `isFirstRenderedRow`
  and the name-size input change the header's measured height; `bandStyle` is paint-only.
  Because the header configuration's height equivalence is full-model equality today, the
  header needs its **own** height-equivalence that keeps `topGap`, `isFirstRenderedRow` and
  the name-size input but **ignores `bandStyle`**, so a band color change does not remeasure
  the header. Toggling the setting legitimately changes header height (name size and the
  gap), so a toggle does remeasure headers — correctly.
- **Height reuse also gates on the environment, not just the model.** Both
  `hasEquivalentHeightContent` paths require `environment.hasEquivalentPresentation` first,
  and that snapshot compares `readabilityBackdropHex`, `colorScheme` and `displayAccessibility`.
  `colorScheme` and `displayAccessibility` genuinely affect height; `readabilityBackdropHex`
  does not, yet a backdrop change (e.g. toggling terminal-match) still remeasures every row
  today. The band's no-remeasure promise is therefore scoped to a **group recolor that does
  not change the environment**. Closing the backdrop-toggle remeasure is optional: a builder
  may add a header/row environment-height-equivalence that ignores `readabilityBackdropHex`
  while keeping scheme and accessibility; the toggle is rare, so this is not required.
- Member row (`SidebarWorkspaceRowSnapshot`/`SidebarWorkspaceRowInput`,
  `SidebarWorkspaceRowModel`): `groupGuide: SidebarGroupGuide?` where
  `SidebarGroupGuide` is a small `Equatable, Hashable` value holding the guide `NSColor`
  (or hex) and `endsRun`. Nil for ungrouped rows, when the setting is off, or when the
  indent is too narrow. The guide does not change member-row height. **Member height
  equivalence (`SidebarWorkspaceRowModel.hasHeightEquivalentContent`, which today excludes
  only `index` and `isFirstRow`) must also normalize out `groupGuide` and the
  `showsGroupDividers` flag carried in the member's settings snapshot**; otherwise a guide
  color or run-boundary change, or toggling the setting, would remeasure every member row
  for a paint-only change. (The member model still stores the whole settings snapshot, so the
  flag is excluded in the height comparator, not removed from the model.)
- `SidebarTabItemSettingsSnapshot`: `showsGroupDividers: Bool`.

### Renderers

- **AppKit header cell** (`SidebarGroupHeaderTableCellView` /
  `SidebarGroupHeaderRowView`): `preferredHeight(model:)` adds `topGap`; `layout()` offsets
  the background frame and all content by `topGap` and centers content on the band, not the
  cell; `applyModel` fills the background layer with the band color when idle (the active and
  multi-selected branches keep their fills); **`showOptimisticDeselection()` resolves and
  paints the idle band through the same shared helper instead of `NSColor.clear`**; the top
  drop indicator moves per the visual formula above. The height-cache estimate
  `estimatedGroupHeaderHeight` must stay in true lockstep with `preferredHeight(model:)`:
  it is made **model-aware** — fed the same `model.fontScale` basis (not global magnification
  alone), the `topGap`, and the first-rendered-row fact — so there is no first-row settle.
  The exact reconciliation of the fontScale source is left to the builder, but estimate and
  authoritative must return the same height for the same header.
- **AppKit member cell** (`SidebarWorkspaceRowTableCellView`, in
  `SidebarWorkspaceRowCellView.swift`): a new layer-backed guide view,
  framed in `layoutContent` from `groupGuide` and the row's measured height, hidden when
  `groupGuide` is nil. Its frame extends past the cell bounds by half the row spacing;
  the cell already does not clip. The cell dims the whole view (`alphaValue = ... 0.6`) while
  `isBeingDragged`, so a guide subview dims with it automatically. The guide view is reused
  across cell recycling (shown or hidden by `groupGuide`), so recycling costs no allocation.
- **SwiftUI header** (`SidebarWorkspaceGroupHeaderView`): the band color becomes the
  idle `background`; `topGap` is applied as top padding outside the band but inside the
  drop-indicator overlays, and `SidebarWorkspaceTopDropIndicator` gains a `topInset`
  parameter so the top line centers in the gap.
- **SwiftUI member row** (`SidebarWorkspaceRowView`): the guide is drawn in the existing
  leading padding with an `overlay(alignment: .leading)` positioned from the grouping
  metrics, so `TabItemView` and its `Equatable` contract are untouched. Because
  `TabItemView`'s `.opacity(isBeingDragged ? 0.6 : 1)` sits inside `TabItemView` and this
  overlay is outside it, the overlay applies the **same `isBeingDragged` opacity** itself
  (the snapshot already carries the drag state), so the SwiftUI guide dims exactly as the
  AppKit guide does. A dragged-member parity check pins this.

### Where the facts are assembled

- SwiftUI: `workspaceRowInput(...)` and `sidebarWorkspaceGroupRowSnapshot(...)` in
  `ContentView.swift` and `VerticalTabsSidebar+WorkspaceGroups.swift`.
- AppKit: the workspace row configuration builder in `ContentView.swift` and
  `sidebarWorkspaceGroupTableConfiguration(...)`.
- Both read the new render-context facts (effective group color, guide run boundaries, the
  first-rendered-row id) and the settings flag; nothing new is read inside a row body or a
  cell.

## Tests

Behavioural tests first, then the fix, per the testing policy. New test files need
`scripts/sync-test-wiring`.

- `SidebarWorkspaceGroupHeaderMetricsTests`: top gap scales with font scale; name size is
  12.5 with dividers on and 11 off.
- A render-item test for the guide run boundaries (computed from the filtered projection):
  two groups, a collapsed group, an empty group, an ungrouped row directly after a group's
  last member, a stale-group row in the same position, **a group whose members are split
  into two runs with a root row between them**, and **a cache-missing member dropped from
  the projection before a root row**. The run boundary is marked at the end of each rendered
  run; the between-runs row, the dropped-member's predecessor's guide, and the
  stale/ungrouped rows behave correctly (no guide crosses a gap it should not).
- A **first-rendered-row** test: the fact comes from the rendered projection and is stable
  before, during and after a drag (it does not flip when `sidebarReorderIds` fills or changes
  scope); when the leading `.workspace` item is cache-missing and dropped, the following
  header that becomes visually first is the one with `topGap == 0`.
- An appearance test for the band and guide resolvers: neutral and colored, light and
  dark, Increase Contrast, honouring brighten-in-dark-mode, the opacity cap is never
  exceeded; the **no-concrete-backdrop (material) case** (`readabilityBackdropHex` nil) draws
  the table opacities with no contrast check; the **match-terminal saturated backdrop** case
  applies the decorative-separation check; the **neutral-equals-backdrop** case (concrete
  backdrop RGB == the neutral label color) uses the luminance-shifted fallback and separates,
  rather than going invisible or opaque; a **scheme/background mismatch** (opaque terminal
  with a declared scheme unlike its luminance) uses the provided scheme.
- A **text-over-band** legibility check: the header name's contrast over the composited band
  stays above the readable threshold for a saturated colored band and for the neutral
  fallback, in light and dark.
- `SidebarAppKitRowCellTests`: header `preferredHeight` with and without the gap; the
  background layer carries the band color when idle, the selection fill when active and
  stays clear when the setting is off; **`showOptimisticDeselection()` leaves the idle band
  in place for a header that has one (not clear), and `restoreStoredModelPaint()` restores
  it**; first rendered row has no gap; the **estimate equals `preferredHeight(model:)`** for
  first and non-first headers at default and enlarged font (no settle); member cell guide
  frame for a mid-run member, a run-ending member, an ungrouped row and the setting off; the
  guide hides below the minimum indent.
- A **height-equivalence** test: two member models differing only in `groupGuide` (color,
  presence, or `endsRun`), or only in the `showsGroupDividers` flag, are
  `hasHeightEquivalentContent`, so member rows are not remeasured on a paint-only change or a
  setting toggle. A header config differing only in `bandStyle` is height-equivalent (no
  remeasure), while one differing in `topGap`, `isFirstRenderedRow` or name font size is
  **not** (it must remeasure).
- A **dragged-member guide parity** test: for a member with `isBeingDragged` true, both
  renderers draw the guide at 0.6 opacity (AppKit via cell alpha, SwiftUI via the overlay's
  own opacity).
- Drop: an **empty-group header gap drop** resolves to "before this group" on the left half
  and keeps today's adopt behaviour on the right half; a **non-empty** header's gap drop
  reads "before this group" on both halves. Cover both renderers' frame inputs.
- Settings: the **real JSON importer** (`parseSidebarSection`) reads `sidebar.groupDividers`
  true and false from a `cmux.json` section and writes the resulting `sidebarGroupDividers`
  defaults value (not merely schema acceptance); the snapshot carries it; the JSON path maps
  to the defaults key; a **native** declared-path/default test proves the embedded generated
  schema accepts the key (so `cmux set sidebar.groupDividers` is not rejected) and
  `verify-local.py`'s schema-drift check passes; the curated search entry and its alias
  resolve to the new row (anchor contract).
- Snapshot plumbing: the row input for a group member carries `groupGuide` with the group's
  color and the right `endsRun`; the header snapshot carries `bandStyle`, `topGap` and
  `isFirstRenderedRow`.

## Verification and evidence

- `python3 scripts/verify-local.py` before committing (includes the schema-drift check,
  which now covers the regenerated embedded schema).
- `./scripts/test-unit.sh build-for-testing` so `cmuxTests` compiles; app-host suites run
  in PR CI.
- Tagged dev build: `CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag group-divide`.
  Dogfood through `CMUX_TAG=group-divide scripts/cmux-debug-cli.sh`.
- Screenshots with `cmux shot --region 0,0,360,1000` from the tagged CLI: dark and light,
  default and enlarged sidebar font, setting on and off, the sidebar matching the terminal
  background (including a terminal color near a group color, to exercise the neutral
  fallback), a **custom sidebar tint with terminal match off**, AppKit list and SwiftUI list
  (flip the AppKit-list feature flag; see the cmux-architecture skill's feature-flag
  reference). A "before" capture of the real sidebar already exists at
  `/tmp/cmux-ta4-before-sidebar.png`; the PR shows before and after.
- Drag a workspace over a non-empty header's top gap, over an **empty** group header's gap on
  both left and right halves, and over a member (watch the dragged member's guide dim) in a
  tagged build; record a short clip with `cmux record` if the indicators move.
- Click off an active group header and confirm the band does not flash to clear (optimistic
  deselection path).

## Localization audit

Strings added: the Settings toggle label and description, the search alias, and the schema
description. Swift strings go in `Resources/Localizable.xcstrings` for every catalog
locale; the schema description goes in all `web/messages/*.json` (and flows into the
regenerated embedded schema). Report the audit in the PR per the cmux-localization skill.

## Upstream coordination

Two open upstream pull requests touch the same files: a configurable member indent
(`sidebar.groupMemberIndent`) and members inheriting the group color as a left rail.
Neither addresses the between-group boundary. This design reads the indent through the
grouping metrics so the configurable value slots in, hides the guide below 6 pt, and keeps
group color resolution in one helper that the color-rail change's appearance type can
replace. Expect merge conflicts in the header and row cells if either lands first; resolve
by keeping both behaviours.

## Review corrections

Two repo-grounded review rounds (astra on GPT-6, sol on GPT-5.6, both reading this tree)
found claims in the drafts that did not match the code. Each was verified against the
repository before the correction was folded in.

**Round 1 (structural):**

- `SidebarWorkspaceGroupHeaderMetrics.dropTargetHeight` has **no callers**; the drop-hit
  path is the real row frame split at its midpoint by `SidebarWorkspaceReorderDropResolver`,
  with a documented empty-group right-half adopt exception.
- `isFirstRow` is derived from the drag-only `sidebarReorderIds`; the top-gap exemption uses
  a separate stable first-rendered-row fact instead.
- The AppKit header has a second idle-paint entrypoint, `showOptimisticDeselection()`, which
  must paint the band, not clear.
- The `cmux.json` schema has a generated embedded copy that must be regenerated, and the
  Settings search is curated with an anchor contract.
- The band/guide cannot reuse the 3.5:1 text contrast floor (which goes opaque when
  unreachable); a capped decorative target with a neutral fallback is specified, and the
  resolver takes the backdrop and `brightenInDarkMode`.
- The height estimate used a different fontScale source than the authoritative height; it is
  made model-aware so there is no first-row settle.

**Round 2 (refinements):**

- The header name does **not** use `readableSecondaryColor` today (SwiftUI `Color.primary`
  at 0.9, AppKit `labelColor` at 0.9). The earlier claim was wrong; the name's paint is kept
  as-is and text-over-band legibility is checked, not asserted.
- The first-rendered-row fact must come from the **rendered projection**, not
  `workspaceRenderItems.first`: a `.workspace` item is dropped on a snapshot-cache miss, so a
  later header can be visually first.
- The Settings-search entry belongs in `CuratedSettingEntry+Default.swift` with the alias in
  `Sources/SettingsSearchAliases.swift` (the package `SettingsSearchIndex.swift` is a generic
  builder); the earlier file list was wrong.
- The renderer tolerates a group split into two runs, so the guide is driven by rendered
  adjacency (per-run boundaries), not a single per-group last member.
- `groupGuide` is paint-only and must be normalized out of
  `SidebarWorkspaceRowModel.hasHeightEquivalentContent`, or it would evict the row-height
  cache on a paint change.
- The dragged-row dim differs between renderers (AppKit dims the whole cell; SwiftUI's
  opacity is inside `TabItemView` while the guide overlay is outside it); the SwiftUI guide
  applies the same `isBeingDragged` opacity so both match, with a parity test.
- (Round 2's "the effective backdrop is the composited sidebar tint" was itself too strong;
  see Round 3 — there is no concrete RGB over a dynamic material.)

**Round 3 (depth):**

- There is **no concrete backdrop color over a material**: `readabilityBackdropHex` /
  `WindowAppearanceSnapshot.sidebarReadabilityBackdrop` is nil except for match-terminal
  (Round 4 corrected the earlier "or Reduce Transparency" — that opaque composite is not
  exported to rows), and the sidebar otherwise draws a dynamic `NSVisualEffectView`
  material. The contrast check now runs only when a concrete backdrop is present; over a
  material the band/guide draw at table opacities with no check, matching existing sidebar
  colors. No new backdrop plumbing is introduced.
- A neutral fallback that raises the opacity of a color equal to the backdrop stays invisible
  (`cmuxCompositedNSColor` preserves equal fg/bg RGB at every alpha), and the schema permits
  a tint that makes this happen. The fallback now shifts luminance; the test covers
  neutral-equals-backdrop and documents the best-effort limit.
- The setting's consumer list omitted the JSON importer: the key must be registered in
  `SidebarSettingsFileMapping.booleanSettings` or `parseSidebarSection` never reads it and
  the app ignores a value the CLI happily writes. The parse test exercises the real importer.
- Height equivalence was under-scoped: member rows must also ignore the `showsGroupDividers`
  flag (paint-only for members), and the header needs its own height-equivalence that ignores
  `bandStyle` but keeps `topGap`/`isFirstRenderedRow`/font size.
- Guide run boundaries must be computed from the same filtered projection as
  first-rendered-row, or a cache-missing member makes a visible member continue its guide
  across a gap.

**Round 4 (final, folded into this document after the last review):**

- Round 3 over-claimed that **Reduce Transparency** already exposes a concrete backdrop:
  `sidebarReadabilityBackdrop` returns nil whenever terminal-match is off
  (`guard unifySurfaceBackdrops else { return nil }`); the opaque composite lives in
  `policy(for:)` and is not forwarded to rows. Corrected: today only terminal-match exports a
  backdrop, and exposing the opaque composite is optional builder plumbing.
- Round 3's "a low-opacity wash over a muted system blur is always visible" is false for an
  opaque custom tint (`tintOpacity = 1`, terminal-match off) equal to the group color with
  brightening off. Corrected to an accepted, documented invisible-band edge of the
  nil-backdrop branch, with the opaque-tint plumbing offered as the optional fix.
- Height reuse gates on `environment.hasEquivalentPresentation` **before** the model
  comparator, and the environment includes `readabilityBackdropHex`; so a bandStyle-only model
  exclusion does not stop a backdrop-change remeasure. The no-remeasure promise is scoped to a
  group recolor with an unchanged environment, with environment-height-equivalence offered as
  an optional refinement.
- The 11↔12.5 toggle needs an **explicit height-bearing name-size field** on the header; the
  model carries only `fontScale` today and `topGap`/`bandStyle` cannot stand in.
- The Settings-search surface also has a **legacy app-target index and path-to-anchor
  mapping** (`Sources/SettingsSearchIndex.swift`); the key must join those too, or the legacy
  contract is explicitly retired.
- Confirmed correctly folded by both reviewers: the JSON importer registration, guide runs
  from the filtered projection, split-run support, optimistic-deselection paint, and the
  member settings-flag height normalization. (The note that deriving `groupGuide` alone keeps
  the flag off the member model is dropped — the model still stores the whole settings
  snapshot, so the flag is excluded in the comparator, not absent.)

## Recorded concerns (not blocking; decisions are fixed)

- **Added visual load for users who do not have the hard case** (user persona, held firm
  across all four rounds with rising confidence — the one unresolved objection). A user with a few short groups may
  read the band and guide as noise, and someone who colors groups may find nine washes busy.
  The fixed decisions mitigate but do not erase this: the treatment is a wash not a fill
  (anti-goal), the neutral tint is very quiet (0.07–0.09), and one switch restores today's
  look exactly. The persona's objection is specifically to *on by default* for users without
  the hard case; that default is a fixed brainstorming decision (Nathaniel), so it is recorded
  as a taste trade-off, not a change. The design keeps the cost of being wrong low: flipping
  the default to off is a one-line change behind the same setting, so if post-ship feedback
  echoes the persona it is cheaply reversible.
- **Builder-tuned opacities** (devils-advocate). The ±0.05 tolerance and the decorative
  target are set on screenshots of the first tagged build; intentional latitude, with the
  final values pinned in the metrics type and the appearance test.
- **UX/accessibility sign-off** (devils-advocate). Covered in-design by the Increase-Contrast
  handling, the decorative-separation rule, and the text-over-band legibility check; a human
  design pass on the tagged build screenshots is still worthwhile before merge.

## Left to the builder

- Final opacity values within the stated tolerance, and the named decorative-separation
  target and neutral-fallback trigger, after the first screenshot.
- Exact names of new helpers, render-context fields and test functions.
- Whether `topGap` is a stored field or derived in the view from `isFirstRenderedRow` plus
  the metrics, as long as both renderers derive it the same way from the stable fact (never
  from the drag-only `isFirstRow`).
- The exact reconciliation of the estimate's fontScale source with `model.fontScale`, as
  long as estimate and authoritative return the same height.
- The exact shape of the guide run-boundary fact (a set of run-ending ids, or an `endsRun`
  flag per member), as long as it is run-aware and the between-runs row draws no guide.

## Decisions made during brainstorming

- Treatment B + D with the color wash (Nathaniel, from mockups).
- On by default with one switch to turn off (Nathaniel).
- Build approach 1, per-row painting (Nathaniel).
- Color source matches the header icon; name to title size; active selection replaces
  the band; first rendered row has no top gap; 10 pt gap scaled; guide hides below 6 pt
  indent; setting off restores the baseline including the 11 pt name (proposed by Claude,
  accepted by Nathaniel without correction).
- After the builder check: band and guide run a capped decorative-separation check with a
  luminance-shifted neutral fallback **only when a concrete backdrop exists** (today,
  terminal-match), and otherwise draw at table opacities over the material like the
  existing sidebar colors, with an accepted invisible-band edge for an opaque custom tint
  equal to the group color (revised across rounds from the first draft's reuse of the
  secondary-text floor); the guide is run-aware off the filtered projection; the header name
  keeps today's text paint; paint-only fields stay out of height equivalence; the JSON
  importer mapping is in scope (Claude's calls after repo review, no user-visible change
  beyond the intended band/guide).

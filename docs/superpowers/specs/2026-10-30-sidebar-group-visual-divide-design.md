# Sidebar workspace groups: header band and indent guide

Design for the epic "Give workspace groups a more visually distinctive divide in the sidebar".
Brainstormed 2026-10-30 with mockups; Nathaniel chose the treatment, the color behaviour,
the default and the build approach recorded below. Revised the same day after a four-round
design review in which two reviewers read the repository; the round-by-round record, including
the code facts the first draft got wrong, is in the companion file
`2026-10-30-sidebar-group-visual-divide-design-consult.md` beside this one.

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
for the guide. **Resolver inputs:** optional group color hex, color scheme, Increase
Contrast, the optional concrete backdrop (`readabilityBackdropHex`; nil means "no contrast
check", see below), and the `workspaceColors.brightenInDarkMode` flag (the band and guide
brighten exactly as `WorkspaceTabColorSettings.displayNSColor` does).

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
    `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ConfigValidation/CmuxConfigSchema.generated.swift`,
    produced by `scripts/generate-cmux-config-schema.py`. The native config loader reads the embedded
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
and is not the hit mechanism).

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
  (flip the `appKitSidebarListFlag` feature flag defined in `Sources/FeatureFlags.swift`;
  see the cmux-architecture skill's feature-flag reference). A "before" capture of the real sidebar already exists at
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

## Concerns the review recorded

- **On by default** was the one objection no revision closed. The end-user reviewer held
  that people with a few short groups will read the band and guide as noise. The default is
  Nathaniel's decision and stands; the wash, the quiet neutral tint and the single switch keep
  the cost of being wrong to a one-line default change later.
- **Builder-tuned opacities** and the decorative-separation target are set on screenshots
  of the first tagged build, then pinned in the metrics type and the appearance test.
- **A human look at the tagged build** in light and dark, with Increase Contrast on, is
  still worth doing before merge. The tests check contrast arithmetic, not taste.

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

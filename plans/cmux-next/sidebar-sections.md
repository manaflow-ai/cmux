# Sidebar sections

Status: design + phase 1 build, sidebar-sections lead, 2026-10-02. Binding: OWNERSHIP-PRINCIPLES.md,
architecture.md, actions.md. Inputs: Lawrence's request (2026-10-02, quoted in the coordinator task),
Home (home.md, Home lead), Leo's sidebar direction (https://github.com/manaflow-ai/cmux/issues/16688),
the old Home row prototype (https://github.com/manaflow-ai/cmux/pull/16279).

## 1. What the user gets

The left sidebar is an ordered list of **sections** in three **regions**:

| Region | Behavior | Default content |
| --- | --- | --- |
| Top | sticky under the titlebar row; never scrolls with the list | section "Home" (hidden title): Home, built-in look |
| Middle | scrolls; the only region that takes all leftover height | the Workspaces section (pinned workspaces, machines, groups; Leo's stack + history layer lives here unchanged) |
| Bottom | sticky above the room bar | section (hidden title), one line: Settings (icon + label) at the leading edge, the account avatar (icon only) at the trailing edge |

Every section has: an optional title (hidden titles draw no header), a region, an ordered item list, a
**look** (`builtIn`: compact rows that read as app chrome, like Home; `list`: rows that look like
workspace rows), a collapse state (only sections with a visible title can collapse), and a scroll
policy (sticky regions only).

Items:

| Kind | Example | Reference | Click |
| --- | --- | --- | --- |
| `builtIn(id)` | home, settings, account, notifications, history, bookmarks (tasks later) | id defined in code (`SidebarBuiltIn`) | runs the item's registry action (`home.show`, `openSettings`, `accounts.show`, `history.show`, `bookmark.manager`, `showNotifications`) with origin `user` |
| `workspace(ref)` | a pinned workspace | qualified public id `<session>:ws_…` | selects it |
| `tab(ref)` | a pinned terminal, browser page or agent tab | `<session>:tab_…` | selects its workspace and focuses the tab |
| `room(id)` | jump to a room | room id | shows that room in the window |
| `savedGroup(id)` | reopen a saved group | group id | reopens or focuses it |
| `url(string)` | a pinned page with no open tab | URL | opens it in a new browser tab |

Home is a plain built-in item: right-click "Remove from Sidebar", the palette ("Remove Home from
Sidebar", "Add Home to Sidebar"), the CLI and MCP remove and re-add it. The Workspaces section can
move between regions and sections around it, but it cannot be removed (the layout always holds
exactly one; section 4 invariant L1), because removing it would hide every open workspace.

Unknown items (written by a newer client) render nothing and survive every edit (L5).

## 2. Name

Lawrence: "leaning towards sections, but maybe shelves? since we have concept of room in sidebar
too". Candidates:

| Name | For | Against |
| --- | --- | --- |
| **sections** (recommended) | what Finder, Mail, Xcode and Notion call these; self-explanatory in a menu ("Add Section", "Move Section to Bottom"); no new metaphor to learn | generic |
| shelves | pairs with rooms ("this room's shelves"); playful, ownable | a second invented noun next to rooms; "shelf" also suggests a drawer that slides out (Yoink, Dropover); translators need a metaphor |
| docks | sticky feel | collides with the macOS Dock |
| zones / areas | neutral | read as regions, not as named lists |
| stacks | Arc-like | collides with Leo's "stack of workspaces" |
| groups / folders | familiar | taken by workspace groups and bookmark folders |

Recommendation: **sections** for the user-facing noun, **regions** for top/middle/bottom (shown in
menus as "Top", "Scrolling", "Bottom"). Rooms stay the switchable sets; sections are how a room's
sidebar is laid out. The prototype carries both nouns behind a DEV switch
(`sidebar.sections.noun` = sections | shelves) so the menus and headers can be compared.

## 3. Sections and rooms

A room (wire `profile`) chooses which workspaces a window shows. Two models:

- **A. One layout, room-scoped sections (recommended).** The user has one section layout. Each
  section has `scope`: `allRooms` (default) or `room(id)`. Room-scoped sections show only while
  their room is shown; the Workspaces section always lists the shown room's workspaces (today's
  behavior). Home, Settings and the account stay put when you switch rooms, which is what built-in
  chrome should do; a "Project X" section with pinned tabs can belong to one room (Arc's per-space
  pinned tabs, while global sections behave like Arc's favorites).
- **B. One layout per room.** Every room owns a complete layout, copied from the default when the
  room is created. Maximal freedom, but adding Home back or moving Settings must be repeated in
  every room, and a new room starts from a stale copy.

A covers B's use case at section granularity without duplicating the chrome, so phase 1 builds A
(`scope` on every section; "Show in This Room Only" / "Show in All Rooms" actions). The prototype
screenshots two rooms under A, and a B mock (every section room-scoped) for comparison.

## 4. Data model and invariants

```
SidebarLayoutDocument { revision: u64, sections: [Section] }       // per user
Section { id: "sec_<base32>", title: String?, shows_title: Bool, region: top|middle|bottom,
          look: built_in|list, arrangement: Arrangement, room: String?, max_rows: Int?,
          content: items|workspaces, items: [Item] }
Arrangement { layout: list|inline|grid, align: leading|center|trailing|fill, gap: 0...32?, columns: 1...12? }
Item { id: "itm_<base32>", ref: {kind, value}, shows_label: Bool }  // id stable across moves
```

`section.update` patches each arrangement field alone (`layout`, `align`, `gap`, `columns`; null
clears `gap` or `columns`), so concurrent edits of different fields both apply. Unknown `layout`,
`align` or `look` values from a newer app decode to the defaults on an older client (it never writes
the document back; it sends ops). The shared cases in
`Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json` run against
both reducers (Swift and cmux-tui-core).

Arrangement is a small flexbox (Lawrence, 2026-10-02): `list` puts one item per row; `inline` puts
items on one line with icon and label while they fit (an item with `shows_label: false` shows its icon
only), then icons only, then wraps; `grid` puts tiles in columns (Arc's pinned tiles). `align` places
the leftover space on a line (`fill` spreads it between items, so two items sit at both edges; one
item stays leading). `align` defaults to leading for every layout; a grid with fitted columns
stretches its tiles, and a grid with fixed columns places every line by the leftover of a full
line, so columns line up. Precedence: a section's inline or grid arrangement always wins; the tray
and lines-icons looks only tile built-in sections whose arrangement is a list (the default).

Order inside a region is the order of `sections` filtered by region. Invariants, checked by the pure
reducer and its tests:

- L1 exactly one section has `content == workspaces`.
- L2 ids are unique across sections and items; a move never changes the set of items (conservation,
  like tab conservation); only `item.remove` / `section.remove` delete.
- L3 a reference appears at most once per section (pinning a workspace twice into the same section
  is a no-op, not a duplicate).
- L4 `maxRows` is nil or 1...50; titles are at most 80 characters; at most 32 sections and 200 items.
- L5 unknown item kinds and unknown built-in ids are kept verbatim.
- L6 removing a section that holds items deletes them with it (the action asks for confirmation when
  the section is not empty); removing the Workspaces section is rejected (`workspaces_required`).

Ops (each carries a client-chosen idempotency key; replay returns the stored result, invariant 5):

| op | fields | notes |
| --- | --- | --- |
| `section.add` | `section` (id minted by the client, region, index in region, title, look, scope, content items) | |
| `section.update` | `id`, any of title, look, scope, maxRows | |
| `section.move` | `id`, `region`, `index` (in region, excluding itself) | |
| `section.remove` | `id` | L6 |
| `item.add` | `section`, `index`, `item` | L3 dedupe |
| `item.move` | `id`, `section`, `index` | across sections and regions |
| `item.remove` | `id` | |
| `item.update` | `id`, `shows_label` | |
| `layout.reset` | — | back to the defaults |

A remove-Home convenience is `item.remove` on the `builtIn(home)` item; re-adding inserts it at the
top of the first top-region section (creating one when the region is empty).

## 5. Ownership

| State | Owner | Role | Why |
| --- | --- | --- | --- |
| Section layout document | workspace store, personal (home daemon `sidebar-layout-v1`) | owner | per-user arrangement that references store entities (workspaces, tabs, rooms, saved groups); synced with rooms and workspace groups (ownership.md table, "workspace store (personal)") |
| Built-in item definitions (symbol, title, action) | code (`SidebarBuiltIn`) | definition | localized, versioned with the app |
| Section collapse | client view state, per window (`WindowState.collapsedSections`, saved with the window) | client | a laptop window and a large display want different sections open; syncing it would make other windows jump while you glance. Workspace group collapse stays synced as today; revisit with the ownership lead |
| Region scroll offsets, hover, drag gap | client | client | gestures |
| Look variants (prototype) | Debug Settings tunable | client | DEV only |

Wire contract (capability `sidebar-layout-v1`, home daemon, personal store next to rooms and groups):

| cmd | params | data |
| --- | --- | --- |
| `sidebar-layout-get` | `{}` | `{layout: SidebarLayoutDocument}` (defaults when never written) |
| `sidebar-layout-op` | `{idempotency_key, transaction?, op}` | `{layout, revision, replayed}` |

Event: `personal-changed` with `kind: "sidebar-layout"` and the new revision. The reducer is the same
pure function in Rust (store) and Swift (client overlay for the intent log); Swift tests and the
Rust tests share fixture JSON (`Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-*.json`).

Client: the confirmed mirror is written only by `sidebar-layout-get` replies and events; pending ops
form the intent log (visible = mirror + pending; an op leaves on echo or reject, reject animates
back). Before the daemon serves the capability (it is `awaitingPin` until the next cmux-tui pin
cut), the app shows the default layout and every layout action is disabled with the reason
"Needs a newer cmux-tui"; nothing queues and nothing is written to a local file. DEV builds may
turn on `sidebar.sections.localPrototype` (Debug Settings) to edit an in-memory layout for
prototyping; it is never persisted.

## 6. Surfaces

Every action is a registry action with an inline surface plan
(`CmuxNextActions/Catalog/SidebarSectionActionCatalog.swift`); `check-action-surfaces.sh` enforces
it. Target kinds `sidebar-item` (`itm_…` or a built-in name such as `home`) and `sidebar-section`
(`sec_…`); right-click contexts `sidebarItem` and `sidebarSection`. The palette asks for the target
(`SidebarSectionTargetSource`). CLI verbs are `cmux sidebar <verb>` (Rust CLI, requested from
feat-cmux-next-99; until then `cmux action run <id>`); MCP follows the CLI.

| Action id | Palette | CLI verb | Right-click |
| --- | --- | --- | --- |
| `sidebar.home.add` | Add Home to Sidebar | `sidebar add-home` | background > New |
| `sidebar.home.remove` | Remove Home from Sidebar | `sidebar remove-home` | (the Home row's Remove from Sidebar) |
| `sidebar.item.add` (`item` = home, settings, account, notifications, history, bookmarks; `section`) | Add to Sidebar… | `sidebar add-item` | background > New, section |
| `sidebar.item.remove` | Remove from Sidebar | `sidebar remove-item` | item |
| `sidebar.section.add` (`title`, `region`) | New Section… | `sidebar add-section` | background > New, section |
| `sidebar.section.rename` (`title`) | Rename Section… | `sidebar rename-section` | section |
| `sidebar.section.moveToTop` / `moveToScrolling` / `moveToBottom` | Move Section to … | `sidebar move-section-top` / `-scrolling` / `-bottom` | section > Move |
| `sidebar.section.useBuiltInLook` / `useListLook` | Built-in Look / List Look | `sidebar section-look-built-in` / `section-look-list` | section > Appearance |
| `sidebar.section.toggleRoomScope` | Show Only in This Room | `sidebar toggle-section-room` | section > Options |
| `sidebar.section.setMaxRows` (`rows`, 0 = automatic) | Set Section Height… | `sidebar set-section-height` | section > Options |
| `sidebar.section.toggleCollapsed` | Collapse or Expand Section | exempt `focusMove` (view state) | section |
| `sidebar.section.remove` (destructive, confirms) | Remove Section | `sidebar remove-section` | section |
| `sidebar.section.layoutList` / `layoutInline` / `layoutGrid` | Show as List / on One Line / as Grid | `sidebar section-layout-list` / `-inline` / `-grid` | section > Appearance |
| `sidebar.section.setAlignment` (`align`) / `setGap` (`gap`) / `setColumns` (`columns`, 0 = fit) | Set Section Alignment… / Spacing… / Grid Columns… | `sidebar set-section-alignment` / `set-section-gap` / `set-section-columns` | section > Appearance |
| `sidebar.item.toggleLabel` | Show or Hide Label | `sidebar toggle-item-label` | item |
| `sidebar.layout.reset` (destructive, confirms) | Reset Sidebar Layout | `sidebar reset` | background > Options |

Still to add: pin a workspace or tab to a section (`workspace.pinToSection`, `tab.pinToSection`), a
read verb (`sidebar layout --json`), and the customizations in section 10.

Drag and drop: items drag within and between sections of any region (the insertion line and gap
come from the same `DropResolver` geometry as workspace rows); workspace rows dragged onto an items
section pin them there (Option-drop keeps the workspace where it was and only pins); a section
header drags to reorder sections and to move between regions.

Keyboard: Cmd-1 runs the first item of the first top-region section (Home by default), Cmd-2…8
select the first seven workspaces, Cmd-9 the last. With no top-region item, Cmd-1…8 select
workspaces 1…8 (today's behavior). Arrow keys move through every visible row of all regions in
visual order; Return activates.

## 7. Prototypes (Debug Settings > Sidebar)

Look: setting `sidebar.sectionLook` in cmux.json and Settings > Appearance > Sidebar, default
`quiet` (Lawrence, 2026-10-02); Debug Settings `sidebar.sections.look` overrides it in DEV. The band
caps are settings too: `sidebar.topBandMaxShare` (default 1/3), `sidebar.bottomBandMaxShare`
(default 1/4), `sidebar.stickyBandsScroll` (default true; false = the bands never scroll and the list
shrinks to three rows). In both modes the two bands together leave the list three rows (they
shrink in proportion and scroll inside), and each band keeps at least its first row, so Home and
Settings never vanish in a short window. The two shares together are at most 0.8; past that both
shrink in proportion. Looks:

- quiet: icon + label rows, no fill at rest; a hairline separates the sticky bands from the list.
- card: each section of a sticky band sits in a rounded inset card.
- tray: built-in sections as an icon grid (Arc favorites).
- lines: no headers and no labels on section boundaries; a thin line between every section and
  between subsections (the shared `Borders` metric; under `appearance.borders = none` a tonal step
  instead of a line). Rows keep icon + label.
- lines-icons: lines, and built-in items show icons only (a compact row of icon buttons per
  built-in section); list-look sections keep their labels.

Every look: section titles are optional per section and the new looks hide them; sticky bands and
the middle list show gradient edge fades while more content is hidden (the shared
`ScrollEdgeFadeView`). Rooms model B is mocked in the screenshots by scoping every section to one
room. The menus' noun stays "Section"; "Shelf" copy is listed in the report instead of a runtime
switch (descriptor titles are built once at launch).

## 8. Phases

1. Done (9c2d458fb75, 96e8343fec6): pure document model + reducer + tests, default layout.
2. Done (9ef77a69a9b, 3c7de1001eb): sticky bands, built-in and list looks, quiet/card/tray, Home as
   an item, scroll caps.
3. Registry actions with surface plans, App-wide `SidebarLayoutService`, palette targets. Then:
   lines and lines-icons looks, optional titles, edge fades, the room bar's hover-only "+", Cmd-1 rule
   and the Home item's highlight after Home lands, collapse saved in `WindowState`.
4. Store: `sidebar-layout-v1` in cmux-tui-core personal store (Rust reducer, proptest for L1-L3 and
   idempotency), client mirror + intent log, Rust CLI verbs. Coordinated with the state-module owner
   and the Rust CLI session.
5. Drag and drop between sections and regions; tab and room items; footer accessories become items.

## 9. Open decisions for Lawrence

- Collapse state per window (recommended) or synced per user.
- Whether sections subsume the room bar (rooms as an item) and the footer accessories.

## 9a. Decisions (Lawrence, 2026-10-02)

- Default look quiet; name "sections"; rooms model A.
- Bottom band: Settings and the account avatar on one line (above).
- Per-section arrangement list | inline | grid with alignment, gap and columns (section 4).
- Band caps 1/3 and 1/4, then scroll; customizable (section 7).
- Custom icons (emoji, SF Symbol or image) for workspaces and Home: the existing workspace
  `icon` string of workspace-metadata-v1 is extended (sidebar sections lead, in the store next to
  `sidebar-layout-v1`); the Home lead reuses it.
- Home is a workspace with `kind: home` (Home lead, plans/cmux-next/home.md section 7): created once
  by the store, not closable, first in its top section; tab bar hidden, fixed and not closable are
  derived from kind on the client. The sidebar item stays `built_in:home`; it runs `home.show`
  (select the home workspace) and draws active when the shown workspace has kind home.
- The store op `sidebar-layout-v1` is built by the sidebar sections lead, coordinated with the
  state-module owner.

## 10. Customizations

What users and agents will want, in priority order; bold ones are built in this round.

Per section: **hide in other rooms (room scope)**, **collapse (per window)**, **max height**, **look
(built-in / list)**, **title shown or hidden**, compact density (row height), sort (manual, name,
recent), filter (machine, agent status, unread only), counts and badges on the header, icon and color
for the header.
Per item: **remove**, **move between sections and regions (reducer; drag in phase 5)**, rename (a
display title override), icon and color override, open in a new window.
Layout: **reset to defaults**, import/export as JSON (`sidebar layout --json` and
`sidebar import-layout`), per-room layouts if model A proves too coarse.
App-wide: the look (setting once Lawrence picks; Debug Settings switch now), band height shares,
edge fades on or off (follows Reduce Transparency).

## 11. The window rail

Lawrence (2026-10-02): sections subsume Leo's window rail (#16740). The rail becomes a region and a
look of sections: a leading vertical region whose sections draw as icon columns (the lines-icons
look turned vertical). Leo's lane builds the rail look on top of the section layout; shared files go
through the coordinator.

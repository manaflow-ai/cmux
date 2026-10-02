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
| Bottom | sticky above the room bar | section (hidden title): Settings, Account, built-in look |

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
Section { id: "sec_<base32>", title: String?, region: top|middle|bottom, look: builtIn|list,
          scope: allRooms|room(id), maxRows: Int?, content: items([Item]) | workspaces }
Item { id: "itm_<base32>", ref: ItemRef }                          // id stable across moves
```

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

Every action is a registry action with a surface plan (actions.md); `check-action-surfaces.sh`
enforces it.

| Action id | Palette | CLI verb (Rust CLI, requested from feat-cmux-next-99) | Right-click | MCP |
| --- | --- | --- | --- | --- |
| `sidebar.section.add` | Add Section… | `cmux sidebar section add [--region top|middle|bottom] [--title T] [--look built-in|list]` | sidebar background, section header | yes |
| `sidebar.section.rename` | Rename Section | `cmux sidebar section rename <sec> <title>` | section header | yes |
| `sidebar.section.moveToTop` / `moveToMiddle` / `moveToBottom` | Move Section to Top/Scrolling/Bottom | `cmux sidebar section move <sec> --region R [--index N]` | section header > Move | yes |
| `sidebar.section.setLook` | Section Look > Built-in / List | `cmux sidebar section set <sec> --look L` | section header > Appearance | yes |
| `sidebar.section.setMaxRows` | Section Height… | `cmux sidebar section set <sec> --max-rows N|auto` | section header > Options | yes |
| `sidebar.section.toggleRoomScope` | Show in This Room Only / All Rooms | `cmux sidebar section set <sec> --room <id>|all` | section header > Options | yes |
| `sidebar.section.toggleCollapsed` | Collapse/Expand Section | exempt `focusMove` (view state) | section header | follows CLI |
| `sidebar.section.remove` | Remove Section | `cmux sidebar section remove <sec>` | section header | yes |
| `sidebar.item.add` (built-ins: `sidebar.home.add`, `sidebar.settings.add`, …) | Add Home to Sidebar … | `cmux sidebar item add <builtin|ws_…|tab_…|room|url> [--section S] [--index N]` | sidebar background > Add | yes |
| `sidebar.item.remove` (`sidebar.home.remove` alias) | Remove Home from Sidebar | `cmux sidebar item remove <itm|builtin>` | item row | yes |
| `sidebar.item.move` | — | `cmux sidebar item move <itm> --section S --index N` | drag gesture (exempt `dragGesture`) | yes |
| `workspace.pinToSection` / `tab.pinToSection` | Pin to Section… | `cmux workspace pin <ws> --section S`, `cmux tab pin <tab> --section S` | workspace row and tab menus > Move > Pin to Section | yes |
| `sidebar.layout.reset` | Reset Sidebar Layout | `cmux sidebar reset` | sidebar background > Options | yes |
| `sidebar.layout.show` | — | `cmux sidebar layout [--json]` (reads the document) | — | yes |

Drag and drop: items drag within and between sections of any region (the insertion line and gap
come from the same `DropResolver` geometry as workspace rows); workspace rows dragged onto an items
section pin them there (Option-drop keeps the workspace where it was and only pins); a section
header drags to reorder sections and to move between regions.

Keyboard: Cmd-1 runs the first item of the first top-region section (Home by default), Cmd-2…8
select the first seven workspaces, Cmd-9 the last. With no top-region item, Cmd-1…8 select
workspaces 1…8 (today's behavior). Arrow keys move through every visible row of all regions in
visual order; Return activates.

## 7. Prototypes (Debug Settings > Sidebar)

- `sidebar.sections.look` = `quiet` | `card` | `tray`:
  - quiet: built-in rows are icon + label with no pill at rest, a 1 px hairline (respects
    `appearance.borders`) separates sticky regions from the scrolling list; headers are small caps
    in secondary text.
  - card: each sticky region sits in a rounded inset card (subtle fill, no border), headers inside.
  - tray: built-in items in a top region lay out as an icon grid (Arc favorites style); bottom
    region as a single row of icon buttons; list-look sections unchanged.
- `sidebar.sections.noun` = sections | shelves (menu and header copy).
- `sidebar.sections.roomModel` = shared | perRoom (mock only: shows model B).

Screenshots come from a throwaway demo executable that links CmuxNextSidebar with the mock model.

## 8. Phases

1. This doc. Pure document model + reducer + tests (Swift), default layout. *(landing)*
2. Sidebar view: three regions, built-in and list looks, three look variants, Home as an item,
   scroll caps, mock + screenshots.
3. App: registry actions with surface plans, right-click and palette, Cmd-1 rule, Home lead's
   `home.show` as the Home item's action (replaces the hard-wired Home row from the Home branch),
   collapse in `WindowState`.
4. Store: `sidebar-layout-v1` in cmux-tui-core personal store (Rust reducer, proptest for L1-L3 and
   idempotency), client mirror + intent log, Rust CLI verbs. Coordinated with the state-module owner
   and the Rust CLI session.
5. Drag and drop between sections and regions; tab and room items; footer accessories become items.

## 9. Open decisions for Lawrence

- Name: sections (recommended) or shelves.
- Rooms: model A (one layout, room-scoped sections; recommended) or B (layout per room).
- Defaults: bottom = Settings + Account, or only Settings (account lives in the room bar today).
- Scroll policy default: sticky regions grow until they reach their share of the sidebar height (top
  1/3, bottom 1/4), then scroll inside; per-section `maxRows` overrides. Alternative: never scroll,
  the middle shrinks to a minimum of 3 rows.
- Collapse state per window (recommended) or synced per user.

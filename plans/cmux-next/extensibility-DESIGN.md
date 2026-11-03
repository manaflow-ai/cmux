# Extensibility primitives: what end users build without recompiling cmux (design)

Status: design. Prototype landed: `samples/apps/priority-view` (Priority View as a sidebar app) and
one runtime fix that the prototype found. Owner: Chief subagent "App Store extensibility
primitives", 2026-10-21.

Source: the user's voice talk with Leo (Chief log, message 9663). The cmux-next App Store has too
much in it, and it looks like a settings page. Making apps must not get ahead of the primitives
that apps stand on. An investor told the story of BB: users customized it so much that it became
slow, buggy and a maintenance burden. That must not happen to cmux.

Related: `custom-sidebar-DESIGN.md` (a469, `cmux.sidebar/1`), `app-platform.md` (the app host),
`app-platform-critique.md` (typed interfaces), `no-swiftui-DESIGN.md` (AppKit only),
`pane-protocol.md` (pages and providers), `browser-isolation.md` (process isolation),
`sidebar-performance.md` and the a436 perf gate.

## 1. Summary

- An end user can extend cmux in exactly **three places**:
  1. **Sidebar parts**: sections, row decorations, hover cards, or the whole workspace list.
     They are written in the small JS view DSL and drawn natively.
  2. **Panes**: a tab that shows an HTML/React page.
  3. **Right sidebar panels**: one of the two kinds above, docked in the right sidebar.
- Each place has **one interface**, **one runtime**, **one budget** and **one perf-gate scenario**.
  There is no fourth way. In particular, no extension point is a Swift `if` on an app id or on a
  setting.
- The App Store lists only apps that are built on these three primitives. Today it does not:
  - 49 of its entries are settings switches (the Features tab);
  - 3 of its 4 bundled apps are native pages with a manifest around them.

  Section 7 trims the store to what fits.
- The first example is Aziz's **Priority View**. Today it is native code in 43 Swift files behind
  `sidebar.priorityView.enabled`, and the App Store shows it as a "feature". The prototype shows
  that the same view is about 60 lines of app code on the public DSL. To retire the native
  version, cmux needs one missing data primitive (`chat.list`, section 5).

## 2. Hard requirements

These rules apply to all three places. A design that breaks one of them is wrong.

| # | Rule | How it is enforced |
| --- | --- | --- |
| R1 | **Zero cost when not used.** With no extension in a place, that place starts no VM, opens no stream, creates no view and observes nothing. | perf-gate counters (`custom_sidebar_mounts = 0` already exists; one counter per place) |
| R2 | **Extension code never runs on the app's main thread.** JS runs in the app-host process (QuickJS-ng, OS sandbox). Page JS runs in a WebKit or Chromium renderer process. | architecture; the JavaScriptCore prototype engine is DEV only and is removed when the Rust host ships everywhere |
| R3 | **Bounded main-thread cost per update.** One changed row costs one row's work, at any row count. Budget: p95 < 1 ms of main-thread time per batch at 500 rows. | `CustomSidebarPerfTests`, plus one perf-gate scenario per place (section 8) |
| R4 | **Web content cannot make the native app lag.** A page in a busy loop, a hung page or a crashed page does not change frame time in the terminal, the sidebar or another pane. | perf-gate scenario `web_pane_busy` (section 8); the existing sad-tab and "Page unresponsive" paths |
| R5 | **Navigation never depends on an extension.** If a sidebar script fails, is slow or is removed, the native list is shown. An app cannot take focus without a user gesture. | existing rule for `cmux.sidebar/1` and gesture tokens; applies to every place |
| R6 | **Rate limits, not trust.** Budgets are enforced by the host, not by app code. An app that goes over its budget is slowed, then paused, and the user sees why. | app host (section 6) |
| R7 | **No per-feature native hooks.** A feature that is offered as an app is built on the public primitive. If the primitive is missing something, the primitive is extended (with a version), not the app id special-cased. | review rule; the Store lists only manifest apps (section 7) |

R7 is the direct answer to the BB story. Customization becomes slow and costly when each new
customization adds its own path through the core. Here every app goes through the same three
bounded paths, so the cost is the cost of the paths. That cost is measured once and gated.

## 3. Sidebar parts: the JS view DSL

### What exists

- **Runtime.** `cmux-tui/crates/cmux-app-host` runs app JS out of process:
  - QuickJS-ng in an OS sandbox;
  - 32 MiB of memory and a 250 ms deadline per entry.

  `js/src/view.ts` gives the classic builders (`VStack`, `HStack`, `Text`, `Row`, `Badge`,
  `ForEach`, `EmptyState`, modifiers). `js/src/materialize.ts` turns them into retained scene ops
  (`create`, `update`, `children`, `remove`, `root`).
- **Interfaces** (`cmux-tui/crates/cmux-app-host/interfaces/`):

  | Interface | Draws |
  | --- | --- |
  | `cmux.section/1` | a sidebar section |
  | `cmux.sidebar.rows/1` | decorations on workspace rows |
  | `cmux.hovercard/1` | a row's hover card |
  | `cmux.sidebar/1` | the whole workspace list (a469, on `scratch/a469-custom-sidebar`, not landed yet) |

- **Data.** `cmux.live(op, params)` reads a catalog op as a signal. It reads again only on that
  op's `<family>.changed` event, so there is no timer and no per-frame work.
- **The user's own folder.** `~/.config/cmux/customize/` installs as `local/customize` and hot
  reloads. That folder is how a user (or an agent for the user) builds without an App Store.

### Decisions

1. **The DSL stays the only way to draw in the left sidebar.** No HTML in the sidebar. The sidebar
   is drawn all the time, and it is the hottest view in the app. A web view per section would add
   a renderer process, a compositor layer and IPC to every frame. Scene ops cost one AppKit view
   update per changed node.
2. **The scene renderer moves to AppKit.** Today `CmuxNextApps/Render` draws scenes with SwiftUI
   (27 files import it). This conflicts with `no-swiftui-DESIGN.md`, which lists
   `CmuxNextApps/Section` as a hot path. The renderer becomes AppKit views:
   - one `NSView` per scene node type;
   - the per-node slots from a469 (`AppSceneNodeSlot`) become direct view updates.
3. **CmuxNextApps on the web (a491).** The App Store **page** can become React, because it is a
   cold page. The **scene renderer** for sidebar parts stays native (AppKit). Default picked: split
   the module. The store UI goes to web, and the renderer goes to AppKit.
4. **Fixed vocabulary.** The DSL gets new node types only through a versioned interface change.
   Apps cannot draw pixels, cannot set frame-level animations (the host owns motion and Reduce
   Motion), and cannot measure layout.

### Budgets (enforced by the host)

| Budget | Value | When it is exceeded |
| --- | --- | --- |
| Scene nodes per mount | 4096 (exists) | the mount fails; the native fallback is shown |
| Entry time | 250 ms (exists) | the call fails; after 3 failures the mount pauses |
| Memory per app | 32 MiB (exists) | the VM is killed and restarted once, then paused |
| Op batches per mount | at most 1 per frame, coalesced in the host; at most 10 per second sustained | above 10 per second for 5 s, the host coalesces to 1 per second and the section header shows "Slowed" |
| Timers | `cmux.timer.every` ≥ 1 s (exists) | clamped |
| Live reads | coalesced to at most 2 per burst of `<family>.changed` (exists) | coalesced |

The new budget is the batch rate. All the others exist. The batch rate is what stops an app that
is correct but chatty (for example, one that rewrites a clock row 60 times a second) from costing
frames. The cost is bounded by the host, not by the app's good behavior.

## 4. Panes: HTML/React pages

### What exists

- **Interface.** `cmux.pane/1` has `render: scene | web | native`. The `web` form is designed but
  not built. `AppImplementation` has no web field, so the codemirror app's `web` entry is ignored
  today.
- **First-party React pages.** App Store (web variant), Cloud and CodeRouter use `PageWebView` with
  a scheme handler (`cmux-page://`), a strict CSP and the `cmuxPage` bridge
  (`webviews/README.md`, `pane-protocol.md`).
- **Isolation.**
  - Each WebKit page runs its JS in a WebContent process.
  - Chromium (CEF) renderers, GPU, network and extension processes are separate processes.
  - Only CEF's browser process is in the cmux process (`browser-isolation.md`, decision 1).

### Decisions

1. **One host for every web pane: the shared page host.** A third-party pane is a page on
   `cmux-app://<app-id>/` with:
   - the app's `runtime.web.root` as its only file root;
   - the app's declared CSP, intersected with the strict PageCSP;
   - the `cmuxPage` bridge, which exposes the same catalog ops the app's scopes allow.

   There is no Node, no `file://`, and no direct network access. Network goes through
   `cmux.net.fetch` with declared hosts, as for JS apps.
2. **Engine: WebKit (WKWebView) for app panes.** Default picked. WebKit runs page JS in a
   WebContent process, and an app pane needs no Chrome extensions. CEF stays for browser tabs.
   CEF's browser process runs in the cmux process, so a fault in CEF code can still affect the
   app. With WebKit, nothing from an app pane runs in-process except the compositor layer.
3. **The bridge is asynchronous and bounded.** No synchronous bridge call exists, so a page can
   never block the main thread with a call. The limits are:
   - messages up to 256 KiB;
   - at most 200 calls per second per page;
   - a page over the limit gets `rate.limited` errors.

   Large data (files, diffs) goes by handle (`doc_…`, `diff_…`), not by value.
4. **Hidden panes are throttled.** A pane that is not shown has its timers throttled by the
   engine. After the existing tab-hibernation delay, it is hibernated (the snapshot is shown, and
   the page reloads when shown again).
5. **Hang and crash.** The existing paths apply: the sad tab with Reload, and the "Page
   unresponsive" card with Wait and Exit page. Neither path blocks the main thread.

A React pane is the right choice for document-like content: dashboards, editors, long mixed
lists, charts. A pane that is "a list of rows with status" is a scene pane (`render: scene`),
because a scene pane costs less and matches native rows.

## 5. Right sidebar panels

### What exists

- `RightSidebarMode` is a closed enum: files, find, sessions, feed, dock, machines
  (`CmuxNextApp/RightSidebar/RightSidebarMode.swift`).
- `RightSidebarSections+App.swift` registers each mode in Swift. No app API reaches the right
  sidebar, and there is no CLI verb for it.
- The one way to put other content there is to dock a pane as a column (Dock mode,
  `column.dock_right`).

### Design

1. **The modes become an open list of panels.** Each panel is one of:
   - a native built-in (the six current modes, unchanged, registered as before);
   - a scene contribution (`cmux.section/1`, with `place: "rightSidebar"`);
   - a web pane (`cmux.pane/1` with `render: web`), docked.

   Default picked: no new interface. A right-sidebar panel is a section or a pane that the user
   places on the right. Both have budgets and tests already.
2. **Placement is user state.** The list of panels and their order are in the window's layout
   document, next to the left sidebar's sections. An app declares that it *can* be placed on the
   right (`places: ["sidebar", "rightSidebar"]`). Only the user (or an agent with the user's
   approval) places it.
3. **New ops, with CLI and palette surfaces:**

   | Op | CLI | Palette |
   | --- | --- | --- |
   | `rightSidebar.panel.add {contribution}` | `cmux right-sidebar add --app <id>#<export>` | "Add to Right Sidebar" on an app's section or pane |
   | `rightSidebar.panel.remove {panel}` | `cmux right-sidebar remove <panel>` | — |
   | `rightSidebar.panel.list` | `cmux right-sidebar list --json` | — |
   | `rightSidebar.panel.move {panel, index}` | `cmux right-sidebar move <panel> <index>` | — |

   They go through `ActionRegistry`, like every other entry point (shared behavior policy).
4. **Same budgets as on the left.** A panel that is not the selected mode is not mounted (R1).
   Switching to it mounts it. After 60 s hidden, it is unmounted.

### How a user tells an agent to put something there

> "Put my open PRs in the right sidebar."

1. The agent writes a section in the user's folder, `~/.config/cmux/customize/`:
   - `cmux-app.json` gets `implements["cmux.section/1"] = { "export": "prs", "places":
     ["rightSidebar"] }`;
   - `src/main.ts` gets the view, written with the DSL and `cmux.live`.

   `local/customize` hot reloads. No App Store, no review, no restart.
2. The agent runs `cmux right-sidebar add --app local/customize#prs`. The panel appears in the
   right sidebar's mode bar.
3. If the content is a document (a chart, a long report), the agent writes a web pane instead
   (`web/index.html`, `render: web`) and adds it the same way.

The `cmux-customization` skill gets this recipe, so every agent does it the same way. Code that an
agent writes in `local/customize` runs under the same sandbox and budgets as a store app.

## 6. How the host enforces budgets (R6)

The host enforces one ladder for every mount (sidebar part, right panel or pane):

| Step | Trigger | Action | User sees |
| --- | --- | --- | --- |
| 1. Normal | within budget | none | nothing |
| 2. Slowed | over the batch rate (or, for a page, the bridge rate) for 5 s | the host coalesces updates to 1 per second | "Slowed" in the header, with "Why?" (app logs) |
| 3. Paused | 3 entry timeouts in 60 s, a memory kill after a restart, or "Slowed" for 60 s | the mount stops; native fallback | "Paused: this app used too much time" and a Resume button |
| 4. Off | the user clicks "Turn Off", or the app is removed | unmount; R1 zero cost again | the native view |

The ladder is the same for a store app and for the user's own `local/customize` code. Agents read
the same state through `app.logs` and `app.info`. An agent that wrote a slow section sees the slow
step and can fix its own code.

## 7. App Store inventory and trim

### What the store lists today

The store has two catalogs (source: the inventory of 2026-10-21):

- **Discover / Installed**: manifest apps from the daemon's supervisor. Only apps with a `BUNDLED`
  marker ship (`scripts/cmux-next/sync-app-runtime.sh`).
- **Features**: a Swift array of 49 `AppFeature` entries
  (`CmuxNextApps/Store/AppFeature+Catalog.swift`). Get and Remove write one cmux.json key. The
  native code reads that key.

#### Bundled apps (Discover)

| App | Id | What it really is | Id-specific native code | Fits a primitive? |
| --- | --- | --- | --- | --- |
| Home | `cmux/home` | native page (`native: "home"`), no JS | `TopPageRoute.swift:53`, `SidebarBridge+Sections.swift:75`, `AppStoreListing.swift:88` (cannot be removed), `SidebarLayoutDocument+RailMigration.swift:113` | no: it is cmux itself |
| App Store | `cmux/app-store` | native page; React page under Debug `apps.store.surface = web` | `TopPageRoute.swift:54`, `AppsService.swift:176`, `KeyRouter+Context.swift:97`; the store hides its own entry | no: it is cmux itself |
| Cloud | `cmux/cloud` | `native: "cloud"` page and a Rust server (`fs.provider`, `terminal.connector`) | `AppCloudFeature.swift:15` (Discover banner), `CloudLinkKey.swift:7`, `CloudCredentialRelay.swift:22` | the provider part fits (it uses public interfaces); the page is native |
| CodeRouter | `cmux/coderouter` | a real JS app: section, status item and pane exports; hidden by default | `TopPageRoute.swift:55`, `AppsService.swift:135,155` (React page under `coderouter.surface = web`), `TopPages.swift:89` | yes, after the native page switch is removed |

Two defects found while making the inventory:

- **The `native` field routes nothing.** `AppImplementation.swift:22` only parses it. Opening
  Cloud from the store runs `app.open`, which needs a scene pane (`AppPanePage.swift:37`), so it
  very likely fails with `noPage`. This was found by reading the code; it was not run. The Cloud
  page that works is a separate React page (`palette.openCloudPane`).
- **`cmux.pane/1` web is ignored.** `codemirror` declares `web: "web/index.html"`, and the client
  drops it (section 4).

#### Unbundled first-party apps (dev directories only)

| Kind | Apps |
| --- | --- |
| JS scene apps | search, inbox, notes, usage, diffs, finder, integrations, memory, skills, agents, caffeinate |
| web pane | codemirror |
| native pane and native server | remote-desktop (`native: "remote-view"`) |

Id-specific code also exists for `cmux/memory` (`AgentMemorySearchHandler.swift:25`) and
`cmux/notes` (`cmux-tui-core/src/apps/catalog.rs:468`).

#### Features tab: 49 switches, none of them an app

| Group | Entries | Kind |
| --- | --- | --- |
| Backgrounds | shufflePaintings, desktopWallpaper, glass, perPane | settings keys |
| Appearance | ultraCompact, calm, brailleStatus, runningCommands | settings keys |
| Chief and chat | pet, channels, suggestedTasks, needsYou, githubFeed | settings keys |
| New Tab | projects, actions, chats, weather, machines, nowPlaying | settings keys (New Tab widgets) |
| Media | media.sidebar | settings key |
| Editor | splitDiff, minimap | settings keys |
| Devices | phoneAccess, globalHotKey | settings keys |
| Sidebar | **priorityView**, workspaceTabs, hoverCards, comfortable, expanded, minimal, sessionTree, timestamps, groupByComputer | settings keys |
| Browser | agentCursor, bookmarksBar, fullURLs, verificationCodes | settings keys |
| Layout | focusFollowsMouse | settings keys |
| Sidebar items | chief, home, notifications, history, bookmarks, search_chats, new_terminal, new_browser, new_agent_chat, customize | `.sidebarItem` cases of the `SidebarBuiltIn` enum (edit `sidebar.layout`) |

Each entry is a hard-coded `if` somewhere in the app: the feature's own code reads its key (for
example `SidebarSectionsSetting.swift:273` for `priorityView`). The store only adds a second UI for
a setting that Settings already shows. That is why the store "looks like a settings page".

### Trim (proposal)

| Item | Action | Why |
| --- | --- | --- |
| Features tab (39 settings keys) | **Remove from the store.** They stay in Settings, which already lists every key with search. A store card links to Settings > Customize. | they are settings, not apps (R7) |
| Features tab (10 sidebar items) | **Remove from the store.** "Customize Sidebar" (the sidebar's own edit mode) adds and removes built-in items. | they are layout, not apps |
| Home, App Store | **Remove from the listing.** They are not removable and not apps. | not apps |
| Cloud | **Keep one listing**, for the provider (Machines, files, terminals). The Discover banner stays. Remove `native: "cloud"` from the manifest; the Cloud page is opened by its own action. | the provider fits the interfaces; the page is cmux |
| CodeRouter | **Keep.** Remove the `coderouter.surface` native page switch when its React page ships as `render: web`. | a real app |
| Priority View | **Becomes the first app listing** after the port in section 9, step 3. Until then, it is a setting only. | the example app |
| Unbundled first-party apps | **List only when each one passes the perf gate** of its place (section 8). Then add `BUNDLED`. | R3, R4 |
| Samples | not listed (no change) | examples, not products |

After the trim, the store has 2 to 3 apps on day one (Cloud, CodeRouter, then Priority View). It
grows only through apps on the primitives. Default picked: a small, true store, not a full store
of switches.

## 8. Perf gate scenarios (a436 gate)

| Scenario | Setup | Pass |
| --- | --- | --- |
| `ext_none` | no app mounted in any place | per-place mount counters = 0; no app-host process started for a place |
| `section_500` | a `cmux.section/1` app with 500 rows; 200 one-row updates | main-thread p95 < 1 ms per batch; one `update` op per changed row |
| `section_chatty` | an app that sends 60 batches per second | the app reaches "Slowed" within 5 s; terminal key-to-glyph p95 unchanged (±1 ms) |
| `custom_sidebar` | a469's scenario | as in `custom-sidebar-DESIGN.md` |
| `web_pane_busy` | a web pane that runs `while (true) {}`, while the gate types in a terminal and switches workspaces | key-to-glyph and switch p95 unchanged (±1 ms); the pane shows "Page unresponsive" |
| `web_pane_flood` | a web pane that sends bridge calls as fast as it can | `rate.limited` after 200 per second; main-thread p95 unchanged |
| `right_panel_hidden` | a scene panel and a web panel placed but not selected | 0 mounts and 0 renderer processes for them |

## 9. Steps

| # | Step | Owner | State |
| --- | --- | --- | --- |
| 1 | This design. Prototype `samples/apps/priority-view` with a test. The empty-slot op fix found by the prototype (below). | this agent | landed |
| 2 | Scene renderer to AppKit (decision 3.2), with the no-SwiftUI owner (a488); split CmuxNextApps (store page to web, a491) | a488 / a491 | next |
| 3 | `chat.list` op and `chat.changed` event (every ACP chat on every machine: state, unread, pinned, CI failing; `chat.markRead`, `chat.pin`) in the app catalog, owned by acpmux lanes. Then Priority View ships as an app, and the native Priority code is deleted (red test first: the app shows the same order as `AgentPriorityRankingTests`). | lanes owner, then app platform | needs the op |
| 4 | Batch-rate budget and the Slowed/Paused ladder in the app host | app platform | next |
| 5 | `render: web` panes on the shared page host (`cmux-app://`, WebKit), with the bridge limits | pages owner | next |
| 6 | Right sidebar: open panel list, `rightSidebar.panel.*` ops, CLI, palette; the `cmux-customization` skill recipe | right sidebar owner | after 2 |
| 7 | Store trim (section 7) | app platform | can start now |
| 8 | Perf-gate scenarios (section 8) | a436 owner | with 4 to 6 |

## 10. First example: Priority View

**Today.**

- **Code.** It is native: 43 Swift files mention `SidebarPriority*`, `AgentPriorityRanking` or
  `priorityView`. The view, the panel model, the ranking, the feed wiring, the setting and the
  toggle action are all separate.
- **Switches.** `sidebar.priorityView.enabled` is its App Store switch; `.shown` is the titlebar
  bell.
- **Order.** needs you → finished unseen → failed or lost → CI failing → working → idle; pinned
  first in a tier.

**As an app** (`samples/apps/priority-view`, prototype):

- **Manifest.** A `cmux.section/1` export, `renderPriority`, with `defaultRegion: top`.
- **Data.** It reads `cmux.live("agent.list")`, ranks the agents by tier and then by most recent
  change, and taps focus the agent's terminal with the tap's gesture token.
- **Test** (`cmux-tui/crates/cmux-app-host/js/test/samples.test.ts`):
  - the order is blocked, done, working, with idle hidden;
  - renaming one agent sends **exactly one `update` op**, with no `children` and no `create` ops.

**What it found.** The first run of that test sent `children: []` twice for the
`() => empty ? EmptyState : null` slot on every refresh, while the slot stayed empty. Every app
with an empty-state slot (29 source files in the samples and first-party apps use `EmptyState`) sent this waste on every data
change. `materialize.ts` `buildDynamic` now skips a rebuild when the slot was empty and stays
empty. All 112 runtime tests pass. This is the kind of cost the primitive must own once, so that
each app does not pay it.

**Gaps that keep the native version for now** (step 3):

1. `agent.list` lists terminal agents only. The native view ranks every ACP chat on every machine,
   with unread, pinned and CI state. The app catalog needs `chat.list` and `chat.changed`.
2. Mark Read and Pin need `chat.markRead` and `chat.pin`, called with the tap's gesture token.
3. **The titlebar bell.** Default picked: apps get no titlebar slot (the chrome stays native). The
   section header's collapse control does the bell's job. If the user wants the bell, it becomes
   a `cmux.status/1` item placed in the sidebar titlebar.

## 11. Defaults picked (the user can override)

1. Three extension places only: sidebar parts (DSL), panes (web), right-sidebar panels (either).
2. No HTML in the left sidebar; the scene renderer goes to AppKit; only the store page goes to web.
3. App web panes use WebKit (WebContent process), not CEF.
4. A right-sidebar panel reuses `cmux.section/1` and `cmux.pane/1`; there is no new interface.
5. The Features tab leaves the store; settings stay in Settings.
6. No titlebar slot for apps; Priority View's bell becomes the section header.
7. One budget ladder (Slowed, Paused, Off) for store apps and for the user's own code.

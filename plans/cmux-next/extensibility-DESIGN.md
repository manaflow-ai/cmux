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
8. Every setup change is a generation, and cmux can always start in safe mode (section 12).
9. No layout providers; a palette source is an ordinary app (section 12, item 20).

## 12. What Linux distros, tiling window managers and ricing teach us

Source: Lawrence, 2026-11-10: "what are the best distros doing? What are the best sort of tiling,
window manager, customization things doing that we could do? What are the bad things that they
necessarily have to do that we don't have to follow? What are the, like, terrible lessons that
they've learned that we can preemptively guard against?" The survey behind this section, with
sources, is cmuxterm-hq#8750. This section takes or rejects each of its 22 proposals.

The short answer: the three places and their budgets (sections 1 to 6) already cover most of what
the Linux desktop learned the hard way. What cmux lacks is the layer distros are best at: getting
back to a working setup. A bad theme, settings file or app can't be undone in one step today, and
nothing starts cmux without them.

### 12.1 The 22 proposals

Verdicts: **exists** (cmux does this today; **partly exists** names the part that doesn't), **take** (new work, step in 12.4), **changed** (taken
in another form), **rejected**.

| # | Proposal | Verdict | Where, or why |
| --- | --- | --- | --- |
| 1 | **Generations.** Every theme, settings or app change is a numbered, atomic setup you can go back to, from the launcher too. | take | Step 9. A generation is the content hash of the resolved `cmux.json`, the theme file, the `local/customize` tree digest, and each installed app's approval (the module store already records digest and commit per install, `module-store-threat-model.md` T16, T17) with its on or off state and granted scopes. Going back restores that install state too. An app's own storage is data, not setup: it stays as it is, so a rollback never loses what an app saved. `cmux generations list`, `switch N`, `rollback`. The last 20 are kept. |
| 2 | **Safe mode and bisect.** A held key, or two crashes in a row, starts with no apps and the stock theme; bisect finds the bad app by halving. | take | Step 10. Today the fallback is per mount (R5 and the section 3 budgets; the section 6 ladder is step 4). Safe mode is the same rule for the whole launch: Option held at launch, or two crashes within 10 minutes, starts with every app and `local/customize` off and the stock theme. A banner offers Turn Back On, Go Back One Generation, and Find the Problem (bisect over installed apps, one relaunch per half). |
| 3 | **Validate before apply.** A setup that fails its schema or its load is never applied; the last good one keeps running and the error names the line. | changed | Settings already refuse bad values (`settings.invalid`, `settings-react.md`) and app manifests are schema-checked. Step 11 makes it one rule for every file a person edits by hand: a `cmux.json`, theme file or customize manifest that fails to parse leaves the last good generation running, and the error names file and line. |
| 4 | **One declarative profile, shared as a link** that previews on the real window first. | take | Step 12. A profile is a generation exported: theme, layout, settings, pinned app ids and versions. It holds data only; apps in it install through the normal consent sheet. Opening a link previews on the real window, then applies as a new generation. |
| 5 | **Portable profiles.** No absolute paths, a per-machine layer, secrets only as keychain references, a secret scan before sharing. | take | Step 12. Export refuses an absolute path or a secret value, and names the key. Per-machine values (fonts that aren't installed, display sizes) go in a local layer that is never exported. |
| 6 | **Immutable base, overlays on top.** First-party UI is never patched; removing every overlay gives the stock app. | exists | R5 and R7: apps draw only in the three places, through interfaces, and the native view is the fallback. |
| 7 | **A stable, versioned SDK, never a raw ABI.** | exists, plus a rule | Interfaces are versioned (`cmux.section/1`), JS runs in the QuickJS sandbox with declared scopes, and the DSL has a fixed vocabulary (decision 3.4). New rule: an interface major stays supported for 12 months after its successor ships, and every deprecation ships a migration in `cmux ext` and a warning in `cmux ext dev`. |
| 8 | **Compatibility testing.** Every listed app runs against each nightly and breakage is flagged before release. | changed | Not in cmux CI (no new CI jobs, Lawrence 2026-10-23). The registry runs each listed app's own tests against each nightly on its side and marks the listing "not checked with this version" on failure. Step 14. |
| 9 | **One push-based event bus**, no polling, no timers under 1 s, no per-tick process spawns. | exists | `cmux.live` rereads only on `<family>.changed`, and `cmux.timer.every` is clamped to 1 s (section 3). Running a command (`pane.run`, `workspace.run`) needs the `workspace:execute` scope the person approved and runs in a terminal; it isn't a data source. Missing: a GitHub change event (cmux#40249's fourth item). |
| 10 | **Reactive widget SDK**: a widget is a function of signals and patches in place. | exists | The DSL and `materialize.ts`: one changed row sends one `update` op (section 10's test). |
| 11 | **Curated, signed registry**, built by us from a tagged commit; sideloading is a separate, visibly different path. | changed | The git install path already pins a reviewed commit and digest, binds the publisher to the repo owner and refuses silent updates (threat model T5 to T27). Verified native servers are signed per platform. Step 14 adds the listed tier: the registry builds each version from its tagged commit and refuses an upload whose digest differs. A sideloaded app keeps the consent sheet and carries a visible "not reviewed" mark. |
| 12 | **No install-time code**, no dependency resolution on the user's machine, no extension packs; reject invisible and bidi Unicode. | exists, plus a check | Install never checks out or runs anything (T9, T18), and a module is one digested tree with no dependency field. New: step 11 refuses bidi controls and invisible characters in an app's JS and manifest strings (T13 covers file names only). |
| 13 | **Permission re-consent** on an update that widens scopes; publishers use 2FA and trusted publishing. | exists, plus registry | Updates never apply silently and list added scopes and origins (T22, T23). Publisher 2FA and publishing from CI with provenance are registry rules, step 14. |
| 14 | **Automatic snapshot before each install or update**, one-click undo. | take | Falls out of step 9: every install, update or removal is its own generation, labelled "Before installing X". |
| 15 | **One theme schema**, import and export of the common 16-color scheme format, and a lint against raw colors in app UI. | changed | `ThemeTokens.derive` is the one token model, and theme files carry it (cmux#40235). Take the 16-color scheme import and export (step 13). The raw-color check is a warning in `cmux ext dev`, not a CI lint. |
| 16 | **Palette from the wallpaper**, held to the contrast floors. | take | Step 13: accent, glass tint and terminal ANSI from the background image, through `ThemeTokens.derive`'s contrast floors. |
| 17 | **Motion tokens**: every animation reads a named curve and duration from the theme; apps declare motion and never drive frames. | exists | Every animation goes through a motion gate (`motion-DESIGN.md`), tokens live in `motion.md`, and apps can't set frame-level animations (decision 3.4). What a theme file can't set yet is tracked in cmuxterm-hq#8758. |
| 18 | **Performance budgets per app**, shown, with lazy activation and throttling past budget. | partly exists, plus display | The per-mount budgets in section 3 exist; the batch-rate budget and the Slowed and Paused ladder are step 4 (next). R1 means an unused place costs nothing. New: the App Store's Installed list shows each app's start time, memory and updates per minute (step 10), so the slow one is found without bisecting. |
| 19 | **Named feature flags**, honoured by every app. | changed | Settings are already named, schema-checked keys on every surface. Apps read a short list of global ones (Reduce Motion, glass, compact) as a signal, rather than a second flag system. |
| 20 | **Out-of-process providers** for layouts and palette sources. | rejected for layout | The app host is already out of process, so a palette source is just an app. A layout program would sit on the resize path, which is per frame (R3), and layout is the person's state in the layout document (5.2). Revisit when someone asks for a layout cmux can't express. |
| 21 | **Built-in capture**: the setup in a clean demo state as an image and a short clip; shared pieces record their lineage. | take, later | After step 12. A shared profile records what it was forked from. |
| 22 | **One docs page per extension point**, each with a template that runs on first save. | exists, in progress | `cmux ext new` and `cmux ext dev` (cmux#40242), templates and the ideas page (cmux#40247), the `cmux-customization` skill. Each interface in `cmux-app-host/interfaces/` gets its own page. |

### 12.2 What they have to do that we don't

Each Linux desktop program is its own project, so they pay costs cmux doesn't have to pay:

- **Twenty config formats.** We own every surface: one settings file and one schema.
- **Theming each program by hand.** One token set feeds native chrome, web pages, terminals and
  agent panes.
- **Plugins that link against the compositor.** Apps see a versioned interface in a sandbox, never
  our memory (R2, item 7).
- **Shell scripts polled every second for bar widgets.** Data is pushed (item 9).
- **Packaging as code run as root.** An app is data plus sandboxed code; install runs nothing
  (item 12).
- **A black screen on a broken config.** The native app always draws; a failed app shows its native
  fallback (R5), and launch can fall back to safe mode (item 2).
- **Log out to see a change.** Themes and sidebar parts already apply live.
- **Fixing paths by hand when copying someone's dotfiles.** Profiles are portable by schema
  (item 5).

### 12.3 Their worst lessons, and the guard for each

| What went wrong there | Guard here |
| --- | --- |
| Compositor plugins break on every release and get pinned to one version | Versioned interfaces with a 12-month window, registry checks against nightly (items 7, 8) |
| A desktop shell's move to ES modules broke nearly every extension at once, because extensions patched its internals | No access to internals; deprecations ship a migration (item 7) |
| Polling widgets spawn processes several times a second and drain the battery | Pushed data, a 1 s timer floor, the batch-rate budget (section 3) |
| Malware shipped through an unreviewed package repository (July 2025) | Listed tier built and checked by the registry; sideloads marked (item 11) |
| Worms spread through package install scripts and stolen publish tokens (2025) | No install-time code, publishing from CI with 2FA (items 12, 13) |
| A trusted editor extension pushed a malicious update hidden in invisible Unicode, spread through extension packs | Updates need approval and list new reach; invisible and bidi characters refused; no packs (items 12, 13) |
| A long-trusted maintainer hid a backdoor in release tarballs that weren't in git (2024) | The registry builds from the tagged commit itself; git installs read the tree, never an upload (items 11, 12) |
| Dotfile repos leak API keys | Export refuses secrets and absolute paths (item 5) |
| Users can't find which of their extensions is slow | Per-app cost in the Installed list, bisect in safe mode (items 2, 18) |
| A config error crashes the session at login | Generations, safe mode, validate before apply (items 1 to 3) |

### 12.4 Steps

These continue section 9's table.

| # | Step | Owner | State |
| --- | --- | --- | --- |
| 9 | Generations: hash, keep 20, `cmux generations list / switch / rollback`, a generation before every install, update and removal | app platform | next |
| 10 | Safe mode at launch (Option held, or two crashes in 10 minutes), bisect over installed apps, per-app cost in the Installed list | app platform | after 9 |
| 11 | One validate-before-apply rule for `cmux.json`, theme files and customize manifests, naming file and line; refuse bidi and invisible characters in app code and manifests | settings lead, app platform | next |
| 12 | Profiles: export a generation as data, portable (no absolute paths or secrets, per-machine layer), share as a link that previews before applying | app platform | after 9 |
| 13 | Import and export of the common 16-color scheme format; palette from the background image through `ThemeTokens.derive` | theme owner | can start now |
| 14 | Registry listed tier: build from the tagged commit, publish from CI with 2FA, check listed apps against each nightly | registry owner | after the store trim (step 7) |

Generations, safe mode and profiles each need an iPhone row in `cmux-next-ios/verify/parity-mac.md`
when they ship: the phone lists generations and can go back one. Safe mode itself is "not from a
phone" (it is how the Mac app starts).

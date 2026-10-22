# Custom sidebars: the classic JS sidebar, ported (Lawrence, 2026-10-21)

> "all i want to see is the blue dot and spinner. no timestamps/merged indicator. but we should
> support super custom sidebars (look at the js scripting stuff we have in cmux-classic, we need
> to port similar thing over for custom sidebar) but you need to ensure performance is
> extraordinarily fast. but by default sidebar needs to be as minimal as possible." (user 9208)

The default sidebar stays minimal (a419 owns that). This doc covers the opt-in custom sidebar:
a user script that replaces the workspace list.

## What classic does (origin/main)

- **Files.** `~/.config/cmux/sidebars/<name>.js`, hot reloaded by a kqueue watcher (150 ms
  throttle).
- **API.** `sidebar(fn)` returns a view from the SwiftUI-like builders: `VStack`, `HStack`,
  `ZStack`, `LazyVStack`, `Text`, `Image`, `Spacer`, `Divider`, shapes, `ProgressView`, `Menu`,
  `TextField` and `Button`. It also has keyed `ForEach`/`Reorderable`, `signal`/`computed`,
  `data.<key>()` and `cmux(method, params)`.
- **Data keys.** `workspaces` (title, selected, unread, status, branch, pr, agents...), `groups`,
  `selectedId` and `unreadTotal`.
- **Output.** The script emits scene ops (`root`, `update`, `append`), which a Swift store
  renders as native SwiftUI.
- **Runtime.** One `JSContext` per sidebar, `@MainActor`, with a 250 ms watchdog through a
  private symbol (silently off when that symbol is missing).
- **Classic's cost: the script runs on the main thread.**
- **Classic's cost: a 1 s rebuild.** A `TimelineView(.periodic(by: 1))` rebuilds the whole data
  context every second on main.
- **Classic's cost: whole-array resends.** `workspaces` is one key, so one change re-serializes
  and re-parses every row.
- **Classic's cost: sticky errors.** One exception keeps the sidebar in an error view until the
  next save.

## What cmux-next already has

- **The engine.** The app platform runs app JS in the daemon's app host
  (`cmux-tui/crates/cmux-app-host`): QuickJS-ng in an OS sandbox, 32 MiB and 250 ms per entry,
  in a separate process.
- **The view language.** It is the classic one (`js/src/view.ts`), with a retained materializer
  (`js/src/materialize.ts`):
  - one scene node per view and one effect per live prop;
  - a prop sends `update` only when its value changed;
  - `ForEach` is keyed and sends `children` only when the order changed.
- **Classic compatibility.** `js/src/compat-sidebar-data.ts` already gives classic scripts
  `sidebar(fn)`, `data.<key>()`, `cmux(method, params)`, `openURL` and `log`. Nothing mounted
  the `sidebar` export, so a classic script rendered nowhere.
- **The user's folder app.** `~/.config/cmux/customize/` installs as `local/customize` and hot
  reloads (`local_reload.rs`). It already implements `cmux.hovercard/1` and
  `cmux.sidebar.rows/1` (`docs/cmux-next/sidebar-customization.md`).
- **The Swift side.** `AppsClient.mount` → `AppSceneModel` (an op reducer) → `AppSceneView`
  (native SwiftUI).

So the port is small. It adds a new interface, mounts it in place of the list, and fixes the one
main-thread hot spot.

## The API: `cmux.sidebar/1`

```json
"implements": { "cmux.sidebar/1": { "export": "sidebar" } }
```

`sidebar(ctx)` returns a view. It replaces the workspace list. The titlebar row, the sections
above and below, and the footer stay native. A classic script ports with its body unchanged:

```js
sidebar(() => VStack([...]))          // classic form: the compat layer sets exports.sidebar
// or
globalThis.__cmuxAppExports = { sidebar: () => VStack([...]) }
```

- **Opt in.** Only the user's own app (`local/customize`) may replace the list. That is the same
  rule as rows and the hover card: an installed third-party app cannot take over navigation.
- **Opt out.** Delete the export, or the folder. The native list comes back at once.
- **Errors.** A script that fails to render never leaves the user without navigation. The native
  list stays and shows under the failure row. Saving a fixed file remounts it (same rule as rows).

### Data a script can read

The script reads through the scoped catalog ops its manifest grants (`workspace:read`,
`agent:read`, `notification:read`), as live signals:

| Classic `data.` key | Source in cmux-next |
| --- | --- |
| `workspaces` | `workspace.list`, mapped to the classic shape: `id`, `title` (= `name`), `selected` (= `focused`), `index`, `unread` (from `notification.list`), `agents` (from `agent.list`), `status` (`working` when an agent works, `needs-attention` when one waits, else `idle`) |
| `agents` | `agent.list` |
| `notifications` | `notification.list` |
| `workspaceCount`, `selectedId`, `selectedTitle`, `unreadTotal` | computed from the above |

- **Lazy keys.** Each key is created on first read, so a script that never reads agents never
  subscribes to them.
- **Read-only.** There is no file system, no network (unless granted in the App Store page), and
  no `eval` of host data.

### Actions

- **Calls.** `cmux(method, params)` (classic) or `cmux.<area>.<op>(params)` call catalog ops.
  Classic names are renamed: `workspace.select` → `workspace.focus`, `surface.focus` →
  `tab.focus`.
- **Gestures.** A tap or menu event mints a one-shot user-gesture token (ABI "Gesture tokens").
  A script can only move focus in answer to a click, never on its own.

## Update model and performance

The budget is p95 < 1 ms of main-thread time per sidebar update, at 500 workspaces with a script
on. With no script set, the cost is zero.

1. **No script: zero cost.** `SidebarCustomizationService` mounts nothing unless
   `local/customize` implements `cmux.sidebar/1`. No mount means:
   - no app-host VM is started for it;
   - no `apps-scene` stream;
   - no `NSHostingView`;
   - no observation.

   The native list is untouched. The perf gate's `custom_sidebar` scenario checks the
   `customSidebarMounts` counter = 0 and `customSidebarApplies` = 0 while the stock gate scenarios
   run.
2. **Script runs off main, always.** The JS runs in the app-host process, not in the app. The app
   only receives op batches. A runaway script hits the host's 250 ms entry budget there and costs
   the app nothing.
3. **Inputs change → ops, never per frame.**
   - There is no timer and no `TimelineView` tick.
   - `cmux.live` re-reads only on a `<family>.changed` event, coalescing bursts to at most two
     reads.
   - The keyed `ForEach` reconciles rows, and each prop effect sends an `update` only when its
     scalar changed.
   - A 500-row refresh where one row's unread count changed sends one `update` op.
4. **Main thread: only touched nodes re-render.** Before this change, `AppSceneModel.scene` was
   one observed property, so any op invalidated every `AppSceneNodeView` (O(nodes) body
   evaluations per update). Now:
   - `scene` is `@ObservationIgnored`;
   - each node has its own observable slot, `AppSceneNodeSlot`, holding the node and its
     flattened children;
   - `apply` reports the ids it touched, and only those slots (plus the inline `Group`/`ForEach`
     parents whose flattened children changed) are written;
   - a one-row update re-evaluates one row's body, whatever the row count;
   - whole-scene observers (row decorations, hover card readiness) watch a `revision` counter.
5. **Virtualized.** The host wraps the scene in a `ScrollView`. Scripts use `LazyVStack` for long
   lists (the templates do), so only on-screen rows have views. The node budget (4096) still
   applies.

### Measured

`CustomSidebarPerfTests` (Swift Testing, run on the fleet) hosts a 500-row scene the way the
sidebar does. It applies 200 single-row update batches and times `apply` plus
`layoutSubtreeIfNeeded` + `displayIfNeeded` on main. It records p50/p95 and asserts the 1 ms
p95 budget. `CustomSidebarSlotTests` asserts the structural property behind it: one update
invalidates exactly one slot. The results table is in the landing report and in
`~/fun/cmux-galleries/custom-sidebar/`.

## Tests (red first)

- `CustomSidebarSlotTests`:
  - a one-node update invalidates only that node's slot;
  - a `children` op invalidates the parent and its inline ancestors;
  - a remove clears the slot.
- `CustomSidebarServiceTests`:
  - no `cmux.sidebar/1` implementation → no mount and no view (zero cost);
  - an implementation → one mount on surface `customSidebar`;
  - removing the export unmounts it.
- `CustomSidebarPerfTests`: the p95 budget at 500 rows.
- Rust `interfaces.rs` unit test: `cmux.sidebar/1` loads (known interface, valid options).
- Perf gate `custom_sidebar` scenario: the counters prove zero cost with no script.

## Not in this step

- `groups` and `Reorderable` drag-to-reorder through `workspace.reorder`. The JS side exists; the
  daemon op mapping is a follow-up.
- `clock`. Scripts use `cmux.timer.every`, which is clamped to ≥ 1 s and runs off main.
- Showing the custom sidebar in a pane or in the right panel (classic `cmux sidebar open`).

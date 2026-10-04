# cmux next: app screens (screen kinds `workspace`, `app`)

Spec: worktrees/cmux-next-spec/spec/app-screens.md (Lawrence R63 to R65; the coordinator owns the
spec). Owner of this plan: layout lead (daemon screen model, app rendering). Manifest
`presentation`: app platform lead. Sidebar items and drag into a workspace: sidebar lead. Primary
input: Home lead and keybindings lead.

Model decision (coordinator, app-only): there is no `appColumn` in v1. Every app workspace (Home,
App Store, CodeRouter, any `presentation.screen` app) is app-only.

## 1. Model (daemon owns it, OWNERSHIP-PRINCIPLES)

```
Screen { kind: ScreenKind, ... }                          // kind defaults to workspace
ScreenKind = workspace | app { app: AppId }
Tab kind `app` { app: AppId, route: Option<String> }      // frontend-rendered app page
```

- `workspace`: today's screen, unchanged.
- `app`: exactly one pane holding exactly one `app` tab. No tab strip, no splits, no columns.
- An app workspace has global scope: one per app per daemon store. It holds exactly one screen,
  the app screen. Re-open selects it. The app surface cannot be closed or moved out; closing the
  workspace closes the app.
- The daemon stores the kind and the app id and has no special case for Home, App Store or
  CodeRouter, except that the Home app workspace is the home workspace (`workspace.ensure_home`).
- An `app` tab in a `workspace` screen is an ordinary tab ("Open as Tab"). An ordinary workspace
  whose only tab is an app tab is valid and survives a restart.

Invariants (reducer and daemon, with tests):

| Id | Invariant |
| --- | --- |
| A1 | An `app` screen has one pane with one tab, of kind `app`, for its own app. |
| A2 | An app workspace has exactly one live screen, its app screen. |
| A4 | A refused op changes nothing (typed error, below). |

## 2. Ops and refusals (daemon, capability `app-screens-v1`)

- Create: `workspace.ensure_app {app, kind: "app"}` (v2 op, idempotent per app): one workspace of
  workspace kind `app` holding one `app` screen with the `app` tab. Result `{workspace_id,
  screen_id}` plus `replayed` and `revision`. Steps are separate commits (workspace, app tab, kind
  row); the next call resumes. A workspace that lost its shape between the commits stays an
  ordinary workspace with every tab, and the app gets a fresh workspace.
- Home: `workspace.ensure_home {app}` makes the home workspace the app workspace of the Home app
  (section 4).
- Raw `new-app-tab` and v2 `tab.create_app {app, route?}` create an app tab at a pane, or in a
  workspace (its first pane when it is empty). `route` is a bounded client state (max 4096 bytes),
  persisted and restored after restart.
- Refused with raw `error_code` `app-screen-fixed` (v2 `app.screen_fixed`, details `{screen_id}`)
  when a command targets the app screen, its pane or its tab: `split`, `new-pane`,
  `new-pane-right`, `new-row`, `new-screen` in an app workspace, `move-tab*` into or out of it,
  `move-tab-to-column`, `set-column-sticky`, `swap-pane`, `apply-layout`/`workspace.layout.apply`,
  `undo-layout`, `close-tab`/`close-pane` of the app tab, and a new tab at an explicit pane of the
  app screen. Allowed: its width, and closing the workspace.
- A new tab sent to an app workspace without a pane (a workspace or screen target, including
  `new-conversation-tab {workspace: home}`) is not refused: it goes to the app workspace's
  companion workspace, an ordinary workspace of kind `app_tabs` (one per app) placed directly
  after it, created when missing in the same commit as the tab. Its default name is `"<display_name> Tabs"` (the optional
  `display_name` on `workspace.ensure_app`/`workspace.ensure_home`, the manifest's English
  name; else the app id). It reads back as `extra.kind: "app_tabs"`, `extra.app` (raw
  `Workspace.kind`/`Workspace.app`) and `extra.default_title: true` (raw `Workspace.extra.default_title`) until any rename, which
  turns it false for good. The marker, never the name, finds the companion.
- `workspace.create {initial_content: "app", initial: {app, route?}}` and raw `create-workspace
  {initial}` make an ordinary workspace whose only tab is an app tab in one commit (the
  session-target `tab.create_browser` path), so no client sees it empty.
- The v2 state ops map to the same checks in the one shared validator (state/app_rules.rs), so the
  raw and v2 paths refuse alike. The layout reducer has `Reject::AppScreenFixed`. The commit check
  (state/app_commit_rules.rs) is authoritative on the committed rows.
- Read shape: `screens[].kind: "app"` and `screens[].app` on an app screen, omitted on a
  `workspace` screen. Connections without `app-screens-v1` read an `app` tab as a frontend
  `browser` tab.
- Storage: `resource_screen_kinds(screen_id, kind, app_id)` (kind is always `app`), a side table
  older builds ignore (deleted on tombstone, overlaid and shape-checked at load, rows that lost
  their shape deleted in one transaction). The app tab is `app_tabs` next to its frontend browser
  row; app workspaces are `app_workspaces`; companions are `app_tabs` rows of the one kind table `workspace_kind` (rebuilt at open from the
  home-only shape: kind IN ('home','app_tabs'), with app_id, default_name and renamed). A closed
  app workspace that `closed.reopen` brings back loads as an ordinary workspace with its app tab;
  the next `workspace.ensure_app` for that app restores its kind when it still has its shape, else
  makes a fresh app workspace.

## 3. App (Swift, no cmux-tui window)

- Decode `kind`, `app` (ScreenSnapshot, LayoutMapping).
- Rendering: an `app` screen draws the app surface full bleed (no pane chrome, no tab strip, no
  focus ring).
- Menus and palette: actions that would be refused are hidden on these targets
  (ActionTargetReasons), so menus and the daemon agree.
- The app surface is the same view type for a screen and for a tab ("Open as Tab": an `app` tab
  in a workspace screen when the manifest has `tab: true`), with one state source.
- Sidebar items call `cmux.apps.open` (app platform lead), which calls `workspace.ensure_app` and
  selects the workspace.

## 4. Migration

- Home: the existing home workspace keeps its id. On the first `workspace.ensure_home {app}`, a
  home that holds tabs moves every screen, pane and tab into its companion workspace ("Home
  Tabs", directly after Home; created holding them in one commit, so it is never empty), then
  gets the Home app tab and kind. No tab is lost. Each step is
  resumable and the call is idempotent (twice-run and restart tests). An empty home becomes the
  Home app screen with no companion.
- App Store and CodeRouter are session-local internal page tabs today (`local-page:` ids, not
  restored after relaunch), so nothing persisted migrates.

## 5. Steps (each lands alone)

1. This plan.
2. Daemon: model, side tables, refusals in the shared validator and the reducer, read shape,
   `workspace.ensure_app`, Home migration, companion routing, spec/schema/bindings; red wire and
   restart tests first.
3. App: decode, rendering, hidden menu rows, sidebar items, "Open as Tab". Swift only.
4. Primary input contract (Home lead, keybindings lead), test matrix row per surface.

## 6. Open points

1. The manifest schema still lists `presentation.screen: appColumn`; the daemon accepts only
   `app`, so `cmux.apps.open` must map it.

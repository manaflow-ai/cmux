# cmux next: state ownership, consistency and the CLI surface

Decisions by the user on 2026-09-30. Builds on architecture.md 1, data-model.md 1-3,
state-audit.md and cli.md; where this file and an older one disagree, this one wins.

## 1. The rule

A fact has exactly one owner. The owner is the longest-lived process that every client
that needs the fact can reach:

| Owner | Holds | Clients |
| --- | --- | --- |
| Workspace's home daemon, shared | anything two clients of that workspace must agree on | app, TUI, CLI, iOS, other Macs |
| Home daemon, personal (`profiles-v1`) | how one user organizes and views things | this user's app, CLI, TUI on this Mac |
| App file | preferences only the app reads | app |
| App memory | state that dies with a gesture or a window | app |

A client may cache an owner's fact, but a cache is always rebuilt from the owner's
events and never written back as a second source. Every write goes to the owner, by
public id, with an idempotency key.

## 2. Ownership table (target)

Shared on the workspace's home daemon:

- Layout: workspaces, screens, columns, splits, panes, tabs, tab order.
- Workspace identity: name, custom title, color, icon.
- Tab state: name, pinned, tab groups (name, color, collapsed, members), browser tab
  record (url, title, favicon, engine, profile id, zoom, short back/forward list),
  terminal font-size zoom.
- Screens: name, pinned, color, order, screen groups (new: not in the daemon today).
- Closed history: recently closed tabs, screens, workspaces (new, `closed-history-v1`).
- Workspace kind: `ephemeral` (incognito). Closed by the daemon at its next start and
  never listed as a normal workspace. Replaces `incognito-workspaces.json`.
- Workspace status: status line, progress, log (new). Replaces the dead
  `WorkspaceStatusBoard`.
- Terminal-derived: title, cwd, git branch, OSC 9;4 progress, parsed by the daemon for
  every terminal, not only mounted ones.
- Notifications and acks, agent state (already there).

Personal on the home daemon:

- Workspace groups and sidebar order (the only copy; the shared `workspace_groups`
  table and its commands are removed after the one-time migration that already runs).
- Rooms, room follows, room pins, session registry (already there).
- Saved tab groups (moved from the shared store; room-scoped).
- Window records, including each window's selected tab per pane and focused pane
  (section 3). Saved on every change, not on a 500 ms timer. One record per window,
  keyed `(install_id, window_id)`, owner = install id, per-record revision with CAS
  (`window_record.list|put|delete`, `window-records-v1`). The old `windows` frontend
  projection migrates once into records owned by `install_unadopted`; an app adopts
  one by putting the same `window_id`.
- Workspace and room recency.
- Browser profiles (id, name, color); their data directories stay app files.

App files: site permissions, browser import, DevTools layout, onboarding, updater,
crash marker, per-profile browser visit history (one file per profile).

App memory: drag, hover, popups, find bar, palette query, niri scroll offset and
in-drag widths, notification banners.

Later (not this pass): mobile host and pairing, the SSH link, one Cloud credential store
shared by app and CLI.

## 3. Selection and focus

What is "current" belongs to the window that shows it. Each window record holds its
selected tab per pane and its focused pane; the app writes it on every change, and the
CLI, TUI and iOS read it. `cmux tab <id> focus` asks the app to show that tab in the
window that lists its workspace (app scope). The daemon's shared focused workspace,
pane and terminal remain only the default for clients with no window (the TUI, a CLI
with no app); the CLI's `current` selector means that default, and `$CMUX_TUI_TERMINAL_ID`
names the caller's own terminal.

## 4. Consistency contract for every CLI mutation

1. A mutation returns only after every later read, on any connection, sees it.
   Daemon v2 already does (reply after commit and in-memory apply).
2. App `action.run` waits by default: it replies after every daemon command the action
   sent has replied and the app store has applied their echoes, then republishes the
   snapshot. The reply carries `created` (public ids) and the target as given.
3. App reads accept `after` (a daemon revision); the app awaits a snapshot that covers
   it before resolving targets. Targets resolve by exact public id or unique prefix; an
   id that matches nothing after the barrier is `not_found`.
4. Every mutation carries an idempotency key. The CLI generates it, prints it on any
   failure after sending, and `--idempotency-key K` retries safely. The app passes the
   key through as the daemon mutation id. A timeout says whether the request never ran
   (`not_run`) or may still apply (`in_progress`).
5. No sleeps: waits use `session.events`, `events.stream`, `terminal.wait`, or a
   barrier. acpmux's fixed sleeps (cancel, peer add, host restart, detach) go.

## 5. CLI surface (curated)

`cmux` shows and accepts only scopes for features cmux-next supports:

```
workspace  screen  pane  tab (+ group, pin)  terminal  browser  notification  agent
group (workspace groups)  room  window  settings  events  acp  app
```

- Daemon scopes use `cmux.protocol/2`. New v2 resources: workspace metadata, tab pins,
  tab groups, saved tab groups, workspace groups, rooms, screen metadata and groups,
  closed history, workspace status. All ids are public and stable.
- App actions are callable by CLI name only when the registry marks them for the CLI
  (`cli: true`: a purpose outside the GUI). `cmux action run <id>` stays for scripts.
- Hidden from help and refused under the `cmux` name: `raw`, `provider`, `pairing`,
  `projection`, the shared workspace group commands. The binary keeps them where its own
  processes need them (machine agent, provider authority) under private spellings.

## 6. Work plan

| Step | Area | Contents |
| --- | --- | --- |
| A | daemon v2 | resources over existing storage: workspace metadata, tab pin, tab groups, personal workspace groups and order, rooms and pins; saved tab groups move to personal |
| B | daemon new state | screen metadata and groups, closed history, `ephemeral` workspaces, workspace status, browser record fields, terminal progress; remove shared group commands |
| C | app | consumes B (closed history, ephemeral, status, browser fields); selection saved in window records immediately; `action.run` contract; per-profile history file |
| D | CLI | curated grammar over A and B, consistency flags, acpmux without sleeps |

A and B are Rust in cmux-tui-core; C is Swift; D is the cmux-tui CLI and acpmux.

## 7. Single-writer gaps (client-enforced until connections carry an install identity)

- Window records: the daemon trusts the `install_id` a `window_record.put|delete`
  names; any local client can write any install's record.
- Browser tab records: `owner` (the hosting app's install id) is set by the raw
  frontend browser commands and `tab.update {owner}`; the daemon does not check that
  the writer is that install, and other record fields (url, title, zoom, history)
  are not yet refused for writers other than the owner.
- Fix: bind an authenticated install id to each connection (peer credentials plus a
  per-install key locally), then reject single-writer record writes from anyone but
  the stored owner.

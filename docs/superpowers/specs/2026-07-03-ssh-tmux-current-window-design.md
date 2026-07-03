# Design: `cmux ssh-tmux` mirrors into the current window (no group, no new window)

**Date:** 2026-07-03
**Status:** Draft (awaiting user review)
**Branch:** `feat/sub-workspace`
**Feature area:** Remote tmux beta (`cmux ssh-tmux`)

> **Design history:** an earlier draft wrapped the mirrored sessions in a
> `WorkspaceGroup`. The user cut that: mirrored sessions should be **plain
> workspaces in the current window**, exactly like local ones — no group
> wrapper, no dedicated window. That collapses the feature to re-routing the CLI
> default onto behavior the app **already has** (`remote.tmux.mirror` /
> `RemoteTmuxController.mirrorHost`), plus filling that path's gaps and adding a
> `--new-window` escape hatch. Group scope is dropped entirely (see §7).

---

## 1. Problem & goal

Today `cmux ssh-tmux <host>` → `remote.tmux.window` → `mirrorHostInNewWindow`
opens a **dedicated new cmux window** mirroring the host's tmux sessions (one
workspace per session), quarantined from the user's local workspaces.

**Goal:** by default, mirror the host's tmux sessions as **plain workspaces in
the current window's sidebar**, alongside local workspaces — no group, no new
window. Keep the dedicated-window behavior behind a `--new-window` flag.

## 2. Decisions

| # | Decision | Choice |
|---|----------|--------|
| D1 | Container | **No group.** Plain workspaces in the current window (like local). |
| D2 | Replace vs add | **New default = current-window mirror**; `--new-window` keeps the dedicated-window path verbatim. |
| D3 | No current window | Create a **plain** window, mirror into it. |
| D4 | Session end (network loss) | **Reconnect like SSH workspaces** — a recoverable SSH/network drop keeps the workspace in a reconnecting/disconnected state with the existing reconnect path; it does NOT close. |
| D5 | Session end (definitively killed) | The tmux session no longer exists → nothing to reconnect to → the workspace closes (existing per-session teardown). Reconnect is scoped to *transport loss while the session is still alive*. |
| D6 | New tmux session on host | **Not offered in v1.** New sessions are created on the host directly and appear via the live `%sessions-changed` feed. No new-workspace interception anywhere. |

**Rationale for D4/D5 (product judgment, delegated):** a tmux session that is
truly killed does not exist anymore, so a "reconnect" button would silently
create an unrelated empty session — worse than closing. The app already draws
this line: a recoverable transport loss reconnects the `tmux -CC` connection and
never reaches the definitive-end hook, while a real session-end does. So D4
(keep + reconnect on network loss) and D5 (close on real kill) are already the
system's two existing paths — this design just makes sure the current-window
mirror uses them, and adds no new disconnected-state machinery.

## 3. Architecture

The unit of mirroring becomes the **current window's `TabManager`**, not a
dedicated window. Every tmux session → one `isRemoteTmuxMirror` workspace in
that window via the existing `mirrorSession(host:sessionName:into:)`. No
`WorkspaceGroup`, no `remoteHostHash`, no new registry key — the mirror is just
workspaces the existing per-session mirror/teardown code already manages.

**Reused as-is (verified):**

- `RemoteTmuxController.mirrorHost(host:)` — *"mirrors each session as its own
  workspace in the active window's sidebar."* This is the target behavior; it
  already exists. This design hardens it (auth-required, no-window, idempotency)
  and routes the CLI default to it.
- `mirrorSession(host:sessionName:into:)` — one workspace per session,
  unchanged.
- `handleSessionEndedRemotely(...)` — definitive-end hook; its `.closeWorkspace`
  action already applies to shared-window mirrors, which is exactly this case.
  Doc comment already states a transient loss does NOT reach here (D4/D5 split
  is already implemented).
- `WorkspaceRemoteConnectionState` (`disconnected/connecting/reconnecting/
  connected/failed`) + `reconnectRemoteConnection()` +
  the "Reconnect" context-menu item — the existing reconnect UX (D4).

## 4. Command flow

### 4.1 CLI (`CLI/cmux.swift`, `runRemoteTmux`)

- Add a `--new-window` flag to the `ssh-tmux` arg parser (today parses `--port`,
  `--identity`, `--no-focus`, destination).
- Default (no `--new-window`) → **new socket method `remote.tmux.attach-here`**
  (name TBD in impl; a distinct method from `remote.tmux.mirror` so it can carry
  the hardened auth/no-window/idempotency contract and a proper return payload).
- `--new-window` → existing `remote.tmux.window` (verbatim).
- The auth-retry loop (BatchMode fails → run returned `ssh_argv` in the user's
  tty → retry once, bounded by `didAuthenticate`) is shared: both methods return
  the same `{auth_required, ssh_argv}` / `{mirrored, …}` shapes.
- `--no-focus` (`activate=false`) for the current-window path: don't raise the
  window and don't change the selected workspace; the mirror workspaces are
  still created. `activate=true` raises the window and selects the first
  mirrored workspace.
- Update `cli.help.ssh-tmux` help text to document `--new-window`.

### 4.2 Socket command (`Sources/TerminalController+RemoteTmux.swift`)

New handler modeled on `v2RemoteTmuxWindow` but delegating to the hardened
current-window mirror:

- Same beta-flag gate + `remoteTmuxHost(from:)` trust-boundary parsing
  (dash-prefix / hidden-char / port-range rejections reused).
- Returns `{host, mirrored, window_id}` or `{host, auth_required, ssh_argv}`.
- Register the method in `TerminalController.swift`'s dispatch switch (~line
  1135), the socket-worker allowlist (~line 2035), and `CmuxControlSocket`'s
  `ControlCommandExecutionPolicy` list.

### 4.3 Controller — harden `mirrorHost` into the user-facing path

`mirrorHost(host:)` today: `AppDelegate.shared?.tabManager` (throws if nil),
discover sessions with `createIfEmpty: false`, `ensureControlMasterReadyForBurst`,
`mirrorSession` each. Gaps to fill so it matches the window path's robustness:

1. **Auth-required** — wrap discovery so a recoverable BatchMode auth failure
   returns `.authRequired(sshArgv:)` (as `mirrorHostInNewWindow` does), instead
   of throwing an opaque error. The CLI's retry loop depends on this.
2. **No current window (D3)** — if `AppDelegate.shared?.tabManager` is nil (no
   main window), `createMainWindow` a plain window and mirror into its
   `TabManager`.
3. **Idempotency / reuse** — if the host already has live mirror workspaces in
   some window, select/reveal the first one and return instead of duplicating.
   (The window path guards this via the window registry; the current-window path
   guards via existing `sessionMirrors` keyed on host connection-hash + session.)
4. **`beginAttach`/`endAttach`** connection-hash guard around the await gap
   (reused verbatim) so a double attach can't double-mirror.
5. **Cancellation** — `Task.checkCancellation()` before mutating UI, so a
   caller that already timed out leaves no orphaned workspaces.
6. **activate/focus** — honor `activate` per §4.1.

## 5. Session-end & reconnect behavior (D4/D5)

**No new code.** The current-window mirror rides the existing hooks:

- **Recoverable transport loss (D4):** the `tmux -CC` connection reconnects; the
  workspace shows the existing reconnecting state; `reconnectRemoteConnection()`
  + the "Reconnect" context-menu item work as for any remote workspace. This
  path never reaches `handleSessionEndedRemotely`.
- **Definitive session end (D5):** `handleSessionEndedRemotely` runs; with no
  dedicated window bound for the host, `sessionEndAction(...)` returns
  `.closeWorkspace` (its existing shared-window branch) and only that workspace
  closes. Never closes the window. When it's the host's last session, the
  ControlMaster teardown already runs.
- One session ending while others remain: existing `hostHasOtherMirrors` path —
  only that workspace closes.

## 6. Persistence

Mirror workspaces are live-connection state, not restorable layout — treated
exactly as the dedicated-window mirror is today (not recreated on restore). No
new persistence surface, since there's no group to persist.

## 7. What was dropped from the earlier draft

- `WorkspaceGroup.remoteHostHash` field — **not needed.**
- Group creation / anchor / dissolve lifecycle — **not needed.**
- Group-scoped new-session interception (group "+") — **not needed** (D6: new
  sessions not offered in v1).
- Registry `(windowId, groupId)` pair — **not needed**; the existing window
  registry stays window-only for the `--new-window` path.

## 8. Testing

Parsimonious; two-commit regression policy for any bug-class fix.

- **Unit (`cmuxTests/`, wired into `project.pbxproj`):**
  - `mirrorHost` hardening: no-window → creates a plain window and mirrors into
    it; auth-required → returns `.authRequired`, no workspaces created; empty
    host → no workspaces; idempotent repeat attach → no duplicate workspaces.
  - Definitive session-end closes only the dead mirror workspace, leaves other
    (local) workspaces and the window intact (extend existing remote-tmux
    session-end tests).
- **CLI arg parsing:** `--new-window` routes to `remote.tmux.window`; default
  routes to the current-window method (extend `RemoteTmux*Tests`).
- **Manual/E2E:** `reload.sh --tag sub-workspace`, then
  `CMUX_TAG=sub-workspace scripts/cmux-debug-cli.sh ssh-tmux <host>` against a
  real tmux host; verify sessions appear as workspaces in the current window;
  kill a session on the host → its workspace closes, window + local workspaces
  survive; drop the network → workspace shows reconnecting and recovers.

## 9. Localization & docs (required)

- New user-facing strings (`--new-window` help, any new error messages) →
  `Resources/Localizable.xcstrings` (EN + JA).
- Docs: update `web/app/[locale]/docs/remote-tmux/page.tsx` to describe the new
  default (mirror into current window) vs `--new-window`, in both
  `web/messages/en.json` and `web/messages/ja.json`.
- No new keyboard shortcut. Run the localization audit before completion.

## 10. Out of scope

- Grouping mirrored sessions (explicitly cut).
- Creating new tmux sessions on the host from cmux (D6 — v1 does not offer this).
- Persisting mirrors across app restarts.
- Changing the dedicated-window behavior itself (only re-routing the CLI default
  away from it).
- iOS mobile shell.

## 11. Files touched (anticipated)

- `Sources/RemoteTmuxController.swift` — harden `mirrorHost` (auth-required,
  no-window, idempotency, beginAttach guard, cancellation, activate).
- `Sources/TerminalController+RemoteTmux.swift` — new current-window socket
  handler.
- `Sources/TerminalController.swift` — dispatch + allowlist registration.
- `Packages/macOS/CmuxControlSocket/.../ControlCommandExecutionPolicy.swift` —
  allowlist.
- `CLI/cmux.swift` — `--new-window` flag, default routing, help text.
- `Resources/Localizable.xcstrings`, `web/.../remote-tmux/page.tsx`,
  `web/messages/{en,ja}.json` — strings + docs.
- `cmuxTests/` — new/updated tests (wired into `project.pbxproj`).

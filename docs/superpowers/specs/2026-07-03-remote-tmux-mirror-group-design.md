# Design: Remote tmux mirror as a sidebar group

**Date:** 2026-07-03
**Status:** Draft (awaiting user review)
**Branch:** `feat/sub-workspace`
**Feature area:** Remote tmux beta (`cmux ssh-tmux`), workspace groups

---

## 1. Problem & goal

Today `cmux ssh-tmux <host>` opens a **dedicated new cmux window** that mirrors
every tmux session on the host (one workspace per session). That window is
special-cased as a whole: new-workspace becomes "new tmux session on the host,"
and closing/teardown is keyed on the window.

The isolated window is heavy: it quarantines remote sessions away from the
user's local workspaces and forces a window switch to reach them.

**Goal:** by default, mirror the host's tmux sessions as a **collapsible group
in the current window's sidebar**, alongside the user's local workspaces —
reusing the existing `WorkspaceGroup` construct. Keep the dedicated-window
behavior available behind a `--new-window` flag.

This is framed as an **enhancement to `WorkspaceGroup`**: the group becomes the
container that the dedicated window provides today, and the group carries the
"mirrors remote host X" binding.

## 2. Decisions (from brainstorming)

| # | Decision | Choice |
|---|----------|--------|
| D1 | Mental model | Scoped section within a window → a **remote-mirror `WorkspaceGroup`** |
| D2 | Replace vs add | **Add as new default**, keep `--new-window` flag for old behavior |
| D3 | No current window | **Create a plain (non-dedicated) window**, put the group inside it |
| D4 | New-workspace in group | **New tmux session, scoped to the group only** (local new-workspace elsewhere stays local) |
| D5 | Group lifecycle | **Dissolve when host disconnects / last session ends** — but NOT the window |
| D6 | Group marker | One new field on `WorkspaceGroup`: `remoteHostHash: String?` |

### Product judgment calls (delegated: "do most logical and best things")

- **J1 — Selection after dissolve:** focus falls to the nearest surviving
  workspace (row above the group's old position, else below, else window's
  first). Never leaves the window unselected. Reuses the neighbor-pick used
  when closing a normal workspace.
- **J2 — Transient disconnect ≠ dissolve:** a recoverable SSH drop keeps the
  group and shows the existing per-session reconnecting state (the mirror
  connection already models `.connected` vs `.reconnecting`). Dissolve happens
  only on a *definitive* host end (last session actually gone / user detach),
  never a recoverable blip.
- **J3 — Naming & identity:** group name defaults to the host destination
  (`user@host` or SSH alias); header icon defaults to a network/server SF
  Symbol instead of `folder.fill`. Both stay user-editable through the normal
  group rename/icon UX — no special-casing of edits.
- **J4 — One mirror per host:** if the host is already mirrored (as a group in
  any window, or a dedicated window), a repeat `ssh-tmux` **reveals/selects the
  existing mirror** rather than forking a second one. Same one-mirror-per-host
  invariant the window registry enforces today.
- **J5 — `--new-window` vs existing group:** if a host already has a mirror,
  the existing mirror wins and is revealed; we never fork a host into two
  simultaneous mirrors regardless of flag.
- **J6 — Only the group's "+" creates remote sessions:** the window-level
  new-workspace shortcut is NOT hijacked. Remote-session creation is explicit
  and discoverable via the group's own affordance; local new-workspace behavior
  is completely intact.

## 3. Architecture

Shift the unit of remote-mirror isolation from **window** to
**`WorkspaceGroup`**.

### 3.1 `WorkspaceGroup` gains a remote binding

Add one optional field to
`Packages/macOS/CmuxWorkspaces/Sources/CmuxWorkspaces/Values/WorkspaceGroup.swift`:

```swift
/// When non-nil, this group mirrors the remote tmux host with this
/// connection hash (RemoteTmuxHost.connectionHash). nil for ordinary local
/// groups. This is the single fact that scopes remote new-session
/// interception and host-end teardown to the group instead of the window.
public var remoteHostHash: String?
```

`nil` ⇒ ordinary local group (unchanged behavior). Non-nil ⇒ remote-mirror
group. The memberwise `init` gains the parameter with a `nil` default so all
existing call sites compile untouched.

### 3.2 Registry keyed by (window, group), not window

Today `RemoteTmuxWindowRegistry` maps `hostHash → windowId`. Generalize the
host's mirror *location* to a `(windowId, groupId?)` pair:

- Dedicated-window mirror: `groupId == nil` (today's shape).
- Group mirror: both set.

Either extend the existing registry to store the pair, or add a parallel
`groupId` map alongside the `windowId` map. The `beginAttach`/`endAttach`
connection-hash guard (prevents a double mirror across the await gap) is reused
verbatim.

### 3.3 Reuse of existing plumbing

`RemoteTmuxController.mirrorSession(host:sessionName:into:)` is **unchanged** —
it still attaches the `tmux -CC` connection and creates one
`isRemoteTmuxMirror` workspace per session. The new code path additionally
assigns each created member's `groupId` to the new group.

`mirrorHostInNewWindow` is **unchanged**; `--new-window` routes to it verbatim.

## 4. Command flow & entry points

### 4.1 CLI (`CLI/cmux.swift`, `runRemoteTmux`)

- Add a `--new-window` flag to the `ssh-tmux` arg parser (currently parses
  `--port`, `--identity`, `--no-focus`, and the destination).
- Default (no `--new-window`) → new socket method **`remote.tmux.group`**.
- `--new-window` → existing method **`remote.tmux.window`** (verbatim).
- The auth-retry loop (BatchMode fails → run returned `ssh_argv` in the user's
  tty → retry once, bounded by `didAuthenticate`) is shared: both methods
  return the same `{auth_required, ssh_argv}` / `{mirrored, …}` shapes. The
  group path returns `{mirrored, window_id, group_id}`.
- Success print for the group path: `OK host=<dest> group=<group_id>`.
- Update `cli.help.ssh-tmux` localized help text to document `--new-window`.

### 4.2 Socket command (`Sources/TerminalController+RemoteTmux.swift`)

New handler `v2RemoteTmuxGroup(id:params:)`, modeled on `v2RemoteTmuxWindow`:

- Same beta-flag gate, same `remoteTmuxHost(from:)` trust-boundary parsing
  (dash-prefix / hidden-char / port-range rejections reused).
- Delegates to `controller.mirrorHostAsGroup(host:activateWindow:)`.
- Returns `{host, mirrored, window_id, group_id}` or `{host, auth_required,
  ssh_argv}`.
- Register `remote.tmux.group` in `TerminalController.swift`'s dispatch switch
  (near line 1135) and in the socket-worker method allowlist (near line 2035),
  and in `CmuxControlSocket`'s `ControlCommandExecutionPolicy` list.

### 4.3 Controller (`Sources/RemoteTmuxController.swift`)

New `mirrorHostAsGroup(host:activateWindow:) async throws ->
RemoteTmuxAttachOutcome`, structured like `mirrorHostInNewWindow` but targeting
a group in an existing window:

1. **Reuse check** — host already mirrored (group *or* window)? Reveal/select
   it, return `.mirrored`. (J4/J5.)
2. **`beginAttach` guard** — bail if a concurrent attach is in flight.
3. **Resolve target window** — focused/current main window's `TabManager`; if
   none, `createMainWindow` as a **plain** window (D3) and use it.
4. **Discover sessions** (BatchMode). Recoverable auth failure →
   `.authRequired(sshArgv:)`, no group created. Empty host → throw, no empty
   group. (Same guards as the window path.)
5. **`Task.checkCancellation()`** then **`ensureControlMasterReadyForBurst`** —
   both before mutating any UI state, so a not-ready/cancelled attach leaves no
   orphaned group.
6. **Create group + members** — create a `WorkspaceGroup` with `remoteHostHash`
   set (name = host destination, network icon; J3); `mirrorSession(...)` each
   session into the window's `TabManager`; set each member's `groupId`. Anchor =
   first mirrored session's workspace. Normalize group contiguity via the
   existing `normalizeWorkspaceGroupContiguity`.
7. **Bind** `hostHash → (windowId, groupId)` in the registry.
8. **Failure cleanup** — no session mirrored → dissolve the group, unbind,
   `spawnControlMasterExit`. Never discard the window (it may hold local
   workspaces). Contrast with the window path, which discards the window it
   created.

## 5. Scoped behaviors

### 5.1 New workspace → new tmux session (group-scoped) — D4/J6

- Today: `handleRemoteWindowNewWorkspaceRequested(windowId:)` intercepts *any*
  new-workspace in the dedicated window.
- New: the **sole trigger is the group's own "+" affordance** on a group with
  `remoteHostHash != nil` (the window-level new-workspace shortcut is NOT
  intercepted — J6). When that "+" fires, resolve the host from
  `remoteHostHash`, create the tmux session on the host,
  and let the live `%window-add` / `%sessions-changed` feed materialize the
  member (one source of truth — never create a local orphan). A plain
  new-workspace with no remote-group context falls through to normal local
  creation, untouched.

### 5.2 Group lifecycle — dissolve on host end, keep the window — D5/J1/J2

- Today: `resolveSessionEndAction(...)` may close the dedicated window when the
  host's sessions end.
- New: the equivalent operates on the **group**. Definitive host end (last
  mirrored session gone / user detach) → close the group's member workspaces
  and dissolve the group via the existing group-removal machinery; unbind the
  registry. **Do not close the window.** This is the core inversion from
  today's window-close behavior.
- Per-session: one session ending (others remain) closes only that member
  (existing per-session teardown); the group persists until the last one ends.
- Recoverable disconnect (J2): no dissolve; members show reconnecting state.
- Selection after dissolve (J1): nearest surviving neighbor.
- The existing anchor rule still holds as a floor: closing the anchor member
  dissolves the group. Since the anchor is a mirrored session, its remote end
  reaches dissolve through the lifecycle path anyway.

## 6. Persistence

Remote-mirror groups are **live-connection state**, not restorable layout: a
mirror only exists while its `tmux -CC` connections are live. On session
restore, a group with `remoteHostHash != nil` must NOT be recreated as an empty
local group. Restoration skips remote-mirror groups (and their mirror member
workspaces) exactly as the dedicated-window mirror is not persisted today.
`remoteHostHash` round-trips through the group's in-memory model but is treated
as non-restorable at the persistence boundary.

## 7. Testing

Following the repo's parsimonious posture and two-commit regression policy for
any bug-class fix:

- **Unit (`cmuxTests/`, wired into `project.pbxproj`):**
  - Group-mirror creation binds `remoteHostHash`, assigns members' `groupId`,
    sets the anchor to the first session. (Mirror `mirrorSession` with a fake
    `TabManager`/transport as existing remote-tmux tests do.)
  - Host-end dissolve closes members + removes the group but leaves other
    (local) workspaces and the window intact (J1/D5).
  - New-workspace interception fires only for a `remoteHostHash != nil` group,
    not for a local group or plain new-workspace (D4/J6).
  - One-mirror-per-host: repeat attach reveals the existing group, creates no
    second group (J4).
- **Behavior-level** coverage for the exact "mirror into current window as a
  group" repro path (shared-behavior policy).
- **CLI arg parsing:** `--new-window` routes to `remote.tmux.window`; default
  routes to `remote.tmux.group` (extend `RemoteTmux*Tests`).
- **Manual/E2E:** `reload.sh --tag sub-workspace`, then dogfood via
  `CMUX_TAG=sub-workspace scripts/cmux-debug-cli.sh ssh-tmux <host>` against a
  real tmux host; verify the group appears in the current window, new-session
  via the group "+", and host-end dissolve keeps local workspaces.

## 8. Localization & docs (required)

- **New user-facing strings** (group default name pattern if any, network icon
  tooltip, `--new-window` help, any error messages) → `Resources/Localizable.xcstrings`
  with EN + JA.
- **Docs:** update `web/app/[locale]/docs/remote-tmux/page.tsx` to describe the
  new default (group in current window) vs `--new-window`, in both
  `web/messages/en.json` and `web/messages/ja.json`.
- **Shortcut policy:** no new keyboard shortcut is introduced (the group "+"
  reuses existing group affordances). If one is added during implementation, it
  must be registered per the shortcut policy.
- Run the localization audit before completion.

## 9. Out of scope

- Nested groups / groups-in-groups.
- Persisting remote mirrors across app restarts.
- Changing the dedicated-window behavior itself (only re-routing the CLI
  default away from it).
- iOS mobile shell (this is a macOS remote-tmux flow).

## 10. Files touched (anticipated)

- `Packages/macOS/CmuxWorkspaces/.../Values/WorkspaceGroup.swift` — add `remoteHostHash`.
- `Sources/RemoteTmuxController.swift` — `mirrorHostAsGroup`, group-scoped
  new-session, group-scoped dissolve.
- `Sources/RemoteTmuxWindowRegistry.swift` — store `(windowId, groupId?)`.
- `Sources/TerminalController+RemoteTmux.swift` — `v2RemoteTmuxGroup`.
- `Sources/TerminalController.swift` — dispatch + allowlist registration.
- `Packages/macOS/CmuxControlSocket/.../ControlCommandExecutionPolicy.swift` — allowlist.
- `CLI/cmux.swift` — `--new-window` flag, default routing, help text.
- Session-restore path — skip remote-mirror groups.
- `Resources/Localizable.xcstrings`, `web/.../remote-tmux/page.tsx`,
  `web/messages/{en,ja}.json` — strings + docs.
- `cmuxTests/` — new/updated tests (wired into `project.pbxproj`).

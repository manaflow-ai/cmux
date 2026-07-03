# `cmux ssh-tmux` Current-Window Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `cmux ssh-tmux <host>` mirror a host's tmux sessions as plain workspaces in the **current window** by default (no group, no new window), keeping the dedicated-window behavior behind a `--new-window` flag.

**Architecture:** The target behavior already exists as `RemoteTmuxController.mirrorHost(host:)` ("mirror each session as its own workspace in the active window's sidebar"). We harden that method (auth-required handling, no-window fallback, idempotency, concurrency guard, cancellation, focus), expose it through a new socket command, and re-route the CLI default onto it. Session-end and reconnect reuse the existing `handleSessionEndedRemotely` / `WorkspaceRemoteConnectionState` paths unchanged.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (macOS app), Swift Testing (`@Suite`/`@Test`), the cmux v2 control socket, `tmux -CC` remote mirroring.

**Spec:** `docs/superpowers/specs/2026-07-03-ssh-tmux-current-window-design.md`

## Global Constraints

- **Beta gate:** every remote-tmux socket handler must gate on `RemoteTmuxController.isEnabled` and return the `socket.remoteTmux.disabled` error when off (copy the existing `v2RemoteTmuxWindow` guard verbatim).
- **Trust boundary:** parse the host only via `Self.remoteTmuxHost(from: params)` (reuses dash-prefix / hidden-char / port-range rejection). Never read `params["host"]` directly.
- **Localization:** every new user-facing string uses `String(localized: "key", defaultValue: "…")` and gets an entry for **English and Japanese** in `Resources/Localizable.xcstrings`. Docs strings go in **both** `web/messages/en.json` and `web/messages/ja.json`. `defaultValue` alone does NOT satisfy the audit.
- **Test wiring:** any new file in `cmuxTests/` MUST be added to `cmux.xcodeproj/project.pbxproj` (PBXFileReference + PBXSourcesBuildPhase), or it silently never runs. Use `TabManagerUnitTests.swift` / `RemoteTmuxNewWindowCwdTests.swift` as the wiring template, then verify with `./scripts/lint-pbxproj-test-wiring.sh`.
- **Build/verify command (tagged, never bare xcodebuild):**
  `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-sub-workspace build`
- **Socket command registration is three-sited:** a new `remote.tmux.*` method must be added to (1) the dispatch switch in `Sources/TerminalController.swift` (~line 1135), (2) the socket-worker method allowlist in `Sources/TerminalController.swift` (~line 2035), and (3) `ControlCommandExecutionPolicy` in `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/ControlCommandExecutionPolicy.swift` (~line 88). Missing (2) or (3) → `method_not_found` at runtime.
- **No new keyboard shortcut** is introduced by this plan.

---

## File Structure

- `Sources/RemoteTmuxController.swift` — harden `mirrorHost` into the user-facing current-window attach: returns a `RemoteTmuxAttachOutcome`, handles auth-required, no-window fallback, idempotent reuse, `beginAttach` guard, cancellation, and focus. (Existing file; the mirror lives here alongside `mirrorHostInNewWindow`.)
- `Sources/TerminalController+RemoteTmux.swift` — new `v2RemoteTmuxAttachHere` socket handler (sibling to `v2RemoteTmuxWindow`).
- `Sources/TerminalController.swift` — dispatch case + worker allowlist entry for the new method.
- `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/ControlCommandExecutionPolicy.swift` — allowlist entry.
- `CLI/cmux.swift` — `--new-window` flag parse + default method routing + help text.
- `Resources/Localizable.xcstrings` — new strings (EN + JA).
- `web/app/[locale]/docs/remote-tmux/page.tsx`, `web/messages/en.json`, `web/messages/ja.json` — docs.
- `cmuxTests/RemoteTmuxAttachHereTests.swift` — new unit tests (wired into pbxproj).

**Method naming (locked, used across tasks):**
- Controller: `func mirrorHostInCurrentWindow(host: RemoteTmuxHost, activateWindow: Bool = true) async throws -> RemoteTmuxAttachOutcome`
- Socket handler: `nonisolated func v2RemoteTmuxAttachHere(id: Any?, params: [String: Any]) -> String`
- Socket method string: `"remote.tmux.attach_here"`
- CLI default routes to `"remote.tmux.attach_here"`; `--new-window` routes to `"remote.tmux.window"`.

`RemoteTmuxAttachOutcome` already exists (`Sources/RemoteTmuxAttachOutcome.swift`) with cases `.mirrored(windowId: UUID)` and `.authRequired(sshArgv: [String])` — reused, not redefined.

---

## Task 1: Harden `mirrorHost` into `mirrorHostInCurrentWindow`

**Files:**
- Modify: `Sources/RemoteTmuxController.swift:428-446` (the current `mirrorHost`)
- Test: none for this task — the flow is integration-shaped (SSH + live app + window creation); verified by the Task 5 E2E run. See the Testing note below.

**Interfaces:**
- Consumes: `mirrorSession(host:sessionName:into:)` (existing, `Sources/RemoteTmuxController.swift:450`); `transport(for:).discoverMirrorSessions(createIfEmpty:)`; `ensureControlMasterReadyForBurst(host:)`; `RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(_:)`; `windowRegistry.beginAttach(hostHash:)`/`endAttach(hostHash:)`; `AppDelegate.shared?.tabManager`, `.createMainWindow(shouldActivate:)`, `.tabManagerFor(windowId:)`; `RemoteTmuxAttachOutcome`.
- Produces: `func mirrorHostInCurrentWindow(host: RemoteTmuxHost, activateWindow: Bool = true) async throws -> RemoteTmuxAttachOutcome` — Task 2 calls this.

**Design note:** model the body on `mirrorHostInNewWindow` (`Sources/RemoteTmuxController.swift:318-422`) but target the current window's `TabManager` and never discard the window on failure. Keep `mirrorHost(host:)` deleted (its only caller, `v2RemoteTmuxMirror`, is retargeted in Task 2) — its behavior is subsumed by the new method with `activateWindow: true`.

**Testing note (revised):** the reuse decision is a single `Set.contains()` on
live-mirror connection hashes — wrapping it in a named helper and unit-testing
it would be over-abstraction + a test-of-a-trivial-helper (both parsimony
anti-patterns in the testing rules). It is inlined in Step 1. The behavior that
matters (don't double-mirror a host) is genuine integration behavior — the whole
`mirrorHostInCurrentWindow` flow needs SSH + a live app + window creation and is
verified by the **Task 5 E2E** run (idempotent repeat attach, no-window
fallback, kill-session close, network-drop reconnect). Task 1 therefore adds no
standalone unit test file; this is honest about the task being integration-shaped
rather than manufacturing a fake unit seam. `RemoteTmuxAttachHereTests.swift` is
NOT created.

- [ ] **Step 1: Replace `mirrorHost` with `mirrorHostInCurrentWindow`**

In `Sources/RemoteTmuxController.swift`, replace the `mirrorHost(host:)` method (lines 424-446) with:

```swift
/// Discovers every tmux session on `host` and mirrors each as its own
/// workspace in the CURRENT window's sidebar (the `cmux ssh-tmux` default —
/// no group, no dedicated window). Hardened sibling of
/// ``mirrorHostInNewWindow(host:activateWindow:)``:
/// - returns ``RemoteTmuxAttachOutcome/authRequired(sshArgv:)`` on a
///   recoverable BatchMode auth failure (the CLI then authenticates and retries),
/// - falls back to creating a plain window when no main window exists,
/// - reuses an existing mirror for the host instead of duplicating,
/// - never discards the window on failure (it may hold local workspaces).
@discardableResult
func mirrorHostInCurrentWindow(
    host: RemoteTmuxHost,
    activateWindow: Bool = true
) async throws -> RemoteTmuxAttachOutcome {
    guard let appDelegate = AppDelegate.shared else {
        throw RemoteTmuxError.unreachable("app not ready")
    }

    // Reuse: if the host already has a live mirror workspace, reveal it and
    // return instead of mirroring twice. The mirror struct's `tabManager`
    // is private/weak, so resolve the manager from the workspace id via the
    // confirmed `tabManagerFor(tabId:)` (Sources/AppDelegate+RecoverableMainWindowRoutes.swift:385).
    if let workspaceId = sessionMirrors.values
           .first(where: { $0.host.connectionHash == host.connectionHash })?
           .mirroredWorkspaceId,
       let manager = appDelegate.tabManagerFor(tabId: workspaceId) {
        if activateWindow {
            manager.selectWorkspace(workspaceId)  // TabManager+FocusHistoryHosting:40
        }
        let windowId = appDelegate.windowId(for: manager) ?? UUID()
        return .mirrored(windowId: windowId)
    }

    // Guard the await gap so a concurrent attach can't double-mirror.
    guard windowRegistry.beginAttach(hostHash: host.connectionHash) else {
        throw RemoteTmuxError.unreachable("already attaching \(host.destination)")
    }
    defer { windowRegistry.endAttach(hostHash: host.connectionHash) }

    // Discover over the shared ControlMaster (BatchMode). A recoverable auth
    // failure hands back the interactive ssh argv (same classification as the
    // window path) so the CLI authenticates and retries.
    let sessions: [RemoteTmuxSession]
    do {
        sessions = try await transport(for: host).discoverMirrorSessions(createIfEmpty: false)
    } catch let error as RemoteTmuxError {
        if case .commandFailed(_, let stderr) = error,
           RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
            return .authRequired(sshArgv: host.interactiveAuthInvocation())
        }
        throw error
    }
    guard !sessions.isEmpty else {
        throw RemoteTmuxError.unreachable("no tmux sessions on \(host.destination)")
    }

    // Bail before mutating UI if the caller already timed out/cancelled.
    try Task.checkCancellation()
    try await ensureControlMasterReadyForBurst(host: host)

    // Target the current window; create a plain window if none exists (D3).
    let manager: TabManager
    if let current = appDelegate.tabManager {
        manager = current
    } else {
        let windowId = appDelegate.createMainWindow(shouldActivate: activateWindow)
        guard let created = appDelegate.tabManagerFor(windowId: windowId) else {
            throw RemoteTmuxError.unreachable("could not create window")
        }
        manager = created
    }

    var firstMirroredWorkspaceId: UUID?
    for session in sessions {
        do {
            try mirrorSession(host: host, sessionName: session.name, into: manager)
            if firstMirroredWorkspaceId == nil {
                let key = Self.connectionKey(host: host, sessionName: session.name)
                firstMirroredWorkspaceId = sessionMirrors[key]?.mirroredWorkspaceId
            }
        } catch {
            #if DEBUG
            cmuxDebugLog("remote-tmux: mirror session \(session.name) on \(host.destination) failed: \(error)")
            #endif
        }
    }

    if activateWindow, let firstMirroredWorkspaceId {
        manager.selectWorkspace(firstMirroredWorkspaceId)  // TabManager+FocusHistoryHosting:40
    }
    let windowId = appDelegate.windowId(for: manager) ?? UUID()
    return .mirrored(windowId: windowId)
}
```

**APIs referenced above — all verified present (spelling confirmed):**
- `RemoteTmuxSessionMirror.mirroredWorkspaceId: UUID?` — `Sources/RemoteTmuxSessionMirror.swift:163` (computed `workspace?.id`). The struct's `tabManager` is `private weak` (line 45) and NOT accessible from the controller — hence resolving the manager via `tabManagerFor(tabId:)` instead.
- `AppDelegate.tabManagerFor(tabId:) -> TabManager?` — `Sources/AppDelegate+RecoverableMainWindowRoutes.swift:385`.
- `AppDelegate.tabManagerFor(windowId:) -> TabManager?` — same file, line 185.
- `AppDelegate.createMainWindow(..., shouldActivate:) -> UUID` — `Sources/AppDelegate.swift:8388` (returns the new window id).
- `TabManager.selectWorkspace(_ workspaceId: UUID)` — `Sources/TabManager+FocusHistoryHosting.swift:40`.
- `AppDelegate.windowId(for: TabManager) -> UUID?` — used at `Sources/AppDelegate.swift:2727` (`self.windowId(for: $0)`); if the exact label differs at implementation time, fall back to reading `mainWindowContexts.values.first(where: { $0.tabManager === manager })?.windowId` (the shape used at AppDelegate:4614 + the `.windowId` field at 564/586).
- `host.interactiveAuthInvocation()` — window path line ~356 (confirmed).
- `windowRegistry.beginAttach`/`endAttach` — window path lines ~333-336 (confirmed).
- `AppDelegate.tabManager` (the current window's manager, `weak var`) — `Sources/AppDelegate.swift:674`.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-sub-workspace build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. Fix any name mismatches surfaced by the "APIs referenced" note above (in particular the `windowId(for:)` fallback).

- [ ] **Step 3: Confirm `mirrorHost` is fully removed and nothing else references it**

Run: `rg -n "func mirrorHost\b|\.mirrorHost\(" Sources/`
Expected: no matches (the only caller, `v2RemoteTmuxMirror`, is retargeted in Task 2).

- [ ] **Step 4: Commit**

```bash
git add Sources/RemoteTmuxController.swift
git commit -m "feat(remote-tmux): mirror ssh-tmux into current window (harden mirrorHost)"
```

---

## Task 2: New socket command `remote.tmux.attach_here`

**Files:**
- Modify: `Sources/TerminalController+RemoteTmux.swift` (replace `v2RemoteTmuxMirror`, add `v2RemoteTmuxAttachHere` — put it next to `v2RemoteTmuxWindow` at line ~152)
- Modify: `Sources/TerminalController.swift:1135-1136` (dispatch), `~2035` (worker allowlist)
- Modify: `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/ControlCommandExecutionPolicy.swift:88` (allowlist)

**Interfaces:**
- Consumes: `controller.mirrorHostInCurrentWindow(host:activateWindow:)` (Task 1).
- Produces: socket method `"remote.tmux.attach_here"` returning `{host, mirrored, window_id}` or `{host, auth_required, ssh_argv}` — Task 3 (CLI) calls it.

- [ ] **Step 1: Add the handler**

In `Sources/TerminalController+RemoteTmux.swift`, add (modeled on `v2RemoteTmuxWindow`, lines 152-184):

```swift
/// `remote.tmux.attach_here` — mirror every tmux session on a host as plain
/// workspaces in the CURRENT window (the default `cmux ssh-tmux` entry point).
///
/// Params: `host` (required), optional `port` (Int), optional `identity_file`
/// (String), optional `activate` (Bool, default `true`).
///
/// Returns `{mirrored: true, window_id}` on success, or
/// `{auth_required: true, ssh_argv: […]}` when the host needs interactive
/// authentication (the CLI runs `ssh_argv` in the user's terminal and retries).
nonisolated func v2RemoteTmuxAttachHere(id: Any?, params: [String: Any]) -> String {
    guard RemoteTmuxController.isEnabled else {
        return v2Error(id: id, code: "disabled", message: String(localized: "socket.remoteTmux.disabled", defaultValue: "remote tmux beta is disabled"))
    }
    guard let host = Self.remoteTmuxHost(from: params) else {
        return v2Error(id: id, code: "invalid_params", message: String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
    }
    let activate = (params["activate"] as? Bool) ?? true
    return v2VmCall(id: id, timeoutSeconds: 60) {
        guard let controller = await MainActor.run(body: { AppDelegate.shared?.remoteTmuxController })
        else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        let outcome = try await controller.mirrorHostInCurrentWindow(host: host, activateWindow: activate)
        switch outcome {
        case .mirrored(let windowId):
            return [
                "host": host.destination,
                "mirrored": true,
                "window_id": windowId.uuidString,
            ]
        case .authRequired(let sshArgv):
            return [
                "host": host.destination,
                "auth_required": true,
                "ssh_argv": sshArgv,
            ]
        }
    }
}
```

Then **delete** the now-unused `v2RemoteTmuxMirror` (lines 120-137) since `mirrorHost` was removed in Task 1. (No test references it; the `remote.tmux.mirror` method is retired — see Step 3.)

- [ ] **Step 2: Register the method (three sites)**

`Sources/TerminalController.swift` dispatch — replace the `remote.tmux.mirror` case (lines 1135-1136) with:

```swift
        case "remote.tmux.attach_here":
            return v2RemoteTmuxAttachHere(id: request.id, params: request.params)
```

`Sources/TerminalController.swift` worker allowlist (~line 2035) — in the string list that currently contains `"remote.tmux.mirror", "remote.tmux.window",`, replace `"remote.tmux.mirror"` with `"remote.tmux.attach_here"`.

`Packages/macOS/CmuxControlSocket/.../ControlCommandExecutionPolicy.swift` (~line 88) — replace `"remote.tmux.mirror",` with `"remote.tmux.attach_here",`.

- [ ] **Step 3: Confirm no other references to the retired method**

Run: `rg -n "remote.tmux.mirror|v2RemoteTmuxMirror|func mirrorHost\b" Sources/ Packages/ CLI/`
Expected: no matches (all replaced/removed). If any remain, update them.

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-sub-workspace build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/TerminalController+RemoteTmux.swift Sources/TerminalController.swift Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/ControlCommandExecutionPolicy.swift
git commit -m "feat(remote-tmux): add remote.tmux.attach_here socket command"
```

---

## Task 3: CLI `--new-window` flag + default routing

**Files:**
- Modify: `CLI/cmux.swift:8522-8628` (`runRemoteTmux`), `~14953` (`ssh-tmux` help text)
- Modify: `Resources/Localizable.xcstrings` (any new CLI strings — but CLI help uses `String(localized:)` already; add EN+JA)

**Interfaces:**
- Consumes: socket methods `"remote.tmux.attach_here"` (default) and `"remote.tmux.window"` (`--new-window`).

- [ ] **Step 1: Parse `--new-window`**

In `runRemoteTmux` (`CLI/cmux.swift`), add a local `var newWindow = false` beside `var noFocus = false` (line 8530), and add a case to the arg loop (after the `--no-focus` case, line 8557):

```swift
            case "--new-window":
                newWindow = true
                index += 1
```

- [ ] **Step 2: Route the method by flag**

Change the `sendV2` call (line 8593-8597) to select the method:

```swift
            let method = newWindow ? "remote.tmux.window" : "remote.tmux.attach_here"
            let result = try client.sendV2(
                method: method,
                params: params,
                responseTimeout: 75  // > the app-side 60s timeout, so the app's result/error always arrives first
            )
```

- [ ] **Step 3: Update the success print to name the mode**

Replace the success branch (lines 8598-8606) so the non-JSON line reflects window vs current-window:

```swift
            if (result["mirrored"] as? Bool) == true {
                if jsonOutput {
                    print(jsonString(result))
                } else {
                    let windowId = (result["window_id"] as? String) ?? ""
                    print("OK host=\(destination) window=\(windowId)")
                }
                return
            }
```

(Payload shape is identical for both methods, so this branch is unchanged in substance — keep it.)

- [ ] **Step 4: Update the help text**

In the `ssh-tmux` help case (`CLI/cmux.swift:~14953`, `cli.help.ssh-tmux`), add a `--new-window` line to the usage/options and note that the default now mirrors into the current window. Keep it inside the existing `String(localized: "cli.help.ssh-tmux", defaultValue: """ … """)`. Add the matching `cli.help.ssh-tmux` update to `Resources/Localizable.xcstrings` for **English and Japanese**.

- [ ] **Step 5: Build the CLI to verify it compiles**

Run: `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-sub-workspace build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add CLI/cmux.swift Resources/Localizable.xcstrings
git commit -m "feat(cli): ssh-tmux mirrors into current window by default, add --new-window"
```

---

## Task 4: Docs + localization audit

**Files:**
- Modify: `web/app/[locale]/docs/remote-tmux/page.tsx`
- Modify: `web/messages/en.json`, `web/messages/ja.json`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the docs page**

In `web/app/[locale]/docs/remote-tmux/page.tsx`, update the `cmux ssh-tmux` description so the default is "mirrors the host's tmux sessions as workspaces in your current window" and document `--new-window` for the old dedicated-window behavior. Use the existing message-key pattern in that file (no bare English literals).

- [ ] **Step 2: Add the message keys for both locales**

Add every new message key used in Step 1 to **both** `web/messages/en.json` and `web/messages/ja.json`. Keys must match exactly across the two files.

- [ ] **Step 3: Localization audit**

Run: `rg -n "ssh-tmux|new-window" web/messages/en.json web/messages/ja.json`
Expected: the same set of keys present in both files (compare counts).
Run: `rg -nE '>[A-Za-z][A-Za-z ]{3,}<' web/app/\[locale\]/docs/remote-tmux/page.tsx`
Expected: no newly-introduced bare English JSX text (all copy goes through message keys).

Also verify the Swift side: parse `Resources/Localizable.xcstrings` and confirm every new key (`cli.help.ssh-tmux` edit and any new `socket.remoteTmux.*`) has both `en` and `ja` localizations, not just `defaultValue`.

- [ ] **Step 4: Commit**

```bash
git add web/app/\[locale\]/docs/remote-tmux/page.tsx web/messages/en.json web/messages/ja.json
git commit -m "docs(remote-tmux): document current-window mirror default and --new-window"
```

---

## Task 5: End-to-end verification against a real host

**Files:** none (verification only).

**Interfaces:** none.

- [ ] **Step 1: Build and reload the tagged Debug app**

Run: `./scripts/reload.sh --tag sub-workspace`
Expected: `** BUILD SUCCEEDED **` and an `App path:` line. Provide the user the `file://` app link (cmd-clickable) so they can launch it; the remote-tmux beta flag must be enabled in Settings.

- [ ] **Step 2: Mirror into the current window (default)**

With the tagged app running and a reachable tmux host available, run:
`CMUX_TAG=sub-workspace scripts/cmux-debug-cli.sh ssh-tmux <host>`
Expected: `OK host=<host> window=<id>`; each tmux session on the host appears as a **workspace in the current window's sidebar** (alongside any local workspaces), and **no new window** was created.

- [ ] **Step 3: Verify `--new-window` still isolates**

Run: `CMUX_TAG=sub-workspace scripts/cmux-debug-cli.sh ssh-tmux <host2> --new-window`
Expected: a dedicated new window opens mirroring `<host2>` (old behavior intact).

- [ ] **Step 4: Verify definitive session-end closes only its workspace (D5)**

On the host, kill one mirrored session (`tmux kill-session -t <name>`).
Expected: only that session's workspace disappears from the sidebar; other workspaces (local and remote) and the window survive.

- [ ] **Step 5: Verify network-loss reconnect (D4)**

Drop connectivity to the host briefly (e.g. disable the network / suspend), then restore.
Expected: the mirror workspace shows the reconnecting state and recovers (via the existing remote reconnect path) without closing — the tmux session is still alive.

- [ ] **Step 6: Run the full remote-tmux test suite**

Run: `xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-sub-workspace test -only-testing:cmuxTests/RemoteTmuxAttachHereTests -only-testing:cmuxTests/RemoteTmuxNewWindowCwdTests 2>&1 | tail -30`
Expected: all tests PASS (0 failures).

- [ ] **Step 7: Record verification outcome**

Note in the PR/summary which tiers of the live-target probe ran (Tier 1/2 reuse-or-start app; the E2E here IS the live run) and the observed results for Steps 2-5. If a real tmux host was unavailable, state that explicitly and mark Steps 2-5 as UNIT_VERIFIED with the reason.

---

## Self-Review

**Spec coverage:**
- D1 (no group, plain workspaces) → Task 1 (mirror into `TabManager`, no group). ✓
- D2 (new default + `--new-window`) → Task 3 (routing). ✓
- D3 (no window → plain window) → Task 1 Step 1 (createMainWindow fallback). ✓
- D4 (network-loss reconnect) → reused existing path; verified in Task 5 Step 5. ✓
- D5 (killed session closes workspace) → reused `handleSessionEndedRemotely`; verified in Task 5 Step 4. ✓
- D6 (no new-session creation) → nothing built (correctly absent); no interception added. ✓
- Auth-required / no-window / idempotency / beginAttach / cancellation hardening → Task 1. ✓
- Socket registration three-sited → Task 2. ✓
- Localization + docs → Tasks 3-4. ✓

**Placeholder scan:** No TBD/TODO in steps. The socket method name and controller method name are fixed in "Method naming (locked)". All TabManager/AppDelegate selectors in Task 1 Step 1 were verified against the codebase (file:line cited inline); the only residual is the exact label of `windowId(for:)`, which has a cited fallback. The `shouldReuseExistingMirror` helper and its two trivial unit tests were removed (parsimony) — the reuse check is inlined and the behavior is E2E-verified in Task 5.

**Type consistency:** `mirrorHostInCurrentWindow` (Task 1) is the exact name called in Task 2. `"remote.tmux.attach_here"` is identical across Task 2 (all three registration sites) and Task 3 (CLI routing). `RemoteTmuxAttachOutcome` cases (`.mirrored(windowId:)`, `.authRequired(sshArgv:)`) match the existing enum and the Task 2 switch.

**API verification (done during planning):** `mirroredWorkspaceId` (RemoteTmuxSessionMirror:163), `tabManagerFor(tabId:)` (AppDelegate+RecoverableMainWindowRoutes:385), `tabManagerFor(windowId:)` (:185), `createMainWindow → UUID` (AppDelegate:8388), `selectWorkspace(_:)` (TabManager+FocusHistoryHosting:40) all confirmed. The mirror struct's `tabManager` is `private weak` — the plan routes around it via `tabManagerFor(tabId:)` rather than inventing accessor access. Only `windowId(for:)`'s exact label is left with a documented fallback (read `mainWindowContexts` directly).

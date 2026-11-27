# cmux next: agent permission requests and computer use onboarding

Design note, 2026-10-20. Module: `CmuxNextAgentPermissions` (model, card, onboarding flow, mock TCC).
App wiring: `Sources/CmuxNextApp/Permissions/`. Gallery: `plans/cmux-next/agent-permissions-gallery.html`.

User goal (2026-10-20, paraphrased): a general permissions UI that an agent can drive (CLI, MCP,
socket). The agent never fires the macOS prompt first. cmux shows its own card: which agent asks,
why (in the agent's words), and what the user asked for. When the reason does not fit the request,
the card says so. Only after the user presses Continue does cmux open the right System Settings list
and float a drag-the-app helper over it, and it sees the grant land live. Computer use is one of the
kinds. Computer use gets an onboarding flow from first principles.

## 1. What exists (inventory, feat-cmux-next 0c78ed8b298)

| Piece | Where | Reuse |
| --- | --- | --- |
| Computer use grants (Accessibility, Screen Recording), read from the helper `permissions_status`, no polling, recheck on app activation and the AX trust distributed notification | `CmuxNextApp/ComputerUse/ComputerUseSetup.swift` | The probe for `accessibility`, `screen_recording` and `computer_use` reads this model. |
| Onboarding computer use step: Allow opens the list and floats a tile | `CmuxNextOnboarding/Model/ComputerUseStepModel.swift`, `Steps/ComputerUseStepView.swift` | The new flow replaces the step's order and text; the source protocol stays. |
| Drag-the-app panel over System Settings (non-activating, never key, bottom center) | `CmuxNextOnboarding/Steps/HelperDragPanel.swift`, `HelperAppTile.swift` | Same pattern, rebuilt in the new module so other kinds can use it (the onboarding types are internal). |
| System Settings deep links | `ComputerUseSetup.settingsURL` (Privacy_Accessibility, Privacy_ScreenCapture) | Extended to every kind in `PermissionKind.settingsAnchor`. |
| Full Disk Access probe + "open the list" for browser import | `CmuxNextCookieImport/CookieImportService.swift`, `CmuxNextOnboarding/Steps/ImportAccessView.swift` | Same probe idea (read a TCC-protected file; no prompt). |
| Camera / microphone | `CmuxNextDictation/SystemDictationAuthorizer.swift`, `CmuxNextAgentPane/AgentPaneDictation.swift` | `AVCaptureDevice.authorizationStatus` read only. |
| Remote view upstream grants | `CmuxNextRemoteView/Upstream/RemoteUpstreamPermissions.swift` | Not touched. |
| App permissions (first-party app scopes, not TCC) | `CmuxNextAppPermissions` | Different domain (cmux app scopes). Kept separate; the name says "agent". |
| Agent question card (glass, keys, pills) | `CmuxNextAgentQuestion` | Style source: `Glass.makeOverlayPanel`, `Palette`, Enter/Esc hint line. |
| Add Server pairing card (glassy top-center, Approve/Deny, Enter/Esc) | a202, not on feat-cmux-next yet | Same placement and keys; the panel class is ours until a202 lands, then both move to one shared top-center panel. |
| Browser use and computer use cursor (a143, a200, a201) | `CmuxNextAgentCursor`, `plans/cmux-next/browser-use-cursor/` | The onboarding "try it" step shows the gray glass cursor. |

Gaps found: no agent-facing request path for any grant; every grant UI is a fixed place
(onboarding, Settings) that the person must find; no record of who asked and why; no Deny result.

## 2. One request API

Three entry points, one path (`AgentPermissionRequests.request`):

- Socket: `permissions.request {kind, reason, prompt?, prompt_id?, agent?, caller?, target?, timeout_seconds?}`
  and `permissions.status {kind?}`. Deadline `.fixed(timeout + 5 s)`, timeout default 300 s, max 600 s.
- CLI: `cmux permissions request <kind> --reason "..." [--prompt "..."] [--timeout 300] [--json]`,
  `cmux permissions status [<kind>]`. Rust cmux-tui verb that calls the socket method (left, section 8).
- MCP: tool `permissions_request` with the same arguments, generated next to the CLI verb.

Kinds (`PermissionKind`):

| kind | macOS service | holder | Settings anchor | drag helper |
| --- | --- | --- | --- | --- |
| `full_disk_access` | SystemPolicyAllFiles | cmux | `Privacy_AllFiles` | yes |
| `accessibility` | Accessibility | cmux Computer Use helper | `Privacy_Accessibility` | yes |
| `screen_recording` | ScreenCapture | helper | `Privacy_ScreenCapture` | yes |
| `automation` (`--target <bundle id>`) | AppleEvents | cmux | `Privacy_Automation` | no (macOS asks once, per target) |
| `camera` | Camera | cmux | `Privacy_Camera` | no (macOS prompt after Continue) |
| `microphone` | Microphone | cmux | `Privacy_Microphone` | no (macOS prompt after Continue) |
| `computer_use` | Accessibility + Screen Recording | helper | both, one at a time | yes |

Result (JSON, same for every entry point):

```
{"kind": "full_disk_access", "outcome": "granted" | "already_granted" | "denied" | "timed_out" | "cancelled" | "unavailable",
 "request_id": "perm_…", "reason_check": "matches" | "unclear" | "no_prompt" | "no_reason"}
```

Errors the agent sees (exit code 3 on the CLI): `permission_denied` ("The person denied Full Disk
Access. Do not ask again in this turn; tell them what you could not do."), `permission_timed_out`,
`permission_unavailable` (for example, no signed helper in this build), `invalid_params`
(unknown kind, empty reason).

Rules:

1. Already granted: no card, answer at once with `already_granted`.
2. One card at a time. The same kind from the same agent while a card is up joins that request
   (one answer to both). Others queue in arrival order. A badge says "2 more".
3. The card never takes focus from the user's typing (non-activating panel, never key until the
   person clicks it). Enter and Esc work once the person clicks into the card.
4. The macOS prompt or System Settings opens only after Continue.
5. Deny is final for that request; the agent gets `permission_denied`. cmux remembers nothing.
   No "always allow" for grants: macOS already keeps the grant.
6. The request times out after `timeout_seconds` with `permission_timed_out`; the card goes.

## 3. The card (recommended variant: "Context card")

Top center of the active window's screen, Liquid Glass overlay (`Glass.makeOverlayPanel`), 420 pt
wide. From top:

1. Agent line: brand mark, agent name, workspace name ("Claude Code in a214 · PlanetScale").
2. Title: "Allow Full Disk Access?" One line on what that grant lets cmux do, in plain words.
3. "Why": the agent's reason, quoted, as the agent wrote it.
4. "You asked": the user's prompt that the request belongs to, one or two lines, truncated.
5. Mismatch row (only when flagged): gray warning glyph and "This reason does not clearly match
   what you asked. Deny if you did not expect this."
6. Buttons: Deny (Esc), Continue (Enter). Gray only, no blue.

After Continue the card becomes a guide: "Drag cmux into the list, then turn it on." The app tile
(drag source) shows on the card and the System Settings list opens. The row turns to "Granted" by
itself when the grant lands, and the card closes after a short confirm (Reduce Motion: no slide).

Variants in the gallery (`agent-permissions-gallery.html`): A Context card (Recommended), B Compact
banner, C Two-step sheet, D Inline chat card. Recommended because it shows who/why/what-you-asked
at once, works for every kind, and turns into the drag guide in place without a second window.

## 4. Reason check

`PermissionReasonCheck` is deterministic (no model call), cheap and explainable:

- `no_reason`: the reason is empty or under 8 characters. The socket refuses it (`invalid_params`).
- `no_prompt`: the request names no user prompt. Shown as "No request from you is linked."
- `unclear`: neither the reason nor the prompt shares a content word with the other, and the
  prompt names no term the kind's vocabulary knows (Full Disk Access: files, folder, disk, mail,
  messages, library, import, backup, database …; computer use: click, app, screen, control, open …).
- `matches`: otherwise.

Stems are compared in lowercase, stop words removed, a simple suffix strip ("folders" = "folder").
False "unclear" is harmless (one gray row); a false "matches" is the risk, so the row text never
says "safe". A later version may ask a small model for a second opinion; the deterministic check stays
the floor.

## 5. Detecting the grant

`PermissionProbe` (protocol): `status(kind) async -> PermissionStatus` (`granted`, `denied`,
`not_determined`, `unknown`), `changes() -> AsyncStream<Void>`.

App probe (`SystemPermissionProbe`):

- Full Disk Access: try to open `~/Library/Safari/Bookmarks.plist` or the TCC db for reading (no prompt).
- Accessibility, Screen Recording, computer use: `ComputerUseSetup` (the helper owns those grants).
- Camera, microphone: `AVCaptureDevice.authorizationStatus`.
- Automation: `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)`.

Change events (nothing polls): `NSApplication.didBecomeActive`, the
`com.apple.accessibility.api` distributed notification, `ComputerUseSetup` observation, and while a
guide is up a bounded recheck with `Backoff` after the panel's tile was dropped (the drop is an
event). Tests use `MockPermissionProbe` (a settable map and a change stream).

## 6. Computer use onboarding (first principles)

Questions a person has, in order: What is this? What can it do to my Mac? What does macOS need from
me? How do I stop it? Did it work? The flow answers one per step, one action per step:

1. **What it does.** "Agents can use apps on this Mac for you: click, type, read the screen. You
   see a gray cursor with the agent's name whenever one acts. Nothing runs until you allow it."
   Buttons: Not now, Set up.
2. **Accessibility.** Why: "lets the agent click and type in other apps." Action: Open System
   Settings (list opens, tile floats). The step completes by itself when the grant lands.
3. **Screen Recording.** Why: "lets the agent see the window it works in." Same pattern.
4. **Try it.** cmux opens a sandbox window and the agent cursor clicks one button in it. Success
   shows "It works." Failure shows which grant is missing, with Retry.
5. **How to stop.** "Press Esc twice or click Stop on the cursor tag. Turn computer use off in
   Settings > Computer Use. Remove the grants in System Settings at any time." Done.

Retry and revoke paths: a step whose grant was removed later goes back to its pending state (the
flow is a function of the grants, never a stored step index). "Revoke" in Settings opens the same
list with a "Turn off cmux Computer Use" guide. If the helper is missing (dev build), step 1 says
"Computer use needs a signed build" and nothing else.

`ComputerUseOnboardingFlow` (pure): `steps(for: grants, tried: Bool, introSeen: Bool) -> current step`.

## 7. Ownership and files

- `CmuxNextAgentPermissions` (UI module, depends on `CmuxNextDesign`): `PermissionKind`,
  `PermissionStatus`, `PermissionRequest`, `PermissionRequester`, `PermissionOutcome`,
  `PermissionReasonCheck`, `PermissionProbe`, `MockPermissionProbe`, `PermissionSettingsOpening`,
  `AgentPermissionRequests` (@Observable coordinator), `ComputerUseOnboardingFlow`,
  `PermissionRequestCardView`, `PermissionRequestPanel`, strings, Localizable.xcstrings.
- App: `Permissions/PermissionsControl.swift` (socket methods), `Permissions/SystemPermissionProbe.swift`,
  `Permissions/AgentPermissionsPresenter.swift` (shows the panel for `current`).
- The App is the composition root; the module never imports the daemon.

## 8. Status and what is left

Shipped in this change: the module (model, reason check, coordinator, onboarding flow, card,
panel, mock probe), tests (Swift Testing, mock TCC), socket methods `permissions.request` and
`permissions.status`, the gallery.

Left:

- Rust CLI verb `cmux permissions request|status` and the MCP tool (cmux-tui owns the CLI).
- Real-app check of the System Settings drag (needs a signed build and a person; UNVERIFIED).
- Attribution is claimed by the caller (`agent`, `caller.terminal_id`) and shown as such; the
  launch credential (computer-use.md section 3) replaces it when it exists.
- Wire the new onboarding flow into the onboarding window (the old step stays until then).
- Merge the panel with a202's pairing card into one shared top-center panel.

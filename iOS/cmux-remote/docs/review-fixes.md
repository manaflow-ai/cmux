# cmux-remote rev-2 — fixes applied after the first adversarial review

The first adversarial 4-way review (Codex / Cursor / Pi / Gemini per the
[CLAUDE.md doctrine](../../CLAUDE.md)) returned **NO-GO** with strong
convergence. This document summarises what changed in rev-2 by fix
category, and which reviewer flagged each item — so the next review pass
can verify the deltas without re-walking the whole tree.

## Critical fixes

| # | Issue | Convergent reviewers | Fix |
| - | --- | --- | --- |
| C1 | `aps-environment = development` shipped to Release | Codex / Cursor / Pi / Gemini | Added `App/Configuration/CmuxRemote.Release.entitlements` with `production` and split per-config in `project.yml` |
| C2 | `BackgroundEventDrain` used `.acceptAny` host-key policy | Codex / Cursor / Pi | Fail closed: drain aborts if no pinned fingerprint exists |
| C3 | AFK auto-approve matched on `detail` first-token, ignored `onlyReadOnly` | Codex / Cursor / Pi / Gemini | Plumb `toolName`/`command`/`isReadOnly` through `AgentDecision`; evaluator matches structured fields; defaults dropped `sed/awk/grep/jq`; `git diff …` regex now anchored `$` with no shell metacharacters |
| C4 | Widget extension imported the app module (`CmuxRemote`) — App-Store-illegal | Codex / Cursor | Moved `CMUXActivityAttributes`, `AgentDecisionActivityAttributes`, `ResolveDecisionIntent`, widget-state cache into `CmuxKit`. Widget extension imports `CmuxKit` only. App-target intent dispatch goes through `CmuxIntentResolverRegistry` (closure registered at launch) |
| C5 | `snapshotConsumerTask` cancelled on every `connect()` → UI froze after first reconnect | Codex / Cursor | `tearDown()` no longer touches the snapshot consumer; only stops the transport-coupled actors. Resume-journal task is tracked + cancelled per host |
| C6 | `applyCursor()` synthesised a fake Ack which wiped `seq` on the next real Ack | Codex / Pi | Added `ServerState.seedCursor(_:)` that assigns the cursor directly; `applyCursor()` uses it |
| C7 | `ShellEscape.single()` left leading-`-` values unquoted → CLI flag injection | Cursor | Always quote when value starts with `-`. Added regression test (`testInjectionRegressionCommandShape`) |
| C8 | Host edit wiped TOFU pin | Cursor | `HostAddView` captures `existingPin` and preserves it across saves. New "Clear pin" affordance for deliberate re-TOFU |
| C9 | Lock Screen / Live Activity leaked raw command / diff text | Codex / Cursor | `AgentDecisionNotifier.composedBody` no longer includes `detail`; `AgentDecisionActivityAttributes.ContentState.detail` set to `nil` from the decision presenter |
| C10 | `AppDelegate` used `override` on `keyCommands` / `buildMenu` / `canPerformAction` but inherited `NSObject` | Codex / Gemini | Now inherits `UIResponder` |
| C11 | Send / send-key used `--text` / `--key`; cmux CLI expects positional args after `--` | Codex | Fixed to positional `-- <text>` / `-- <key>` per `docs/cli-contract.md` |
| C12 | `focus-panel --surface` was wrong arg name; `mark-notification-read --notification` was wrong; `cmux feed resolve` doesn't exist | Codex | Use v2 RPC directly: `surface.focus`, `mark-notification-read --id`, `feed.permission.reply` / `feed.question.reply` via `cmux rpc <method> <json>` |
| C13 | TOFU validator succeeded promise BEFORE persisting fingerprint → MITM credential leak | Gemini | Promise now succeeds inside the `Task.detached` after `onSeen(fingerprint)` returns |
| C14 | Boot-id change with non-`gap` ack silently corrupted local state | Gemini | `EventReactor.consumeEvents` now also forces `refreshSnapshot()` on any boot-id mismatch, regardless of `ack.resume.gap` |
| C15 | `HostStore` used `UserDefaults.standard` → widget/intent extensions could not see active host | Gemini | Switched to `UserDefaults(suiteName: "group.com.cmuxterm.remote")` |
| C16 | `requireBiometricForDestructive` was UI-only — not enforced on auto-resolve | Cursor / Codex | `NotificationCenterBridge.observeAgentDecision` falls through to manual notification when policy demands biometric + decision has destructive choice |
| C17 | Per-choice `requiresAuth` ignored in notification category options | Codex | `AgentDecisionNotifier.makeCategory(for:)` now derives `.destructive` / `.authenticationRequired` per-choice; category id encodes the auth signature |
| C18 | `ResolveDecisionIntent` silently no-op'd when client nil + dismissed notification BEFORE server ack | Cursor / Pi | Intent returns `IntentDialog("Not connected …" / "Couldn't deliver…")` on failure; only removes the delivered notification after the registry resolver reports `.delivered` |

## Important fixes

| Issue | Reviewer | Fix |
| --- | --- | --- |
| `AgentWatchdog` was dead code | Cursor | Wired through `EventReactor.Configuration.watchdog`; `ConnectionManager` constructs one per host, hooks `notifyOnStuck` to a time-sensitive local notification |
| Widgets never fed | Codex / Cursor | `CMUXLiveActivityController.applySnapshot` writes a `CmuxWidgetEntry` to the App-Group-backed `CmuxWidgetStateStore` on every snapshot |
| `NotificationCategories.installAll()` overwrote everything | Cursor / Codex / Gemini / Pi | Reads existing categories and unions before `setNotificationCategories` |
| `BrowserCommands`/`AgentDecisionResolver` hardcoded `"cmux"` | Codex / Pi / Gemini | Both use `self.cmuxBinaryPath` |
| `ResumeJournal` wrote to disk on every snapshot tick | self | Added a 5-second debounce + explicit `flush()` for graceful shutdown |
| Missing `Tests/CmuxRemoteTests` target | Codex | Created `AFKPolicyEvaluatorTests.swift` with regression coverage |

## Tests added

* `ShellEscapeTests.testLeadingHyphenAlwaysQuoted` + `testInjectionRegressionCommandShape` (C7)
* `CmuxEventDecoderTests.testSeedCursorPreservesSeqOnReconnect` (C6)
* `AgentDecisionMapperTests.testMapsPermissionRequestToToolCall`, `…testQuestionAsked…` cover the structured `toolName`/`command`/`isReadOnly` plumbing (C3)
* `TerminalInputAssistTests` cover `ModifierEncoder` + `SmartPasteSanitiser`
* `AFKPolicyEvaluatorTests.testReadOnlyToolWithoutReadOnlyFlagDoesNotAutoApprove`, `testWriteToolNeverAutoApproves`, `testChainedCommandDoesNotAutoApproveGitRule` (C3 plus Gemini's chained-command bypass)

## Still open (deferred, with rationale)

* **Cursor persisted before downstream side effects complete.** `docs/events.md` recommends persisting `seq` only after side effects succeed; we currently advance the cursor in `ServerState.apply(event:)`'s `defer` block before the `onAgentDecision` callback runs. Crash window is real but small, and the gap-resume contract plus snapshot refresh covers reconnect cases. **Status:** noted, not fixed in rev-2. Future fix: make `apply(event:)` return a token the callback hand-acks before the cursor advances.
* **Background credential access while device locked.** Keychain is gated on `.whenUnlockedThisDeviceOnly + .biometryCurrentSet`, so a `BGAppRefreshTask` firing while the device is locked can't decrypt the credential. Fixing requires either lowering the keychain protection class (Gemini's suggestion) or front-loading the BG drain credential into a separate after-first-unlock keychain item. **Status:** documented in `known-limitations.md`; the watchdog/event drain silently no-ops while locked rather than failing the BG task.
* **Push-to-start Live Activities** still need a cmux-side APNs sender (out of scope for the iOS client).
* **Surface output streaming** still requires the snapshot poll fallback; documented.

## Reviewer outputs

The four review files are pinned at:

* `/tmp/codex-cmux-remote-review.md`
* `/tmp/cursor-cmux-remote-review.md`
* `/tmp/pi-cmux-remote-review.md`
* `/tmp/gemini-cmux-remote-review.md`

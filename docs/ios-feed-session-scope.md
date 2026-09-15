# iOS Feed: session scope and decisions

This is the living scope record for the Feed work continued in this session. It includes the existing feature carried forward, subsequent user requests, implementation decisions, evidence, and unfinished work. Code being present does not mean the feature has passed a real phone check.

- Updated: 2026-09-15. Connection observations were refreshed on 2026-09-15; earlier feature-test results remain dated 2026-09-14.
- Branch: `task-ios-feed-tab`.
- Initial feature inventory snapshot: `c8ec337d105`. Later changes are recorded below.
- [Pull request 10218](https://github.com/manaflow-ai/cmux/pull/10218), author: Abdulaziz Albahar (`azooz2003-bit`).
- Current Mac/iOS development tag: `xfd2`.
- Original workspace: `workspace:38`, pane `pane:53`, surface `surface:117`.

## Changing scope

Refer to stable IDs below, for example: “remove F04,” “change D03 to allow another reply,” or “add support for provider X.” Editing this file directly also works. A requested removal changes the scope first; it does not mean its code has already been removed.

After each scope or implementation change, update the affected rows, decisions, evidence, and change log. Keep IDs stable. Mark removed or deferred items instead of deleting their history. Record user requirements separately from engineering choices; changing the latter does not imply the user approved a new product requirement.

**Status:** Built = implementation exists; Partial = part of the requested outcome remains; Pending = unfinished verification or delivery. Evidence is listed separately. All features remain in scope unless explicitly marked otherwise. There are no user-requested removals or deferrals recorded yet.

## Capabilities

### Feed foundation carried forward

These capabilities were already on this feature branch when this session continued. They are part of the current product scope, but their original design choices are not treated as newly approved user requirements.

| ID | Capability and current behavior | Status | Evidence / remaining work |
| --- | --- | --- | --- |
| F01 | Dedicated iOS Feed tab with a full-width, newest-first timeline across paired Macs; separate Notifications tab. | Built | Ordering and per-Mac state tests pass. Latest phone presentation remains pending. |
| F02 | Agent identity, relative time, quoted user prompt, assistant output, plans, stop reasons, and failed tool results. Long output supports Show more. | Built | Source inventory; latest visual checks pending. |
| F03 | Reduce timeline noise: omit routine tool use, successful tool results, and standalone user prompts. Keep prompts as context; unwrap encoded plan envelopes into readable content. | Built | Source and branch history; mixed-history visual check pending. |
| F04 | Permission actions: Allow once, Always, Deny, plus All tools and Bypass in an overflow menu. | Built | Uses the existing Mac decision handler. Provider support depends on its native integration; terminal reply tests do not prove permission support. |
| F05 | Plan actions: approve with the supplied default mode, choose another available mode, deny, or send revision feedback. | Built | Shared Mac decision path; complete visual and provider behavior checks pending. |
| F06 | Question options with immediate single selection, accumulated multiple selection and Send, plus Other for free text. | Built | Source inventory; complete question interaction checks pending. |
| F07 | All Activity / Needs Input toolbar filter, tab count, and leading swipe to mark Done or Needs Input. | Built | Badge and local triage state tests pass. Triage changes attention state without answering a request. |
| F08 | Sheet composer with quoted parent message, draft, Cancel, and Reply/Send. Used for terminal replies, Other answers, and plan revisions. Keyboard belongs to the sheet. | Built | Source inventory; keyboard, dismissal, multiline entry, and failure recovery need visual verification. |
| F09 | Live updates and pull to refresh; separate snapshots per Mac, stale revision rejection, coalesced refreshes, and reset/removal handling. | Built | Focused state tests pass. Real reconnect and multiple-Mac checks remain pending. |
| F10 | Capability-gated Feed support, connection/update/loading/empty states, bounded decoding, and tolerance of malformed rows. | Built | State tests cover malformed rows. A newer host advertises `feed.v1`; older hosts cannot provide this feature. |
| F11 | Shared permission/question/plan reply handlers with Mac-side pairing authorization. | Built | Uses `FeedCoordinator.deliverReply`; legacy workspace-scoped tickets must not authorize account-wide decisions. Complete hosted authorization checks remain pending. |
| F12 | English and Japanese Feed strings, accessibility identifiers, and consistent decision controls. | Built | Earlier catalog validation recorded. Current localization and accessibility presentation still need a final audit. |

### User-requested fixes and delivery

| ID | Requested outcome and implementation | Status | Evidence / remaining work |
| --- | --- | --- | --- |
| F13 | Reply actually submits the prompt. Paste literal text, then send the provider-appropriate submit key through the shared Mac terminal operation. | Built | Real terminal checks and five actual provider editors pass for single-line and multiline text. Provider/model acknowledgement is not returned to the app; see D04 and G02. |
| F14 | A small, conventional reply action replaces the bulky filled button. Use a curved arrow and Reply text, with at least a 44-point touch height. | Built | Current source implements the replacement. User acceptance and latest screenshot/video remain pending. |
| F15 | Reply transitions through a brief spinner with Sending, then a checkmark with Replied only after successful terminal submission. Show the user's reply under the referenced row. | Built | Failure, repeat submission, and refresh state tests pass. Animation and failure recovery need a real UI check. |
| F16 | Avoid duplicate Stopped rows for the same event while retaining any recorded reply. | Built | Duplicate-stop regression test passes. Exact screenshot scenario and rapid separate turns remain to verify; current matching is a time-based heuristic. |
| F17 | Send to the row's owning Mac, workspace, and terminal, including a secondary Mac. An unavailable owner must not redirect to a different instance. | Built | Secondary-owner and offline tagged-owner tests pass. End-to-end phone routing remains pending. |
| F18 | Support other coding providers, including OpenCode, Pi, Cursor, Grok, and Google Gemini CLI, with the same submission path. Preserve provider identity through ingestion. | Partial | Five real editor checks pass; seven-provider routing/identity coverage passes. Broader feature parity and live authenticated provider runs are not established. |
| F19 | Explain or fix why older completed rows have no Reply action. | Partial | Reply currently requires a stop row with both workspace and terminal IDs. Missing historical targets still suppress it; the original older-row screenshot has not been resolved end to end. |
| F20 | Install the current version on Mac and Aziz's physical iPhone, ready to open Feed and try it. | Partial | The existing pair passed same-account pairing and a credential-free phone relaunch on 2026-09-15. Latest `main` is now merged; replacement Mac/iOS builds and repeat verification are in progress. |
| F21 | Verify the final iOS experience on an isolated simulator and the physical phone. | Pending | Simulator build installed; latest Feed UI, keyboard, animation, and paired reply path have not been exercised there. |
| F22 | Keep repeatable regressions for submission, routing, stop deduplication, and provider compatibility. | Partial | Focused tests and manual provider harness pass. Hosted application tests and the new provider workflow still need successful complete runs. |
| F23 | Maintain this Markdown inventory so the user can add, remove, or change scope. | Built | This file, with stable feature/decision/gap IDs and a change log. Maintenance continues with the session. |
| F24 | Refresh rejected personal development credentials through `scripts/setup-team-dev.sh --refresh`, preserving the agent profile and requiring verification before replacement. | Built | Three regression tests pass for successful refresh, rejected credentials, and unavailable sign-in service. Optional password recovery remains available. This session instead used a genuine development server session, so the user did not need to enter credentials or run a command. |
| F25 | Pull the latest `main` into this branch and reinstall matching Mac/iPhone apps with the Feed work preserved. | Partial | Merged `88945c86fc3` in `1b1ab94d738`, resolving six conflicts and preserving upstream submodule versions. Mac revision `9798baef9e4` is installed; the matching iOS build is installed on the isolated simulator and queued for the physical phone until it reconnects. |

## Decisions

| ID | Decision | Origin and consequences |
| --- | --- | --- |
| D01 | Keep agent activity and response controls in Feed; retain Notifications as a separate surface. | Carried-forward design. This session does not imply a push-infrastructure redesign. |
| D02 | Use a compact message-style reply action and a composer quoting the parent message. | User requested familiar reply conventions and rejected the large button. The particular arrow, label, and sheet layout are implementation choices awaiting visual acceptance. |
| D03 | A row permits one successful terminal reply. Disable its reply action while sending and after success; retain its reply marker across refreshes. | Engineering choice to prevent duplicate submission. User requested a Replied state, but did not explicitly require permanent one-reply-only behavior. State is local to the current shell session; cross-device or restart persistence is not established. |
| D04 | Mark Replied only when `mobile.terminal.paste` returns `submitted: true`. | Engineering implementation of the user's success requirement. Today this confirms that the terminal accepted or queued the submit key, not that an agent or model acknowledged the message. Closing this semantic gap is G02. |
| D05 | Share paste/submit behavior between iOS Feed and the Mac Feed reply path. Preserve literal text and internal newlines. | Principled fix: one operation owns paste, submit, and its result. Avoid divergent newline-based submission paths. |
| D06 | Choose the submit key from the active agent process identity, with fallback to existing detection when current identity is absent. Claude multiline input uses Ctrl+Enter; other current cases use Return. | Principled ownership choice: switching providers in a terminal must not retain the original provider's submission rules. Hosted submit-key tests still need to execute successfully. |
| D07 | Separate paste and Enter by a 150 ms asynchronous wait. Reject concurrent submissions to one terminal and recheck its identity and generation before Enter. | The target checks are principled lifecycle protection. The delay is a pragmatic compatibility workaround for provider paste handling, not a readiness acknowledgement; provider changes or severe load remain risks. |
| D08 | Keep Sending visible for an additional 350 ms after a successful response, then record the reply. | Presentation choice to make the transition legible. User asked for brief progress; this exact duration is not a user constraint. |
| D09 | Collapse stop rows within two seconds when Mac device, workstream, provider, and stop reason match. Preserve a reply marker from either row. | Heuristic fix for the reported duplicate. The key omits the Mac instance tag and conversation text; genuine rapid turns or sibling instances can collide. See G04. |
| D10 | Route using the row's owning connection; fail if that owner is unavailable. | Principled routing decision to prevent sending into the selected but unrelated Mac or terminal. |
| D11 | Swiping Done changes local attention state only. Actual permission/question/plan controls follow the authoritative pending state. | Carried-forward design. Marking a request Done must not silently approve or deny it. |
| D12 | Preserve each provider's identity, including an explicit Grok source. Use the shared terminal path wherever possible. | User requested multiple-provider verification. This does not promise identical permission, plan, or question support for every provider. |
| D13 | “Installed” is insufficient for delivery: Mac and phone need the same tag, matching personal account, trusted pairing, usable connection, and Feed open. | User requested immediate testing; repository dogfood contract supplies these acceptance conditions. Physical phone uses the personal profile; isolated simulator uses the agent profile. |
| D14 | Keep the existing pull request open until verification and user dogfood are complete. Merge requires an explicit merge instruction. | Session constraint. No merge authorization is recorded. |
| D15 | Match the installed `xfd2` Mac's API, broker, and sign-in addresses to the phone's existing staging configuration. Keep the personal authentication profile. | Operational repair on 2026-09-15. Both servers responded before repair, so server availability did not explain the rejected password. Future reloads must preserve a matching server configuration. |

| D16 | Use a genuine 24-hour developer session for the existing personal account when the saved password is rejected; preserve the phone’s valid session and refresh its pairing ticket. | User explicitly requested the developer command and no user-run setup. Account identity was verified through Stack and both apps passed the same-account RPC gate. This does not change the password; the temporary session will expire. |
| D17 | Preserve main’s iPhone/iPad navigation structure while adding Feed to each supported destination control. | Merge resolution. Native tabs remain on compact layouts; the existing split-sidebar destination control gains Feed. Existing Feed English/Japanese strings are retained alongside main’s newer translations. |

| D18 | Await the shared terminal submission operation in main’s new macOS notification and relayed-phone reply callers before recording delivery. | Semantic merge repair: the Feed branch made paste/submit asynchronous, so newly merged callers must propagate that contract. Existing partial-paste handling remains unchanged to avoid typing a reply twice. |

## Provider coverage

The real-editor harness starts actual provider command-line apps with isolated configuration and a local request recorder using test credentials. A pass means the exact submitted prompt reached the provider's outgoing model-request path. It does not test paid inference, real-account authentication, a completed model response, or the iPhone transport/UI.

| Provider | Version in recorded editor verification | Routing and identity tests | Real editor: single-line / multiline |
| --- | --- | --- | --- |
| Claude Code | Not recorded in this harness | Pass | Not run in this harness |
| Codex | Not recorded in this harness | Pass | Not run in this harness |
| Pi | 0.73.1 | Pass | Pass / Pass |
| OpenCode | 1.18.31 | Pass | Pass / Pass |
| Cursor CLI | 2026.09.10-fd3934a | Pass | Pass / Pass |
| Grok Build | 1.0.30 | Pass | Pass / Pass |
| Google Gemini CLI | 0.59.0 | Pass | Pass / Pass |

Pi's multiline case passed on rerun after a transient terminal screen-read failure. Cursor's recorder handles its HTTP/2 request path. “Google” is interpreted here as Gemini CLI, and “Cursor” as Cursor CLI; other products and unnamed providers are not yet enumerated coverage.

## Verification and delivery record

| ID | Recorded result | Limit |
| --- | --- | --- |
| V01 | `MobileAgentFeedTerminalReplyTests` and `MobileShellAgentFeedStateTests`: 14 tests pass, including 14 routing argument combinations across seven providers and two prompt shapes. | Package behavior tests, not phone UI evidence. |
| V02 | `ControlCommandCoordinatorMobileHostTests`: 8 tests pass. | Shared control-operation coverage. |
| V03 | `WorkstreamStoreTests`: 13 tests pass, including seven provider identity cases. | Ingestion coverage, not every provider's permission protocol. |
| V04 | Real terminal paste/submit checks pass for plain text, multiline Unicode, and literal punctuation. Five-provider editor checks pass as listed above. | Recorded tagged runtime checks; temporary raw evidence is not a durable published artifact. |
| V05 | [macOS build run](https://github.com/manaflow-ai/cmux/actions/runs/34922165927) succeeded. Tag `xfd2` was installed locally. | Includes the runtime fixes, predates later harness-only changes. The original sign-in blocker was resolved in V15–V16; this build predates the main merge. |
| V06 | Current iOS phone archive and simulator build succeeded; signing/export completed. Simulator `cmux-dev-xfd2` was installed. | Installation alone proves neither UI behavior nor pairing. |
| V07 | Physical iPhone installation was queued on 2026-09-14 because Aziz's device was unreachable. | Queue entry: `~/Library/Application Support/cmux-dev/iphone-install-queue/pending/xfd2`. Phone installation, authentication, pairing, and Feed navigation remain pending. |
| V08 | [Hosted submit-key test run](https://github.com/manaflow-ai/cmux/actions/runs/34922167776) failed before tests executed: `WindowAndDragTests.swift` was missing `customSidebarDataContext`. | No passing result can be inferred for `ComposedPromptSubmitKeyTests`. |
| V09 | Provider workflow added; initial [run](https://github.com/manaflow-ai/cmux/actions/runs/34922456272) failed workflow validation. Environment scoping was corrected in `c8ec337d105`. | A successful complete run after that correction is not yet recorded. |
| V10 | Pull request checks were not all passing at the last observation, including CLA policy and web complexity checks. | Do not describe this as ready to merge. Reassess concrete failures before closeout. |
| V11 | 2026-09-15: local server on port 4377, former remote server on port 4577, and staging all returned 200. Staging sign-in returned 200 and after-sign-in redirected with 307. Phone was reachable and `dev.cmux.ios.xfd2` was installed. | Installation queue now reports `needs-auth`, superseding V07's pending installation state. Mac `auth status` was signed out at that observation; superseded by V15. |
| V12 | 2026-09-15: the native development sign-in endpoint returned HTTP 400 with `EMAIL_PASSWORD_MISMATCH` for the saved personal profile. Installation helper was refreshed and the machine setup check passed. | Setup checks validate profile presence; they do not prove the credentials are accepted. The password-based launcher still rejects this saved pair; V15 records the alternate developer-session repair. |
| V13 | 2026-09-15: three personal-account refresh regressions pass; the same tests fail against the preceding setup script. Shell syntax and help checks pass. The repaired Mac bundle was signed, verified, and relaunched. | No app executable changed. The Mac still reports signed out; neither phone pairing nor Feed interaction is claimed verified. |
| V14 | 2026-09-15: the prescribed `scripts/mobile-dev-launch.sh --tag xfd2 --device --device-id 4A52829D-6427-599F-A166-4058881D2DF4 --ensure-mac --auth-profile personal --credentials-file ~/.secrets/cmuxterm-dev.env` flow ran. It relaunched the exact tagged Mac, then failed its signed-in account gate for `aziz@manaflow.ai`. | This is the dev flow result, not a normal browser sign-in result. This historical failure was resolved for the installed pair using the genuine developer session and persisted phone session in V15–V16. |
| V15 | 2026-09-15: created a genuine developer session for the existing personal account using the configured development Stack server credentials. Mac `auth status` verified `aziz@manaflow.ai` and the expected user/team. | Session is limited to 24 hours. No password was changed, and no tokens were included in logs or this document. |
| V16 | 2026-09-15: fresh phone pairing established usable workspace RPC in 14,097 ms. A second launch without credentials or a ticket reconnected in 765 ms. | Applies to the pre-main-merge installed apps. Secret-free receipts are stored under `artifacts/task-ios-feed-tab/connection-repair/`; the reinstalled apps must pass again. Feed UI is not visually verified by this gate. |
| V17 | 2026-09-15: merged latest main (`88945c86fc3`), resolved six conflicts, parsed affected Swift files, validated the project file, and checked wiring for 942 test files. | Syntax/project checks are not compilation. Remote app builds are in progress. |
| V18 | 2026-09-15: 48 of 49 attachment/setup checks passed. The remaining check expected the older receipt shape; its fixture was updated for main’s installed-bundle evidence and the focused rerun passed (five selected tests). The merged localization catalog validates for nine languages. | No application behavior was changed by the fixture update. |
| V19 | [Refreshed hosted submit-key run](https://github.com/manaflow-ai/cmux/actions/runs/35022290439) found new notification callers using asynchronous terminal paste synchronously. Added an awaited-delivery regression and propagated async through both notification paths. | Compilation blocked test execution. The superseded Mac build and dependent provider run were cancelled; rebuilt evidence is pending. |

| V20 | [iPhone/iPad navigation run](https://github.com/manaflow-ai/cmux/actions/runs/35023839799) compiled both apps but selected zero tests. Corrected the dispatch selector to include both target and class; the next attempt timed out during checkout before testing. | Neither run proves navigation behavior. Fixed the Feed time-label free-function convention violation; unrelated namespace-type lint failures inherited from main remain. |
| V21 | The first two hosted Mac rebuilds exposed main API drift (`idleTimeoutNanoseconds`, then `FeedJumpResolver.parse`); both were fixed. | A third run completed successfully after those fixes. |
| V22 | [Mac rebuild run](https://github.com/manaflow-ai/cmux/actions/runs/35030862663) completed and installed tag `xfd2`; auth status still reports `aziz@manaflow.ai`. The matching iOS archive compiled and exported, and the isolated simulator install succeeded. | The physical iPhone was unavailable, so the signed app is queued with the personal account contract. It will auto-install when the phone reconnects; pairing after replacement remains pending. |
| V23 | [Provider verification](https://github.com/manaflow-ai/cmux/actions/runs/35033730472) was dispatched against the successful Mac build. | Awaiting its complete result. |

## Gaps and next work

These are outstanding parts of existing scope or limits that affect its acceptance. Proposed extensions are identified explicitly; they are not silently added as requirements.

| ID | Gap | Next action / acceptance condition |
| --- | --- | --- |
| G01 | Original sign-in/pairing blocker resolved through a genuine developer session and fresh ticket. Mac replacement is complete. The iOS archive and simulator replacement are complete; the signed physical-phone delivery is queued until the device reconnects. | Agent rebuilds and installs both apps, preserves the verified personal identity, repeats the same-account and persisted-reconnect checks, and exercises Feed. The user runs no setup commands. |
| G02 | Replied currently reflects terminal key acceptance. | Verify the agent actually starts a turn from the phone path. If the product requires a provider acknowledgement before showing Replied, add that acknowledgement contract; it is not implemented today. |
| G03 | Original older rows without Reply remain unexplained at the product level. | Inspect those rows' target metadata. Recover a valid live target where possible and decide the unavailable-session presentation. Do not send to an unrelated terminal. |
| G04 | Stop deduplication uses a two-second heuristic. | Reproduce the two Stopped rows; prove repeated delivery collapses and distinct rapid turns remain visible. Strengthen event identity if the heuristic conflates them. |
| G05 | Composer dismisses immediately on Send; Feed submission failure is logged without a visible recovery flow in this path. | Exercise owner-offline, paste-accepted/key-failed, and connection-loss cases. Define clear failure feedback and draft/retry behavior that cannot paste the text twice. |
| G06 | No latest visual proof for reply styling, progress, completion, or duplicate removal. | Record the exact flow on an isolated simulator, then check the physical phone. Include multiline input, keyboard dismissal, repeated taps, refresh, and failure behavior. |
| G07 | Provider evidence is narrower than full provider feature parity. | Complete requested submission coverage through the paired phone; keep routing, editor submission, real inference, and permission/question support separately reported. Broader provider parity requires an explicit scope choice. |
| G08 | Application tests and provider workflow have no complete passing final result. | Address the concrete test compilation/workflow failures and run the focused checks on hosted or fleet machines. |
| G09 | Local reply and triage state are not proven durable across app restart or shared across devices. | Current promise is survival across refreshes. Treat durable or cross-device state as a proposed extension unless the user adds it. |
| G10 | Presentation and localization acceptance remains open. | Audit current strings, accessibility labels, touch targets, and readable layout; collect user feedback on the familiar reply interaction. |

## Source map

- [Feed overview and existing provider integration semantics](feed.md).
- [Timeline, filtering, and swipe actions](../Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/AgentFeedView.swift).
- [Row controls and reply states](../Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/AgentFeedRow.swift), [composer](../Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/AgentFeedReplyComposer.swift).
- [Feed synchronization, routing, submission, and stop matching](../Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+AgentFeed.swift).
- [Item identity, reply eligibility, and triage semantics](../Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileAgentFeedItem.swift).
- [Mac terminal submission](../Sources/TerminalController.swift), [active-provider submit-key selection](../Sources/TextBoxAgentDetection.swift).
- [Reply regression tests](../Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileAgentFeedTerminalReplyTests.swift), [Feed state tests](../Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellAgentFeedStateTests.swift).
- [Real terminal harness](../tests_v2/test_mobile_terminal_paste_submit.py), [provider editor harness](../tests_v2/test_mobile_terminal_paste_providers.py), [hosted provider workflow](../.github/workflows/test-feed-reply-providers.yml).
- [Personal account setup and refresh](../scripts/setup-team-dev.sh), [refresh regression tests](../scripts/setup-team-dev.test.mjs).

## Change log

| Date | Change |
| --- | --- |
| 2026-09-15 | Created the session inventory from user requests, current source, branch history, and recorded verification. Distinguished implementation from evidence, and recorded remaining installation, pairing, submission, UI, and test gaps. No product scope added or removed. |
| 2026-09-15 | Investigated the user's inability to connect to the Mac. Confirmed working servers, an installed phone app, and rejected personal credentials; aligned the Mac server configuration and refreshed installation tooling. Added F24 for credential recovery within F20, with D15 and V11–V12 recording the repair and remaining blocker. |
| 2026-09-15 | Ran the requested tagged dev launcher instead of normal sign-in. The launcher reached the exact Mac but failed the personal account gate; added V14. |
| 2026-09-15 | Completed developer sign-in and phone pairing without user commands; a credential-free relaunch passed. Added D16 and V15–V16 and removed the user-run setup requirement from G01. |
| 2026-09-15 | User requested pulling main and reinstalling. Merged 1,646 upstream commits, retained Feed in updated compact and split navigation, and started rebuilding the pair. Added F25, D17, and V17. |
| 2026-09-15 | Reconciled main’s notification reply callers with asynchronous Feed submission, added delayed-success/failure coverage, and expanded the provider workflow to run notification delivery tests. Updated the attachment receipt fixture for main’s evidence metadata. |

## Dictionary

- **RPC:** a request one app sends to another app to perform an operation.
- **Revision:** an increasing number used to reject an older Feed snapshot.
- **Tag:** a name isolating a development Mac/iOS app pair from other installed versions.
- **Dogfood:** trying the development app through the actual user flow before approving the change.
- **Harness:** a program that drives a repeatable test and captures its result.
- **Hosted check:** an automated build or test running outside the user's Mac.
- **CLA:** the contributor license agreement checked for contributions to the repository.

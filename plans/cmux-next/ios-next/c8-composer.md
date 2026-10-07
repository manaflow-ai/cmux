# C8 `composer`: dispatch a task from the phone

Status: lane C8 of [PLAN.md](PLAN.md), 2026-10-06, branch `feat-cmux-next-ios-c8-composer` off
`feat-cmux-next-ios` (A0, A1, B1, B5, C5 merged there). Binding: PLAN.md section 4,
OWNERSHIP-PRINCIPLES.md, a1-shell.md (2.3 `TaskComposerSink`, parity 1.10 and 1.13), a0-rpc.md (5.9
task family), b1-control-do.md (task op forwarding, `task:<host>` mirror), b5-mac-host.md (policy,
spawn verification), c5-workspaces.md (picker seam), c4-files.md (attachment seam, unmerged).

## 1. Ownership

| State | Owner (single writer) | On the phone |
| --- | --- | --- |
| Task records (id, agent, workspace, tab, state, title) | the target Mac's task runner (`task:<host>`, mirrored by `HostDO`) | mirror per host, read only |
| Which agents (harnesses), models and efforts a Mac offers | the Mac (acpmux `_acpmux/harnesses` + `_acpmux/models`, projected by the task runner into the `task:<host>` snapshot) | mirror only |
| Workspaces to target | each Mac's workspace store (C5) | C5's `WorkspaceSource` projection |
| Draft (target, agent, model, effort, prompt, attachment refs, template) | this client (view state) | `UserDefaults` JSON, one draft per target |
| Saved prompt templates, last-used agent/model/effort | this client (view state) | `UserDefaults` JSON, never synced |
| Uploaded attachment bytes | the Mac file system (C4 upload staging) | upload ids from C4 |

A dispatch is one op with a client-chosen idempotency key. The phone never infers a task's start: the
receipt is the owner's `result`, progress is the owner's `task.state.set` events. While the target Mac
is unreachable, Send is disabled with the reason and nothing queues (U5); the draft stays.

## 2. Wire (A0 task family, additive)

A0 already has `task.dispatch {host, workspace?, agent, model?, effort?, prompt, attachments[] (up_
ids), template?}` -> `{task, workspace, tab}`, `task.cancel`, `task.list` (read) and owner
`task.state.set`. C8 adds, in `families/task.schema.json` only (no new message, so the catalogs do not
change):

- `$defs/Agent {id, name, models[{id, label, efforts[], default_effort?}], default_model?,
  unavailable?}` and `$defs/TaskStreamState {agents: [Agent], tasks: [Task]}`: the state of a
  `task:<host>` snapshot. `unavailable` is acpmux's reason string ("Not signed in").
- Structural changes (a new task, the agent list changed) go out as a fresh snapshot at the next seq;
  state transitions go out as `task.state.set` events. HostDO stores and broadcasts both
  (b1-control-do.md 3: a snapshot without `to` replaces the stored one). This keeps the catalog
  unchanged; a `task.upsert` owner event is the follow-up if snapshot size ever matters (bounded:
  agents are a handful, tasks capped at the 50 newest).
- Cap `task.dispatch` in `hello.ok` and `host.caps.set`: the Mac accepts dispatch. The phone enables
  Send only when the host is live and advertises it; otherwise the reason is "This Mac doesn't accept
  tasks yet".

## 3. Mac side (`CmuxMobileHost`)

Seam `MobileTaskRunner` (the app implements it over acpmux and the workspace store; tests use a fake):

```swift
public protocol MobileTaskRunner: Sendable {
    func agents() async throws -> [MobileAgent]          // _acpmux/harnesses + _acpmux/models
    func tasks() async throws -> [MobileTask]            // tasks this runner started, newest first
    func changes() async -> AsyncStream<Void>            // one signal per change batch
    func dispatch(_ request: MobileTaskDispatch, context: MobileOpContext) async throws -> MobileTaskDispatchResult
    func cancel(task: String, context: MobileOpContext) async throws
}
```

Daemon capabilities the app adapter calls (no new daemon command): acpmux `_acpmux/harnesses`
(installed harnesses, `unavailable` reasons) and `_acpmux/models` for the catalog; for a dispatch,
the workspace store's `create-workspace` when `workspace` is absent (no argv/cwd/env from the phone),
then acpmux `session/new {harness, cwd: <the workspace's directory from the store>, model, effort as
the harness config option}` in a new agent tab of that workspace, then `session/prompt` with the
prompt as one ACP `text` content block plus one `resource_link` per resolved attachment path; cancel
is `session/cancel`. State comes from acpmux session events (`queued` until the session is created,
`running`, `needs_input` on a permission request, `done`, `failed`).

`MobileTaskPolicy` (default deny, b5-mac-host.md 3 rules), run inside the same `MobileOpExecutor`
ledger as workspace ops, keyed `(install, idempotency_key)`:

- Only `task.dispatch` and `task.cancel`; params exactly the schema's; every command-bearing param
  (`command`, `argv`, `env`, `cwd`, `shell`, `script`, `url`, ...) refused `auth.forbidden` first.
- `agent` must be an id the runner advertises right now and not `unavailable`
  (`task.agent_unavailable` otherwise). `model`, when given, must be one of that agent's models;
  `effort` one of that model's efforts (`validation.invalid`). The Mac never forwards a phone string
  as a harness name, binary or flag.
- `prompt` is data: 1 to 100000 characters, no NUL; it reaches the harness only as an ACP text
  block, never a shell string, argv element or environment value. `template` is a label (<= 128
  characters of `[A-Za-z0-9._:-]`), never expanded on the Mac.
- `workspace`, when given, must be a `ws_` id in this host's current tree (`workspace.not_found`);
  `host`, when given, must be this host.
- `attachments` are `up_` ids resolved by `MobileTaskAttachmentResolver` for the calling install
  only (C4 staging); unknown ids are `task.attachment_missing`. The phone never sends a path.
- `task.cancel` takes a `task_` id the runner owns (`task.not_found`).
- Spawn gate: a dispatch always starts an agent process (and maybe a workspace), so it is refused
  `auth.forbidden` with `details.reason: spawn_unverified` unless
  `MobileHostConfiguration.allowsTaskDispatch` is on (default **off**). Turning it on requires the
  live check of b5-mac-host.md 3 on a tagged build: the agent session runs on this Mac's session host
  as the user, in the workspace's own directory, with no phone text in its argv, cwd or env, and the
  prompt arrives verbatim as the first user message. `task.dispatch` is advertised only when the
  runner is present and the gate is on.

`TaskStreamOwner` projects the runner into `task:<host>` exactly like `WorkspaceStreamOwner` (seq from
process start ms, `epoch`, bounded tail, change signals coalesced, no timer). The rpc channel serves
`subscribe`/`snapshot.request` for both streams; `HostControlUplink` answers `snapshot.request
{stream: task:<host>}` and `read task.list` from it. Without a runner, task ops stay
`proto.unsupported` as before.

## 4. Phone modules

| Module | Owns | Imports |
| --- | --- | --- |
| `CmuxiOSComposerCore` | draft model and store, selection rules (effort follows model), send gate, prompt tokens (slash templates, `@` mentions, markdown-lite ranges), templates store, dispatch encoder, `task:` mirror, `TaskControlChannel` seam + `ControlPlaneTaskChannel`, `ControlPlaneTaskComposerSink` | Foundation, FeatureKit, CmuxMobileWire, CmuxControlPlane |
| `CmuxiOSComposer` | Compose tab, composer sheet for the floating button, pills, prompt editor, attachment strip, dictation, receipt and progress | UIKit, Speech, AVFAudio, PhotosUI, Core, Design |

FeatureKit (additive, defaults keep callers compiling): `ComposerModel`; `ComposerAgent.modelOptions,
defaultModel, unavailableReason`; `ComposerCatalog.agentsByHost` + `agents(on:)` + `taskDispatch caps`;
`TaskDraft.templateID, uploads`; `TaskReceipt.started` gains optional `taskID`, `tabID`;
`TaskRecord`, `TaskState`; `TaskComposerSink.tasks(on:)` (a requirement with no default: a protocol
extension default shadowed the actor witness at concrete call sites); `RealFeatureFactories.composer` takes
the resolved `WorkspaceSource`.

### 4.1 Real sink

`ControlPlaneTaskComposerSink(workspaces:channels:)`: hosts and workspaces come from C5's
`WorkspaceSource` (no second workspace mirror); per paired Mac a channel from C5's
`ControlPlaneWorkspaceChannelFactory(...).streaming("task")` (C5's control-plane channel now takes a
stream kind: one `ControlPlaneClient` on `/v1/wire/host/<host>` subscribing `task:<host>` and
`host:<host>`) feeds a
`TaskStreamMirror` (snapshot replaces, `task.state.set` applies, epoch change drops). Catalog =
hosts x agents per host x caps, one snapshot per change batch. `dispatch` encodes `task.dispatch`
with the intent key as idempotency key and `origin: user`, submits on that host's channel, and maps
`result` to `.started(workspace, task, tab)` and `reject` to `.refused(message)`; a channel that is
not live throws `.offline`; a lost socket mid-flight keeps the key and the client resends on
reconnect (owner dedupes). Channels open only while a composer screen subscribes the catalog, so a
hidden composer costs nothing. Follow-up: share one host socket with C5's channel (today two sockets
per host while both screens are visible).

### 4.2 Composer UI (UIKit, HIG: Text views, Menus, Buttons, Keyboards, Sheets)

- Target row: Mac and workspace ("New workspace" allowed), opens C5's picker
  (`WorkspacesFeature.makePicker`, injected as a closure from `ShellComposition`).
- Pills in one horizontal scroller (parity `TaskComposerEffortPickerUITests`): agent (the Mac's
  advertised agents; unavailable ones disabled with their reason), model, effort. Picking an agent
  selects its default model; picking a model keeps the effort if offered, else its default effort.
  Last-used choices persist per Mac.
- Prompt: multiline `UITextView`, markdown-lite styling (headings, `**bold**`, `` `code` ``, list
  bullets, `@mentions`) without changing the text. `/` at a line start lists built-in and saved
  templates (insert prompt text; templates are prompt text, never shell commands as in the shipping
  app). `@` lists files from a `ComposerFileSuggesting` seam (C4 `files.list`; empty until C4 lands).
- Attachments: photos (PhotosPicker) and files (document picker) through `ComposerAttachmentPicking`,
  a small seam C4's `FileSendActions.pick(for: .composer)` + `FileAttachmentSink` fill; each
  attachment carries its upload id. Send waits for uploads.
- Dictation: `SFSpeechRecognizer` with `requiresOnDeviceRecognition` when supported, else server
  recognition; partial results stream into the prompt at the cursor; stops on Send or tap.
- Send: button and Cmd-Return (`UIKeyCommand`); disabled with a footnote reason (offline, no Mac,
  agent unavailable, empty prompt, uploads pending, no `task.dispatch` cap). One `IntentKey` per
  send attempt is kept with the draft until a receipt, so a retry after an unknown outcome reuses it.
- Receipt: "Started in <workspace>" with Open (C5 `WorkspacesFeature.open(hostID:workspaceID:)`),
  then the task's live state from `tasks(on:)`. Refusal shows the owner's message; the draft stays.
- Drafts: one per target (`host|workspace` or `host|new`), saved on change (debounced by the text
  view's own end-editing and on disappear, no timer), cleared on a started receipt.
- Floating compose button over Feed and Workspaces (hidden on Compose) presents the composer as a
  sheet with the current workspace preselected when known.

## 5. Tests (Swift Testing)

`CmuxMobileHostTests`: policy (unknown agent, unavailable agent, model/effort not offered, command
params, NUL prompt, foreign workspace, attachments resolved per install, spawn gate off), dispatch end
to end over the rpc channel and the uplink (result + settled, idempotent replay, stream snapshot with
agents, `task.state.set` event), cancel. `CmuxiOSComposerCoreTests` (macOS through a scratch package,
compiled for the simulator): selection rules, send gate reasons, draft store per target, prompt token
parsing, encoder params, mirror snapshot/event/epoch, sink catalog/dispatch/refusal/offline over a fake
channel.

## 6. Not here

C4 upload wiring (seam only), `files.list` mentions (seam only), the app's `MobileTaskRunner` over
acpmux (cmux-next app, no local Mac build), the live spawn check (gate stays off), task cancel UI
beyond the receipt, Live Activity per task (C7 owns `notify.activity.*`), tagged build (blocked:
no fleet manifest, dev backend VM).

## 7. Status (2026-10-06)

Done: design; Mac side in `CmuxMobileHost` (`MobileTaskRunner`, `MobileTaskPolicy`,
`TaskStreamOwner`, `MobileTaskService` in `MobileOpExecutor`, multi-stream rpc channel and uplink,
`read task.list`, caps `task.stream`/`task.dispatch`, `allowsTaskDispatch` default off; 18 new tests,
69 total green with `swift test`); schema `$defs` for the task stream state; FeatureKit additions;
`CmuxiOSComposerCore` (31 tests incl. 6 session tests, green on macOS through a scratch package, 52
with FeatureKit's); `CmuxiOSComposer` (Compose tab, sheet, floating button over Feed and Workspaces when
the `composeTab` flag is on); `AppContainer.realFactories.composer` registered (DEBUG still defaults
to mocks: `CMUX_IOS_SOURCE_COMPOSER=real`). `CmuxiOSApp`, `CmuxiOSComposerCoreTests`,
`CmuxiOSFeatureKitTests` and `CmuxiOSShellTests` compile for `arm64-apple-ios17.0-simulator`.

Mocked or seams only: the app's `MobileTaskRunner` over acpmux (cmux-next app wiring, not built
here), attachment upload (`ComposerAttachmentUploading`, nil until C4 merges, so the attach button is
hidden), `@` mention names (`ComposerFileSuggesting`, `NoFileSuggestions` until C4's `files.list`).

Unverified: everything visual (no simulator run), dictation on device, VoiceOver and large Dynamic
Type, the live spawn check (so dispatch stays refused `spawn_unverified` on real Macs), TS catalog
tests (no `node_modules`). Tagged build not attempted (known blocked: no fleet manifest, dev backend
VM).

## 8. Attachment intake prerequisite (2026-10-07)

The upload path now preserves the Mac's verified `files.upload.done.upload` reference through
`MobileTransferManager`, its restart journal, `LinkFileTransfer`, `TransferProgress`, and
`FileSendCoordinator` into `FileAttachment.uploadID`. Older journal records keep a nil reference;
a remote path is never converted into an upload id.

`ComposerSession.attachmentSink()` supplies a weak `FileAttachmentSink` bound to the current
host, target, and draft generation. It accepts at most the task protocol's 32 attachments,
updates duplicate transfer ids without consuming another slot, and requires an owner-shaped
`up_` reference. It refuses attachments for another host, after switching targets (including
switching back), after a successful send, or while a send has an unknown outcome. Refused
uploads remain in the Mac inbox and do not alter another draft.

This is a core prerequisite, not completed attachment UI: `ComposerAttachmentUploading` is still
not supplied in `ShellComposition`. The picker requires explicit cancellation/removed-item handling,
temporary-file cleanup, and upload ownership across target changes before that button is enabled.
C8's parity row therefore remains **seam only**.

Regression coverage added: real loopback upload id through the file coordinator and restart history;
transfer-manager result and journal retention; backward journal decoding; persisted composer intake;
invalid/missing ids and foreign hosts; the 32-item cap and replay; target-generation invalidation;
unknown/successful dispatch races. Swift parsing and `git diff --check` passed. The focused remote
Swift test command did not execute: `nx-remote` job `1007-165217-271b07` exited 255 because
`cmux-lawrence-2` could not resolve (known HQ REPAIR.md build-host alias/DNS symptom). No simulator
or phone verification was performed.

# Computer Use: permission modes and app approvals

How cmux decides whether an agent may use an app on a machine, on macOS,
Windows and Linux, on a person's desktop and on a VM or box that runs
cmux-tui unattended. It builds on cmux Remote (`docs/cmux-remote.md`): the
Computer Use worker loads upstream Cua Driver (trycua/cua, MIT,
`cua-driver-rs-v0.34.0`, commit `b0968e1b12834e485dda68789541a3cc57664a9f`,
`scripts/cmux-next/cua-driver-sdk.pin.json`) in process.

## Principles

- **Upstream's authorization model is the core.** Every call passes the
  driver's own chokepoint: hard invariants, the built-in risk map, managed
  and user policy, the permission mode, the capability manifest, then a host
  decision for a residual boundary. cmux adds no second policy engine; it
  chooses the mode, writes the manifests and collects the person's answers.
- **Only the box owner raises trust.** The mode and the saved approvals are
  set by the person on the machine (the Mac app's dialog, or
  `cmux computer-use setup` run on the box with elevation), never by a tool
  call. CLI and MCP can lower trust (revoke, deny, a lower mode) freely; a
  raise from CLI or MCP waits for the person's confirmation on a protected
  collector.
- **Approvals come only from protected collectors**: the cmux app's card, the
  owner's phone or Mac through the device hub, polkit on a Linux desktop,
  Windows Hello on Windows. Never a terminal prompt, a file or an MCP
  elicitation. Each answer is bound to one request digest and nonce, is single
  use, and a machine never answers its own requests.
- **Fail closed.** No answer, a malformed answer, a lost link or an unreadable
  config refuses the call.
- **Same documented limit as upstream.** This protects against agents limited
  to cmux's tools. An agent that already runs arbitrary code as the same OS
  user can drive the OS directly; isolate it with a VM, a separate user or a
  second device.

## Modes (per machine, chosen by its owner)

| `computerUse.mode` | For | Behavior |
| --- | --- | --- |
| `ask` (turn on in Settings: Agents Using Apps) | Personal machines where the person wants to be asked | Each agent session starts as an upstream `bounded` session whose manifest lists no app. A call on an app outside it asks the person (below); an answer grows that session's manifest, or the client's saved list. |
| `standard` (default, D24) | Every machine until its owner picks another mode | Upstream `standard`: routine observe and input run without prompts; only residual boundaries ask. |
| `bounded` | User-owned boxes set up once | Upstream `bounded` with the owner's manifest (`cmux computer-use setup`): in scope runs silently; anything else asks through the device hub, or is refused when nobody can answer. |
| `unrestricted` | Disposable cmux VMs | Upstream `unrestricted`, which needs both `CUA_DRIVER_PERMISSION_MODE=unrestricted` and `CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS=1` in the host's service configuration, owned by root (Linux), SYSTEM (Windows) or written by the app (macOS). No prompts; hard invariants, the indicator, revocation and audit remain. |

The driver is created with the ceiling `allowed_modes` = the configured mode
(plus `bounded` under `ask`), `unrestricted_acknowledged` only for
`unrestricted`. A running worker never changes mode; a mode change restarts
the worker. On Windows and Linux the host reads the owner's config once and
gives the worker that reading; `cmux computer-use setup` asks the running host
to reload after it writes the file (`computer_use.reload`, docs/cmux-remote.md
"Mode and collectors"), and `computer_use.status` reports the reading in
force with `pending_reload` while the file differs.

## Sessions

- One admitted connection to the worker's socket is one agent session (the
  acpmux `cua-mcp` bridge runs once per agent session). Its authority is
  bound to the connection: a trusted upstream session
  (`cua_driver_session_create_v1`) created at admission and destroyed when the
  connection closes, which revokes its grants. No request field selects a
  session.
- After admission the bridge sends `{"id":0,"method":"session/hello","params":{"agent":S,"workspace":S,"client":S}}`.
  These are display labels for the approval card, set by acpmux from the
  session it spawned, never authority. acpmux marks them at spawn (agent: the
  harness, `claude`; workspace: the session folder's name; client: `cmux` for
  an agent chat, `cli` for `cmux computer-use`) in the bridge's own env
  (`ACPMUX_CUA_LABEL_AGENT|WORKSPACE|CLIENT`, after any profile or preset,
  never in the harness's env). Each label is one printable line of at most 80
  characters. The worker answers `{"id":0,"ok":true}`; the bridge skips any
  reply with id 0, so an older worker that refuses the method still works.
- Under `ask` the session's manifest (version 3) allows every tool in the
  driver's inventory except opaque dispatch (`run_script`,
  `replay_trajectory`), `resources.desktop.display: false`,
  `resources.apps` = the apps granted to this session plus the client's saved
  list, `expires_after` = the session TTL (8h), `idle_timeout` = 30m. A grant
  writes a new manifest (0600, private directory) and replaces the session
  handle between calls.

## Discovery before approval

The pinned driver classes `list_apps` and `list_windows` as private desktop
observation (R2). An `ask` session's manifest has `desktop.display: false`, so
upstream refuses both without a pid, and with the pid of an app outside the
manifest (`bounded_resource_outside_manifest`). An agent could then never find
a target and reach the question below. So the worker answers these calls
itself, with metadata only (decision D21; trust note on cmux#13742):

| Call | Under `ask`, and `bounded` outside the owner's apps | Otherwise |
| --- | --- | --- |
| `list_apps` with no target | the worker: each app with a window, `{pid, name, bundle_id \| executable, running}` | upstream |
| `list_windows` with no `pid` | the worker: `{window_id, pid, app_name, bundle_id \| executable}` per window | upstream |
| `list_windows {pid}` of an app this session may not use | the worker, that pid's windows only | upstream |
| `list_windows {pid}` of an app this session may use, and every other tool | upstream, unchanged (titles included) | upstream |

- No window title, icon, frame, position, screenshot or accessibility tree.
  The result has upstream's shape (MCP `content` text plus
  `structuredContent`), with `"titles": "hidden until you are allowed to use the app"`
  and `"source": "cmux"`; the text tells the agent to call the tool it needs
  with the app's pid, which asks the person.
- Never-allowed apps (Rules: cmux, Cua, password managers, login and
  security UI, system settings, terminals the owner did not allow) are left
  out entirely. A `list_windows {pid}` of one is refused `target_refused`, as
  any call on it.
- Discovery never asks the person, never runs the driver, and never grants
  anything: titles, pixels and input still need the per-app answer.
- `bounded`: when the owner's manifest grants `resources.desktop.display:
  true`, upstream answers discovery; "the owner's apps" are its
  `resources.apps` plus this session's grants and the saved list. On macOS a
  manifest that is not JSON leaves discovery to upstream.
- `standard` and `unrestricted`: unchanged; upstream answers (the mode
  permits display observation).
- The worker also resolves a call's `window_id` through its own window list,
  so a call that names only a window reaches the question for its app.

How each OS is listed, reading no title:

| OS | Windows | Apps |
| --- | --- | --- |
| macOS | `CGWindowListCopyWindowInfo`, layer 0, `kCGWindowOwnerPID` and `kCGWindowNumber` only (never `kCGWindowName`) | the window owners' `NSRunningApplication` with activation policy regular (no process list) |
| Linux X11 | `_NET_CLIENT_LIST` on the root window, each window's `_NET_WM_PID` (else the X Resource extension's client pid); never `WM_NAME` / `_NET_WM_NAME` | the window owners, `/proc/<pid>/exe` |
| Linux Wayland | none: a Wayland client cannot list other clients' windows; `list_windows` returns `windows: []` with `windows_unavailable` | this user's processes with `WAYLAND_DISPLAY` or `DISPLAY` in their environment, one per executable |
| Windows | `EnumWindows`: visible, unowned, not `WS_EX_TOOLWINDOW`; `GetWindowThreadProcessId` (never `GetWindowText`) | the window owners, `QueryFullProcessImageNameW` |

What an agent learns before any approval: which regular apps run and how many
windows each has, not what is in them. The documented limit stands: an agent
that runs arbitrary code as the same user can list processes itself.

## The approval question

When a call targets an app outside the session's manifest, the worker
resolves the real target (pid, window or bundle id, `CuaTargetGuard`; never
the agent's words), then asks the host. Wire: JSON lines on the host consent
link (macOS app) or the `remote-host-v1` supervisor link (Windows, Linux).

worker → host:

```json
{"type":"app_approval","id":7,"request":{
  "v":1,"nonce":"<32 hex>","client":"com.cmuxterm.app.debug.cu1",
  "machine":"<device id or hostname>","session":"<opaque connection id>",
  "agent":"Claude","workspace":"api-server",
  "target":{"bundle_id":"com.apple.Safari","executable":null,"name":"Safari"},
  "tool":"click","risk":"R1",
  "created_ms":1793400000000,"wait_until_ms":1793400120000,"answerable_until_ms":1793400600000,
  "digest":"<64 hex: sha256 of the canonical JSON of this object without digest>"}}
```

host → worker: `{"type":"app_approval","id":7,"ok":true,"decision":"once"|"session"|"always"|"deny","digest":"…","via":"mac"|"phone"|"polkit"|"windows-hello"}`
or `{"type":"app_approval","id":7,"ok":false}` (no collector, cancelled).

worker → host: `{"type":"app_approval_cancel","id":7}` when the session ends.

host → worker, any time: `{"type":"approved_apps","apps":[{"bundle_id"|"executable","name"}]}`
(the client's saved list, replacing the previous one) and
`{"type":"revoke","scope":"all"|"app","app":{…}}`.

Canonical JSON: keys sorted by their UTF-8 bytes at every depth, no
whitespace, UTF-8; strings escape only `"`, `\` and characters below U+0020
(`\b \f \n \r \t` by name, the rest `\u00xx` lowercase), so `/` and
non-ASCII stay as they are (Swift: `.withoutEscapingSlashes`); numbers are
integers only (a float is refused). The same bytes in Swift and Rust
(`cmux-tui/crates/cmux-computer-use-approval`; `schemas/computer-use/approval-fixtures.json`,
`{"version":1,"cases":[{"name","request","canonical","digest"}]}`, is the shared
conformance fixture, where `request` has no `digest` key).

Rules:

- A refused call answers the bridge `{"id":N,"ok":false,"code":"approval_timeout"|"approval_denied"|"approval_pending",
  "error":"<text>","target":{"name":"Safari"}}` (`target` optional, for the
  agent's text only). The bridge also reads the code from `error.code` or a
  bare `error` of that code. It turns them into the MCP tool error
  `computer_use.approval_*` (acpmux `cua_v2/approval.rs`) that says the person
  was asked and what to do now, and keeps the connection, so the session's
  grants (and a late Allow) survive. A worker refusal never closes the
  connection; only a broken connection does.
- The call waits until `wait_until_ms` (2 minutes), then fails with
  `approval_timeout`. The question stays answerable until
  `answerable_until_ms` (10 minutes): a later Allow grants the session (or
  saves the app), so the agent's retry runs.
- `once` runs this call only; `session` adds the app to this session's
  manifest; `always` adds it to the client's saved list (per cmux client:
  stable, NIGHTLY, RC and each DEV tag keep separate lists) and this session;
  `deny` refuses this call with `approval_denied`. One question per session ×
  app at a time; parallel calls join it.
- A decision whose digest differs, a second answer, or one after
  `answerable_until_ms` is ignored.
- Never asked, always refused (hard invariants, `CuaTargetPolicy`): Cua's
  and cmux's own UI, password managers, the login window, security agents,
  System Settings, and terminals or cmux builds not explicitly allowed.

## Collectors

| Machine | Collectors (first valid answer wins) |
| --- | --- |
| macOS with the cmux app | The app's approval card (Allow Once, Allow for This Session, Always Allow <App>, Deny); a phone push to the owner's iPhone |
| Linux desktop session | polkit action `com.cmux.computer-use.approve` (system authentication dialog, one at a time; `approvals pending` marks the question on screen), plus the owner's pinned iPhone through the device hub |
| Windows interactive session | Windows Hello consent (`UserConsentVerifier`) in a host-owned window, one at a time (closing it is no answer, not a deny), plus the owner's pinned iPhone through the device hub |
| Headless box or VM | Only the owner's other devices through the device hub |

Phone choices: Allow Once, Allow for This Session, Deny as notification
actions (Allow opens the app for Face ID, as other phone approvals do).
"Always Allow <App>" from the phone is a Computer Use-only exception to the
rule that a paired phone never makes a lasting grant: it needs Face ID and
the setting `computerUse.phoneAlwaysAllow` (default off), and its trust note
is on cmux#13742.

## Device hub approvals (Windows, Linux, VMs)

Every machine that runs cmux-tui with Computer Use registers as a device on
the device hub (`docs/device-hub/PROTOCOL.md`), with its own keys (macOS:
Secure Enclave; Windows: TPM-backed CNG; Linux: the Secret Service keyring,
or a 0600 key file on a headless box, reported as lower assurance).

- `POST /v1/approvals` `{request}` from the asking device (device-signed).
  The hub stores it until `answerable_until_ms` and pushes
  `{type:'approval.request', approval:{id, deviceId, request}}` to the user's
  other devices (User DO socket and phone push).
- `POST /v1/approvals/:id/decision` `{decision, digest, sig}` from another
  device of the user (403 `self_approval` from the asking device). `sig` is
  the deciding device's ECDSA-P256-SHA256 (base64 raw r||s) over
  `"cmux-cu-approval-v1\n<digest>\n<decision>"`, with the key below. The hub
  pushes `{type:'approval.decided', id, decision, digest, deciderId, sig}` to
  the asking device.
- **Which key signs.** An Allow (`once`, `session`, `always`) is signed only
  by the decider's **approval key**; a `deny` is signed by its device
  `signingKey`. The approval key is a P-256 key separate from the device keys
  whose every use needs the person at the OS level: on iPhone (and on a Mac
  once the macOS app registers one; it does not yet) a Secure Enclave key made with access control
  `.privateKeyUsage` + `.userPresence`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  (Face ID or the passcode before each signature, the same protection as the
  phone's Mac approval key in `verify/phone-approvals.md`). Code running in the
  app cannot sign an Allow without the person; Deny stays cheap because it only
  refuses. The canonical message is the same for both keys.
- **The device record.** An approver registers it in `POST /v1/devices` as
  `approvalKey` (base64 of the 65-byte X9.63 uncompressed point, like
  `signingKey`); `GET /v1/devices` and every device JSON return it
  (`approvalKey`, `null` when the device has none). The hub keeps a device's
  first approval key: another one for the same id is 409
  `approval_key_mismatch` (the iPhone app then makes a new device id), a
  registration without one keeps the stored one, and a device registered before
  approval keys adds one later under the same id. Only `macos`/`ios` may send
  one, and never equal to its `signingKey` (400). The hub verifies an Allow
  with `approvalKey` (403 `approval_key_required` when the device has none)
  and a Deny with `signingKey` (400 `bad_decision_signature` otherwise).
  The hub cannot tell that a registered key needs presence: registration is
  signed only by the signing key, so code holding that key could register a
  software approval key on a device that has none yet. The guarantee is the
  asking machine's pin of a fingerprint the owner compared on the phone; a
  machine that verifies Allows without pins trusts the hub.
- One Face ID check signs one Allow, for the digest that was on screen: the
  iPhone app re-reads the approval before signing and refuses one whose digest
  changed, and the evaluated `LAContext` is invalidated after the signature.
- **The fingerprint a box pins**: the lowercase hex SHA-256 of the approval
  key's 65 X9.63 bytes (the bytes `approvalKey` base64-decodes to), the same
  rule as `viewerKeyFingerprint` applied to the approval key. People compare
  its first 32 hex digits, uppercase, in eight groups of four (`1A2B 3C4D …`,
  Swift `DeviceIdentity.displayFingerprint`, Rust
  `display_fingerprint(key_fingerprint(..))`). The iPhone shows its own in
  Settings → Computer Use → Approval key (copyable; "No approval key" when it
  has none), to compare with what setup prints. Both sides reproduce
  `schemas/computer-use/approval-key-fingerprint-vector.json`
  (`{key_base64, fingerprint_hex, display}`).
- The asking device verifies before it applies a decision; the hub's word
  alone never grants. For an Allow: the decider is not itself, it is a
  `macos`/`ios` device in `GET /v1/devices`, the SHA-256 of its `approvalKey`
  bytes is one of the approver fingerprints the owner pinned on this machine,
  and `sig` verifies with that `approvalKey`. A device without `approvalKey`,
  or whose key is not pinned, never grants. A `deny` may be applied after
  checking `sig` against the decider's `signingKey` (it only refuses).
  Swift: `ComputerUseApprovalDecided.verifies(decider:)` picks the key by
  decision; the pin check is the box's.
- **Pinned approvers.** The hub's word alone never grants; only pinned approvers do. The box
  owner pins each approver on the box (`cmux computer-use setup --approver
  <device id>`, elevated): setup reads the account's devices as the box's own
  device, shows each chosen device's name, platform and **approval key**
  fingerprint (the lowercase hex SHA-256 of the 65 X9.63 bytes its
  `approvalKey` decodes to, shown as the iPhone shows it in Settings → Computer
  Use: the first 32
  hex digits, uppercase, in eight groups of four) and asks the owner to type
  `yes` once it matches. The typed `yes` is only a check (an agent in that
  terminal could type it); the gate is the elevation that writes
  `{device_id, approval_key_fingerprint}` into the root- or SYSTEM-owned
  config: `sudo -k` (always asks for the password, never a cached ticket) or
  UAC. A device with no `approvalKey` is refused; for now that is every Mac
  (the macOS app registers no approval key yet), so only iPhones can be pinned. An Allow (`once`, `session`, `always`) applies only when the
  decider is a pinned `macos`/`ios` device whose `approvalKey` in
  `GET /v1/devices` (used only to fetch it) still has the pinned fingerprint
  and `sig` verifies with that key; a `deny` applies when `sig` verifies with
  the decider's `signingKey` (it only refuses). The decider is never the
  asking device. A device registered on the hub with any platform and a valid
  signature (a stolen account session, another of the user's boxes, a
  compromised hub) cannot allow unless the owner pinned its approval key; an
  Allow signed with a device's signing key, or by a pinned device whose
  approval key the hub now lists differently, is refused. No pinned approver
  means no hub collector (fail closed; `computer_use.status` says why under
  `device_hub`). Rust: `cmux-device-hub-client` `verify_decision` and
  `pin_of`; the host's collector is `cmux-remote-host/src/hub.rs`.
- `GET /v1/approvals/:id` returns the state after a reconnect.
- Only the user's Macs and iPhones answer (403 `not_approver` for a Windows
  or Linux machine). `POST /v1/approvals` carries `allowAlways`, the asking
  machine's `computerUse.phoneAlwaysAllow`; without it the hub refuses
  `always` and approvers do not offer it. The full API, the canonical JSON
  rules, `approval.closed`, cancel, expiry and the APNs payload are in
  `docs/device-hub/PROTOCOL.md`, "Computer Use approvals"; the Rust client is
  `cmux-tui/crates/cmux-device-hub-client`.

## Controls

| Control | CLI | MCP | Palette |
| --- | --- | --- | --- |
| Status: mode, sessions, grants, collectors | `cmux computer-use status` | `cua_status` | Computer Use: Show Status |
| Driver tools | `cmux computer-use tools`, `call <tool> --args JSON`, `screenshot --out FILE` | `cua_*` | |
| Saved approvals | `cmux computer-use approvals list\|revoke <app>\|revoke --all` | `cua_approvals_list`, `cua_approvals_revoke` | Computer Use: Revoke Saved App Approvals… |
| Pending questions | `cmux computer-use approvals pending\|approve <id>\|deny <id>` | none (an agent never answers) | the card |
| Mode | `cmux computer-use setup --mode …` (on the box, elevated) | read only | Settings |

`approvals approve` from the CLI opens the app's card (macOS) or the local
collector; it never decides by itself.

## Phone wire (macOS)

On a Mac with the cmux app, the phone collector rides the iPhone host
(`cmux-mobile-host`, "hostd"), the same path that carries agent permission
pushes and their Face ID signed replies (`cmux-next-ios/PROTOCOL.md`, "Push
notifications", "Phone actions", "Reply mailbox"). The app stays the one that
decides: hostd forwards, the app checks the signature again with its own copy
of the phone's paired approval key before an answer counts.

### App → hostd (stdin control lines)

- `{"type":"cu_approval","request":{…},"always":true|false}`: ask every paired
  phone of the signed-in owner. `request` is the worker's request object
  byte for byte as parsed (the contract's fields, `digest` included). `always`
  is true only while `computerUse.phoneAlwaysAllow` is on. The app sends it
  again to a restarted hostd while the question is pending; the same `digest`
  twice is the same question.
- `{"type":"cu_approval_done","digest":"<64 hex>"}`: the question was answered
  (on the Mac card or by a phone), cancelled by the worker, or passed
  `answerable_until_ms`. hostd drops it; a later answer for it is refused
  `not_pending`.

### hostd → Worker (`POST /v1/devices/:macId/notify`)

- `kind`: `computer_use` (new). `eventId` and `permissionId`: `cu-` + the
  first 32 hex digits of `digest`. `agent`, `workspace` as in the request,
  `title`: the target's `name`, `state`: `waiting`.
- `computerUse`: `{"request":{…},"always":bool}`, the request object as the app
  sent it, so the phone shows exactly what the Mac asks and recomputes the
  digest (canonical JSON, contract above) before it offers an Allow. A sealed
  push carries the same object inside `box`.
- APNs `category`: `CMUX_MOBILE_COMPUTER_USE`. Banner: "<agent> wants to use
  <name>", subtitle "<workspace> · <Mac>".

### Phone actions

| Identifier | Options | Delivery |
| --- | --- | --- |
| `cmux.cu.once` | foreground, authenticationRequired | the app opens, Face ID, signed `once` |
| `cmux.cu.session` | foreground, authenticationRequired | the app opens, Face ID, signed `session` |
| `cmux.cu.always` (only when `always` is true) | foreground, authenticationRequired | the app opens, Face ID, signed `always` |
| `cmux.cu.deny` | destructive, authenticationRequired | background, unsigned `deny` |

The signature: the phone's **approval key** (Secure Enclave,
`.privateKeyUsage` + `.userPresence`, `verify/phone-approvals.md`), so every
signature is a Face ID (or passcode) check. ECDSA P-256 / SHA-256, raw
`r || s` as lowercase hex, over

```
cmux-cu-phone-approval-v1 \0 phone \0 digest \0 decision \0 expiresAt
```

`phone` is the phone's link device id, `decision` one of `once`, `session`,
`always`, `deny`, `expiresAt` Unix seconds as a decimal string (the phone uses
now + 120 s). `deny` is sent unsigned (narrowing needs no proof).

### Phone → hostd

- Over the link, on the `daemon` channel: `cu-approval-answer
  {digest, decision, expires_at, signature?}`, answered by hostd itself (as
  `notification-reply`); `phone` is the link's device id, never an argument.
- Through the reply mailbox: `kind` `computer_use`, `target` `{digest}`,
  `action` `{type: "allow" | "deny", optionId: "once" | "session" | "always" | "deny"}`,
  `approval` `{approver, expiresAt, signature}` (absent for `deny`).

hostd checks that the phone is paired, the digest is a pending `cu_approval`,
`always` only when that question allowed it, `now <= expiresAt <= now + 300`,
and the signature with that phone's paired approval key; then it answers the
phone `{ok}` (else `not_paired`, `not_pending`, `refused`, `expired`,
`bad_signature`) and tells the app:

### hostd → App (stdout event)

```json
{"type":"cu_approval_answer","phone_device_id":"<link device id>","digest":"<64 hex>",
 "decision":"once"|"session"|"always"|"deny","expires_at":1793400120,"signature":"<128 hex>"}
```

(`signature` absent for `deny`.) The app applies it only when the digest is
still pending on this Mac, before `answerable_until_ms`, with an allow's
signature valid for that phone's approval key in the app's own paired list
(`MobileHostPairedDevices`), and an `always` only while
`computerUse.phoneAlwaysAllow` is on; otherwise it drops it. The first valid
answer from any collector wins; the app then sends `cu_approval_done`.

## Mac app wire (worker configure, socket)

- The worker's mode and client are fixed when it starts, never by a
  `configure` line: `CMUX_COMPUTER_USE_MODE` (`ask` | `standard` | `bounded`
  | `unrestricted`, `computerUse.mode`) and `CMUX_COMPUTER_USE_CLIENT` (this
  app's bundle id, the value the worker puts in each request's `client`; the
  app refuses a question for any other client). The in-app helper gets them in
  the environment the app starts it with. Through cmux Remote the app's
  `computer-use` channel open carries `"permission_mode"` and `"client"`; the
  host refuses a mode outside the four (`bad_request`) and a client other than
  the signing identifier of the app's running code, read by the connection's
  audit token (`refused`), then starts the worker with both in its
  environment. The worker's `ready` line reports `permission_mode` and
  `client`, and the app stops a worker that reports any other pair. A mode
  change stops the worker's channel and opens a new one (cmux Remote starts a
  new worker) with the new value.
- The app also refuses, without asking anyone, a question whose
  `answerable_until_ms` is more than 11 minutes after `created_ms` or after its
  own clock, and one whose target is cmux itself (its own bundle id or any
  `com.cmuxterm.*`).
- The card has no Return default and no Command key on an allow: Escape is
  Deny, and an allow needs a click. A card panel takes the keyboard only after
  the person clicked it.
- App socket methods (Lane 3's CLI and MCP): `computer_use.approvals.list`
  → `{client, apps:[{bundle_id|executable, name, added_ms, via}]}`;
  `computer_use.approvals.revoke {app?: {bundle_id|executable}, all?: true}`
  → `{revoked: n}` (sends `revoke` to the worker); `computer_use.approvals.pending`
  → `{pending:[{id, digest, agent, workspace, client, target, tool, risk,
  wait_until_ms, answerable_until_ms}]}`; `computer_use.approvals.prompt {id}`
  shows that question's card again (it never decides). `id` is the first 16
  hex digits of the digest. `computer_use.mode.set {mode}` writes
  `computerUse.mode`: a lower mode at once, a higher one only after the person
  confirms a cmux dialog (`{ok:false, declined:true}` otherwise).
  `computer_use.status` → `{mode, phone_always_allow, saved, pending, worker}`.
### How the CLI and MCP reach it

Status and approvals (CLI and MCP share one code path,
`cmux-tui/src/cli/mcp/computer_use_tools.rs`) are daemon commands
`{"cmd":"remote-host-call","method":M,"params":P}` that the daemon forwards to
the host, which answers from its state or asks the worker:

| `M` | `P` | Who may call |
| --- | --- | --- |
| `computer_use.status` | `{}` | any local Unix connection |
| `computer_use.approvals.list` | `{}` | any local Unix connection |
| `computer_use.approvals.pending` | `{}` | any local Unix connection; each entry has `on_screen` (the question the local dialog shows), and `on_screen` at the top level is its id or null |
| `computer_use.approvals.revoke` | `{"all":true}` or `{"app":{"bundle_id"\|"executable":S}}` | any local Unix connection (lowers) |
| `computer_use.approvals.deny` | `{"id":S}` | any local Unix connection (lowers) |
| `computer_use.approvals.prompt` | `{"id":S,"decision"?:"once"\|"session"}` | any local Unix connection; shows the question again with the dialog's own choices (never `always`, which only the phone or Mac offers), decides nothing; one question at most once every 10 s (`cooldown`); refused while a dialog is up (`dialog_up`); `ended` when the question ends while its dialog is up (the dialog closes, its answer is ignored) |

The daemon refuses every other `computer_use.*` method with
`origin.forbidden` (`cmux-tui-core/src/server/remote_host_command.rs`): no
command approves, saves an app or raises the mode. `computer_use.reload` is
refused there too; the elevated `setup` asks the host itself. On macOS `approve` calls
the app's `computer_use.approvals.prompt {id}` instead, which shows the card.

The driver's tools from the CLI (`tools`, `call`, `screenshot`) go through the
acpmux daemon: `_acpmux/computer_use_mcp {"message": <MCP tools/list or
tools/call request>}`, local Unix socket only, answered with the MCP response.
The daemon runs one `acpmux cua-mcp` bridge child of its own
(`acpmux/src/cua_v2/cli_bridge.rs`), so the worker's admission is unchanged:
the peer is acpmux code, its ancestor is the registered acpmux daemon, and it
presents the secret from `endpoint.json`, which the CLI never sees. That child
is one session labelled `{"agent":"cmux computer-use","client":"cli"}` for
every CLI caller of the daemon: Allow for This Session covers later CLI calls,
and a late Allow lets the next call run. Calls run one at a time; one that
waits for the person holds the next for at most 2 minutes. The session ends
with the daemon or when the worker ends it.

Residual (the same documented limit as above): any local process of the user
can reach `_acpmux/computer_use_mcp`, including an agent's own shell, so an
agent can use the `cli` session and any app the person allowed for it. It gets
no more than the person granted that session, every new app still asks the
person (labelled `cmux computer-use`, client `cli`), and the person's Revoke
or Deny applies to it. A per-caller session needs a caller identity the daemon
can verify; it is not in this version.

### `setup` on Linux and Windows

`cmux computer-use setup --mode M [--manifest FILE] [--i-understand-unrestricted]
[--device-hub URL --hub-token-command PROGRAM [--hub-allow-always] --approver DEVICE_ID...]`
writes the TOML the host reads (`cmux-remote-host` `config.rs`; one file, one
schema): `mode`, `manifest` (the path of the owner's capability manifest,
copied next to the config), `[environment]` with upstream's two-part opt-in for
`unrestricted`, `[device_hub]` (`url`, `token_command`, `allow_always`) and the
pinned `[[approvers]]` (`device_id`, `approval_key_fingerprint`, `name`,
`platform`). `schemas/computer-use/setup-config` holds what setup writes; the
CLI renders each case and the host parses each file in their tests.

| OS | Files | Writer |
| --- | --- | --- |
| Linux | `/etc/cmux/computer-use.toml`, `/etc/cmux/computer-use.manifest.yaml` (0644, in a root-owned 0755 folder; refused if the folder is not root's or is group/world writable) | root; otherwise `sudo -k` from a terminal |
| Windows | `%ProgramData%\cmux\computer-use.toml`, `…\computer-use.manifest.yaml` (folder owned by Administrators, ACL SYSTEM and Administrators full, Users read, inheritance off) | an elevated administrator or SYSTEM; otherwise UAC from a terminal |

`--approver` (repeatable) reads the account's devices from the hub as this
user's device (the one cmux Remote uses), shows each chosen device's name,
platform and approval key fingerprint, and asks the person to type `yes` once
each matches the iPhone's (Settings → Computer Use → Approval key); it then elevates with the confirmed pins. sudo or
UAC is the gate; the `yes` is only a check that the person compared. Only
another device of the account with an approval key can be pinned, which for
now means an iPhone (the macOS app has no approval key yet). After writing,
the elevated run asks the running host to reload (`--reload-endpoint`, from
`computer_use.status`), and the non-elevated run reports whether the host has
the new config in force (`host.in_force`); without a running host it applies
when the host starts. Root's provisioning can pass
`--approver-pin '{"device_id","approval_key_fingerprint","name","platform"}'`
directly; a non-root run refuses it. A setup without approver flags keeps the
current `[device_hub]` and approvers. `token_command` is a program that prints
the account's access token (bare or `{"access_token"}`), run as the person's
user.

`bounded` needs `--manifest` (a JSON object with `"version": 3`, which is
also YAML), and only `bounded` takes one. `unrestricted` needs both upstream env vars set in the
invoking shell and `--i-understand-unrestricted`. Without a terminal and
without root/elevation, setup refuses; it never writes a file the user owns.
The host must read the file only when its owner and ACL are as above. On
macOS, `setup --mode M` is `settings.set computerUse.mode` with
`confirm: true`: the app asks the person before a raise.

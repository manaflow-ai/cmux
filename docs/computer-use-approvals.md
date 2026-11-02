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
| `ask` (default on a person's Mac or desktop) | Personal machines | Each agent session starts as an upstream `bounded` session whose manifest lists no app. A call on an app outside it asks the person (below); an answer grows that session's manifest, or the client's saved list. |
| `standard` | Owners who want upstream's default | Upstream `standard`: routine observe and input run without prompts; only residual boundaries ask. |
| `bounded` | User-owned boxes set up once | Upstream `bounded` with the owner's manifest (`cmux computer-use setup`): in scope runs silently; anything else asks through the device hub, or is refused when nobody can answer. |
| `unrestricted` | Disposable cmux VMs | Upstream `unrestricted`, which needs both `CUA_DRIVER_PERMISSION_MODE=unrestricted` and `CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS=1` in the host's service configuration, owned by root (Linux), SYSTEM (Windows) or written by the app (macOS). No prompts; hard invariants, the indicator, revocation and audit remain. |

The driver is created with the ceiling `allowed_modes` = the configured mode
(plus `bounded` under `ask`), `unrestricted_acknowledged` only for
`unrestricted`. A running worker never changes mode; a mode change restarts
the worker.

## Sessions

- One admitted connection to the worker's socket is one agent session (the
  acpmux `cua-mcp` bridge runs once per agent session). Its authority is
  bound to the connection: a trusted upstream session
  (`cua_driver_session_create_v1`) created at admission and destroyed when the
  connection closes, which revokes its grants. No request field selects a
  session.
- After admission the bridge sends `{"id":0,"method":"session/hello","params":{"agent":S,"workspace":S,"client":S}}`.
  These are display labels for the approval card, set by acpmux from the
  session it spawned, never authority.
- Under `ask` the session's manifest (version 3) allows every tool in the
  driver's inventory except opaque dispatch (`run_script`,
  `replay_trajectory`), `resources.desktop.display: false`,
  `resources.apps` = the apps granted to this session plus the client's saved
  list, `expires_after` = the session TTL (8h), `idle_timeout` = 30m. A grant
  writes a new manifest (0600, private directory) and replaces the session
  handle between calls.

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

Canonical JSON: keys sorted, no whitespace, UTF-8; the same bytes in Swift
and Rust (`schemas/computer-use/approval-fixtures.json` is the shared
conformance fixture).

Rules:

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
| Linux desktop session | polkit action `com.cmux.computer-use.approve` (system authentication dialog), plus the owner's phone and Mac through the device hub |
| Windows interactive session | Windows Hello consent (`UserConsentVerifier`) in a host-owned window, plus phone and Mac through the device hub |
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
  the deciding device's ECDSA-P256-SHA256 over
  `"cmux-cu-approval-v1\n<digest>\n<decision>"`. The hub pushes
  `{type:'approval.decided', id, decision, digest, deciderId, sig}` to the
  asking device.
- The asking device verifies `sig` with the decider's registered signing key
  (`GET /v1/devices`) and that the decider is not itself before it applies the
  decision; the hub's word alone never grants.
- `GET /v1/approvals/:id` returns the state after a reconnect.

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

- The app passes the mode and its client to the worker in its `configure`
  line: `"permission_mode": "ask" | "standard" | "bounded" | "unrestricted"`
  (`computerUse.mode`) and `"client": "<this app's bundle id>"`, the value the
  worker puts in each request's `client` (the app refuses a question for any
  other client). A mode change stops the worker's channel and opens a new one
  (cmux Remote starts a new worker) with the new value.
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

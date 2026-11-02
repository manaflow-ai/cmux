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

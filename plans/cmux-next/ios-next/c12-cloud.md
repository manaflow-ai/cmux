# C12 `cloud`: Cloud VMs on the phone

Status: lane C12 of PLAN.md, 2026-10-06. Branch `feat-cmux-next-ios-c12-cloud` off `feat-cmux-next-ios`.
Binding: PLAN.md section 4, OWNERSHIP-PRINCIPLES.md, cloud-client-contract.md (sections 1.1 to 1.7, pause
and snapshot notes), a1-shell.md (parity 1.1, 1.5, 1.7, 1.8, 1.16), b1-control-do.md, b5-mac-host.md
(phase 2 note), b6-pairing.md, c5-workspaces.md (`WorkspaceHostDirectory`).

## 1. Ownership

| State | Owner | On the phone |
| --- | --- | --- |
| Machines, status, size, host binding, pause reason, plan and usage | `CloudDO` (one per team, stream `cloud:<team>`) | confirmed mirror + one ordered intent log |
| Peer data (WireGuard key, overlay address, epoch, services) | `CloudDO` + `TeamDO` peer map | read on dial only (`connect_info`), never stored |
| Dial credential | `CloudDO` mints per dial (`cloud.machine.link_token`, install principal, grant `cloud-link`) | used for one `hello`, never cached or logged |
| VM terminals, workspaces | the VM's session host and workspace store (cmux-tui on the VM) | C5 mirror, like a Mac |
| Selected machine, sheet drafts, sort | this client | view state |

The phone never infers a machine's state: start, pause, delete and create are ops; rows change on the
owner's `cloud.machine.upsert` / `cloud.machine.removed` (or the op result, which carries the same
committed record and revision). While an op is in flight the intent log overlays the transitional
status (`starting`, `pausing`, `deleting`, the new name); the intent leaves the log on the reply.

## 2. How a phone reaches a Cloud VM

Two planes, as for a Mac (PLAN.md section 1).

Control plane, live now:

- Reads `POST /v1/read` (`cloud.machine.list` pages, `cloud.plan.get`) as this install (grant `read`).
- Events: `GET /v1/wire/cloud` (`cmux.wire.v1, bearer.<install token>`), frame `subscribe`. The snapshot
  carries the head only (`{team, rev, active, saved}`); the phone then reads the list. Live events carry
  `event: cloud.machine.upsert {machine}` or `cloud.machine.removed {machine, revision}` (and snapshot
  events); events without extras (ledger-only commits) only advance `seq`. A seq gap sends
  `snapshot.request`, whose snapshot triggers one re-read. No polling: the plan is re-read only after a
  machine change, coalesced to one read in flight.
- Mutations `POST /v1/ops` with one idempotency key per user intent, reused on retry, origin `user`.
  `cloud.machine.create`, `delete`, `start`, `pause` need a signed-in person (`principal.kind ==
  session`, domains/cloud.ts), so the phone sends them with the Stack session token, not the install
  token. `mutation.indeterminate` retries the same key (at most 3 times; the Worker itself waits 25 s
  for the provider), never a new key.
- Contract names: "stop" and "hibernate" are both `cloud.machine.pause` (Freestyle pause keeps memory
  and disk; there is no separate stop). The app says Pause / Resume.

Stream plane (terminals, workspaces, files), needs the VM link host:

- The VM is a link host exactly like a Mac: the phone speaks `cmux.mobile/1` over `CmuxLink` (A0, A3)
  to the VM daemon, and C5/C1/C4 work unchanged on top.
- Carrier: in-app userspace WireGuard (B3's `CmuxLinkWG` engine) keyed by `connect_info.peer`
  (`wg_public_key`, `overlay_address`, `epoch`). The VM already terminates WireGuard (`cmux-wg`, UDP
  4101). Underlays, in path order: (a) plain UDP to `peer.public_ipv6:4101` when the team policy opened it
  for this install's /128 (no rendezvous, the V3 shape); (b) the V2 WebRTC data channel to the VM with
  signaling through `HostDO` and Cloudflare TURN, which reaches a VM with no public address. The VPC
  endpoint (`peer.vpc_endpoint`) and the Freestyle `gateway` tunnel are for VPC members (Macs with the
  hub); a phone is never in the VPC, so direct VPC dialing is out.
- Auth: the phone mints `cloud.machine.link_token {host, services: [daemon]}` per dial and sends it in the
  link `hello`; the VM daemon's verifier checks it (cloud-client-contract.md 1.7). The phone pins the VM
  by its WireGuard key and epoch from `connect_info`. A paused machine answers `cloud.machine.paused`:
  the phone asks "Resume machine?" and runs `cloud.machine.start`; nothing starts a machine on connect.
- Control-plane presence for C5: the VM daemon joins `HostDO` as the host of its own `host_…` id, so
  `host:` presence and the `workspace:` mirror flow to the phone through C5's existing
  `ControlPlaneWorkspaceChannelFactory` with no phone change.

## 3. Decision: the CloudVPN packet-tunnel extension is dropped

The shipping app's `ios/CloudVPN` (`NEPacketTunnelProvider`, wg-quick config in a shared Keychain, the
"Cloud System VPN") is not carried into the new app. Reasons: iOS runs one packet-tunnel VPN at a time,
so it fights Tailscale and corporate VPNs (cloud-ios.md 3.2); it needs the Network Extension entitlement,
an extension target and App Review justification; and every cmux feature that needs the VM (terminals,
workspaces, files, port forwards for the in-app browser, C14) rides the in-app link above. What is lost:
other apps (Safari, third-party SSH clients) reaching VM ports through the system VPN. If users ask for
it, the follow-up is an opt-in extension that embeds the same `CmuxLinkWG` engine, not the wg-quick one.

## 4. Phase 2: the Rust host on the VM (dependency, not built here)

Everything in section 2's stream plane needs the VM side, which is Rust and is not built in this lane:

1. `cmux-link-session` crate: the CmuxLink session machine in Rust (channels, credit, revisions, close,
   resume), passing A3's `LinkFrame` golden vectors (b5-mac-host.md phase 2 note).
2. `cmux.mobile/1` services from the daemon, matching B5's Swift `MobileChannelHandler` contract: the rpc
   channel with the `workspace:<host>` projection of the VM's cmux-tui store plus `workspace.rename`,
   `workspace.tab.close`, `workspace.close`, `workspace.read` behind a default-deny policy; terminal
   channels over `attach-surface` GHOSTSNP; `files.*` later (C4 contract).
3. Carrier on the VM: B3's lane ARQ (overlay IPv6/UDP 4104) in Rust next to `cmux-wg`, accepting the
   phone's WireGuard key from its B6 `wg` link cert through the `TeamDO` peer map; then a WebRTC data
   channel endpoint (webrtc-rs or libdatachannel) for underlay (b).
4. `HostDO` admits a `vm` install as `host` for its own bound host id (the backend admission boundary is
   now landed; the Rust uplink still has to publish `host:` presence and `workspace:` snapshots and
   events through a Rust `HostControlUplink`).
5. The link-token verifier gates G1 and G2 (F1, F2) before any daemon runs with `control_plane`.

Sizing: 1 and 3 are the large parts (a second implementation of A3 and B3); 2 and 4 are mechanical once
1 exists. None of it is small, so this lane builds none of it and runs no cargo.

## 5. What this lane builds (iOS)

Modules follow a1-shell.md 2.1.

- `CmuxiOSFeatureKit/Cloud`: seam `CloudMachineSource` (`updates() -> SourceSnapshot<CloudState>`,
  `perform(_ CloudIntent, key:) -> IntentReceipt`), value types (`CloudMachine`, `CloudMachineStatus`,
  `CloudMachineSize`, `CloudPlan`, `CloudState`, `CloudIntent`), `MockCloudMachineSource` on
  `MockSnapshotHub`. New `FeatureSeam.cloud` (lane C12), `RealFeatureFactories.cloud`,
  `FeatureSources.cloud`.
- `CmuxiOSCloudCore` (Foundation only, tests run on macOS): `CloudWireDecoder`, `CloudMachineMirror`
  (revision-ordered upserts and removals, list replace), `CloudIntentLog` (overlay), `CloudAPIClient`
  seam + `URLSessionCloudAPIClient` (`/v1/read`, `/v1/ops`, Stack session for mutations, one 401 retry
  with a fresh token), `CloudWireTransport` seam + URLSession socket, `WireCloudMachineSource` (the real
  seam), `CloudMachineListModel` (sections, per-status actions, usage summary), `CloudCreateOptions`
  (sizes from `plan.limits.memory_options_mb`, locked sizes disabled), `CloudFirstMachine` (the
  onboarding create: smallest unlocked size).
- `CmuxiOSCloud` (SwiftUI, low frequency): Cloud tab (usage, machines by section, swipe and context
  actions Resume / Pause / Delete with a destructive confirmation, create sheet with name and size,
  refusal alerts mapped from error codes, offline state), en and ja strings.
- Shell: `ShellTab.cloud` behind `ShellFeatureFlag.cloudTab` (on in DEBUG, off in Release),
  `ShellFeatureFlag.cloudOnboarding` (off everywhere until Cloud ships) and `cloudWorkspaces` (off until
  phase 2).
- C5 seam: `WorkspaceHostKind.cloud`; `CloudMachineHostDirectory` (in `CmuxiOSWorkspacesCore`) turns
  bound machines (`host != nil`, not classic, not `deleting`/`failed`) into `.cloud` descriptors;
  `CompositeHostDirectory` merges them with B6's Macs. `RealFeatureFactories.workspaces` now gets the
  resolved Cloud seam next to the device registry. The cloud hosts join only with the
  `cloudWorkspaces` flag (read at launch): until phase 2 `HostDO` refuses a VM host socket, so the
  default list opens no socket that would fail. With the flag on, VM hosts use C5's existing
  `ControlPlaneWorkspaceChannelFactory` unchanged.
- C10 hook: `OnboardingStep.cloudMachine` after `sshHost`, shown when signed in, first run and
  `OnboardingContext.offersCloudMachine` (the flag and a registered hook);
  `OnboardingDependencies.cloud` (`OnboardingCloudHook`) runs `CloudFirstMachine` through the account's
  cloud seam.

Not here: billing checkout (`cloud.billing.checkout` is not live in the Worker; plan refusals say so and
point to Settings > Plans when C16's billing ships), snapshots, rename UI, resize, classic migration
screens, the rescue shell (`cloud.shell.open`, not live), terminal attach (phase 2).

## 6. Tests

Swift Testing against fake `CloudAPIClient` / `CloudWireTransport` responses shaped like
`backend/catalog/cloud-vectors.json`: decode of machines and plan; mirror ordering (older upsert
dropped, removal by revision, list replace); intent overlay and settlement; source end to end (snapshot
-> list read, upsert and removed events, seq gap -> exactly one `snapshot.request` and one re-read,
create/pause/start/delete use the session token and one key, `mutation.indeterminate` retries the same
key, refusal codes, offline refuses without sending); list model sections and actions; create options;
first-machine pick; host directory and channel routing; onboarding flow with the new step. No backend
change, so no vitest.

## 7. Status

See the coordination line in `coordination/ios-next.md` and section 8 when the lane lands.

## 8. Status (2026-10-07)

Done: sections 2 (control plane), 3, 5 and 6. Tests: 22 in `CmuxiOSCloudCoreTests`, 2 in
`CmuxiOSWorkspacesCoreTests` (`CloudHostDirectoryTests`), 1 in `CmuxiOSOnboardingCoreTests`; they pass with
`swift test` on macOS through a scratch package with the existing WorkspacesCore and OnboardingCore
suites (97 tests). `CmuxiOSApp` compiles for `arm64-apple-ios17.0-simulator` with SwiftPM.

Real now: the Cloud tab against the live CloudDO ops (`cloud.machine.list/create/start/pause/delete`,
`cloud.plan.get`, `/v1/wire/cloud` events). Needs the phase-2 Rust host (section 4): VM terminals,
workspaces and files on the phone; the `cloudWorkspaces` flag stays off until then.

The phone-side phase-2 boundary is now typed in `CmuxiOSCloudCore`: `cloud.machine.connect_info`
decodes to credential-free `CloudConnectInfo`, `CloudAttachPreflight` enforces exactly one machine or
host selector, and `CloudAttachPlanner` validates the machine/host binding, positive epoch, service,
32-byte WireGuard peer key, and `fd7c:6d78::/32` overlay before a carrier opens. Paused, pausing and
starting machines return `resumeRequired`; this preflight alone neither caches nor mints a dial token
(section 9 supplies the separate one-shot credential seam). Attach and
decode regressions are added; they are syntax-checked but await the unavailable hosted Swift test
lane. Live VM hello, WireGuard and WebRTC paths remain blocked on the Rust host and credentials.

Unverified: everything visual and runtime (no simulator or device run; the fleet archive is compile
evidence only), live
calls against a dev backend (Stack session principal on `/v1/ops` from the phone), VoiceOver and
Dynamic Type at large sizes. `vm_hours_used` is 0 until UsageMeterDO metering lands (backend).

## 9. Phase-2 credential seam (2026-10-08)

`CmuxiOSCloudCore` now has a bounded `CloudAttachSession` for the phone side of
the VM session-host boundary. It re-reads `cloud.machine.connect_info`, refuses
paused or mismatched machines before any dial, mints `cloud.machine.link_token`
as the install principal with the operation's required empty idempotency key,
and validates the returned host, epoch, service set, and expiry against the
preflight plan. The grant is returned to the caller but never retained by the
actor; a second mint is refused until `resetForReconnect()` and a fresh
preflight. Terminal, workspace, and file adapters can use the daemon service
through the existing `CmuxMobileLink` channels once the Rust VM host is live.

`49b298df07` reserves prepare and mint operations across actor suspension, invalidates stale
completions after reconnect, and rejects a grant with extra services as well as missing services.
The added interleaving and grant-binding tests are syntax-checked; native execution remains blocked
by the hosted package/toolchain issue.

This is a phone-side implementation with static and contract-test evidence only. The VM Rust session host,
WireGuard/WebRTC underlays and live link-token verification remain unimplemented;
`cloudWorkspaces` stays disabled and no live VM attach is claimed. HostDO VM
admission is now implemented as a backend boundary, but it does not by itself
claim that a VM session host or carrier is live.

## 10. HostDO admission boundary (2026-10-08)

`TeamDO.hostAccess` now treats Cloud machine hosts as a separate placement
source owned by `CloudDO` (they are not ordinary TeamDO host rows). A VM
principal is admitted as `host` only when its active grant is kind `vm`, its
`bound_machine` is the machine selected by the current CloudDO row, and that
row names the same `vm_install` and overlay `host`; deleting or failed machines
are refused. A VM cannot fall through to the team-member device rule or reach
another host. A signed-in member or non-VM install is admitted as `device`
only after TeamDO confirms membership. `requestPrincipal` permits VM installs
only on the HostDO route; all user/team/feed/cloud sockets and HTTP surfaces
retain the VM isolation gate.

`backend/apps/api/test/cloud-vm-isolation.test.ts` now proves the bound VM
receives a HostDO `welcome` with role `host`, and the creator's session receives
role `device`; the same suite keeps the unrelated-host 403 assertion. The
focused Vitest file passes (5 tests), and the API TypeScript typecheck passes.
This is admission evidence only: the Rust session host, WireGuard/WebRTC
underlays, one-shot link-token verifier and live terminal attach remain
unimplemented.

# D1b `mac-integration`: what the lanes left for the cmux-next Mac app

Status: landed (local) on `feat-cmux-next-ios-d1b-mac`, 2026-10-07. Plan: [PLAN.md](PLAN.md) D1b.
Binding: OWNERSHIP-PRINCIPLES.md, [d1-terminal-ux.md](d1-terminal-ux.md) 7, [b1-control-do.md](b1-control-do.md),
[b2-webrtc.md](b2-webrtc.md), [b5-mac-host.md](b5-mac-host.md), [b6-pairing.md](b6-pairing.md), C2, C3, C4, C8, C13, C14.

## 1. The Mac's account (`MobileLinkHostAccount`)

`InstallHostAccount` (CmuxNextMobileConnect/Account): the shared `InstallAuthClient` with an
`InstallRegistration` (`.macOS`: kind `mac`, platform `macos`, the owner's default grant; iOS unchanged)
registers the Mac's install with the signed-in Stack session and mints install tokens from a signed
challenge; `host.enroll {name, platform}` (TeamDO keys the host by the enrolling install, so a repeat is a
lookup) gives the `host_…` id; `MacInstallKey` (Secure Enclave when the enclave makes a key, else software)
signs link certs (`LinkKeySigning`) and, as `MacInstallKeyIdentity`, WebRTC bindings. Storage follows the
irx host's v2 keys: a 0600 file under the bundle's state directory in DEV, the login Keychain
(`ThisDeviceOnly`) in release; the (user, install) record is an identifiers-only file. API origin = the
feed's Worker (`FeedService.apiBaseURL`).

## 2. Control plane

- TURN on the Mac: `HostControlUplink.read(op:params:)`; `HostSocketICEServers` reads
  `signal.turn_credentials {host}` on the live uplink, STUN only on refusal. HostDO now serves that read
  for the host role (`macFrame`). The uplink skips HostDO's `welcome` before `hello.ok` (a real Mac never
  registered before this).
- `wg` certs: both ends publish once the account socket is live (ops need a negotiated socket); the Mac
  always publishes `direct` and `wg`; the phone publishes `wg` and passes the key with `CMUX_IOS_LINK_WG`.
- One HostDO socket per Mac on the phone: `HostSocketPool` (CmuxControlPlane) leases one client per
  (host, team) to C5 workspaces, C8 tasks, B6 presence and D1 signaling (`ControlPlaneSession`); HostDO
  keeps one socket per install and closed the others (4000). `SharedHostSocket` fans out states, signals
  and stream updates; a second reader resubscribes so the owner's snapshot reaches everyone.
- `team=`: `TrustedHostKey.team`/`MobileHostRoute.team` from `trust:<user>.remote`; the signaling lease
  asks `?team=` for another account's Mac.

## 3. Services (`MobileLinkServices` -> `MobileHostFeatures`)

| Lane | Mac adapter | Notes |
| --- | --- | --- |
| C4 | `MobileFiles` over `DaemonFileRoots` (first local terminal directory per workspace) | config from home |
| C13 | `MobileGit(sharing:reader: DaemonGitReader)` over `GitResourceClient` | cap `git.read` |
| C14 | `MobileTunnels` over `DetectedTunnelPorts(DaemonWorkspaceProcesses, libproc, allowlist)` minus this Mac's own listeners (`FilteredTunnelPorts`) | allowlist defaults empty |
| C14 | `SimulatorAppCaptureHost`: simctl list, ScreenCaptureKit on the Simulator window, events posted to the Simulator pid, `simctl pbcopy` | no private SimulatorKit |
| C2 | `TabBrowserPages` over `MobileBrowserTabs` (app: `AppMobileBrowserTabs`), DevTools `Input` for rb input | Chromium input only |
| C3 | `RemoteDesktopChannelHandler` with `PanelRemoteDesktopConsent`, `MenuBarRemoteDesktopIndicator`, `GeneralRemoteDesktopPasteboard` | VNC off, loopback blocked by default |
| C8 | `AcpmuxMobileTaskRunner` over `AcpmuxSocketRPC` + `DaemonTaskWorkspaces` | dispatch gated off |

`allowsTaskDispatch` and `allowsTerminalSpawn` are off in every build; DEV builds may turn them on only
for the live check (`CMUX_NEXT_MOBILE_TASK_DISPATCH=1`, `CMUX_NEXT_MOBILE_TERMINAL_SPAWN=1`).

## 4. Verification

Swift Testing: CmuxControlPlane 17, CmuxPairing 16, CmuxMobileConnect 10, CmuxMobileHost 150,
CmuxInstallAuthCore 16, CmuxLinkWebRTC 37, and a scratch package over the real CmuxNextMobileLink,
CmuxNextMobileConnect and CmuxNextMobileHostUI sources (CmuxNextDaemon/Wakeups in Swift 5 mode, as in C1):
20 tests. CmuxiOSApp compiles for `arm64-apple-ios17.0-simulator`. Not compiled: CmuxNextApp (the App
wiring files) and the iOS test targets; vitest for the HostDO change not run (no node_modules).

## 5. Open

No tagged build (no fleet, disk). The HostDO host-role TURN read needs a deploy; until then the Mac falls
back to STUN. acpmux must already run on the Mac (an agent tab starts it) for agents to show. Browser
pane resizes reach the phone with the next page change; a closed tab ends the stream only when the phone
leaves. The Simulator screen mapping assumes a 28 pt title bar and no device bezel.

## 6. App journey and failure states (D1b follow-up)

The Mac-side journey is account-scoped and replacement-safe:

1. App launch starts Cloud and installs the account and service providers before the account observer can
   start phone access.
2. A signed-in user/team creates one `InstallHostAccount`; its first use registers the Mac install,
   enrolls (or looks up) the host, opens the daemon-backed `MobileHostAssembly`, then publishes the
   direct and WireGuard certificates after the user socket negotiates.
3. A user or team switch invalidates the old account, stops its assembly completely, and only then starts
   the new account's assembly. The Bonjour name and direct listener therefore have one owner at a time.
4. Sign-out, disabled settings, a missing account/provider, or a stale start generation leaves no listener
   and no queued mutation. A transient assembly-start failure closes partial resources and clears the
   failed run so a later account transition can retry cleanly.

The user-visible states are `starting` (no phone service yet), `ready` (direct and/or relayed carrier
available), `degraded` (control socket or TURN unavailable; direct may still work), `signedOut`/`disabled`,
and `failed` with a retryable log/refusal. The app must not claim `ready` from a returned port alone: the
control-plane registration, trust mirror and certificate publication are separate readiness gates.

The replacement ordering above is implemented in `MobileLinkService`; the remaining evidence is a hosted
`CmuxNextApp` compile and a tagged Mac/iOS pair run. No local Swift or Rust build is used for this lane.

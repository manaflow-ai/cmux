# D1 `terminal-ux`: the terminal end to end on real carriers

Status: landed (local) on `feat-cmux-next-ios-d1-terminal-ux`, 2026-10-07. Plan: [PLAN.md](PLAN.md) D1.
Binding: OWNERSHIP-PRINCIPLES.md, [a3-link.md](a3-link.md), [b2-webrtc.md](b2-webrtc.md),
[b3-webrtc-wg.md](b3-webrtc-wg.md), [b4-direct.md](b4-direct.md), [b5-mac-host.md](b5-mac-host.md),
[b6-pairing.md](b6-pairing.md), [c1-terminal-rpc.md](c1-terminal-rpc.md), [c5-workspaces.md](c5-workspaces.md),
[c11-settings.md](c11-settings.md), ios-keyboard.md.

## 1. Carrier integration the carrier lanes left

- `DirectTransport.peerIdentity` = the Noise static key (x25519, no install); `WireGuardLinkTransport.peerIdentity`
  = the WireGuard key, with the authorizer's install on the host.
- `MobileHost` reads `LinkSession.peerIdentity` per session and passes a `CarrierAttestation`: the install the
  carrier named (B2, B3), else the install a `CarrierKeyResolver` maps the key to (B4). A key no install owns
  never matches a hello. B6's `TrustedKeyLookup` gained `trustedInstall(linkKey:purpose:onHost:)`;
  `TrustedHostKey` carries the host install key (B2 pin) and its verified `wg` key (B3 pin).

## 2. One link per Mac (`Packages/Shared/CmuxMobileConnect`)

Phone (`CmuxMobileConnect`):

| Type | Role |
| --- | --- |
| `MobileHostRoute` | a trusted Mac's pins (direct, WebRTC, WireGuard) and direct endpoints |
| `MobileRouteBook` | pure join: trust store Macs + Bonjour (`_cmux._tcp`, TXT `host`) + saved direct addresses, each endpoint pinned to that Mac's verified key |
| `MobileCarrierPlan` | B4's `DirectRoutePlanner` applied at connect time (a `PathSelector` is fixed per session): a workable direct route races alone; a reachable but silent Mac (`directFailed`) lets the others race until the next path snapshot |
| `PlannedCarrier` | gates one carrier by the plan, reports direct outcomes |
| `MobileLinkRegistry` | one `MobileLinkClient` per reachable Mac over B4 `DirectCarrier`, B2 `WebRTCCarrier` and, behind a DEV switch, B3 `WireGuardOverWebRTCCarrier`; path snapshots restart the race and WebRTC ICE; live badges per Mac |

Mac (`CmuxMobileConnectHost`): `MobileHostAssembly` merges `DirectAcceptor`, `WebRTCAcceptor` and the B3
acceptor (`MergedLinkAcceptor`) into one `MobileHost`, all authorized by the same trust store:
`TrustStoreMobileDevices` (B5 `MobileTrustStore` over the mirror, key id `install`), `TrustStoreWebRTCAuthorizer`,
`TrustStoreWireGuardAuthorizer`, `TrustedKeyCarrierResolver`.

iOS: `AccountLinkDirectory` (CmuxiOSTerminalLink) binds the signed-in account (routes from the shared B6
runtime's mirror, Bonjour, saved `HostKind.direct` records; NWPathMonitor snapshots). `client(for:)` is async and
waits up to 10 s for the trust store's first snapshot, so a terminal pushed right after sign-in does not read as
unreachable. `LinkClientProvider` hands the same client to terminals (C1), files (C4 `FileHostConnector`) and the
browser stream (C2 `MobileLinkClientProvider`); `AccountLinkDiagnostics` fills C11's `linkDiagnosticsFactory`.
The pairing runtime is cached per account (`PairingRuntimeCache`): the device registry and the links read one
mirror, and a rebuilt registry no longer stops it. Hello proofs and WebRTC bindings sign with the Secure Enclave
install key (`SecureEnclaveInstallSigner.signNow`); the Keychain direct key is published before the first dial.

Fixed on the way: real Macs were addressed by device record id (`install:inst_…`) instead of host id, so the
workspace channel dialed `/v1/wire/host/install:…`; `DeviceRecord.hostID` now carries it.

Mac app: `CmuxNextMobileConnect.MobileLinkHostRunner` runs the assembly with `DaemonMobileDaemon`, the trust
mirror on `/v1/wire/user`, the B1 uplink (`HostControlUplink` over `ControlPlaneHostSocket`, signals into one
`SignalFrameChannel`/`SignalRouter`) and publishes the Mac's direct cert. Setting `MobileLinkSetting.enabled`:
on in Debug, off in Release, `CMUX_NEXT_MOBILE_LINK=1|0` or defaults `cmuxNext.mobileLink.enabled`.

## 3. Terminal chrome

`TerminalChrome` (RenderCore, pure): the badge shows the path, plus RTT and emphasis when relayed or above
50 ms; the banner says Connecting (no content yet), Reconnecting (attempt), Offline; an ended stream shows its
notice instead. Sources opt in through `TerminalConnectionReporting` (link states from
`MobileLinkClient.linkStates()`) and `TerminalHistoryLoading` (`terminal.history` before the oldest page; a host
answering `proto.unsupported` reads as unavailable and is not asked again).

## 4. Commands

One action path for the hardware keyboard (iPad Command overlay), the More menu and the edit menu: Copy, Paste,
Select All, Larger/Smaller/Actual Size (a finished zoom reports the grid at once, like a pinch end), Load Older
History (Command-Up), Close Terminal (Command-W when pushed). Command keys never reach the program; Esc, Ctrl
and Option do (ios-keyboard.md KB2). Key bar, selection, links and the cursor pan are A2's and unchanged.

## 5. DEV switches

`CMUX_IOS_LINK_WG` (B3 carrier; no effect until the phone publishes a `wg` cert) and
`CMUX_IOS_TERMINAL_PREDICTION` (C1 echo prediction), or the shake menu; read at launch, off in Release.

## 6. Tests

- `CmuxMobileConnect` (8): registry -> PathSelector -> real B4 over localhost and real B2 over loopback ICE ->
  `MobileHostAssembly` with a scripted daemon -> attach, ordered input, resize (new grid and READY), live badge,
  input after a cut transport; plan gating; route book.
- `CmuxTerminalLink` (+4): banner states across a drop, history loaded and refused, state mapping.
- `CmuxMobileHost` (+5 attestation), `CmuxPairing` (lookup by purpose, host keys), `CmuxLinkDirect`/`CmuxLinkWG`
  (peer identity), RenderCore (`TerminalChromeTests`).
- `CmuxiOSApp`, `CmuxiOSWorkspacesCoreTests`, `CmuxiOSPairingCoreTests`, `CmuxiOSTerminalTests` compile for
  `arm64-apple-ios17.0-simulator` with SwiftPM.

## 7. Open

- Mac: nothing implements `MobileLinkHostAccount` yet (backend host id, user, install, environment, API origin,
  install-token minter, install `LinkKeySigning` and sync `WebRTCIdentity`), so the host does not start on a real
  Mac; TURN credentials need a read on the host socket (STUN only today). Not compiled: the CmuxNext package and
  the app (typechecked through a scratch package).
- Phone: V2 needs a `wg` cert publish op (B6); host sockets for other accounts' Macs need `team=`; C8's `task:`
  socket is not shared with the signaling socket yet; `terminal.read_range` is not wired (the host answers
  `proto.unsupported`).
- Everything visual is unverified on a device (no tagged build).

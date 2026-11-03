# Opt-in Cloud Tunnel (system-wide route to Cloud VMs)

Status: in progress (a975, 2026-11-03). Supersedes decision X2 in
[deletion.md](deletion.md) for the system extension: it comes back as an
opt-in, with a new engine, not as classic's code.

## Why

cmux's own panes, browser and Desktop reach a Cloud VM through the userspace
hub (`cmux-tui wg hub`, crate `cmux-wg`). That needs no approval and stays the
default. Other programs on the Mac cannot use it: Safari, VS Code Remote,
`ssh` from Terminal, a database GUI on the VM's Postgres. The user asked for
that back as an opt-in (2026-11-03). Only a packet tunnel gives every program
the VM's private address without root, and a Developer ID app can only ship a
packet tunnel as a system extension.

## What we keep, drop and reuse

| Piece | Classic | Opt-in tunnel |
| --- | --- | --- |
| Server peer | `POST /api/vm/tunnel`, `tunnelPurpose: "browser"` | same, unchanged; the server already keeps a `browser` peer beside the hub's `terminal` peer per device (`cloud_vm_tunnels` unique on user, fingerprint, purpose), so the two never rotate each other's key |
| WireGuard engine | vendored WireGuardKit + wireguard-go (Go toolchain, 32 files, a c-archive per arch) | `cmux-wg-tun` (new crate, ~400 lines): boringtun, the same `WgConfig` parser and `TimerSchedule` as the hub, one thread, utun fd <-> UDP. No Go, no second WireGuard implementation |
| Packet path | WireGuardKit finds the utun fd and hands it to wireguard-go | same idea: the provider finds the utun fd and hands it to the Rust engine. No `packetFlow` copies through Swift |
| Mesh (platform#37, #642, cmux#30501) | none | not used. The mesh enrolls install keys and routes only the mesh CIDR for the Native provider; the production Freestyle VMs are on the per-user VPC that only `/api/vm/tunnel` serves. When Native VMs ship, a mesh device role can be a second config source for the same engine |
| Activation | `OSSystemExtensionRequest` on `cmux vpn up` | same API, behind a protocol seam; only on an explicit enable |
| Settings | none ("no VPN rows") | one toggle, Settings > Accounts > Cloud: "Cloud Tunnel", off by default |
| CLI / MCP | `cmux vpn up/down/status` | `cmux cloud tunnel on|off|status` (catalog actions, so MCP gets `app_cloud_tunnel_*` for free) |

## Flow

1. Off by default. A fresh install, an update and every launch with the
   setting off never touch NetworkExtension or SystemExtensions.
2. `cloud tunnel on` (Settings toggle, CLI, MCP, or a Cloud action that opens
   a VM address outside cmux) sets `cloud.tunnel.enabled`, then:
   1. `OSSystemExtensionRequest.activationRequest` for the bundled extension.
      macOS asks once, in System Settings > General > Login Items &
      Extensions; status shows `awaiting-approval` with a button to that pane.
      Replacing an older copy (a classic nightly's, or the last cmux-next
      build's) is automatic.
   2. Enroll the `browser` peer: a fresh Curve25519 key made in the app,
      `POST /api/vm/tunnel` with the device id the hub uses and a
      fingerprint of `<device id>.browser.<channel>`. The completed wg-quick
      config (private key included) goes into the `NETunnelProviderProtocol`
      `providerConfiguration`, which macOS stores in the System keychain;
      it is never written to a file.
   3. Save the `NETunnelProviderManager` ("cmux Cloud", on-demand off) and
      `startVPNTunnel()`.
3. The extension (`NEPacketTunnelProvider`) parses the config, sets the
   tunnel network settings (its own address, only the VPC routes from
   `AllowedIPs`, MTU, the endpoint as tunnel remote address), finds the utun
   fd and starts the engine. Default route changes call
   `cmux_wg_tun_network_changed` (rebind + re-handshake).
4. Later launches with the setting on load the saved manager and start it if
   it is not connected. No approval prompt at launch: a launch never submits
   an activation request unless the extension was approved before (then the
   request is silent and only replaces an older version).
5. `cloud tunnel off` stops the tunnel and removes the manager; the extension
   stays installed (removing it needs the user's password). Sign-out also
   `DELETE`s the `browser` peer (purpose passed explicitly).

## Security

The tunnel widens access on purpose: with it on, every program of every user
on this Mac can reach the VPC, as with Tailscale. That is why it is off by
default and the Settings row says so. Guarantees that stay:

- Only VPC routes enter the tunnel (no default route, no DNS change), so the
  rest of the Mac's traffic is untouched.
- Crypto-key routing: the engine drops a decrypted packet whose source is
  outside `AllowedIPs` (tested).
- The private key is made per enrollment, lives in the System keychain via
  `providerConfiguration`, and is never on disk in a file or in logs
  (`description` of every config type redacts it).
- The hub's token-guarded SOCKS path is unchanged, so cmux's own panes keep
  working with the tunnel off.

## System Settings icon and subtitle

System Settings > Network Extensions shows the containing app's name and icon
as the title and icon, and the extension's `CFBundleDisplayName` as the
subtitle (Tailscale: "Tailscale" / "Tailscale Network Extension"; its
extension bundle has no icon either). The grey row the user saw is classic's
nightly extension whose containing app ("cmux VPN Verification.app") was
deleted: `/Library/SystemExtensions/db.plist` records `container = null`.
Activating the extension from cmux NIGHTLY (same bundle id prefix, team,
higher version) replaces that record, so the row becomes "cmux NIGHTLY /
cmux Cloud Tunnel" with the NIGHTLY icon.

Build-time check (`scripts/cmux-next/check-cloud-tunnel-bundle.sh`, run by the
app target after embedding and by CI on the signed app): the extension sits at
`Contents/Library/SystemExtensions/<id>.systemextension`, its id is the app's
id plus `.tunnel`, it has `CFBundleDisplayName` "cmux Cloud Tunnel",
`NSSystemExtensionUsageDescription`, `NEProviderClasses` for
`com.apple.networkextension.packet-tunnel`, an `NEMachServiceName` prefixed by
the team, a `CFBundleVersion` equal to the app's, and the containing app has a
`CFBundleName` and an icon file that exists.

## Code layout

- `cmux-tui/crates/cmux-wg-tun`: engine + C ABI (`include/cmux_wg_tun.h`),
  staticlib built on CI and fleet hosts by `scripts/cmux-next/build-wg-tun.sh`
  (like acpmux: never cargo on a developer Mac; a tagged reload without the
  library builds the app without the extension and the tunnel reports
  `unavailable`).
- `Packages/macOS/CmuxCloudTunnel`: the domain, shared by app and extension.
  Value types (config summary, network plan, status), the
  `CloudTunnelController` state machine with `SystemExtensionActivating` and
  `TunnelManaging` seams, and their live NetworkExtension implementations.
- `CloudTunnelExtension/`: the system extension target (main, provider,
  Info.plist, InfoPlist.xcstrings, entitlements per channel).
- App: `CloudTunnelEnabledSetting` (Settings), catalog actions
  `cloud tunnel on|off|status`, `CloudHandlers+Tunnel`, composition in the
  app's Cloud service.

## Release pipeline

`sign-cmux-bundle.sh` signs the extension (hardened runtime, sandbox,
channel entitlements, its embedded profile) before the app, and its gate
changes from "no extension" to "an extension needs the profile capability".
`nightly.yml`/`release.yml` give the extension the channel identity
(`<app id>.tunnel`), rename the bundle to match, embed
`APPLE_<CHANNEL>_TUNNEL_PROVISIONING_PROFILE_BASE64` (secrets already exist),
and run the bundle check. The `nightly-next` track (signed without a profile)
strips the extension: no profile, no tunnel.

## Proof

- Engine: `cmux-wg-tun` tests against a real boringtun peer (red then green).
- Domain: Swift Testing suites for the network plan and the controller (off
  by default, no NetworkExtension call while off, approval flow, enable,
  disable, launch with it on).
- Bundle check: a shell test on a built fake bundle.
- End to end: a NIGHTLY build with the tunnel, `cmux cloud tunnel on`,
  approve, `nc -vz <vm ipv4> 1337` from Terminal and `curl` to a dev server
  on the VM, plus the System Settings row before and after.

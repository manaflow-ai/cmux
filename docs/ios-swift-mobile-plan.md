# iOS Swift Mobile Plan

Goal: ship the iOS path from current cmux main with Swift-owned app, session, transport, and storage code. Ghostty remains the terminal engine through GhosttyKit.

## Baseline

- Current main pins `ghostty` to `22fa801f88f96fa842e54ecce6c34a5d36003d19`.
- The first production slice should use only main Ghostty APIs. Fork-only helpers such as an active-screen getter or text snapshot helper are useful learnings, but they should not block the Swift rewrite.
- Main's current mobile host snapshot is not sufficient for Zig-parity terminal rendering. It emits `fidelity: text_vt` with `styled_cells_unavailable`, so iOS can preserve layout but cannot reproduce ANSI/TUI colors until the Mac host exports real styled cells from Ghostty.
- The original Zig/Tailscale branch remains useful for dogfooding behavior and shell UX. It is not the production base.
- Current rollout status: Iroh is the default mobile transport. Mac hosts still publish Tailscale/LAN routes by default as a lower-priority compatibility fallback, and Mac Settings can disable those fallback routes.

## Architecture

- `Packages/Shared/CMUXMobileCore` owns the cross-platform Swift protocol layer: attach tickets, routes, frame codec, and Ghostty snapshot models.
- The iOS shell depends on `CMUXMobileCore` and a `CmxByteTransport`, not on Tailscale, Iroh, WebSocket, or daemon details.
- The Mac host publishes a `CmxAttachTicket` with one or more `CmxAttachRoute` values. iOS dials supported routes in priority order and logs each attempt.
- Iroh is the primary `CmxByteTransport` implementation. The shell and terminal session do not change. A minimal Rust edge is acceptable for the Iroh endpoint/dialer if the Swift code keeps owning route selection, attach-ticket decoding, framing, auth, and app state.
- Tailscale/LAN routes use the Swift `Network` transport over host and port. They remain an optional, lower-priority fallback for rollout compatibility and manual recovery.
- Rivet can store workspace/device presence and issue attach tickets. It should not carry hot PTY bytes in the first production design.

## Iroh Experiment

`experiments/iroh-byte-transport` is the current Rust spike. It proves a single ALPN byte stream and prints an attach-route JSON object that the Swift `CmxAttachRoute` decoder accepts:

```text
dev.cmux.mobile.terminal/0
```

The Swift peer endpoint schema now carries `direct_addrs` and `relay_url` hints so an Iroh route has enough information to dial without changing the app shell.

## Storage

Central workspace storage should keep durable records for workspace id, display name, owning Mac device, recent terminal ids, route hints, and update time. iOS keeps a local cache and reconnects through fresh attach tickets so long-lived credentials never live in QR/deeplink payloads.

## Milestones

1. Land `CMUXMobileCore` with route selection, frame codec, snapshot schema, and tests.
2. Copy the proven SwiftUI shell into `ios/` and wire it to `CmxByteTransport`.
3. Add a Mac mobile listener that emits attach tickets and streams framed terminal bytes, with Tailscale/LAN as the initial TCP lane.
4. Replace the Mac `text_vt` terminal snapshot path with a Swift-owned styled-cell exporter from Ghostty so iOS receives foreground/background/bold/inverse/underline data instead of plain text.
5. Add Iroh behind the same transport factory, using the Rust spike only for the endpoint/dialer until a Swift-native path exists.
7. Default Iroh on for iOS and Mac mobile hosts, keep Tailscale/LAN fallback route publication default-on, and expose active transport in diagnostics/UI.
6. Add auth expiry, reconnect, backpressure, logging, and CI coverage before release.

# iOS Swift Mobile Plan

Goal: ship the iOS path from current cmux main with Swift-owned app, session, transport, and storage code. Ghostty remains the terminal engine through GhosttyKit.

## Baseline

- Current main pins `ghostty` to `22fa801f88f96fa842e54ecce6c34a5d36003d19`.
- The first production slice should use only main Ghostty APIs. Fork-only helpers such as an active-screen getter or text snapshot helper are useful learnings, but they should not block the Swift rewrite.
- Main's current mobile host snapshot is not sufficient for Zig-parity terminal rendering. It emits `fidelity: text_vt` with `styled_cells_unavailable`, so iOS can preserve layout but cannot reproduce ANSI/TUI colors until the Mac host exports real styled cells from Ghostty.
- The original Zig/Tailscale branch remains useful for dogfooding behavior and shell UX. It should not be the production base.

## Architecture

- `Packages/CMUXMobileCore` owns the cross-platform Swift protocol layer: attach tickets, routes, frame codec, and Ghostty snapshot models.
- The iOS shell depends on `CMUXMobileCore` and a `CmxByteTransport`, not on Tailscale, Iroh, WebSocket, or daemon details.
- The Mac host publishes a `CmxAttachTicket` with one or more `CmxAttachRoute` values. iOS chooses the first supported route.
- Tailscale ships first as a Swift `Network` transport over the tailnet host and port.
- Iroh is added as another `CmxByteTransport` implementation once the Swift-side implementation is ready. The shell and terminal session do not change.
- Rivet can store workspace/device presence and issue attach tickets. It should not carry hot PTY bytes in the first production design.

## Storage

Central workspace storage should keep durable records for workspace id, display name, owning Mac device, recent terminal ids, route hints, and update time. iOS keeps a local cache and reconnects through fresh attach tickets so long-lived credentials never live in QR/deeplink payloads.

## Milestones

1. Land `CMUXMobileCore` with route selection, frame codec, snapshot schema, and tests.
2. Copy the proven SwiftUI shell into `ios/` and wire it to `CmxByteTransport`.
3. Add a Mac Tailscale listener that emits attach tickets and streams framed terminal bytes.
4. Replace the Mac `text_vt` terminal snapshot path with a Swift-owned styled-cell exporter from Ghostty so iOS receives foreground/background/bold/inverse/underline data instead of plain text.
5. Add Iroh behind the same transport factory.
6. Add auth expiry, reconnect, backpressure, logging, and CI coverage before release.

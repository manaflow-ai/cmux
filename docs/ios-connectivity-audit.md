# iOS Connectivity Architecture Audit

## Summary

The iOS terminal data plane is a direct iOS to Mac TCP connection over a length-prefixed JSON RPC protocol. The web service is a rendezvous and presence layer, not a terminal relay. The Mac is the source of truth for workspaces, terminals, terminal grids, notification state, and viewport negotiation. The iOS app is a projection that stores pairing metadata, keeps mounted terminal output streams, and applies replay/live frames into libghostty.

The reconnect bug is rooted in split ownership inside `MobileShellComposite`. Transport/session lifetime lives in `MobileCoreRPCSession`, but user-visible connection phase, Mac availability, retry state, event-listener generation, mounted output sinks, and replay obligations live in separate mutable fields in `MobileShellComposite`. A failed event subscription or ended stream marks the Mac unavailable but leaves `connectionState == .connected` and retains `remoteClient`. Retry, foreground resume, network-change recovery, and liveness recovery then enter the connected fast path and only restart the event listener plus replay mounted surfaces on the same client. They do not invalidate the old connection epoch, rebuild a client from the active paired-Mac route, re-establish a server subscription as a fresh epoch, and replay mounted surfaces before marking the connection healthy.

This is not primarily a missing timeout. `MobileCoreRPCSession.ensureConnected()` can create a new transport after teardown on the same `MobileCoreRPCClient`. The app-level defect is that no owner defines "connected" as a coherent epoch consisting of route, socket/session, server subscription, workspace list, mounted-surface replay, and viewport reports. The UI phase is still derived only from `connectionState`, so a stale client plus failed subscription can keep the app in the workspaces phase with a frozen terminal frame, or tear down output tracking in a way that leaves no new subscription/replay owner to restore it.

## Architecture Map

### iOS composition and lifecycle

- `ios/cmux/cmuxApp.swift:11-45` builds one app composition root, registers supported route kinds, constructs `CmxRouteTransportFactory`, `ReachabilityService`, auth, and `CMUXMobileRuntime`.
- `ios/cmux/cmuxApp.swift:53-64` forwards scene phase to the composition root.
- `ios/cmux/AppCompositionRoot.swift:91-147` handles scene phase for analytics only. It does not own reconnect or terminal subscriptions.
- `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift:137-175` creates optional device-registry and presence clients. Both are failure-tolerant.
- `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift:205-240` constructs `CMUXMobileShellStore` with runtime, paired-Mac store, registry, presence, identity, reachability, analytics, diagnostics, and feedback.
- `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/CMUXMobileRootView.swift:88-120` calls `store.resumeForegroundRefresh()` on mount and on active foreground, refreshes Tailscale status, and revalidates auth.
- `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/CMUXMobileRootView.swift:136-156` reconnects stored Macs after auth changes and closes the add-device sheet when `connectionState` becomes connected.
- `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/CMUXMobileRootView.swift:339-356` starts stored-Mac reconnect only when authenticated and `connectionState != .connected`.

### Discovery, pairing, and auth

- `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileSyncProtocol.swift:3-19` defines the default host port, shared pairing compatibility version, and route kinds: Tailscale, iroh, websocket, and debug loopback.
- `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxPairingQRCode.swift:3-40` defines the v2 pairing QR as route-only metadata with no auth token, no expiry, no display name/device id, and no loopback route.
- `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxPairingQRCode.swift:168-215` decodes v2 QR URLs into unscoped `CmxAttachTicket` values and rejects loopback hosts.
- `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxAttachTicketCompactCoder.swift:3-40` documents the compact v1 attach URL grammar and the short-key map. The decoder remains compatible with compact and legacy payloads.
- `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxTransport.swift:79-151` validates route endpoint shape against route kind.
- `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxTransport.swift:159-222` defines attach tickets with Mac identity hints, Stack user metadata, routes, expiry, and optional auth token.
- `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxTransport.swift:292-335` validates tickets structurally, treats expiry as token-consumer data, and picks preferred supported routes.
- `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileShellRouteAuthPolicy.swift:4-17` defines the trust policy: Stack bearer tokens may only ride encrypted routes or loopback.
- `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileShellRouteAuthPolicy.swift:64-93` allows Stack auth only for Tailscale host routes, iroh peers, and debug loopback.
- `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileShellRouteAuthPolicy.swift:95-130` rejects loopback tickets on physical devices and limits implicit pair-link Stack auth to loopback.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift:2178-2313` decodes pairing URLs, checks account metadata, performs offline preflight, calls `connect(ticket:)`, records pairing success/failure, and clears context on connection failure.

### iOS transport, RPC, and session

- `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRuntime.swift:9-29` defines mobile runtime timeouts, token providers, and server-push support.
- `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRuntime.swift:37-106` maps transient token errors to connection-closed style failures and definitive token errors to authorization failures.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:6-16` stores one runtime, route, ticket, auth policy, and `MobileCoreRPCSession`.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:34-50` creates a session bound to one route, exposes disconnect, and exposes event subscription streams.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:73-101` retries authorization failures once after forcing a Stack token refresh.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:124-144` wraps each request with auth and request timeout before sending through the session.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:164-240` adds attach and Stack auth. Every authorized request must send `stack_access_token`; `mobile.host.status` may carry it opportunistically.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:242-292` defines which methods need Stack fallback and which single method is unauthenticated.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCClient.swift:318-342` implements per-request timeout via a task group.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift:4-11` owns one persistent transport, request multiplexing, and event dispatch.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift:58-88` sends a request by ensuring a transport, framing the payload, registering a pending continuation, and yielding to a serialized writer.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift:90-102` creates event streams with `.bufferingNewest(256)`.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift:108-140` tears down by failing pending requests, finishing listeners, closing transport, cancelling reader/writer tasks, and clearing the transport reference.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift:144-201` creates a new transport if `transport` is nil, starts reader/writer tasks, and reuses an existing in-flight connect task when needed.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift:218-247` tears down the session on receive error, remote close, or frame decode failure.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift:249-292` dispatches either event envelopes to subscribed listeners or responses to pending request continuations.
- `Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkByteTransport.swift:100-108` defines the iOS byte transport as an actor over one `NWConnection` with a 15s connect deadline.
- `Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkByteTransport.swift:160-167` uses plain TCP with `NWParameters(tls: nil, tcp:)`.
- `Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkByteTransport.swift:199-255` exposes connect, receive, send, and close.
- `Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkByteTransport.swift:289-329` fails initial connect fast on definitive `.waiting` cases, but ignores post-ready waiting states because midstream recovery is owned by RPC/liveness.

### Mac host service and RPC dispatch

- `Sources/Mobile/MobileHostService.swift:721-737` starts the mobile listener only when iOS pairing host is enabled.
- `Sources/Mobile/MobileHostService.swift:758-785` binds an `NWListener` over plain TCP, installs state and new-connection handlers, and starts path monitoring.
- `Sources/Mobile/MobileHostService.swift:813-835` stops the listener, closes active connections, resets subscription tracking and routes, and clears mobile viewport reports.
- `Sources/Mobile/MobileHostService.swift:978-1050` accepts a connection off the main actor, constructs `MobileHostConnection`, wires auth and request handling, inserts it into the active registry, and starts it.
- `Sources/Mobile/MobileHostService.swift:291-370` defines public and identity status payloads. `mobile.host.status` is unauthenticated but only returns Mac identity when a presented Stack token verifies.
- `Sources/Mobile/MobileHostService.swift:1218-1318` makes Stack auth the sole authorization gate for authorized mobile data-plane verbs and distinguishes account mismatch from unauthorized.
- `Sources/Mobile/MobileHostService.swift:1360-1409` scopes attach-ticket authorization by method but leaves events subscribe/unsubscribe, status, and workspace list allowed at that layer.
- `Sources/Mobile/MobileHostService.swift:1498-1517` exempts only `mobile.host.status` from authorization.
- `Sources/TerminalController.swift:12973-13031` dispatches mobile RPC methods directly to `v2Mobile*` handlers. This is the app-side Mac source of truth.
- `Sources/TerminalController.swift:13125-13151` reports host status with `terminal_fidelity: "render_grid"` and capabilities.
- `Sources/TerminalController.swift:13511-13567` implements `mobile.terminal.replay`, preferring render-grid snapshots and falling back to VT snapshot or raw byte tail.
- `Sources/TerminalController.swift:13569-13610` records paired-device viewport reports and returns effective grid size.
- `Sources/TerminalController.swift:13667-13715` forwards mobile terminal input to the real surface and returns the terminal byte sequence when available.
- `Sources/TerminalController+MobileWorkspaceList.swift:37-183` produces the iOS workspace list by enumerating Mac workspaces and groups.
- `Sources/TerminalController+MobileWorkspaceList.swift:185-230` serializes one workspace and its terminal previews. The Mac owns titles, directories, selection, focus, readiness, pinning, and notification preview fields.

### Mac event fan-out and subscription demand

- `Sources/Mobile/MobileHostService.swift:28-94` maintains global topic subscriber counts and posts `mobileHostEventSubscriptionsDidChange` when counts cross zero.
- `Sources/Mobile/MobileHostService.swift:96-150` tracks active mobile connections and snapshots them for fan-out without holding the registry lock across awaits.
- `Sources/Mobile/MobileHostService.swift:432-462` fans out server-pushed events only when there is at least one subscriber for the topic.
- `Sources/Mobile/MobileHostService.swift:1938-1960` defines `MobileHostConnection` as the owner of one `NWConnection`, timeouts, response tasks, and stream subscriptions.
- `Sources/Mobile/MobileHostService.swift:1993-2019` closes a connection, cancels tasks, removes subscriptions, decrements topic counts, and cancels the `NWConnection`.
- `Sources/Mobile/MobileHostService.swift:2021-2101` receives length-prefixed frames, decodes them, starts response tasks, and closes on errors or remote completion.
- `Sources/Mobile/MobileHostService.swift:2143-2166` applies a 30s idle timeout only after the first frame and only when there are no subscriptions and no response tasks.
- `Sources/Mobile/MobileHostService.swift:2215-2250` handles `mobile.events.subscribe` and `mobile.events.unsubscribe`, returning `already_subscribed` for subscribe probes.
- `Sources/Mobile/MobileHostService.swift:2267-2291` updates per-connection subscriptions, global topic counts, and idle timeout state.
- `Sources/Mobile/MobileHostService.swift:2301-2325` sends event envelopes shaped as `{kind:"event", topic, payload}`.
- `Sources/Mobile/MobileHostService.swift:2327-2358` length-prefixes responses and events on the same connection.
- `Sources/Mobile/MobileHostService.swift:2360-2374` closes the connection on failed/cancelled states and ignores waiting/setup/preparing.

### Terminal frame producers

- `Sources/Mobile/MobileTerminalByteTee.swift:10-21` captures byte-identical raw PTY output from libghostty's tee callback before the VT parser sees the bytes.
- `Sources/Mobile/MobileTerminalByteTee.swift:60-84` bails out of the hot path unless there are subscribers to `terminal.bytes` or `terminal.render_grid`.
- `Sources/Mobile/MobileTerminalByteTee.swift:104-134` advances a per-surface sequence, maintains a 256 KiB replay tail, schedules render-grid export, and emits `terminal.bytes` only when subscribed.
- `Sources/Mobile/MobileTerminalRenderObserver.swift:5-8` pushes render events only while a mobile client is actively subscribed.
- `Sources/Mobile/MobileTerminalRenderObserver.swift:32-70` observes subscription changes, Ghostty frame notifications, and Ghostty IO ticks.
- `Sources/Mobile/MobileTerminalRenderObserver.swift:88-96` schedules a post-parser Ghostty tick after byte-tee input so render-grid snapshots include parsed terminal state.
- `Sources/Mobile/MobileTerminalRenderObserver.swift:111-129` retains Ghostty notification demand only when render topics have subscribers and clears render-grid state when demand disappears.
- `Sources/Mobile/MobileTerminalRenderObserver.swift:149-183` flushes pending surface/global updates and emits `terminal.updated` and `terminal.render_grid`.
- `Sources/Mobile/MobileTerminalRenderObserver.swift:185-237` emits full render-grid frames or row deltas based on row signatures and state sequence.
- `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Mobile.swift:53-91` exports a render-grid JSON frame from the real Ghostty surface and can filter changed rows.

### iOS terminal frame consumption and backpressure

- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileEventEnvelope.swift:3-21` represents pushed event envelopes.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileTerminalReplayResponse.swift:4-19` decodes replay responses, preferring `render_grid` and falling back to `snapshot_data_b64` or `data_b64`.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileTerminalRenderGridEvent.swift:4-10` accepts wrapped or bare render-grid payloads.
- `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileTerminalBytesEvent.swift:3-16` decodes raw PTY byte events with optional sequence.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/TerminalOutputDelivery.swift:4-31` wraps raw bytes or render-grid VT patch bytes as one output chunk.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/TerminalOutputDelivery.swift:34-100` implements one backpressure queue per mounted surface. Raw bytes are nonreplaceable; replaceable render-grid viewport patches coalesce when a prior chunk is still in flight.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalOutputDelivery.swift:5-49` yields exactly one chunk per mounted surface until the surface reports it processed the previous chunk.
- `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/GhosttySurfaceRepresentable.swift:9-15` confirms iOS renders with libghostty plus Metal, not a SwiftUI cell tree.
- `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/GhosttySurfaceRepresentable.swift:128-146` mounts an output task that iterates `store.terminalOutputStream`, calls `surfaceView.processOutputAndWait`, then calls `terminalOutputDidProcess`.
- `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileTerminalInputSendBuffer.swift:3-12` defines a 64 KiB bounded, coalescing input queue.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift:3185-3223` disconnects and clears remote context when the pending input buffer overflows.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift:3235-3242` converts raw input bytes to UTF-8 text for `mobile.terminal.input`.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift:4085-4136` sends terminal input over RPC and marks Mac availability unavailable on availability-classified failures.

### Web registry and presence

- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/DeviceRegistryService.swift:8-24` defines `/api/devices` as a team-scoped registry that can refresh routes, but failures return `nil` so reconnect falls back to local paired-Mac routes.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/DeviceRegistryService.swift:97-136` defines pure reconnect-route and stale-write policies.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/DeviceRegistryService.swift:140-156` fetches fresh routes best-effort.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/DeviceRegistryService.swift:272-320` decodes the registry response and only substitutes routes when exactly one app instance has usable routes.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/DeviceRegistryService.swift:324-343` sends Stack tokens and optional team id to the web API.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/PresenceClient.swift:3-18` defines presence as a WebSocket stream over the `workers/presence` Durable Object edge, separate from terminal data.
- `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/PresenceClient.swift:61-128` opens a bounded `AsyncThrowingStream`, yields snapshot-first updates, and leaves reconnect/backoff policy to the consumer.
- `web/app/api/devices/route.ts:1-11` documents the device registry as best-effort rendezvous. It is not authoritative for pairing.
- `web/app/api/devices/route.ts:127-183` registers devices/routes and rejects loopback or non-attachable manual routes.
- `web/app/api/devices/route.ts:194-311` upserts devices and app instances transactionally with per-team/per-device caps.
- `web/app/api/devices/route.ts:323-388` lists team devices and app instances with stored routes.
- `web/app/api/devices/route-classification.ts:1-18` mirrors native loopback classification.
- `web/app/api/devices/route-classification.ts:186-203` rejects loopback and defines Tailscale-attachable routes.
- `web/app/api/devices/route-classification.ts:257-298` validates manual attach routes as Tailscale host:port routes with valid ids, endpoint type, host, port, and priority.
- A local search for `Convex|convex` under `ios`, `Packages/iOS`, `Packages/Shared/CMUXMobileCore`, `Sources/Mobile`, `web/app/api/devices`, and `web/services` returned no hits for this terminal data plane. Convex is not in the current iOS to Mac terminal stream.

## End-to-end Message Flow

1. The Mac listener starts when the mobile host setting is enabled. `MobileHostService.start()` gates listener creation, then `startListener` binds a plain TCP `NWListener` on the configured or fallback port (`Sources/Mobile/MobileHostService.swift:721-785`).
2. The Mac advertises routes through pairing QR/attach URL metadata and device registry rows. The QR carries only route and account/build context, while the registry can refresh routes later (`CmxPairingQRCode.swift:3-40`, `DeviceRegistryService.swift:8-24`).
3. The iOS app decodes a pairing URL or loads an active paired Mac from the local paired-Mac store. `connectPairingURLResult` and `reconnectActiveMacIfAvailable` both converge on a host/route connect path (`MobileShellComposite.swift:2178-2313`, `MobileShellComposite.swift:1238-1327`).
4. `connect(ticket:)` picks supported routes, creates `MobileCoreRPCClient`, sends an initial `workspace.list`, replaces `remoteClient`, starts event polling, persists the paired Mac, applies the workspace list, sets `connectionState = .connected`, and marks Mac status healthy (`MobileShellComposite.swift:3275-3387`).
5. Each RPC is JSON with `{id, method, params, auth}` inside a 4-byte big-endian length-prefixed frame. iOS adds Stack auth for all authorized requests, and the Mac rejects all authorized methods without same-account Stack auth (`MobileSyncProtocol.swift:178-222`, `MobileCoreRPCClient.swift:164-240`, `MobileHostService.swift:1278-1318`).
6. `MobileCoreRPCSession` multiplexes request responses and event envelopes on the same socket. Event envelopes have `{kind:"event", topic, payload}` and are dispatched to topic listeners (`MobileCoreRPCSession.swift:249-292`, `MobileHostService.swift:2301-2325`).
7. The iOS shell asks the Mac to subscribe the stream id `ios-terminal-events-<clientID>` to output/workspace/notification topics. The Mac records topic counts so terminal frame producers only do work while subscribers exist (`MobileShellComposite.swift:4313-4382`, `MobileHostService.swift:2215-2291`, `MobileTerminalRenderObserver.swift:111-129`).
8. Terminal output arrives as render-grid events when the Mac advertises `terminal.render_grid.v1`. Raw PTY bytes remain a fallback. Cold attach and self-heal call `mobile.terminal.replay`, and live frame gaps call replay again (`MobileShellComposite.swift:5045-5133`, `MobileShellComposite.swift:5135-5224`).
9. Mounted iOS terminal surfaces register `terminalOutputStream(surfaceID:)`, which requests replay. The representable feeds each chunk into the iOS libghostty surface and reports completion so one-surface backpressure can release the next chunk (`MobileShellComposite.swift:4936-4980`, `GhosttySurfaceRepresentable.swift:128-146`, `MobileShellComposite+TerminalOutputDelivery.swift:24-49`).

## Audit Scope Answers

### 1. Connect

iOS connects to the Mac with a direct byte transport chosen from attach routes. Current app composition supports debug loopback in simulator/DEBUG and Tailscale otherwise (`ios/cmux/cmuxApp.swift:18-23`). Route validation requires route kind and endpoint shape to match (`CmxTransport.swift:115-150`). The concrete shipping transport for host routes is TCP over Network.framework with no TLS (`CmxNetworkByteTransport.swift:160-167`), relying on Tailscale encryption for trusted bearer-token routes (`MobileShellRouteAuthPolicy.swift:64-93`).

Discovery is QR/attach URL plus local paired-Mac persistence plus best-effort web registry refresh. The pairing QR is a non-secret route/account/build description (`CmxPairingQRCode.swift:3-40`), decoded into a ticket (`CmxPairingQRCode.swift:168-215`). Reconnect reads the active Mac from `pairedMacStore`, optionally refreshes routes in the background through `/api/devices`, and dials the first supported host/port route (`MobileShellComposite.swift:1238-1327`). Registry refresh is intentionally non-blocking and failure-tolerant (`DeviceRegistryService.swift:140-156`).

Auth is Stack-account auth on every authorized RPC. The attach ticket carries route and scoping context, but host authorization requires the Mac owner's Stack token (`MobileCoreRPCClient.swift:164-240`, `MobileHostService.swift:1278-1318`). `mobile.host.status` is the only unauthenticated probe, and it returns identity only when a presented Stack token verifies (`MobileHostService.swift:333-369`).

### 2. Sync

The Mac is the source of truth. `TerminalController.mobileHostHandleRPC` dispatches iOS requests to Mac app handlers (`TerminalController.swift:12973-13031`). Workspace sync comes from `v2MobileWorkspaceList`, which enumerates Mac windows, `TabManager` workspaces, group sections, terminal panels, titles, directories, readiness, and focus (`TerminalController+MobileWorkspaceList.swift:37-230`). iOS applies that list into local UI state after initial connect and after event-driven refreshes (`MobileShellComposite.swift:3337-3364`, `MobileShellComposite.swift:5226-5264`).

Terminal screen state is also Mac-authored. The Mac exports render-grid snapshots and deltas from the real Ghostty surface (`TerminalSurface+Mobile.swift:53-91`, `MobileTerminalRenderObserver.swift:185-237`). iOS keeps only per-mounted-surface delivery queues and sequence bookkeeping (`MobileShellComposite.swift:590-599`, `TerminalOutputDelivery.swift:34-100`). Replay is the catch-up boundary (`MobileShellComposite.swift:5045-5133`).

### 3. Lifecycle

Connection startup is centralized in `connect(ticket:)`: route loop, first workspace list, client replacement, event listener start, paired-Mac persistence, workspace apply, then connected/healthy (`MobileShellComposite.swift:3275-3387`). Foreground resume does not reconnect. It starts network observation, evaluates presence, and calls `resyncTerminalOutput(reason:"foreground", restartEventStream:true)` (`MobileShellComposite.swift:865-871`). Scene phase handling outside the shell is analytics-only (`AppCompositionRoot.swift:91-147`).

Heartbeat/liveness is subscription-based, not a generic ping. The render-grid liveness watchdog records event arrival, probes by re-subscribing to the same stream id, and only recovers when the probe fails (`MobileShellComposite.swift:4598-4821`). The Mac has a first-frame timeout and an idle timeout, but idle timeout is disabled while a connection has subscriptions (`MobileHostService.swift:2122-2166`).

Network changes come from `ReachabilityService`, which yields on offline-to-online and primary-interface changes but not initial state (`ReachabilityService.swift:93-150`). `MobileShellComposite.startObservingNetworkPathChanges()` maps those yields into `recoverMobileConnection(trigger:.networkChange)` (`MobileShellComposite.swift:1072-1088`).

Backgrounding does not cancel the RPC client or subscriptions in the shell. On active foreground the app tries to restart/resync the existing event stream, not rebuild the connection (`CMUXMobileRootView.swift:111-120`, `MobileShellComposite.swift:865-871`).

### 4. Frames

The primary frame protocol is render-grid. The Mac observes Ghostty render frames and IO ticks only while event subscribers exist, exports render-grid JSON from the live surface, and emits full or row-delta frames based on row signatures and state sequence (`MobileTerminalRenderObserver.swift:32-70`, `MobileTerminalRenderObserver.swift:111-129`, `MobileTerminalRenderObserver.swift:185-237`). Replay responses prefer `render_grid` and include sequence, columns, and rows (`TerminalController.swift:13511-13567`, `MobileTerminalReplayResponse.swift:4-19`).

Raw PTY byte tee remains a fallback and a sequence source. The tee captures bytes before the VT parser, maintains a 256 KiB replay tail, and emits `terminal.bytes` events only when subscribed (`MobileTerminalByteTee.swift:10-21`, `MobileTerminalByteTee.swift:104-134`). iOS detects raw-byte sequence gaps and calls replay for the affected surface (`MobileShellComposite.swift:5178-5224`).

Backpressure is per mounted surface. iOS yields one chunk to a surface, waits for `processOutputAndWait`, then releases the next chunk. Replaceable render-grid viewport patches can coalesce while an earlier chunk is in flight; raw bytes cannot (`TerminalOutputDelivery.swift:34-100`, `MobileShellComposite+TerminalOutputDelivery.swift:24-49`, `GhosttySurfaceRepresentable.swift:128-146`).

### 5. Failure handling

Lower transport/session failure is detected and propagated. `MobileCoreRPCSession.readLoop` tears down on receive error, remote close, or invalid frame, finishes listeners, and clears `transport` (`MobileCoreRPCSession.swift:108-140`, `MobileCoreRPCSession.swift:218-247`). Future sends on the same `MobileCoreRPCClient` can reconnect by creating a new transport (`MobileCoreRPCSession.swift:144-201`).

The shell's app-level recovery is split. Availability failures on operational RPCs can mark the Mac unavailable (`MobileShellComposite.swift:4085-4136`, `MobileShellComposite.swift:3836-3868`). Subscribe-start failure marks unavailable and stops polling, but leaves `connectionState == .connected` and keeps `remoteClient` (`MobileShellComposite.swift:4526-4561`). A stream ending before its subscribe ack also marks unavailable (`MobileShellComposite.swift:4564-4584`). A stream ending after ack restarts polling and refreshes workspace list on the same client (`MobileShellComposite.swift:4586-4594`).

Manual Retry and network-change recovery share `recoverMobileConnection`. If `connectionState == .connected && remoteClient != nil`, the function only marks reconnecting and calls `resyncTerminalOutput(... restartEventStream:true)`, then returns (`MobileShellComposite.swift:1096-1126`). Full stored-Mac reconnect only runs when the store is not in the connected state. `resyncTerminalOutput` restarts the event listener and requests replay on the current `remoteClient`; it never replaces the client, invalidates the connection epoch, or reconnects from persisted routes (`MobileShellComposite.swift:4823-4845`).

Auth failures are the better-owned path. They call `disconnectForAuthorizationFailureIfNeeded`, set reauth state, disconnect, clear connection context, and transition to disconnected (`MobileShellComposite.swift:5385-5425`). Input queue overflow also disconnects and clears remote context (`MobileShellComposite.swift:3185-3223`).

### 6. Protocols

The direct Mac protocol is length-prefixed JSON. Each payload is wrapped by a 4-byte big-endian length with an 8 MiB cap (`MobileSyncProtocol.swift:178-222`). Requests are JSON RPC-shaped with `id`, `method`, `params`, and optional `auth` (`MobileCoreRPCClient.swift:53-70`, `MobileCoreRPCClient.swift:164-240`). Responses are matched by `id`; events are envelopes with `kind:"event"`, `topic`, and `payload` (`MobileCoreRPCSession.swift:249-292`, `MobileHostService.swift:2301-2325`).

Pairing and attach protocol versioning is split by layer. `CmxAttachTicket.currentVersion` covers ticket structure (`CmxTransport.swift:159-222`). QR grammar `v=2` covers route-only pairing URLs (`CmxPairingQRCode.swift:40-44`). Compact attach URL `v=1` covers compact JSON payloads (`CmxAttachTicketCompactCoder.swift:3-40`). `CmxMobileDefaults.pairingCompatibilityVersion` is an app compatibility signal used for warnings (`MobileSyncProtocol.swift:7-12`). Runtime capability versioning happens through `mobile.host.status` capabilities and terminal fidelity (`TerminalController.swift:13125-13151`).

The web protocol is separate. `/api/devices` is authenticated HTTP using Stack bearer/refresh tokens and optional team id (`DeviceRegistryService.swift:324-343`, `web/app/api/devices/route.ts:1-11`). Presence is a WebSocket stream at `/v1/presence/subscribe` with snapshot-first updates and bounded buffering (`PresenceClient.swift:46-128`). Neither relays terminal frames.

## Failure Modes

1. **Subscribe-start failure leaves a stale connected phase.** `beginTerminalEventSubscriptionStart` handles failed ack by stopping polling and calling `markMacConnectionUnavailable`, which sets `connectionRecoveryFailed` while preserving `connectionState == .connected` and `remoteClient` (`MobileShellComposite.swift:4526-4561`, `MobileShellComposite.swift:3836-3865`).
2. **Event stream ends before ack and converges to unavailable, not disconnected.** The guard prevents a reconnecting livelock, but still leaves the same connected-phase/stale-client shape (`MobileShellComposite.swift:4564-4584`).
3. **Event stream ends after ack restarts the listener on the same client.** It marks reconnecting, clears listener ids, starts polling again, and refreshes workspaces. It does not establish a new client epoch (`MobileShellComposite.swift:4586-4594`).
4. **Network change and manual Retry are gated by stale `connectionState`.** When the shell still says connected and has any `remoteClient`, recovery never calls `reconnectActiveMacIfAvailable`; it only resyncs output on the existing client (`MobileShellComposite.swift:1096-1126`).
5. **Foreground resume uses the same connected fast path.** `resumeForegroundRefresh` restarts network observation and calls resync on the current client; it does not repair a stale connected epoch (`MobileShellComposite.swift:865-871`).
6. **Liveness probe failure restarts subscription, not connection ownership.** The watchdog calls `resyncTerminalOutput(... restartEventStream:true)`, which restarts listener and replay but does not clear `remoteClient` or connection state (`MobileShellComposite.swift:4775-4785`, `MobileShellComposite.swift:4823-4845`).
7. **Replay failure is logged unless it is auth-related.** `requestTerminalReplay` catches errors, logs them, and only disconnects for authorization failure. A stale client that cannot replay can leave the mounted surface frozen (`MobileShellComposite.swift:5123-5131`).
8. **Workspace-list refresh failure is logged and leaves stale state.** Event refresh catches errors and keeps the existing list without connection-state transition (`MobileShellComposite.swift:5240-5264`).
9. **Event listener buffering can drop frames silently.** `MobileCoreRPCSession` uses `.bufferingNewest(256)` for event streams and does not inspect `yield` results in dispatch (`MobileCoreRPCSession.swift:90-102`, `MobileCoreRPCSession.swift:249-265`). A slow consumer can miss deltas and depend on later replay or gap detection.
10. **Mac-side listener stop closes connections and clears subscriptions.** The Mac correctly resets state on stop, but the iOS shell can remain in connected phase until its listener/request path observes failure (`MobileHostService.swift:813-835`, `MobileCoreRPCSession.swift:218-247`).
11. **Registry freshness is deferred to the next reconnect trigger.** Stored-Mac reconnect starts a background registry refresh, but current connect uses local routes; a stale local route can fail once before refreshed routes are applied later (`MobileShellComposite.swift:1280-1285`, `DeviceRegistryService.swift:97-114`).
12. **Ambiguous multi-tag registry rows disable route substitution.** If zero or more than one app instance has routes, `routes(forMacDeviceID:)` returns nil and reconnect falls back to local routes (`DeviceRegistryService.swift:309-320`).
13. **Presence is optional and currently does not own reconnect/backoff.** `PresenceClient` explicitly leaves reconnect/backoff to consumers, and the shell treats it as a device-tree hint rather than a terminal connection authority (`PresenceClient.swift:17-18`, `PresenceClient.swift:61-128`).
14. **Input overflow is one of the few full-disconnect paths.** Raw input queue overflow sets `connectionState = .disconnected`, marks status unavailable, and clears remote context (`MobileShellComposite.swift:3185-3223`). This path does not have the stale connected-phase defect.
15. **Authorization failures are properly terminal.** The auth path clears context and moves out of connected state (`MobileShellComposite.swift:5385-5425`). The reconnect bug is concentrated in availability/subscription failures rather than auth failures.

## Root Cause of the 10-20 Minute First-drop Reconnect Bug

The symptom is that after a healthy connection runs for 10-20 minutes, the first connection drop leaves the terminal gone or frozen until app restart/manual intervention.

The narrowed owner defect is in `MobileShellComposite`: availability failure, event subscription lifecycle, connection phase, and client/session ownership are not one state machine. `markMacConnectionUnavailable()` only mutates `macConnectionStatus`, `isRecoveringConnection`, and `connectionRecoveryFailed`; it does not clear `remoteClient` or set `connectionState = .disconnected` while the shell is connected (`MobileShellComposite.swift:3836-3865`). The UI phase remains `.workspaces` whenever `connectionState == .connected` (`MobileShellComposite.swift:604-612`).

The reconnect gate then prevents real recovery. `recoverMobileConnection` checks `connectionState == .connected && remoteClient != nil` first and returns after `resyncTerminalOutput(... restartEventStream:true)` (`MobileShellComposite.swift:1096-1126`). That resync path restarts the listener and replays mounted surfaces on the current client (`MobileShellComposite.swift:4823-4845`). It does not cancel the old connection epoch, replace the client, reselect a route from the paired-Mac store, require a fresh subscribe ack, replay all mounted surfaces as part of a new epoch, or refresh the workspace list before declaring healthy.

The first real drop can therefore land in this bad state:

1. The event stream ends or subscribe-start ack fails (`MobileShellComposite.swift:4526-4584`).
2. The shell sets Mac status unavailable and shows Retry, but leaves `connectionState == .connected` and `remoteClient` retained (`MobileShellComposite.swift:3836-3865`).
3. The terminal view remains mounted because `phase` still returns `.workspaces` (`MobileShellComposite.swift:604-612`).
4. Retry, foreground resume, network change, or liveness recovery takes the connected fast path and only replays/re-subscribes on the same stale owner (`MobileShellComposite.swift:1096-1126`, `MobileShellComposite.swift:4823-4845`).
5. If the old client/session cannot produce a durable new server subscription plus replay, the mounted `GhosttySurfaceRepresentable` has no new authoritative frame stream and stays frozen (`GhosttySurfaceRepresentable.swift:128-146`, `MobileShellComposite.swift:5045-5133`).

The lower session actor is capable of rebuilding its `CmxByteTransport` after teardown (`MobileCoreRPCSession.swift:108-140`, `MobileCoreRPCSession.swift:144-201`). The app does not own an epoch invariant that says a visible connected terminal requires a current route, live socket/session, accepted event subscription, replayed mounted surfaces, refreshed workspace list, and reported viewports. The bug class persists because the UI and recovery code can observe "connected" from `connectionState` while the frame stream and subscription are dead.

Existing tests cover several liveness false-fire and subscription-race bugs. `MobileShellRenderGridLivenessTests.swift:7-23` documents the earlier false-fire causes, and `MobileShellRenderGridLivenessTests.swift:214-245` verifies a stream ending before subscribe ack marks unavailable rather than livelocking reconnecting. The missing test is an end-to-end recovery invariant: after an event stream/subscription failure while connected, the shell must either transition out of connected phase or establish a new epoch that proves socket, subscribe ack, replay, and workspace sync before returning to healthy.

## Recommended Redesign

### Option A: Single connection coordinator with epochs

Make a new connection coordinator the owner of the Mac connection epoch. It can be an actor for transport/session work with a `@MainActor @Observable` projected snapshot, or a `@MainActor` coordinator that owns an internal actor for socket work. The important boundary is one owner for route, ticket, client, session epoch, event subscription generation, mounted surface registrations, viewport reports, replay obligations, workspace refresh, recovery policy, and user-visible connection state.

Current owners:

- `MobileCoreRPCSession` owns transport, pending RPCs, event listener streams, teardown, and transport recreation (`MobileCoreRPCSession.swift:4-11`, `MobileCoreRPCSession.swift:108-201`).
- `MobileShellComposite` owns `connectionState`, `macConnectionStatus`, active ticket/route, retry flags, `remoteClient`, event listener ids, liveness watchdog, mounted output sinks, replay state, and workspace sync (`MobileShellComposite.swift:92-151`, `MobileShellComposite.swift:465-612`, `MobileShellComposite.swift:1028-1126`).
- SwiftUI derives screen phase from `connectionState` only (`MobileShellComposite.swift:604-612`).

New owner:

- `MobileConnectionCoordinator` owns a value snapshot such as:

```swift
enum MobileConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting(target: MobileConnectionTarget)
    case connected(epoch: MobileConnectionEpochSnapshot)
    case recovering(epoch: UUID, reason: MobileRecoveryReason)
    case reconnecting(target: MobileConnectionTarget, reason: MobileRecoveryReason)
    case authRequired(message: String)
    case failed(reason: MobileConnectionFailure)
}
```

End-state invariants:

- A connected snapshot exists only after route selection, `MobileCoreRPCClient` creation, initial workspace list, event subscription ack, mounted-surface replay scheduling, and viewport reporting have either completed or produced explicit degraded obligations.
- Any transport close, subscribe ack failure, event stream finish, liveness probe failure, replay failure that indicates availability loss, or workspace sync failure that indicates availability loss transitions out of `connected(epoch)` and cancels the old epoch.
- Recovery from availability loss creates a fresh epoch from the current ticket or active paired-Mac route. It does not depend on `remoteClient != nil` or a separate availability flag.
- Mounted output streams are keyed by epoch. Old epoch chunks cannot be delivered into a new surface token, and new epoch replay is mandatory for every mounted surface before the surface can be marked caught up.
- UI phase observes the coordinator snapshot. There is no separate `connectionState`, `macConnectionStatus`, `connectionRecoveryFailed`, and `remoteClient != nil` decision lattice.

What changes:

- Move the connected fast path out of `recoverMobileConnection`; recovery chooses "probe existing subscription" only while the coordinator still owns a healthy epoch and the probe succeeds. A failed probe invalidates the epoch and starts reconnect.
- Replace `markMacConnectionHealthy`, `markMacConnectionReconnecting`, and `markMacConnectionUnavailable` with coordinator transitions.
- Move `startTerminalRefreshPolling`, `beginTerminalEventSubscriptionStart`, `handleTerminalEventStreamEnded`, liveness watchdog decisions, `resyncTerminalOutput`, `requestTerminalReplay`, and workspace refresh into epoch-scoped methods.
- Keep `MobileCoreRPCClient` and `MobileCoreRPCSession` as lower-level RPC/session tools. They should not decide app health.
- Keep `MobileShellComposite` as the shell view model, but make it observe coordinator snapshots and apply workspace/terminal projections through one update path.

What stays:

- Direct TCP/Tailscale transport, length-prefixed JSON frames, Stack auth model, Mac RPC methods, render-grid frame format, raw byte fallback, and web registry/presence roles remain intact.
- Mac remains the source of truth for workspace list and terminal screen state.

Why this eliminates the class:

- The frozen-frame state becomes unrepresentable. The app cannot be "connected" while the active epoch lacks a live client, accepted subscription, and replay obligations. Retry and network-change recovery cannot accidentally reuse a stale client because the coordinator has already invalidated the epoch that owned it.

First migration cut:

1. Introduce `MobileConnectionCoordinator` with an epoch id and snapshot, initially wrapping the existing `MobileCoreRPCClient` creation and `connectionState` projection.
2. Move only availability transitions and `recoverMobileConnection` into the coordinator. On subscribe-start failure, stream end, liveness probe failure, and availability-classified RPC failure, invalidate the epoch and run full reconnect from active ticket or active paired-Mac route.
3. Re-establish event subscription and request replay for all mounted surfaces before publishing healthy. Workspace list refresh should be part of the reconnect success path.
4. Leave terminal rendering DTOs, Mac producer code, and web registry unchanged in this cut.

Verification:

- Unit test with a fake transport/router: connect, mount a terminal sink, deliver initial replay, close the event stream after 10 simulated minutes, assert a new epoch is created, the old client is disconnected, `mobile.events.subscribe` is re-acked on the new epoch, `mobile.terminal.replay` is requested for the mounted surface, and UI snapshot never reports healthy until those steps complete.
- Unit test subscribe ack failure while `connectionState` would previously remain connected. Assert recovery does not call `resyncTerminalOutput` on the stale client and instead reconnects or reports a non-connected failed state.
- Unit test foreground resume with a failed old epoch. Assert resume delegates to the coordinator and does not skip full reconnect because a stale `remoteClient` still exists.

### Option B: Targeted full-reconnect on availability failure

Patch the existing shell model so availability failure calls `clearRemoteConnectionContext()`, sets `connectionState = .disconnected` or a new `.recovering` state, and makes `recoverMobileConnection` call `reconnectActiveMacIfAvailable` instead of `resyncTerminalOutput` whenever subscribe/start/liveness/replay/workspace refresh failures imply connection loss.

Current owners stay mostly unchanged:

- `MobileShellComposite` continues to own connection state, availability status, remote client, event listener tasks, liveness timer, mounted sinks, and workspace sync.
- `MobileCoreRPCSession` continues to own socket/session mechanics.

Why it helps:

- The specific stale connected-state gate is removed. Retry and network changes can reach full reconnect because the shell is no longer connected after availability failure.

Why it is weaker:

- It preserves the split ownership that caused this bug. Future code can still set `macConnectionStatus` without clearing `connectionState`, restart listeners without replaying mounted surfaces, or refresh workspaces on stale clients. It narrows this symptom but does not make the bad state impossible.

Recommendation:

Choose Option A. It aligns with the repo's Swift architecture guidance: one UI lifecycle owner, explicit phase enum, actor-owned mutable transport state, value snapshots for SwiftUI, and no timing-based repair as an app invariant. Option B is acceptable only as a short-lived stabilization patch while Option A is being built, and should be deleted once the coordinator owns the epoch.

## Regression Coverage to Add With the Redesign

1. **First-drop full recovery:** Start connected with a mounted terminal, then make the event stream close. Expected: old epoch invalidated, new client created or reconnect attempted, subscribe ack completed, mounted surface replay requested, workspace list refreshed, UI snapshot healthy only after those steps.
2. **Subscribe ack failure while connected:** Force `mobile.events.subscribe` to time out/fail after initial workspace list success. Expected: no stale `.connected` phase with retained client; recovery transitions to reconnecting/failed.
3. **Manual Retry after unavailable:** Put the store in `macConnectionStatus == .unavailable` with an old client. Expected: Retry starts full reconnect, not `resyncTerminalOutput` on the old client.
4. **Foreground resume after background drop:** Simulate background, close the Mac connection, foreground. Expected: coordinator detects stale epoch and reconnects before showing a healthy terminal.
5. **Replay failure as availability failure:** If replay for a mounted surface fails with connection-closed/request-timeout on the active epoch, expected: epoch invalidated and reconnect path starts. Auth failures still route to reauth.
6. **Event stream backpressure drop:** Simulate `AsyncStream` event buffer overflow or dropped render-grid events. Expected: epoch requires replay or treats the stream as degraded, rather than silently trusting delta continuity.

## Non-goals

- Do not replace Tailscale/TCP transport in this redesign. The current transport can be kept under the coordinator.
- Do not route terminal frames through the web registry or presence worker. The web layer is for device discovery and live presence hints.
- Do not patch by only increasing liveness or request timeouts. The bug is a state ownership defect, and a larger timeout only changes how long the frozen frame takes to surface.

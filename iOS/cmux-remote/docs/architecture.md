# cmux-remote architecture

## Layered overview

```text
┌─────────────────────────────────────────────────────────┐
│  SwiftUI views                                          │
│  • Workspace sidebar / pane tree / surface detail       │
│  • Notifications, Command Palette, Hosts                │
│  • Terminal view (SwiftTerm)                            │
│  • Browser control panel                                │
└────────────────────────────┬────────────────────────────┘
                             │ EnvironmentObject
                             ▼
┌─────────────────────────────────────────────────────────┐
│  ConnectionManager (@MainActor)                         │
│  • Owns lifecycle of transport + client + reactor       │
│  • Foreground/background handoff                        │
│  • Wires NotificationCenter + Live Activity             │
└────────────────────────────┬────────────────────────────┘
                             │
       ┌─────────────────────┼─────────────────────┐
       ▼                     ▼                     ▼
┌──────────────┐    ┌─────────────────┐    ┌─────────────────────┐
│ HostStore    │    │ CmuxCredential  │    │ ResumeJournal       │
│ (UserDefs)   │    │ Store (Keychain)│    │ (App Group plist)   │
└──────────────┘    └─────────────────┘    └─────────────────────┘
                             │
                             ▼
                ┌─────────────────────────┐
                │  CmuxKit (framework)    │
                │  • CMUXClient           │
                │  • EventReactor         │
                │  • ServerState (actor)  │
                │  • CmuxEventDecoder     │
                │  • CitadelSSHTransport  │
                └────────────┬────────────┘
                             │ SSH exec
                             ▼
              ┌──────────────────────────────┐
              │  user@mac → cmux CLI         │
              │  • runs `cmux <subcommand>`  │
              │  • events.stream NDJSON       │
              │  • read-screen snapshots     │
              └──────────────────────────────┘
```

## Why "SSH + shell out" instead of a native socket bridge

Three reasons:

1. **The cmux Mac CLI is already the source of truth for socket discovery,
   keychain auth, and v1/v2 envelope encoding.** Reimplementing those on
   iOS (especially the keychain-resolved password and HMAC relay-auth flows)
   would be a maintenance burden and a security risk. By shelling out to
   `cmux <subcommand>` over SSH we inherit every fix to those subsystems
   without code churn.
2. **SSH is universally available.** Macs already have an SSH server
   (Remote Login). No new ports, no new TLS PKI, no new agent process.
3. **The CLI contract is a documented surface area.** `docs/cli-contract.md`
   pins it; we're a downstream consumer of a stable contract.

Future: when cmux ships a native APNs-routed control channel (out of scope
here), the transport abstraction (`CmuxSSHTransport`) lets us swap it in
without touching `CMUXClient` or above.

## State + event flow

The cmux event stream is the single source of truth for live state changes
on the Mac. The reactor:

1. Pulls a snapshot with v2 `window.list`, `workspace.list`, `pane.list`,
   `pane.surfaces`, and `notification.list` at connect time.
2. Subscribes to `cmux events --reconnect` over SSH.
3. Applies each frame to `ServerState` (an actor).
4. On `ack.resume.gap == true`, refreshes the snapshot.
5. Persists the latest `seq` to `ResumeJournal` so reconnects skip already-
   processed events.

`ServerState` exposes an `AsyncStream<Snapshot>` so SwiftUI views receive
diffed snapshots without owning live references to the protocol actor.

## Backgrounding model

Per Apple's documented behaviour, an iOS app cannot keep an SSH socket
alive while suspended. The contract we honour:

* **Foreground**: long-lived `cmux events --reconnect` channel + on-demand
  command channels.
* **Inactive / background**: tear down the SSH session. Citadel + NIO
  cannot reliably outlive a `applicationDidEnterBackground`; we don't try.
* **`BGAppRefreshTask`**: every ~15 min the system may wake us. We open a
  fresh pinned-host SSH session, run `notification.list` and `feed.list`, deliver
  any unread notifications or pending decisions as local notifications, and exit.
* **On `willEnterForeground`**: rebuild the SSH session and let the reactor's
  resume cursor skip events the client already saw via background drains.

## Live Activity model

One Live Activity per active host. The widget extension renders the
Dynamic Island / Lock Screen UI from `CMUXActivityAttributes.ContentState`.
Updates come from foreground snapshots and background refreshes. The current
build starts activities from in-app code and does not request APNs push tokens.

## Terminal display model

cmux does not expose a streaming PTY tail. We:

1. Subscribe to `surface.*` and `pane.*` events to know when to refresh.
2. Poll `cmux read-screen --surface <id>` at ≤ 4 Hz while the surface is
   the foreground view (cancelled when the view disappears).
3. Diff against the previously rendered viewport — if the new viewport
   prefixes the old, only feed the suffix; otherwise clear + repaint.

This is honest about what cmux exposes and produces a responsive feel for
agent output. A `surface.tail` streaming RPC on the cmux side would be the
right follow-up; see [`known-limitations.md`](known-limitations.md).

## File layout

See [`README.md`](../README.md) for the on-disk layout. Three Swift modules
matter:

* **`CmuxKit`** — protocol layer + SSH transport. No UI. Tests live in
  `Tests/CmuxKitTests`.
* **`CmuxRemote`** — iOS app target. Wires CmuxKit to SwiftUI, notifications,
  Live Activities, App Intents, background tasks, iPad keyboard / Pencil
  / gestures.
* **`CmuxRemoteWidgets`** — Widget extension target. Hosts the Live
  Activity widget and Home Screen widgets. Reads cached state from the
  App Group `widget-state.json`.

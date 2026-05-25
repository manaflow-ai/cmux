# cmux-remote

An iOS 26 / iPadOS 26 remote client for [cmux](https://github.com/manaflow-ai/cmux).

cmux runs on a Mac and orchestrates AI coding agents across Ghostty-backed
terminal surfaces, a built-in browser, notifications, and a sidebar. This iOS
app is a first-class remote control for that workflow: see which agents are
waiting, read terminal output, send approvals / text / keystrokes, open new
workspaces, drive the in-app browser, and receive push-style notifications when
agents need attention — all from an iPhone or iPad.

## Status

This is an in-tree side project of the cmux repository. The iOS client is a
separate Xcode project under `iOS/cmux-remote/` and does **not** ship inside
the macOS `cmux DEV.app` binary.

## Architecture in one paragraph

The client treats the user's Mac as the source of truth. It connects over SSH
using [Citadel](https://github.com/orlandos-nl/Citadel) (a pure-Swift SwiftNIO
SSH client) and shells out to the `cmux` CLI running on the Mac for every
operation. cmux on the Mac already speaks v1 (line-text) and v2 (JSON-RPC)
over its local Unix socket and resolves auth from the local keychain — the iOS
client never has to forward the Unix socket or replicate the HMAC relay-auth
dance. Live activity is driven by a long-lived `cmux events --reconnect` exec
channel that streams newline-delimited JSON frames; the client persists the
last `seq` so reconnects resume cleanly per the documented cmux resume
contract. Terminal display uses `cmux read-screen` snapshots refreshed on
`surface.*` and `pane.*` events plus an explicit
manual-refresh affordance (cmux does not currently expose a live PTY-output
stream; this is documented as a known limitation and the only operation that
is not real-time).

## Surface area covered

| Capability                                  | cmux primitive used                                              |
| ------------------------------------------- | ---------------------------------------------------------------- |
| List windows / workspaces / panes / surfaces| v2 `window.list`, `workspace.list`, `pane.list`, `pane.surfaces` |
| Read a terminal surface                      | `read-screen --surface <uuid>`                                   |
| Send text                                    | `send --surface <uuid> -- <text>`                                |
| Send a key                                   | `send-key --surface <uuid> -- <key>`                             |
| Switch focus                                 | `focus-window`, `select-workspace`, v2 `surface.focus`           |
| Create workspace                             | v2 `workspace.create`                                            |
| Notification fan-out                         | `events.stream --category notification`, v2 `notification.list`  |
| Notification actions                         | `open-notification`, `mark-notification-read`, `dismiss-notification`, `jump-to-unread` |
| Agent decision fan-out                       | `events.stream --category agent --category feed`, v2 `feed.list` |
| Agent decision replies                       | v2 `feed.permission.reply`, `feed.question.reply`, `feed.exit_plan.reply` |
| Sidebar metadata                             | `set-status`, `log`, `set-progress`, `list-status`, `list-log`   |
| Browser control                              | `browser open|goto|click|fill|press|find|...`                    |
| Workspace + tab actions                      | `workspace-action`, `tab-action`                                 |
| Live stream                                  | v2 `events.stream` (resume by `seq`)                             |
| Capabilities probe                           | v2 `system.capabilities`, `system.identify`                       |
| Authentication                               | text `auth <password>` prelude where required                    |

The full cmux CLI contract this client targets is at
[`docs/cli-contract.md`](../../docs/cli-contract.md), and the event stream
catalog is at [`docs/events.md`](../../docs/events.md).

## Platform integrations (iOS 26 / iPadOS 26)

- **ActivityKit Live Activity** — Dynamic Island shows a privacy-preserving
  workspace status, agent activity indicator, and pending notification count.
  Decision Live Activities use anonymous action labels on Lock Screen-visible
  surfaces and carry real labels only as reply metadata. Updates drive
  directly off the `cmux events` stream. Started in-app; supports push-to-start
  for follow-ups.
- **UNUserNotificationCenter** — Each `notification.created` event spawns a
  notification with category actions: *Open Workspace*, *Mark Read*,
  *Dismiss*. Time-sensitive entitlement is requested for agent-waiting alerts.
- **BGTaskScheduler** — `BGAppRefreshTask` periodically opens a pinned-host
  one-shot SSH session while the app is suspended, drains notifications and
  pending Feed decisions, posts local notifications, and exits.
- **App Intents + AppShortcuts** — Siri/Spotlight: "Open <workspace> in cmux",
  "Send <text> to <surface>", "Mark all cmux notifications read",
  "Approve last agent prompt". Interactive widgets reuse the same intents.
- **WidgetKit** — Home Screen and Lock Screen widgets show pending
  notification count and the latest unread workspace.
- **Hardware keyboard (iPadOS)** — Full `UIKeyCommand` catalog mirroring
  cmux's macOS shortcuts: workspace switching, surface switching, command
  palette (⌘P), jump-to-unread (⌘⇧U), send-key passthrough into the
  terminal surface, etc.
- **Apple Pencil** — PencilKit overlay on terminal surfaces for ad-hoc
  annotation and screenshot-with-handwriting. Pencil Pro double-tap and
  squeeze gestures cycle surfaces / open command palette. Hover preview on
  command palette rows.
- **Gestures** — Two-finger horizontal swipe switches pane; three-finger
  swipe-down opens command palette; pinch-zoom changes terminal font size.

## Library dependencies

| Library                                                                  | Purpose                                                                  |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| [Citadel](https://github.com/orlandos-nl/Citadel)                        | Pure-Swift SwiftNIO SSH client                                            |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)                  | Terminal emulator + UIKit-backed view                                     |
| [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess)     | Keychain wrapper for SSH key + password storage with biometric gating     |
| [swift-log](https://github.com/apple/swift-log)                          | Structured logging                                                        |
| [swift-collections](https://github.com/apple/swift-collections)          | `OrderedDictionary`, `Deque` for event buffering                         |
| [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)| `AsyncChannel` for the event reactor backbone                            |

Choices are deliberate: each is on the Apple SwiftPM ecosystem mainline, has
maintained iOS-26-compatible releases, and is well-known to Apple reviewers.
Versions are pinned in `Package.swift` / `project.yml`.

## Repo layout

```
iOS/cmux-remote/
├── README.md
├── project.yml                # XcodeGen spec (source of truth)
├── App/                       # iOS app target resources
│   ├── Configuration/
│   │   ├── Info.plist
│   │   ├── CmuxRemote.entitlements
│   │   └── CmuxRemoteWidgets.entitlements
│   └── Resources/
│       ├── Assets.xcassets/
│       └── Localizable.xcstrings
├── Sources/
│   ├── CmuxKit/               # protocol + transport library
│   ├── CmuxRemote/            # iOS app target
│   └── CmuxRemoteWidgets/     # Widget + Live Activity extension target
├── Tests/
│   ├── CmuxKitTests/
│   └── CmuxRemoteTests/
├── docs/
│   ├── architecture.md
│   ├── verification.md
│   └── known-limitations.md
└── scripts/
    └── generate.sh            # `xcodegen generate`
```

## Setup

```bash
# One-time
brew install xcodegen

# From iOS/cmux-remote/
./scripts/generate.sh
open cmux-remote.xcodeproj
```

The Xcode project file (`cmux-remote.xcodeproj`) is regenerated from
`project.yml`; the `.xcodeproj` itself is **not** committed (the spec is).

## Verification

See [`docs/verification.md`](docs/verification.md) for the test and build
matrix. Unit tests live in `Tests/CmuxKitTests` and test the protocol layer
against recorded transcripts so they don't need a live cmux instance. The
client-side terminal renderer is exercised through SwiftTerm's own internals.

## Known limitations

See [`docs/known-limitations.md`](docs/known-limitations.md). The headline
one: cmux does not currently expose a live PTY-output stream, so the
terminal view in cmux-remote is snapshot-based (refreshed on `surface.*` /
`pane.*` events plus a 750 ms idle poll while the surface is the foreground
view, debounced to zero polling while backgrounded). This is faithful to
what cmux actually exposes today; a streaming `surface.tail` RPC would be the
right cmux-side follow-up.

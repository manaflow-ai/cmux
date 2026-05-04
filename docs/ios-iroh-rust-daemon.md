# iOS iroh Rust daemon prototype

This PR starts a new iOS path that reuses the Rust `cmx` runtime instead of the Zig remote daemon from the previous iOS branch.

## Reused shape

The earlier `task-move-ios-app-into-cmux-repo` worktree is useful for the iOS project shape, split-view navigation, terminal sidebar model, signing setup, and dogfood scripts. It also proves that an iOS app belongs in this repository instead of a separate checkout.

The parts this path deliberately does not carry forward are the Zig daemon, localhost/Tailscale assumptions, direct WebSocket/SSH fallback, and Swift-owned terminal state. Those pieces were tied to the old daemon contract.

## Rust daemon path

The Rust `cmx` runtime from `$HOME/fun/cmux-cli` already has the core pieces this app needs:

- workspaces, spaces, panes, and terminal state
- a MessagePack protocol for TUI frame streaming, commands, layout, and native snapshots
- a TUI attach mode that streams the same ANSI frame model used by the Rust `cmx` terminal interface

The first production milestone is not the Swift sidebar model. It is iOS connecting as another `cmx` client and rendering the shared TUI interface through libghostty/GhosttyKit. The iOS client sends `Hello`, receives `PtyBytes`, sends `Input` and `Command`, and reconnects to the same Rust daemon state as the CLI/TUI.

After that works, the Swift app should move to Rust-owned state by using `HelloNative`, `NativeSnapshot`, `TerminalGridSnapshot`, `NativeInput`, `NativeLayout`, and `Command`. Swift should render native controls, but Rust owns the workspace, space, panel, tab, terminal, and reconnect lifecycle.

Current implementation status:

- iOS renders the terminal with actual libghostty/GhosttyKit.
- The iOS renderer has unit coverage for unchanged PTY byte forwarding, actual Ghostty surface creation, ANSI output rendering, and outbound typed input.
- iOS has a local Swift `cmx` MessagePack codec with unit coverage for the TUI wire contract plus native `HelloNative`, `NativeSnapshot`, and `TerminalGridSnapshot` decoding.
- iOS has the Stack/Rivet pairing auth frame model and HMAC proof algorithm. The Swift proof test shares the Rust bridge vector `w62sYb9esNfmw-GwP36Z2ooce7olwxryi3xdRWVRpHs`, and the Rust iroh client binding uses the Rivet-delivered secret before opening the cmx stream.
- Connected mode supports both an explicit `cmx` WebSocket dev stream and the production iroh stream. iOS requests `HelloNative` with `terminal_renderer = libghostty`, applies Rust-owned `NativeSnapshot` state to the workspace UI, sends `NativeInput` scoped to the selected tab, and sends `NativeLayout` for the visible terminal.
- Rust native mode now supports two renderer contracts: existing `server_grid` clients still receive `TerminalGridSnapshot`; iOS `libghostty` clients receive bounded PTY replay plus live `PtyBytes`, so actual libghostty/GhosttyKit owns terminal parsing, themes, colors, cursor state, and input echo.
- The simulator dogfood path connects to `cmx server --ws-bind 0.0.0.0:8787 --auth-token dev` with a direct development ticket and verifies typed input renders back through Ghostty.
- The home screen now uses an iMessage-style workspace inbox shell with node pins and full-width conversation rows. iOS can replace demo state with Stack-authenticated hive discovery from `CMUX_IOS_HIVE_ENDPOINT` or `--cmux-hive-endpoint`.
- The web app now exposes `/api/rivet` with a RivetKit `cmuxHive` actor plus Stack-authenticated `/api/hive` REST endpoints. The discovery response can carry nodes, nested workspaces, spaces, terminals, activity, and platform metadata, and the request uses the stored Stack Auth session headers.
- The rail/resize bounds helper from the old iOS branch lives at `scripts/tui-terminal-bounds-check.sh`, and the Rust tmux dogfood suite verifies the helper tracks the maximum pane size after resize.
- Iroh bridge tickets can now include non-secret node metadata (`id`, `name`, `subtitle`, `kind`). iOS uses that metadata for the connected node row, falling back to the endpoint id if signed-in hive discovery is unavailable.
- iOS handles the existing web Stack Auth deep link (`cmux://auth-callback` / `cmux-dev://auth-callback`), stores the Stack tokens in Keychain, and refuses `rivet_stack` tickets until that session exists.
- iOS fetches and validates the short-lived Rivet pairing secret with the stored Stack Auth session before a `rivet_stack` ticket is allowed to open its transport.
- The iOS terminal detail now stays inside the iPad split-view detail column and resizes the actual Ghostty surface above the software keyboard/accessory bar. The resize source is UIKit's `UIKeyboardLayoutGuide`, with a guide-tracked layout view so floating, docked, and hidden keyboard states invalidate layout through UIKit. XcodeBuildMCP snapshot verification showed the iPad surface shrink from 1290 px high to 843 px while the keyboard was open, then restore to 1290 px after hiding the keyboard.
- A direct WebSocket dogfood run launched iPhone and iPad simulators against the same Rust server in `$HOME/fun/cmux-cli` and attached `cmx attach` to the same socket. Both iOS and cmux-tmux showed `lawrence in ~/fun/cmux-cli on main λ`, and typing `echo IOS_PHONE_SYNC_OK` through iPhone rendered `IOS_PHONE_SYNC_OK` in the cmux-tmux TUI.
- A direct iroh dogfood run launched iPhone simulator tag `irh` with an iroh-only ticket (no WebSocket route). The home screen showed `Lawrence MacBook Pro, iroh dogfood`, opening the workspace showed the shared `lawrence in ~/fun/cmux-cli on main λ` shell, and typing `echo IROH_IOS_FFI_OK` from iOS rendered `IROH_IOS_FFI_OK` through Ghostty.
- Rust tests now cover the old TUI round trip (`Hello`/`PtyBytes`/`Input`), native `libghostty` PTY byte streaming, native layout resize, attached native client layout reporting, multi-client smallest-visible resize after detach, and the rail/bounds helper resize dogfood path.
- `cmux-iroh-bridge` now exposes a reusable Rust client connector and iOS C ABI that takes an encoded bridge ticket, optionally takes the Rivet pairing secret, opens the iroh bidirectional stream, performs the client-side HMAC proof, and frames cmx MessagePack payloads over the authenticated stream.
- The iOS terminal accessory scroller now carries the terminal action set (Esc, Tab, Enter, Backspace, Delete, arrows, Home/End, PgUp/PgDn, tilde, pipe, Ctrl-C/D/Z/L, zoom) plus one-shot/sticky Ctrl/Alt/Shift modifiers. Connected node metadata infers macOS hosts and swaps the bar to macOS-style `⌃`/`⌥` labels with a Mac-only `⌘` control.

The WebSocket route remains an explicit dev fallback for local tickets that include `ws://` or `wss://`. Production tickets without a WebSocket route use the Rust iroh client binding.

## Dogfood attach runbook

Start one shared `cmx` daemon and attach a local TUI to it:

```sh
cd rust/cmux-cli
CMX_SOCKET_PATH=/tmp/cmx-ios.sock cargo run -p cmx --bin cmx -- server --ws-bind 0.0.0.0:8787 --auth-token dev
```

In another terminal:

```sh
cd rust/cmux-cli
CMX_SOCKET_PATH=/tmp/cmx-ios.sock cargo run -p cmx --bin cmx -- attach
```

For the WebSocket dev fallback, launch the installed simulator app with a direct ticket:

```sh
IOS_TAG=irh22
IOS_BUNDLE_ID="dev.cmux.ios.$IOS_TAG"
TICKET='{"version":1,"alpn":"/cmux/cmx/3","endpoint":{"id":"dev-websocket","addrs":[{"Custom":"ws://127.0.0.1:8787?token=dev"}]},"auth":{"mode":"direct"},"node":{"id":"dev-mac","name":"Lawrence MacBook Pro","subtitle":"WebSocket dogfood","kind":"macos"}}'
xcodebuildmcp simulator launch-app --simulator-name "iPhone 17 Pro" --bundle-id "$IOS_BUNDLE_ID" --json "$(jq -n --arg ticket "$TICKET" '{"args":["--cmux-ticket",$ticket,"--cmux-autoconnect"]}')"
```

For the iroh path, expose the same daemon socket through the bridge:

```sh
cd rust/cmux-cli
cargo run -p cmux-iroh-bridge -- --socket /tmp/cmx-ios.sock --allow-insecure-direct --node-name "Lawrence MacBook Pro" --node-subtitle "iroh dogfood" --node-kind macos
```

Press `c` in the bridge terminal to copy the current ticket with OSC 52, then launch iOS with that ticket:

```sh
TICKET="$(pbpaste)"
xcodebuildmcp simulator launch-app --simulator-name "iPhone 17 Pro" --bundle-id "$IOS_BUNDLE_ID" --json "$(jq -n --arg ticket "$TICKET" '{"args":["--cmux-ticket",$ticket,"--cmux-autoconnect"]}')"
```

Once physical devices are unlocked and CoreDevice tunnels are connected, the same ticket can launch the installed device build. XcodeBuildMCP's device launch command does not currently expose process arguments, so this uses `devicectl` only for the final argument-bearing launch:

```sh
xcrun devicectl device process launch --device E4058DA9-F4C7-52DD-951D-0354061B8E89 "$IOS_BUNDLE_ID" -- --cmux-ticket "$TICKET" --cmux-autoconnect
```

The expected proof is the same prompt visible in both clients, for example `lawrence in ~/fun/cmux-cli on main λ`, and text typed from iOS rendering back in the `cmx attach` TUI.

## iroh transport

`cmux-iroh-bridge` exposes a local `cmx` Unix socket over iroh with ALPN `/cmux/cmx/3`. The bridge prints a JSON ticket containing the iroh endpoint address and auth metadata, and the iOS app passes that ticket to the Rust iroh C ABI before sending framed cmx MessagePack payloads.

Tickets may also include node metadata for UI discovery. That metadata is intentionally non-secret and is not an authorization decision. Production auth still comes from Stack identity plus a Rivet-delivered pairing secret proven over the iroh stream before the bridge proxies the local `cmx` socket.

This is not SSH and not a WebSocket tunnel. The transport is iroh's QUIC endpoint with iroh discovery/relay behavior. The application protocol above that stream remains the `cmx` MessagePack protocol, starting with TUI mode for the first iOS sync milestone.

The current bridge defaults to iroh's N0 preset for discovery and relay behavior. It also supports `--relay disabled` for local tests and future self-managed environments. Production must make the discovery/relay policy explicit in settings before relying on it for customer traffic.

## Auth and RivetKit role

Stack Auth owns user identity. RivetKit carries the short-lived pairing control plane: pairing id, encrypted or otherwise protected secret material, device presence, invite/session metadata, and durable account-scoped connection records through actor state, key/value, or database APIs. The terminal stream stays peer-to-peer over iroh.

The bridge does not put the pairing secret in the iroh ticket. The ticket advertises the pairing id, Rivet endpoint, Stack project id, and expiration. A client signed in with Stack asks Rivet for the pairing secret, connects over iroh, receives a nonce, and proves possession with an HMAC before the bridge opens the local `cmx` socket. Direct unauthenticated tickets are only for explicit local development.

The iOS side now has native Stack Auth callback parsing, Keychain persistence, a Stack-authenticated Rivet pairing-secret client, signed-in hive discovery, and a Rust iroh client binding that receives the fetched secret. The server side now has a RivetKit actor keyed by Stack user, a backend service-token guard on actor actions, `/api/hive` discovery, `/api/hive/nodes` upsert, `/api/hive/pairings` upsert, and `/api/hive/pairings/:id/secret` retrieval.

RivetKit docs used for this step:

- https://rivet.dev/docs/actors/state
- https://rivet.dev/docs/actors/connections
- https://rivet.dev/docs/actors/events
- https://rivet.dev/docs/actors/keys
- https://rivet.dev/docs/clients/swift
- https://rivet.dev/docs/general/runtime-modes
- https://rivet.dev/docs/self-hosting/install

## Ghostty decision

The old iOS branch carried Ghostty changes for manual embedded I/O. After checking upstream Ghostty, those cmux-specific manual I/O API changes are still not available upstream.

The iOS app now renders terminal frames with actual libghostty/GhosttyKit, not `libghostty-vt`. The Swift surface feeds PTY bytes into Ghostty's parser, sends user input back through the same store path, and uses Ghostty theme/color rendering. The fork keeps cmux comments on the manual I/O and iOS rendering hooks so they can be removed if upstream Ghostty grows equivalent embedded APIs.

`libghostty-vt` remains useful on the Rust daemon side only for deriving structured native snapshots later. It should not be used as the iOS terminal renderer.

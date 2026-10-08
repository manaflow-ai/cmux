# C9 `ssh`: SSH hosts and sessions on the phone

Status: lane C9 of PLAN.md, 2026-10-06. Branch `feat-cmux-next-ios-c9-ssh` off `feat-cmux-next-ios`
(A1 shell and A2 renderer merged there). Binding: PLAN.md section 4, a1-shell.md (2.3 `HostsStore`,
1.15 SSH parity, 1.4 deferred sign-in), a2-ghostty.md (2.1 `TerminalByteSource`, `.local`).

## 1. What exists and what is reused

`Packages/iOS/CmuxMobileSSH` stays the transport (the Mac links it too): `SSHConnection` (SwiftNIO
SSH over Network.framework, jump hosts through `direct-tcpip`, a handshake deadline that pauses while
a trust prompt waits), `SSHSessionChannel` (PTY request, `window-change`, ordered events),
`SSHHostKey` + `SSHHostKeyVerdict` (OpenSSH SHA256 fingerprints), `SSHKeyStore` (Secure Enclave P-256
and imported OpenSSH keys, secrets in the Keychain `ThisDeviceOnly`), `SSHKeyInstaller` (password
once, then key-only proof). C9 adds only two additive pieces there:

- `SSHKeyStore.generateEd25519Key(label:)` and record kind `generatedEd25519` (Curve25519 raw key in
  the Keychain, never exported).
- `SSHConnection.connect(..., keepalive:)`: kernel TCP keepalive on the outer transport
  (`SO_KEEPALIVE`, idle, interval, count through NIOTS). No app timer sends keepalives, so an idle
  session costs zero wakeups; a dead path surfaces as a closed connection.

The shipping app's `MobileSSHComputers` workspace providers (tmux control mode, screen, cmux-tui
auto install, SFTP) are not ported in this lane; a host opens a login shell. They come back through
C5 (SSH workspaces in the list) and C4 (SFTP) on top of the same connection owner.

## 2. Modules

| Module | Owns | Imports |
| --- | --- | --- |
| `CmuxiOSSSHCore` | config parser, known_hosts file and TOFU verifier, device-local host settings, secret vault, `LocalHostsStore`, `SSHTerminalByteSource`, session state | Foundation, FeatureKit, CmuxMobileSSH, RenderCore |
| `CmuxiOSSSH` | Hosts tab, host editor, config import, keys screen, trust prompts, SSH terminal screen | UIKit, SwiftUI, Core, Design, CmuxiOSTerminal |

The shell gets the Hosts screen by injection: `ShellContent(screens:)` takes tab-to-factory closures
from the composition root, so `CmuxiOSShell` never imports a feature module and lanes stop colliding
on one switch.

## 3. Ownership

- SSH host records (name, address, port, user, jump host) belong to the account's synced host
  store. Today the owner is `LocalHostsStore` on the device (JSON in Application Support, file
  protection complete). `HostsSyncChannel` is the B1 seam: the store publishes each committed
  revision and applies remote records; `DisabledHostsSync` is the default. Paired Macs are not stored
  here (B6 owns them through `DeviceRegistry`); the store refuses them.
- How this device logs in to a host (key id or password) is device state: `SSHHostSettingsStore`
  keyed by `HostID`. Key ids name Keychain items that never leave the device, so they never sync.
- Secrets live only in the Keychain: private keys (`SSHKeyStore`), passwords (`SSHSecretVault`,
  service `dev.cmux.ios.ssh.passwords`, `WhenUnlockedThisDeviceOnly`). Nothing logs a secret,
  a key, a password or a fingerprint; errors carry no payload text.
- Pinned host keys are device state in `SSHKnownHostsFile` (OpenSSH `known_hosts` text,
  `identity algorithm base64`), so a pasted `known_hosts` line can be imported later.
- A new host's id is chosen by the client from its intent key (`HostID.added(by:)`), so the editor
  can bind device settings before the owner's snapshot returns and a replayed add is idempotent.

## 4. Host key trust (TOFU)

`TOFUHostKeyVerifier` computes `SSHHostKeyVerdict` from the pinned key. Trusted: continue. Unknown:
ask "Trust this host?" with the SHA256 fingerprint and algorithm; accept pins it. Changed: a
destructive warning naming both fingerprints; the default action is Disconnect, "Replace key"
re-pins. The handshake deadline is paused while the prompt is up (existing `SSHHandshakeDeadline`).
The prompt is a `SSHTrustPrompter` protocol; the UI implements it with an alert on the presenting
screen.

## 5. `SSHTerminalByteSource` (`.local`)

- `open(viewport)`: connects (jump chain first, each hop verified), opens a session with a PTY of
  the viewport size (`xterm-256color`), starts a login shell and yields `.bytes` in channel order,
  `.path(.direct, nil)` once live, `.title(host name)`.
- `send`: channel writes in call order; throws `FeatureSourceError.offline` while not live (nothing
  queues, U5). Ghostty's query replies reach the server this way.
- `viewportChanged`: sends `window-change` when the grid differs from the last one sent, and only
  while live; the next connect uses the newest viewport.
- Reconnect: when the connection drops (not user close, not auth or trust refusal), state goes
  `reconnecting(attempt)` and a new connection is tried after `SSHReconnectPolicy` backoff on the
  injected clock (one-shot sleeps, cancelled with the source; 0.5 s doubling to 8 s, 5 attempts).
  The renderer keeps its grid; the new shell starts below the old output. A `scenePhase` return or
  user tap retries at once. Terminal states (`failed`, `closed`) end the stream with `.closed`.
- `states()` streams `SSHSessionState` for the screen's banner; the screen never polls.

## 6. Hosts tab

UIKit compositional list (diffable, reconfigure on change) over `HostsStore.updates()`, subscribed
only while visible. Sections: Paired Macs (read-only), SSH, Direct. Row tap on SSH opens the terminal
screen; swipe for Edit and Delete (confirmation); toolbar menu: Add Host, Import from SSH Config,
Keys. Editor (SwiftUI form, low frequency): name, host, port, user, auth (key picker with Generate,
or password stored in the Keychain), jump host picker (other SSH hosts, no self, no cycles), install
key with password. Import: paste `~/.ssh/config`; `SSHConfigParser` reads `Host`, `HostName`,
`Port`, `User`, `ProxyJump` (first hop, mapped to an imported or existing host by alias) and applies
`Host *` defaults; wildcard patterns are skipped; a preview list with checkboxes commits the picked
ones. Keys: list with fingerprint, Generate (Ed25519 default, Secure Enclave P-256 option, Face ID
toggle for enclave keys), Copy public key, Share (activity sheet), Delete.

## 7. Deferred sign-in

The shell gates every tab behind sign-in today. C16 owns deferred sign-in; C9 keeps its store and
screens account-independent (no account id in paths or keys) so the Hosts tab can show signed out
once C16 lets it.

## 8. Tests (Swift Testing, `CmuxiOSSSHCoreTests`)

Config parsing (defaults, wildcards, case, quoting, `ProxyJump` chains, `Port` bounds), known_hosts
round trip and verdicts, TOFU decisions (pin on accept, refuse on decline, replace on changed),
`LocalHostsStore` (add, idempotent replay, update, delete clears jump references, cycle refusal,
paired Mac refusal, persistence across instances, sync publish), reconnect policy, byte source
against a fake session factory (PTY size, window-change dedupe, offline send refused, reconnect
after drop, no reconnect after auth failure). They run with `swift test` on macOS through a scratch
package linking the same sources (the CmuxiOS package is iOS-only), and compile for the simulator.

## 9. Status (2026-10-07)

Done: `CmuxiOSSSHCore` and `CmuxiOSSSH` as above, wired into the shell (`AppContainer` registers
one `LocalHostsStore` as the real `hosts` factory; in DEBUG the seam defaults to its mock, so use
`CMUX_IOS_SOURCE_HOSTS=real` or the DEV switch to exercise the on-device store). 34 Swift Testing
tests in `CmuxiOSSSHCoreTests` pass with `swift test` on macOS (plus the 13 FeatureKit tests after
the `HostID.added(by:)` change); `CmuxiOSApp`, `CmuxiOSSSHCoreTests`, `CmuxiOSShellTests` and
`CmuxiOSFeatureKitTests` compile for `arm64-apple-ios17.0-simulator` with SwiftPM.

Unverified: everything visual and every live SSH path (trust alert, key install, PTY, resize,
reconnect, keepalive drop detection, Secure Enclave keys) on a simulator or device. Tagged build
`nxc9` BLOCKED: `ios/scripts/reload-cloud.sh --tag nxc9` fails on the dev backend VM
(`cmux-dev-backend-1` SSH timeout); with `CMUX_DEV_BACKEND_MODE=local` there is no fleet manifest
(`~/.config/macfleet/hosts.json`), so it falls back to a local Mac build that refuses at 20 GiB free
(floor 40 GiB). Rerun the same command when a fleet slot or disk is available.

Follow-up on 2026-10-07: cmux-tui discovery now retains the validated socket path returned by the
remote listing and attaches with `cmux-tui attach --socket <path>`. This prevents a terminal-launched
owner in one runtime directory from being mistaken for a new owner in the SSH login's directory, and
prevents a vanished owner from being silently recreated. The change is covered by four discovery
regressions and catalog replacement/removal coverage (`931219a37c`, `18ed29075f`). Swift syntax,
scoped package-convention lint, and diff checks pass; native tests and live SSH verification remain
blocked by the unavailable build host.

Remaining parity: tmux multi-pane composition, on-demand history and complete parser-state restore,
SSH create/rename/kill, and hashed cmux-tui sockets. SFTP is landed by E5; importing private keys
and known_hosts lines in the UI (the stores support both), key install through a jump host, and B1
sync behind `HostsSyncChannel` remain follow-ups.

### tmux control attachment slice (2026-10-07)

Modern discovery emits `W2` records with the tmux server PID/start time and stable session/window
IDs. Names and indexes remain labels. `NIOSSHShellConnector` opens `tmux -C -N attach-session`
without a PTY (no protocol echo), checks the discovered server epoch before contributing size or
accepting input, then hydrates the selected window and streams its pane bytes. No selection command
changes another client's active window. Unknown IDs, replaced servers, malformed modern listings,
unsupported layouts and command failures fail closed; there is no name-based fallback for a modern
listing. Workspace and terminal IDs survive rename/reindex and change when the server is replaced.

`SSHTmuxControlChannel` bounds commands (64), input per call (16 KiB), framing (256 KiB line,
2 MiB response), pane inventory (256), and output (128 chunks of at most 16 KiB). It closes on a
reliable-output overflow instead of silently dropping bytes. Each outstanding command sequence has
a cancellable ten-second deadline. `SSHTerminalByteSource` also bounds and chunks its renderer
queue. Reconnect gets a fresh owner snapshot; input bytes are never replayed. tmux layout/lifecycle
notifications trigger catalog rediscovery; there is no sync timer. Capture restores the visible
screen, cursor, margins and standard input modes, preserving binary live bytes and capture escapes.
Attach also requests up to 256 normal-screen scrollback rows and replays them before the visible
rows. The replay requires a complete row-aligned capture; alternate-screen history, truncated
captures and captures beyond the bound fail closed. This gives reconnects useful recent scrollback
without pretending that a raw `.local` byte source can provide on-demand history pages or a complete
GHOSTSNP parser-state restore.

The per-window sizing syntax `refresh-client -C '@id:widthxheight'` and pane output selection are
documented in the [tmux 3.3a manual](https://github.com/tmux/tmux/blob/3.3a/tmux.1), `refresh-client`;
control response framing and notification names follow its `CONTROL MODE` section.

Verification: Swift parsing, scoped iOS convention lint, mobile concurrency/crash-safety checks,
and diff checks pass. Nine focused Swift Testing cases cover fragmented/binary protocol, bounded
framing, stable IDs, replaced-server refusal before resizing/input, malformed targets, snapshot/live ordering,
hex input isolation, bounded history hydration, unsupported layouts, cancellation, and mode/grid
restoration. They are added but not executed: the dedicated
Swift build host is unavailable. No live tmux or simulator/device result is claimed.

Limits: this slice requires a single-pane window and a host-confirmed grid matching the phone
viewport (at most 512 × 256). A mismatched grid, multi-pane layout or pending-wrap snapshot is
refused, because the current `.local` renderer seam cannot reproduce it faithfully. On-demand older
history pages, complete terminal parser state, multi-pane composition and tmux-version compatibility
need live verification and a richer renderer adapter before C9 parity can be marked complete. SSH
create/rename/kill remain deferred: raw SSH commands have no durable idempotency receipt, so a
reconnect-safe owner mutation path is still required.

### Active-pane targeting follow-up (2026-10-07)

Modern tmux discovery now emits one `P2` row per pane and carries the host's
unambiguous active pane id alongside the stable window/server epoch. Control
mode uses that pane id when inspecting a split window, so a matching-grid pane
can be hydrated without selecting a different pane by list order; output from
other panes remains muted. Missing or ambiguous active-pane identity, a stale
server epoch, and a pane whose host-confirmed grid does not match the phone
still fail closed. This is a safe targeting step toward multi-pane parity, not
multi-pane composition: the current terminal source still exposes one pane per
attachment and does not render a layout tree.

### Pending terminal control input hydration (2026-10-07)

The same tmux command sequence now captures `capture-pane -p -P -C` between the visible/history
capture and mode metadata, before enabling live pane output. The phone decodes that pending control
input as bytes and appends it after every screen/mode/cursor restoration escape. An incomplete CSI,
OSC, or DCS therefore remains parser input when its next live bytes arrive, instead of losing the
prefix or consuming the snapshot's own restoration commands.

This follows tmux 3.3a's [pending-capture implementation](https://github.com/tmux/tmux/blob/3.3a/cmd-capture-pane.c)
and [`input_pending` buffer](https://github.com/tmux/tmux/blob/3.3a/input.c). Pending capture uses octal
backslash escaping, unlike the grid capture's doubled backslashes. One response line, at most 64 KiB
encoded and 16 KiB decoded, is accepted. Malformed, multiline, or oversized state closes the attach
before emitting the snapshot; it is never truncated. Pending bytes are cleared on completion/close.

Four new deterministic tests cover control-string/cursor ordering, binary UTF-8 bytes within pending
control strings, malformed/oversized state, and empty state. The fake-peer attachment test now proves
a CSI split across hydration and live output, and a preexisting modern-discovery fixture now supplies
the required `P2` active-pane row. Swift parsing, scoped iOS convention lint, mobile concurrency and
crash-safety checks, and diff checks passed. Native execution remains blocked by the already-confirmed
`cmux-lawrence-2` build-host DNS/SSH failure; no live tmux, renderer, simulator, or device result is
claimed. The recurring connectivity workload is unchanged because this slice changes SSH/tmux
hydration, not its paired-Mac Iroh workload; real SSH attach/reconnect verification remains due.

This closes one parser-state gap only. tmux's `-P` buffer omits incomplete UTF-8 in the ground state;
current pen attributes, saved cursor/charset state, pending wrap, on-demand history, multi-pane layout
composition, and reconnect-safe lifecycle mutations still need follow-up. C9 remains incomplete.

### Read-only split layout model (2026-10-07)

`SSHTmuxLayout` now parses the checksum-prefixed `window_layout` format into a typed split tree
and an ordered pane inventory. Each frame is in host character cells; `{}` means left/right,
`[]` means top/bottom, and one border cell separates siblings. The parser follows tmux 3.3a's
[layout serialization and checksum](https://github.com/tmux/tmux/blob/3.3a/layout-custom.c), checks
exact child coverage, and rejects gaps, overlap, mismatched axes, duplicate pane ids, absent pane
ids, trailing data, malformed numbers, and checksum mismatch. Limits are 16 KiB input, 256 panes,
511 cells, 32 nesting levels, and 65,535 cells per coordinate/dimension; decimal values are parsed
with overflow checks before arithmetic.

Discovery adds read-only `L2` records from `list-windows -a -F ... #{window_layout}` and exposes
validated geometry on `SSHDiscoveredSession.Window.layout`. A layout is retained only if its pane
ids equal the same discovery run's `P2` inventory. Conflicting duplicate or malformed layout rows
invalidate geometry for that window; absent geometry leaves the existing epoch-checked attachment
path intact. Layout ids never become shell input. This is the normal, unzoomed layout returned by
`window_layout`; zoom-aware rendering must separately use `window_visible_layout`.

Eight focused tests cover the published tmux manual fixture, mixed split geometry/order,
checksum/truncation, invalid geometry and ids, numeric bounds, exact pane/depth budgets, discovery
inventory mismatch, and conflicting records. Swift syntax, scoped conventions, mobile concurrency,
crash-safety, and diff checks passed. These new Swift Testing cases have not executed because the
previously confirmed dedicated build-host DNS failure remains unresolved. No live SSH, simulator,
or renderer verification is claimed.

The model is an input to future multi-pane rendering, not a renderer. C9 remains incomplete:
canonical per-pane viewport/input routing and live layout changes still need integration, as do
remaining parser/history gaps and lifecycle mutations. Create/rename/kill are still deferred because
the current read-only SSH seams do not provide durable owner mutation receipts.

### Deterministic pane projection seam (2026-10-07)

`SSHTmuxPaneProjection` is the first carrier-independent seam for composing a validated
`SSHTmuxLayout`. It retains the root host-cell frame and the parser's stable leaf order, marks an
optional host-confirmed active pane, and exposes bounded lookup by pane id. Cell routing only
returns a pane for its interior; tmux's one-cell dividers and cells outside the window return nil.
The projection is immutable, capped at the parser's 256-pane bound, and performs no channel I/O,
pane selection, or renderer lifecycle work, so a future Ghostty composition can own one renderer
per pane while a carrier supplies bytes independently.

Three focused Swift Testing cases cover stable ordering and active state, divider/out-of-window
routing, and unknown active-pane refusal. Swift parsing and diff checks pass; native execution,
live SSH layout changes, and per-pane renderer/input integration remain unverified. This seam does
not promote C9 parity: pane snapshot multiplexing, resize arbitration, lifecycle mutation receipts,
and reconnect-safe renderer composition still need implementation.

### Explicit tmux lifecycle mutation seam (2026-10-07)

`SSHTmuxLifecycleMutation` and `SSHTmuxLifecycleMutating` define the smallest safe
lifecycle boundary for modern tmux windows. The seam carries only host-issued `$session`
and `@window` ids plus the server PID/start epoch; create, rename and kill operations
reject malformed ids, stale/unrepresentable epochs, control characters and oversized
window names. Parameters have canonical `JSONValue` forms (`ssh.tmux.window.create`,
`ssh.tmux.window.rename`, `ssh.tmux.window.kill`) for durable owner records, and
idempotency keys are bounded to printable ASCII. `SSHTmuxLifecycleReceipt` returns the
owner revision and replay bit so reconnect retries can settle without repeating a
mutation.

This is an owner protocol, not an SSH command executor. An implementation must check the
epoch immediately before applying the mutation and persist the operation fingerprint and
idempotency key before returning an applied receipt; an interrupted raw SSH command must
remain indeterminate. The existing `SSHWorkspaceChannel` remains read-only until a host
owner supplies this durable adapter, so this slice cannot claim create/rename/kill runtime
parity. Three focused tests cover wire round trips, hostile fields and bounds; Swift
parsing, mobile concurrency/crash guards and diff checks are the verification gate while
native execution and live SSH lifecycle behavior remain unverified.

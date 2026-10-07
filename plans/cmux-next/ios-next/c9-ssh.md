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

Remaining parity: tmux control mode, SSH create/rename/kill, and hashed cmux-tui sockets. SFTP is
landed by E5; importing private keys and known_hosts lines in the UI (the stores support both), key
install through a jump host, and B1 sync behind `HostsSyncChannel` remain follow-ups.

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

The per-window sizing syntax `refresh-client -C '@id:widthxheight'` and pane output selection are
documented in the [tmux 3.3a manual](https://github.com/tmux/tmux/blob/3.3a/tmux.1), `refresh-client`;
control response framing and notification names follow its `CONTROL MODE` section.

Verification: Swift parsing, scoped iOS convention lint, mobile concurrency/crash-safety checks,
and diff checks pass. Nine focused Swift Testing cases cover fragmented/binary protocol, bounded
framing, stable IDs, replaced-server refusal before resizing/input, malformed targets, snapshot/live ordering, hex input isolation, unsupported
layouts, cancellation, and mode/grid restoration. They are added but not executed: the dedicated
Swift build host is unavailable. No live tmux or simulator/device result is claimed.

Limits: this slice requires a single-pane window and a host-confirmed grid matching the phone
viewport (at most 512 × 256). A mismatched grid, multi-pane layout or pending-wrap snapshot is
refused, because the current `.local` renderer seam cannot reproduce it faithfully. History,
complete terminal parser state, multi-pane composition and tmux-version compatibility need live
verification and a richer renderer adapter before C9 parity can be marked complete. SSH
create/rename/kill remain deferred: raw SSH commands have no durable idempotency receipt, so a
reconnect-safe owner mutation path is still required.

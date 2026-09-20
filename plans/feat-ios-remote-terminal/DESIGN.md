# iOS remote access and encrypted vault

Status: active implementation. This is the full program, not a completion claim.
The goal remains every documented Moshi and Termius feature applicable to the
iOS product, plus native cmux protocol integration. PARITY.md tracks acceptance
and reference-platform gaps without silently dropping requirements.

## Architecture

The existing Ghostty surface renders terminals and emits input and geometry.
An in-process SSH engine handles authenticated connections. Native Swift
packages own SSH session channels, host profiles, credential access, and the
cmux wire protocol. No cmux-tui executable or nested cmux TUI UI is shipped on
iOS. The remote daemon stays on the remote host.

There are two SSH consumers:

- An ordinary shell requests a remote PTY. SSH output becomes terminal bytes;
  input and window changes return on that channel. The app requires an
  authenticated cmux account before it creates or resumes any remote session,
  even when the connection is direct and no sync is enabled.
- A native cmux client opens a non-PTY exec channel for the remote protocol
  entrypoint. Swift consumes workspace/terminal state and drives native mobile
  views. Merely running `cmux-tui attach` and showing a nested TUI does not
  fulfill this requirement.

The current daemon exposes `remote-link --stdio` (framed Noise/session/services)
and `relay --session` (raw JSON lines for an already-running owner).
The relay is documented as a diagnostic bypass of managed preparation and
identity checks, so it is not silently substituted for a supported client.
The implementation must choose and test a supported noninteractive protocol
entrypoint, including version negotiation, startup, terminal continuity,
geometry ownership, and permission failures.

Mosh and ET are native session adapters, bootstrapped with the shared SSH
authentication service. Mosh synchronizes terminal state over UDP; it cannot
carry arbitrary cmux RPC bytes. ET has its own encrypted, resumable TCP
protocol. They share input/output/lifecycle UI contracts, not a fake byte-stream
abstraction that hides these differences.

A normal Linux host without cmux-tui gets SSH and any independently available
Mosh/ET/tmux/Zellij/Herdr features after cmux account authentication.
Installing a remote helper is an explicit action. For cmux-native mode, an
absent or incompatible daemon produces an actionable setup result; no silent
downgrade to a different session.

OS networking owns VPN routing and DNS. A reachable public, LAN, IPv4, IPv6,
or VPN host is supported without a Tailscale-address filter. Jump hosts require
independent authentication and host-key verification for each hop.

## Current implementation and reuse

`Packages/Shared/CmuxRemoteConnections` currently provides validated immutable
profiles, separate credential references, redacted credential material, an
encrypted local profile store, a device-local Keychain adapter, and a bounded
AES-256-GCM record cipher. It also provides an account gate, signed revision
metadata, and explicit personal/team recovery policy. The package is linked
into the iOS composition package only as a dependency; it is not yet used by
the remote UI and does not implement SSH, vault enrollment, recovery execution,
sync transport, durable anti-rollback state, or UI. Its package tests do not
prove app authentication or iPhone behavior.

Existing reuse candidates:

- `CmuxMobileTerminal`: Ghostty surface, terminal input, keyboard, geometry.
- `CmuxMobileShellModel.MobileTerminalOutputSinking`: output consumption and
  renderer backpressure, after separating Mac replay requirements from ordinary
  SSH semantics.
- `CmuxMobileTerminalKit`: keyboard encoding, toolbar, viewport policies.
- `CmuxSyncStore`: transport, local persistence, cursors, bounded snapshots,
  and tombstones. It is not currently an end-to-end encrypted vault.
- Account and Iroh Keychain stores: namespace/access-group conventions, not
  SSH credential policy copied wholesale.
- macOS remote-profile and Mosh command builders: behavior and compatibility
  precedents. Their subprocess execution cannot be reused on iOS.

The earlier SwiftNIO import test ran on macOS and proves only that the two
packages compile together there. Apple SwiftNIO SSH currently omits
keyboard-interactive from its authentication API. Do not select it for full
SSH compatibility based on that experiment. The engine evaluation must test
password, multi-round keyboard-interactive, software and hardware keys,
certificates, agent forwarding, SFTP, and forwarding. A Swift API may wrap a
maintained C SSH library; a Swift package does not require rewriting SSH crypto.

The shared SSH boundary makes account identity, host-key challenge, and lazy
credential loading explicit. The connector returns a credential-free handshake;
the coordinator owns approval and credential loading for that connection. The same gate
will bootstrap Mosh and ET, while their post-bootstrap transport state machines
remain separate.

## Storage and sync boundaries

All remote-profile content is private: host addresses, usernames, labels,
jump-host topology, directory names, snippets, and trust records. If synchronized,
encrypt it client-side just like passwords and exportable SSH keys. Never put
new vault plaintext into existing paired-Mac backup collections.

Keychain holds device-local vault unlocking keys, device identity keys, saved
SSH passwords/software keys/passphrases, and small Mosh/ET resume secrets.
Large protocol checkpoints live in encrypted local files with their wrapping
key in Keychain. Complete resume state must preserve protocol counters and
server identity, not just a key copied into a preference.

Each device's signing/encryption identity stays device-local. Secure Enclave or
external security-key private material is non-exportable; only descriptions and
public keys can synchronize. Imported Ed25519/RSA software key bytes stored in
Keychain are not Secure Enclave private keys.

Do not synchronize live Mosh/ET session secrets by default. Two clients restoring
one cryptographic session can compete for ownership or reuse protocol state.
Cross-device cmux access creates a distinct authorized client and attaches to
the same remote terminals.

Normal profile and credential access is scoped by a stable vault/credential ID.
A shared identity can serve several profiles; deleting one profile removes its
private reference and session secrets, not a key still used by other profiles.
Delete-vault and delete-credential are explicit operations with authenticated
tombstones and local cleanup.

## Vault security contract

The design target is an authenticated cmux account for every remote connection,
with personal and team vaults delivered together. A signed-in account is an
app-level prerequisite for direct SSH, Mosh, ET, cmux protocol, and synced
features. Stack login authorizes the account session and fetching ciphertext; it
does not decrypt credentials or authorize adding an arbitrary device.

- Generate random vault keys on a client. Device enrollment transfers a key
  envelope over an authenticated approval flow with QR/fingerprint binding.
  The shared package's signed X25519 envelope binds account, vault, epoch,
  sender, recipient, ephemeral key, nonce, and ciphertext. The server must not
  substitute a new device public key without detection. Enrollment still needs
  an authenticated membership manifest and user approval before accepting the
  envelope.
- Use independently scoped vaults and key epochs. Authenticate owner, vault ID,
  record ID/type, epoch, revision, deletion flag, and format version.
- The record cipher uses CryptoKit AES-GCM with fresh nonces. It requires
  caller-supplied expected context; it does not infer ownership from ciphertext.
- Key distribution, signed membership, concurrent writes, rollback prevention,
  and offline recovery remain separate required work. The shared package now
  has a merge policy for trusted members, current epochs, stale revisions,
  conflicts, and tombstones, but that policy still needs durable persistence and
  an authenticated membership-manifest source. A symmetric AEAD record alone
  does not prove writer identity or prevent replay of a whole old vault.
- Member/device removal denies future sync and rotates keys for future data.
  Previously disclosed plaintext or keys cannot be clawed back. Removing a
  saved SSH key from the vault does not remove its public key from a server.
- Host trust can synchronize after authenticated device enrollment through
  verified vault records. A server-supplied fingerprint alone grants nothing.
  Changed host keys require an explicit verification flow; conflicting trust
  records must not be merged by timestamp.
- Security policy and credentials use versioned conflict handling, not ordinary
  wall-clock last-writer-wins. Offline deletes must not resurrect access.
- Personal vault membership never follows team membership automatically.
  Read-only sharing also requires authenticated writer authorization, because
  possession of a symmetric decryption key permits manufacturing ciphertext.
- Recovery supports an existing approved device or a user-held recovery key.
  Account password reset cannot decrypt old data. Explicit reset can create a
  new empty vault. Organizations may additionally enable an explicit,
  separately scoped organization-managed recovery path with documented
  administrator authority, member notice, audit events, and a distinct recovery
  key or escrow domain. Organization recovery must never be silently enabled by
  team membership or used for a personal vault.

For local accessibility, use the most restrictive usable Keychain policy.
Biometric access is enforced by Keychain access controls, not just a UI prompt.
A biometric preference cannot promise that already-loaded software keys never
enter memory. App lock must also cover active-session input and loaded vault
state; it does not remotely freeze server processes.

## Acceptance and implementation sequence

Keep the full PARITY.md ledger. The first delivery track runs personal and team
features alongside each other; transport and UI prerequisites still gate both:

1. Native SSH with verified host identity, authentication matrix, plain shell,
   terminal input/resize/backpressure, and saved credential/profile management.
2. Native cmux Swift protocol client and remote workspace/terminal lifecycle.
3. Mosh/ET sessions, multiplexer discovery and recovery, SFTP, tunnels, input
   tooling, and all reference terminal features.
4. Encrypted device enrollment, personal and team vaults in parallel,
   cross-platform sync, recovery/revocation/conflict fixtures, sharing and
   collaboration.
5. Remaining agent, file/diff/browser, dictation, notification/Watch, and
   productivity gaps from the full ledger.

The first positive SSH proof must include a real iOS client talking to a clean
SSH host with no cmux installed. Separate tests must prove native cmux terminal
selection without rendering its outer TUI. Require negative authentication
tests, corrupt streams, Wi-Fi/cellular/VPN changes, background/foreground, app
kill, server loss, and redraw/geometry parity. Vault proof needs two independent
clients, server storage inspection, offline conflicts, revocation, recovery,
and denied access under the wrong account/device.

Use distinct acceptance, interaction/profiling, and final artifact-verification
roles under verify-implementation. Never call package tests iPhone E2E evidence.

## Tooling constraints

No maclease or retired fleet allocation is allowed. `cmux-ci` is the supported
developer-build client; hosted signed iOS tests run on Blacksmith. The initial
package-only workspace lacked a test action. Verification now uses an explicit
signed host with artifact-level entitlement checking.
The worktree initially lacked GhosttyKit; app tests have not passed.
The local dogfood doctor now passes after reinstalling the stable queue tooling
with system Bash. Homebrew Bash deadlocked in heredoc_write; a process sample
identified the blocked setup and only this task's stalled processes were stopped.
The phone is offline or locked; its delivery queue is configured.

## Product decisions

- A cmux account is required before any remote connection, including direct
  SSH, Mosh, ET, and cmux protocol sessions that do not use sync.
- Recovery offers an approved-device path and a user-held recovery key. An
  explicit organization-managed recovery path is also supported for teams, with
  separate scope, authority, audit, and disclosure.
- Personal and team features are delivered alongside each other while the full
  Moshi and Termius parity ledger remains in scope.

## References checked 2026-09-18

- [Moshi connections](https://getmoshi.app/docs/connections)
- [Moshi security/sync](https://getmoshi.app/docs/security-sync)
- [Moshi session recovery](https://getmoshi.app/docs/terminal-sessions)
- [Moshi docs index](https://getmoshi.app/docs)
- [Termius vault](https://www.termius.com/vault)
- [Termius product](https://termius.com/)
- [SwiftNIO SSH authentication](https://github.com/apple/swift-nio-ssh/blob/main/Sources/NIOSSH/User%20Authentication/UserAuthenticationMethod.swift)
- [libssh authentication](https://api.libssh.org/stable/libssh_tutor_authentication.html)
- [Apple Keychain synchronization](https://developer.apple.com/documentation/security/ksecattrsynchronizable)

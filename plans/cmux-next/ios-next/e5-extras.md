# E5 `device-extras`: SFTP, haptics, erase, keep-awake card, deferred sign-in

Status: lane E5 of PLAN.md wave E, 2026-10-07, branch `feat-cmux-next-ios-e5-extras` off
`feat-cmux-next-ios`. Closes the d3-dogfood.md rows 1.4 deferred sign-in, 1.5 keep-awake card,
1.15 SFTP, 1.17 haptics toggle and 1.17 erase all data. Binding: PLAN.md section 4, c9-ssh.md,
c4-files.md 8, c13-viewers.md, c16-platform.md 8 and 9, c10-onboarding.md, c11-settings.md.

## 1. SFTP for SSH hosts

`Packages/iOS/CmuxMobileSSH` already ships an SFTP v3 client (`SFTPClient`, pipelined reads and
writes over the `sftp` subsystem: realpath, stat, lstat, readdir, mkdir, rmdir, remove, rename,
read, write, download, upload). c4-files.md 8 assumed none existed. Writing a second client would
split one protocol across two owners, so E5 extends the existing one:

- `SFTPChannel` protocol (ordered `events`, `write`, `close`); `SSHSessionChannel` conforms, and
  `SFTPClient.open(channel:)` runs the handshake over any channel. Tests drive the client against an
  in-memory SFTP v3 server on a fake channel (no sshd).
- Resume: `download(_:to:resumeFrom:)` reads from the local partial's size and appends;
  `upload(from:to:resumeFrom:)` opens without truncating and writes from the remote size (fstat).
  Both are what C4's resume means ("restart where the bytes end").

New module `CmuxiOSSFTPCore` (Foundation; FeatureKit, SSHCore, ViewersCore, CmuxMobileSSH,
CmuxMobileWire) holds the phone side:

- `SFTPFileSystem` protocol (the client's surface) and `SFTPSessionPool`: one SSH connection per
  host over the same hop chain, TOFU verifier and credentials the terminal uses (C9's
  `SSHHostChain`), opened on first use, reopened on the next call after a drop, closed when the
  browser goes away. No keepalive timer; a dead path surfaces as a failed call.
- `SFTPFileTransfer: FileTransfer` (C4's seam): uploads go to `.directory(path)` destinations,
  downloads to the request's local URL, progress per acknowledged chunk, cancel by task, resume from
  the bytes already there, journal in memory (SSH transfers die with their connection; a relaunch
  starts them again).
- `SFTPViewerContentSource: ViewerContentSource` (C13's seam): one root, the login directory
  (`realpath(".")`); `list` maps entries to `FilesListEntry` (symlinks listed, not followed); git
  reads answer `notARepository`; `fetch` downloads through `SFTPFileTransfer` into the viewers cache.
  It also implements `ViewerFileOperations` (new in ViewersCore: make directory, rename, remove), so
  C13's file browser shows New Folder, Rename and Delete for SSH hosts and never for Macs, whose
  `files.*` wire has no such ops.

UI: Hosts row swipe and context action "Files" on an SSH host pushes C13's browser over the SFTP
source; its Upload button opens C4's picker with a new `FileSendTarget.directory(path)` and the
transfer list over `SFTPFileTransfer`. The SSH module never imports viewers or files: the
composition root injects `SSHFileScreens` (like C14's `SSHBrowserScreens`). Scoping is the server's
(the user's own account); the phone adds no policy.

## 2. Haptics toggle

One owner: `HapticsPreference` (FeatureKit, Foundation) reads and writes
`cmux.mobile.hapticFeedbackEnabled`, the shipping app's key, so an existing choice carries over;
missing means on. `Haptics` (CmuxiOSDesign, UIKit) is the only type that creates feedback
generators; every call site (feed outcomes, onboarding, toasts, QR scan, terminal selection, Home
tapback) calls `Haptics.play(_:)`, which checks the preference first. Settings > Preferences >
Haptics is the toggle. Tests: gating with a recording emitter, default on, persistence.

## 3. Erase All Data

Settings > Erase All Data (last section, both signed in and signed out). Flow: explanation sheet,
the user types the localized confirmation word (`EraseConfirmationRule`: trimmed, case and width
insensitive), then: sign out through the normal owner (revokes the install and removes the push
target while the session works), stop links and SSH sessions, run the wipe, show a final screen that
asks the user to close cmux (stores already in memory must not write back; the next launch is fresh).

`EraseAllDataPlan` (SettingsCore, pure) lists exactly what goes:

| Item | Scope | Why it is ours |
| --- | --- | --- |
| Keychain: generic and internet passwords, keys (incl. Secure Enclave SSH keys), certificates, identities, synchronizable any | the app's own access group | entitlements claim only `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` (the extension shares that group) |
| Application Support, Caches, Documents, tmp contents | the app sandbox | sandbox paths are per app |
| Standard defaults | persistent domain = bundle id | per app |
| App group `group.dev.cmux.ios` | only `<container>/<bundle id>/` and the suite keys prefixed with the bundle id | the group id is shared by every build of the team, so the container itself is never removed |
| URL cache, cookies, website data, delivered and pending notifications | this process | per app |

This covers every lane's store without a per-lane list: hosts, device SSH settings, known_hosts,
passwords and keys (C9), transfer journal and viewers cache (C4, C13), drafts and composer
attachments (C8), onboarding progress (C10), terminal and notification preferences (C11),
diagnostics log, remote config cache and What's New (C16), auth tokens and install identity.
`EraseAllDataExecutor` runs a plan against `KeychainWiping`, `FileWiping` and `DefaultsWiping`
seams and reports per-item failures (the final screen names them). Tests: the plan's contents, that
no path outside the given roots is touched (a sibling directory survives), the group namespace rule,
the confirmation rule, failure reporting.

## 4. Keep Mac Awake onboarding card

New step `keepAwake` after `pair`, shown when signed in, first run, and `offersKeepAwake` (the new
DEV flag `keepAwake`, off in every build, and a `KeepAwakeControl` registered; the mock stands in
until D1b registers the Mac's). The card mirrors `KeepAwakeControl.updates()` joined with the
device registry's Mac names (`KeepAwakeCardProjection`, pure): one toggle per Mac that reports
support, "not available" for the rest, Continue and Skip. Toggles are intents with receipts;
offline refuses (U5). Lane D1b only has to fill `AppContainer.keepAwakeFactory` and turn the flag on.

## 5. Deferred sign-in

Implements c16-platform.md 9. `AccessState` (Platform, pure): `restoring`, `signedOut`, `guest`,
`signedIn(account)`, derived from `AuthState` plus the persisted guest choice
(`GuestModeStore`, `dev.cmux.ios.next.guest.v1`). Signed in always wins.

- Entry: "Use SSH Without an Account" on the sign-in screen (standalone and onboarding's embedded
  one). Choosing it stores the choice and shows the guest shell; onboarding stays where it was.
- Guest shell: Hosts (SSH and direct only, the device-local `LocalHostsStore`, never the mock) and
  Settings (Sign In row instead of the profile, no Devices or Delete Account, Terminal, Haptics,
  Privacy, Diagnostics, Erase All Data). Feed, Workspaces, Compose, Cloud, Search and Home are
  hidden because their owners are account-scoped DOs; a route to one of them parks in the router
  and shows a sign-in prompt toast. `ShellRoute.allowsGuest` marks hosts, settings, diagnostics and
  What's New; `ShellRouter.setAccess(.guest)` delivers those.
- SSH works fully: keys, passwords and pins are device state already (c9 3), terminals and SFTP
  need no account.
- Local data offered on sign-in: hosts added while guest are recorded in `GuestHostsLedger`
  (through a `HostsStore` decorator, one intent key per add). After sign-in, when the ledger names
  hosts that still exist, an alert offers "Sync to Account" or "Keep on This iPhone". Sync sends one
  idempotent adopt intent per host (key derived from the host id) through `HostsAccountAdopting`;
  today it publishes through C9's `HostsSyncChannel`, a no-op until B1 serves host sync, so the
  hosts stay usable on this device either way. Both answers clear the ledger.
- Dogfood auto-login: `GuestAccessPolicy` ignores a stored guest choice when the launch carries
  automated sign-in (`CMUX_UITEST_STACK_EMAIL` or the readiness nonce), so the tagged launcher
  still lands signed in. `CMUX_IOS_GUEST=1` (DEBUG) starts as guest for UI tests.

## 6. Verification (2026-10-07)

- `CmuxMobileSSH`: all 91 tests green on macOS (`swift test`), including 13 new
  `SFTPClientFakeChannelTests` against the in-memory SFTP v3 server (handshake, readdir, stat,
  pipelined read/write across chunks, short reads, mkdir/rename/remove/rmdir, status mapping,
  resume for both directions, cancellation between chunks, dropped channel).
- `CmuxiOSFeatureKitTests`, `CmuxiOSSettingsCoreTests`, `CmuxiOSOnboardingCoreTests`,
  `CmuxiOSPlatformTests`, `CmuxiOSSSHCoreTests` and the new `CmuxiOSSFTPCoreTests`: 201 tests green
  on macOS through a scratch package linking the same sources (the CmuxiOS package is iOS-only).
- `CmuxiOSApp` builds for `arm64-apple-ios17.0-simulator` with SwiftPM (one build, scratch
  deleted). `CmuxiOSShellTests` changes compile with it but were not run (iOS-only, CI).
- Not run: any simulator or device UI. The SFTP browser, Settings rows, erase flow, keep-awake card
  and guest shell are UNVERIFIED on a device; no tagged build was attempted (disk at 12 GiB, no fleet
  manifest, lane rules).

Residual: viewer error copy still says "Mac" for SSH hosts ("No Connection to This Mac"); the
diagnostics log can append a line after the wipe before the app closes; host sync after sign-in is
a republish through the B1 seam, so other devices see the hosts only once B1 serves host sync.

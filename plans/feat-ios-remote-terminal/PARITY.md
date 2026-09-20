# iOS remote terminal parity acceptance ledger

Status: **acceptance draft, every row unverified (`U`)**. This document is an
independent evidence plan for the full product goal: a native iOS/iPadOS remote
terminal that supports Moshi and Termius capabilities, arbitrary SSH hosts,
Mosh and ET carriers, and a native cmux-tui protocol client. It is not a claim
that the nearby implementation is complete. The current worktree contains a
design and an unlinked shared package; neither is evidence of behavior.

Research snapshot: 2026-09-18. The source index below is limited to official
Moshi and Termius documentation available at that date. Where Termius exposes a
feature only on its marketing page, the row says so and requires a product
contract or a documented API before it can pass. Missing or desktop-only
details remain explicit instead of being inferred.

## Evidence rules

Every row remains `U` until the implementation and an independent verifier
produce behavior-level evidence from the final commit SHA. A passing packet
must include:

1. focused Swift/unit/protocol tests for the row, including malformed input,
   cancellation, reconnect, authorization, and secret-handling cases where
   applicable;
2. an end-to-end run against a disposable Linux host fixture (OpenSSH, tmux,
   Mosh, and ET fixtures as applicable), plus an isolated iOS Simulator with a
   unique UDID;
3. a physical iPhone run for VPN routing, background/reconnect, push, camera or
   file-provider, and hardware-key rows. A simulator result cannot pass a
   physical-device row;
4. screenshots for stable UI states, a video plus frame split for transitions,
   and logs or packet traces proving the wire behavior. Artifacts must record
   final commit SHA, simulator UDID/device ID, host fixture image, and test
   command;
5. a negative proof for every row: the listed failure must be observed and
   surfaced safely. “No crash” or “the source contains a type” is insufficient.

Status meanings: `U` = unverified; `P` = independently proven from final SHA;
`F` = failed or contradicted; `G` = source/documentation gap requiring a
contract or explicit scope record before a parity claim is possible. A `G` row
is an evidence limitation, not an automatic request for user permission on
ordinary implementation choices. Rows marked
`desktop/reference` are not silently dropped: they need either a deliberate
iOS adaptation or an explicit documented non-goal.

## Test fixtures and security invariants

The acceptance harness must provision disposable fixtures with: an OpenSSH
server supporting password, public-key, keyboard-interactive and agent
forwarding; a bastion chain; a host-key rotation; a tmux, Zellij and Herdr
session; optional `mosh-server`; optional `etserver`; SFTP files with hidden,
large, conflicting and unreadable entries; a local HTTP dev server; and an
agent-hook fixture emitting approval, question, tool, completion and usage
events. It must also run a malicious server that sends invalid VT/SSH/SFTP
frames and a server that attempts to read credentials.

Security is a gate, not a feature toggle. Private keys, passwords, passphrases,
Mosh/ET resume secrets, cmux-tui enrollment or attach tickets, vault keys and
session cookies must never be unintentionally exposed in ordinary profile
records, analytics, logs, screenshots, crash reports, clipboard history, or
server plaintext. User-authorized public-key export, private-key copy, or host
provisioning must require an explicit biometric-confirmed action and must be
audited. Host keys are trust observations: an authenticated, approved vault
record may synchronize a pin, but a raw server fingerprint must never grant
trust and a changed key must require verified resolution. Synced private data
must be end-to-end encrypted. Server ciphertext inspection is necessary but
not sufficient: key-custody and device-enrollment substitution tests must show
that a server operator cannot decrypt or mint a device envelope. Device
approval, revocation, recovery, deletion/tombstones, and offline conflict
behavior must be tested on at least two devices.

## Source index

### Moshi

* **M-INDEX**: https://getmoshi.app/docs
* **M-CONNECTIONS**: https://getmoshi.app/docs/connections
* **M-SESSIONS**: https://getmoshi.app/docs/terminal-sessions
* **M-TAILSCALE**: https://getmoshi.app/docs/tailscale
* **M-MUX**: https://getmoshi.app/docs/multiplexer
* **M-TMUX**: https://getmoshi.app/docs/tmux
* **M-ZELLIJ**: https://getmoshi.app/docs/zellij
* **M-HERDR**: https://getmoshi.app/docs/herdr
* **M-SCROLLBACK**: https://getmoshi.app/docs/scrolling
* **M-VOICE**: https://getmoshi.app/docs/voice
* **M-GESTURES**: https://getmoshi.app/docs/gestures
* **M-CLIPBOARD**: https://getmoshi.app/docs/clipboard
* **M-KEYBOARD**: https://getmoshi.app/docs/keyboard
* **M-CJK**: https://getmoshi.app/docs/cjk-input
* **M-SECURITY**: https://getmoshi.app/docs/security-sync
* **M-AGENTS**: https://getmoshi.app/docs/agents-usages
* **M-WATCH**: https://getmoshi.app/docs/apple-watch
* **M-IMAGE**: https://getmoshi.app/docs/image-paste
* **M-HOOKS**: https://getmoshi.app/docs/hooks
* **M-HOOK-SETTINGS**: https://getmoshi.app/docs/hook-settings
* **M-CHAT**: https://getmoshi.app/docs/chat-view
* **M-CLI**: https://getmoshi.app/docs/moshi-cli
* **M-LIVE**: https://getmoshi.app/docs/live-activity
* **M-DIFF**: https://getmoshi.app/docs/diff-viewer
* **M-BROWSER**: https://getmoshi.app/docs/browser-preview
* **M-NOTIFY**: https://getmoshi.app/docs/notifications
* **M-FILES**: https://getmoshi.app/docs/files

### Termius

* **T-INDEX**: https://docs.termius.com/llms.txt
* **T-OVERVIEW**: https://docs.termius.com/getting-started/what-is-termius
* **T-IMPORT**: https://docs.termius.com/getting-started/import-existing-hosts
* **T-CONNECT**: https://docs.termius.com/organize-and-connect-to-hosts/connecting-to-a-server
* **T-SFTP**: https://docs.termius.com/organize-and-connect-to-hosts/managing-files-with-sftp
* **T-FORWARD**: https://docs.termius.com/organize-and-connect-to-hosts/port-forwarding-and-tunneling
* **T-GROUPS**: https://docs.termius.com/organize-and-connect-to-hosts/groups-and-tags
* **T-LOGS**: https://docs.termius.com/organize-and-connect-to-hosts/session-logs
* **T-WORKSPACES**: https://docs.termius.com/terminal/workspaces
* **T-SNIPPETS**: https://docs.termius.com/terminal/snippets
* **T-AUTOCOMPLETE**: https://docs.termius.com/terminal/autocomplete-and-shell-integration
* **T-MOBILE**: https://docs.termius.com/terminal/mobile-terminal
* **T-KEYS**: https://docs.termius.com/keychain/ssh-keys-and-certificates
* **T-IDENTITIES**: https://docs.termius.com/keychain/identities
* **T-CREDENTIAL-SYNC**: https://docs.termius.com/keychain/sync-of-keys-and-passwords
* **T-TEAM**: https://docs.termius.com/team-collaboration/team-management
* **T-TEAM-VAULTS**: https://docs.termius.com/team-collaboration/team-vaults
* **T-TEAM-LOGS**: https://docs.termius.com/team-collaboration/team-session-logs
* **T-SSH-ID**: https://docs.termius.com/ssh-id-passkeys-for-ssh/what-is-ssh-id
* **T-SSH-ID-USE**: https://docs.termius.com/ssh-id-passkeys-for-ssh/setup-and-usage
* **T-SSH-ID-SECURITY**: https://docs.termius.com/ssh-id-passkeys-for-ssh/ssh-id-security
* **T-ENCRYPTION**: https://docs.termius.com/security/encryption-overview
* **T-PRODUCT**: https://termius.com/

The Termius documentation index lists no dedicated public page for terminal
multiplayer, serial, or export formats. `T-PRODUCT` advertises terminal
multiplayer, SFTP, Vault, Keychain, port forwarding, snippets, known hosts,
and logs, but that is not a wire contract. Those rows are `G` until Termius
publishes enough detail or we define and test our own compatible behavior.

## Acceptance ledger

### Transport, host profiles, and cmux-tui

| ID | Source | Scope | Positive acceptance | Negative/edge acceptance | Required evidence | Status |
|---|---|---|---|---|---|---|
| R-00 | cmux account contract | iOS/iPadOS | A valid authenticated cmux account session is required before creating, resuming, or importing any remote profile or session, including direct SSH, Mosh, ET, and native cmux protocol connections. Account state is visible and survives ordinary app relaunch according to the auth contract. | Signed-out, expired, wrong-account, and revoked-device states block connection setup before network credentials are read or a remote socket opens. No anonymous local-only mode and no account bypass for unsynced connections. | Auth-gate tests across every carrier, signed-out UI evidence, blocked-network trace proving no remote connect, and account/session audit events. | U |
| R-01 | M-CONNECTIONS, M-TAILSCALE, T-CONNECT | iOS/iPadOS | Save label, host, port, username, auth reference, jump chain, carrier choice and session preference. A normal iOS socket reaches an OpenSSH host through an OS-level Tailscale/WireGuard/corporate VPN without a cmux VPN extension. | No VPN SDK, public-IP assumption, or hidden relay. Unreachable route and DNS failure show actionable errors without leaking credentials. | Simulator plus physical iPhone on a disposable tailnet/LAN and a blocked route; socket route and host logs. | U |
| R-02 | M-CONNECTIONS, M-SESSIONS, T-CONNECT | iOS/iPadOS | Native SSH supports password, public key, keyboard-interactive/2FA, host-key verification, PTY, exec, input, resize, EOF and cancellation. | Wrong password, denied keyboard challenge, refused PTY, malformed SSH message and cancellation close cleanly. | Protocol tests plus OpenSSH fixture with each auth mode and a server transcript. | U |
| R-03 | M-CONNECTIONS, M-TAILSCALE, T-CONNECT | iOS/iPadOS | Carrier selector supports Auto, SSH, Mosh and ET; Auto follows the documented fallback order and explicit modes never silently downgrade. | UDP blocked, missing server binary, jump-host route or ET port failure reports the carrier and allows an explicit SSH retry. | Four fixture matrices with carrier logs and no unexpected fallback. | U |
| R-04 | M-CONNECTIONS | iOS/iPadOS | Key profile fields support custom `mosh-server` path, UDP range, ET TCP port, SSH jump host and multiple jump hosts where supported. | Invalid port/range/path and incompatible Mosh/jump settings are rejected before connect. | Form validation tests and real custom-port fixture. | U |
| R-05 | T-CONNECT, T-OVERVIEW | iOS/iPadOS/reference | Host model can expose SSH, Mosh, Telnet, Serial and SFTP protocols per host, plus proxy/jump settings; local terminal is explicitly classified desktop-only if not shipped. | Unsupported protocol never appears as a falsely working option; unavailable host capability is visible. | Protocol capability matrix and iOS UI evidence. | U |
| R-06 | design contract (cmux-tui) | iOS/iPadOS + cmux-tui host | Swift package speaks cmux-tui’s remote protocol directly over the selected secure channel, including identify, workspace/session discovery, attach, VT replay, output, resize, input, detach and reconnect. It renders through the existing Ghostty surface. | No bundled `cmux-tui` executable, no nested TUI UI, no shell-string scraping, no unvalidated command construction. Unknown protocol version/frame, auth failure and stale ticket fail closed. | Interop test against the cmux-tui fixture, capture decoded protocol transcript, replay after reconnect, and screenshot of the native cmux surface. | U |
| R-07 | T-CONNECT, M-INDEX | iOS/iPadOS | After cmux account authentication, an arbitrary Linux/macOS/VPS/WSL/homelab OpenSSH host works without cmux helper installation; optional host helper discovery is explicit and authenticated. | Signed-out state blocks setup before host access. Missing cmux-tui/moshi-hook/tmux still gives a usable shell after sign-in; no connection side effect installs a binary or grants host access. | Bare-host fixture, auth-gate evidence, and install refusal audit. | U |

### Mosh, ET, persistence, and multiplexers

| ID | Source | Scope | Positive acceptance | Negative/edge acceptance | Required evidence | Status |
|---|---|---|---|---|---|---|
| M-01 | M-CONNECTIONS, M-SESSIONS | iOS/iPadOS | Native Mosh bootstrap over SSH starts `mosh-server`, authenticates the session, carries terminal input/output, survives Wi-Fi↔cellular/VPN path changes, sleep and app relaunch, and resumes visible state. | UDP blocked or malformed Mosh cryptographic/state packets trigger clear SSH fallback only in Auto, never in forced Mosh; no silent data loss claim. | Native Mosh protocol tests, network path transition recording, packet/state logs and resume screenshot. | U |
| M-02 | M-CONNECTIONS, M-SESSIONS | iOS/iPadOS | Native ET adapter bootstraps `etserver`, uses configurable TCP port, reconnects over TCP after sleep/network change and resumes the durable host session. | Missing/old ET server, incompatible protocol, wrong port or replayed checkpoint is rejected; resume secrets remain protected local state or encrypted checkpoint. | ET fixture/version matrix, reconnect video and encrypted-storage inspection. | U |
| M-03 | M-MUX, M-TMUX | iOS/iPadOS | Detect and pick tmux sessions, attach/create, switch windows/panes, expose shortcuts, and automatically reattach after full reconnect. `moshi DIR` behavior is optional only if implemented as a safe host command. | tmux missing, inaccessible socket, invalid session name and stale session are reported; no shell injection via directory/session input. | Fixture with multiple windows/panes, reconnect and invalid names; command audit. | U |
| M-04 | M-MUX, M-ZELLIJ | iOS/iPadOS | Detect Zellij, list sessions, attach/create, expose tab/pane shortcuts, approvals/question/image bridge, and tap-to-open session deep link where supported. | Do not claim tmux/Herdr-only Jump-To tree, deep links, prefix customization or reconnect auto-attach unless independently implemented and documented. | Zellij fixture with capabilities matrix and explicit unsupported-state UI. | U |
| M-05 | M-MUX, M-HERDR | iOS/iPadOS | Detect Herdr sessions and workspaces/tabs/panes, expose shortcut panel and hook context, show blocked/working/done state and Jump-To targeting. | Missing Herdr or unsupported host version degrades to shell, never invents agent status. | Herdr fixture, hook event transcript, deep-link and reconnect evidence. | U |
| M-06 | M-SCROLLBACK, M-SESSIONS | iOS/iPadOS | Maintain bounded app scrollback, visible-screen replay on reconnect, host-side tmux scrollback, active session switching, close/reconnect and resume-last-session. | App scrollback is not advertised as complete host history; mosh reconnect does not fabricate bytes that were never transmitted. | Long-output fixture, reconnect comparison and memory bound trace. | U |

### Terminal input, accessibility, and mobile surfaces

| ID | Source | Scope | Positive acceptance | Negative/edge acceptance | Required evidence | Status |
|---|---|---|---|---|---|---|
| I-01 | M-GESTURES, T-MOBILE | iOS/iPadOS | Configurable tap/double/triple tap, swipes, two-finger pane/session switch, pinch zoom, drag/long-press cursor movement and custom shortcut bindings work without stealing terminal selection. | Conflicting gestures, VoiceOver/Switch Control, rotation and split-view do not send duplicate or unsafe input. | UI video + frame split and accessibility tree for each gesture family. | U |
| I-02 | M-KEYBOARD, T-MOBILE | iOS/iPadOS | Toolbar, D-pad, Enter/Backspace, paste, keyboard show/hide, history, hardware Cmd shortcuts, Option-as-Meta, custom multi-step shortcuts, volume-button actions and extended keyboard work. | Hardware keyboard absent, unsupported shortcut, volume action conflict and keyboard dismissal leave terminal usable. | Simulator keyboard plus physical keyboard/iPhone run; event transcript. | U |
| I-03 | M-CLIPBOARD, M-CJK, T-MOBILE | iOS/iPadOS | Select/copy/paste, OSC 52 host→iOS clipboard, tmux clipboard pass-through, CJK/Japanese/Korean/Chinese IME composition and UTF-8 output work. | OSC 52 over-limit payload is bounded or rejected safely; clipboard permission denial and IME composition never corrupt bytes. | Locale matrix, OSC 52 fixture, clipboard trace, screenshot of composed text. | U |
| I-04 | M-VOICE | iOS/iPadOS | Dictation supports configured on-device/cloud engines, model/language selection, chat composer, editable transcript, auto-send toggle, image attachment and transcription history. | Offline model missing, cloud quota/permission denial and unsupported language explain fallback; audio never leaves device for on-device engines. | On-device/offline and cloud-denial tests, privacy/network trace, UI video. | U |
| I-05 | M-SECURITY, M-INDEX | iOS/iPadOS | Themes, fonts/CJK fallback, cursor, language, notifications, accessibility, biometric-on-key-use and biometric-on-resume settings are persisted safely. | Settings sync does not move secrets when credential sync is off; locked device blocks protected action. | Two-device settings sync with server ciphertext and Keychain dump audit. | U |

### Moshi hooks, agents, files, browser, and notification surfaces

| ID | Source | Scope | Positive acceptance | Negative/edge acceptance | Required evidence | Status |
|---|---|---|---|---|---|---|
| A-01 | M-HOOKS, M-AGENTS, M-HOOK-SETTINGS (vendor reference) | iOS/iPadOS + optional cmux-owned host integration | An optional cmux-owned host helper/agent integration, designed from the vendor reference tiers, reports all supported agents’ lifecycle, approval, question, tool, completion and usage events through the authenticated host route. Events are grouped by host/project/session and approvals/questions can be answered. | No helper means ordinary shell/terminal remains fully usable. Unknown agent event or expired approval is shown as unavailable, never auto-approved. The app must not require or silently install `moshi-hook`; vendor protocols are not assumed compatible. | cmux helper/agent fixture emits every supported event, agent capability matrix covers the full declared agent set, approval audit and terminal/native-surface parity screenshot. | U |
| A-02 | M-CHAT (vendor reference) | iOS/iPadOS | A cmux-owned native agent view may overlay the same live terminal session, render messages/tool cards/plans/images/diffs, send prompts and supported approvals to that session, and close without changing terminal state. | No duplicate agent, no transcript upload to cmux cloud, unsupported action routes to terminal. Vendor Chat View wire behavior is reference evidence only; no Moshi gateway is required. | cmux host transcript vs rendered messages, close/reopen replay and network capture. | U |
| A-03 | M-WATCH, M-LIVE, M-NOTIFY | iPhone + watchOS | Watch inbox shows project/host grouped events, answers approvals, shows usage rings and complication; iOS Live Activity/Dynamic Island shows active session/agent/event and opens the right surface; push can pause/resume and fan out only to opted-in devices. | Watch cannot open a shell, tmux, scrollback, dictation or image paste. Missing push permission, revoked token and stale event do not cause unsafe action. | Physical iPhone + Watch recording, APNs delivery receipts, approval authorization trace. | U |
| A-04 | M-IMAGE, M-FILES | iOS/iPadOS | Camera/photo/clipboard/document-picker file can be SCP’d to host or uploaded to an expiring short URL; chat mode can attach arbitrary files and image paste inserts a host path or URL as documented. | Size/type/expiry/network failures do not leave partial secrets or stale public URLs; no upload without explicit user action. | Fixture filesystem, URL expiry test, file provider run and privacy trace. | U |
| A-05 | M-BROWSER, M-DIFF | iOS/iPadOS + optional host helper | Detect allowlisted loopback HTTP dev servers, create per-session authenticated SSH local forward bound only to device loopback, open in in-app browser; show git staged/unstaged/untracked diff with file navigation. | No public tunnel or host exposure; session close tears down forward; missing helper/repo/HTTP server shows muted unavailable state. | Port scan allowlist, `127.0.0.1` bind check, browser screenshot, diff fixture and teardown log. | U |
| A-06 | M-NOTIFY, M-HOOK-SETTINGS | iOS/iPadOS + host helper | Host-level discovery, usage collection, nested-agent suppression, unlocked-console suppression and scan-port allowlist have explicit settings and restart semantics. | Disabled setting blocks its side effects; settings cannot silently probe unrelated ports or upload usage. | Config diff, restart test and network/port probe audit. | U |

### Termius host organization, vaults, sync, and teams

| ID | Source | Scope | Positive acceptance | Negative/edge acceptance | Required evidence | Status |
|---|---|---|---|---|---|---|
| T-01 | T-OVERVIEW, T-GROUPS | iOS/iPadOS | Personal and team vaults contain hosts, groups/tags, protocols, snippets, forwarding, known-host records and session metadata. Groups nest, inherit protocol/credential/jump/theme settings, and search/navigation are deterministic. | Moving/deleting a group does not orphan or broaden access; inherited override precedence is explicit. | Two-vault fixture, nested group mutation and authorization snapshot. | U |
| T-02 | T-OVERVIEW, T-TEAM, T-TEAM-VAULTS | iOS/iPadOS + web/account admin where required | Personal vault, default team vault and custom team vaults support invite/remove, per-vault edit/view permissions, move/copy entities, ownership transfer, required 2FA and optional SSO. Viewer role controls vault writes and cmux-managed session policies. | A revoked member is denied future vault sync and writes; the vault epoch/key is rotated for remaining members; managed live sessions are terminated where the host acknowledges; remaining host keys can be explicitly revoked. Do not claim remote erasure of plaintext or cached keys already held by a device. A viewer who is given a raw host credential can use that credential according to the host’s own permissions, including arbitrary SSH execution; vault/UI read-only cannot prevent that. | Two accounts + revoked-device test, epoch rotation/device-envelope trace, managed-session termination acknowledgement, host-key revocation and ciphertext/access logs, plus an explicit raw-credential boundary test. | U |
| T-03 | T-CREDENTIAL-SYNC, T-ENCRYPTION, M-SECURITY | iOS/iPadOS/macOS | Profile metadata and encrypted private data sync offline-first across at least two devices. A per-user vault key encrypts records; per-device device-only keys receive envelopes only after approval; conflict/tombstone rules are deterministic. | Server sees only ciphertext/metadata, not host secrets. Credential-sync-off keeps credentials local. Lost/revoked device cannot unwrap new data or write new revisions. Host-key trust may sync only through authenticated approved vault records; a changed key requires verified local resolution. Recovery policy is explicit. | Server database inspection plus key-custody/device-enrollment substitution test, two-device offline conflict run, Keychain access-group dump, revoke/recovery test and packet capture. | U |
| T-04 | T-ENCRYPTION, T-SSH-ID, T-SSH-ID-SECURITY | iOS/iPadOS + hardware | Local Keychain stores private credentials and device identity with appropriate accessibility and biometric gate. SSH ID style device-bound keys keep private parts non-exportable; only public keys sync/publish. | Biometric failure/reboot/locked Keychain blocks use; user-authorized private-key export/copy or host provisioning requires explicit biometric confirmation and audit; public key cannot be accepted as private key; deletion removes linked credentials. | Keychain entitlement/accessibility inspection, biometric denial and approval, authorized export audit, public/private parser tests. | U |
| T-05 | T-KEYS, T-IDENTITIES | iOS/iPadOS | Generate/import/paste SSH keys and certificates, store passphrases, show fingerprint, export public key for `authorized_keys`, link one identity to multiple hosts/groups, and use FIDO2/security-key and biometric keys where platform supports. | Malformed/encrypted/unsupported key, wrong passphrase, public key in private field, missing hardware token and user-presence denial fail safely. | Key type matrix (Ed25519/RSA/ECDSA/cert/FIDO2), hardware key run, no-secret log scan. | U |
| T-06 | T-IMPORT | iOS/iPadOS + desktop import bridge | Import `~/.ssh/config`, `known_hosts`, key files and documented PuTTY/other source formats with preview, deduplication and credential confirmation. Export at least public keys/profile data in a documented interoperable format. | Unknown directives, duplicate aliases, unsupported encrypted files and path traversal are rejected; no secret copied to clipboard/logs without confirmation. | Fixture import corpus, round-trip hash/diff, malformed-file tests. | U |
| T-07 | T-PRODUCT (marketing; source gap) | iOS/iPadOS | If we support Termius-style terminal multiplayer, two authorized users join one host session with quick handoff and one-writer-at-a-time arbitration, with per-user presence/audit. | Unauthorized invite, concurrent writer, revoke and disconnect cannot inject input. | Two-device physical E2E session, arbitration trace, access audit. | G |

### Termius terminal, SFTP, forwarding, and productivity

| ID | Source | Scope | Positive acceptance | Negative/edge acceptance | Required evidence | Status |
|---|---|---|---|---|---|---|
| T-08 | T-CONNECT, M-CONNECTIONS | iOS/iPadOS | SSH password/key, Mosh, SFTP, jump/proxy chain and any deliberately supported Telnet/Serial protocols are selectable per host; a host can expose multiple protocol views without duplicate credentials. | A protocol unsupported on iOS is clearly marked desktop/reference; no fake local-terminal or serial support. | Protocol capability UI and fixture matrix. | U |
| T-09 | T-SFTP | iOS/iPadOS | Multiple SFTP tabs browse remote directories, refresh, hidden files, full paths, download/upload files/folders, copy between hosts, track progress/conflicts/errors, and open downloaded files through Files/provider. | Permission errors, symlink loops, large transfer cancellation, conflict choice, offline resume and deleting a download follow explicit safety semantics. | SFTP fixture with hidden/unreadable/conflict files, transfer queue logs, video and local Files evidence. | U |
| T-10 | T-SFTP | iOS/iPadOS | Download-edit-upload loop works through iOS Files/editor; remote file changes are detected and upload is explicit. | Do not claim desktop in-place editor or arbitrary app filesystem access; deletion from transfer view must match our documented local-storage policy. | Edit conflict fixture and file hash before/after. | U |
| T-11 | T-FORWARD, T-CONNECT | iOS/iPadOS | Local, remote and dynamic SOCKS forwarding support host/port selection, start/stop/status, multi-hop target and loopback browser use. | Reserved/in-use iOS port, denied forwarding, target unreachable and session close tear down listeners without exposing LAN/public bind. | `NWListener`/socket bind inspection, local/remote/SOCKS fixture and teardown test. | U |
| T-12 | T-WORKSPACES | iOS/iPadOS/iPad | Workspace groups multiple terminal sessions, supports focus/split views, reorder/resize, broadcast input, save/restore templates and active-session monitoring. iPad split can be richer than iPhone but behavior remains deterministic. | Broadcast requires explicit confirmation and never crosses unauthorized vaults; one session failure does not kill others; unsupported desktop max (16) is documented if not matched. | iPhone/iPad UI video, split geometry, broadcast audit and template round trip. | U |
| T-13 | T-SNIPPETS, T-AUTOCOMPLETE | iOS/iPadOS | Vault-synced snippets support labels/packages, startup snippet, side-panel run/paste/edit, autocomplete insertion, multi-host execution and team sharing. | Shell quoting, target selection and startup execution are previewable and cancellable; no accidental multi-host run. | Multi-host fixture, dry-run/confirmation and audit output. | U |
| T-14 | T-AUTOCOMPLETE, T-OVERVIEW | iOS/iPadOS | Autocomplete suggests snippets, shell history, paths, built-ins/arguments and matching identities/password prompts; command history can run, paste or save as snippet. AI command generation, if shipped, is opt-in and its account/network/data use is visible. | Never auto-submit a password or AI command; PowerShell/CMD limitation is shown if applicable; offline and no-shell-integration cases degrade to manual input. | Prompt fixture, sensitive-password redaction trace, offline test and AI consent/network capture. | U |
| T-15 | T-MOBILE | iOS/iPadOS | Touch cursor arrows, double-tap Tab, pinch text size, copy/paste, volume-button bindings, side-panel keyboard/shortcuts/password/snippets/history and image/file paste work with hardware keyboard and VoiceOver. | iOS permission denial, external keyboard disconnect and accessibility navigation do not lose or duplicate input. | UI video/frame split and accessibility action log. | U |
| T-16 | T-LOGS, T-TEAM-LOGS | iOS/iPadOS | Session log recording is per vault, encrypted, searchable/bookmarkable/commentable where authorized, synced for permitted team members, and keeps documented recent-log replacement semantics. | Hidden password input is not recorded, plaintext terminal output warning is shown, logs are read-only and cannot be silently exported/deleted/moved. | Log fixture with visible/hidden secrets, vault permissions, bookmarks/comments and server ciphertext inspection. | U |

### Explicit desktop/reference and source-gap ledger

| ID | Reference/source | What must be decided or documented | Required evidence before claiming parity | Status |
|---|---|---|---|---|
| G-01 | T-OVERVIEW, T-WORKSPACES, T-SFTP | Desktop-only dual-pane SFTP, local filesystem pane, drag/drop between desktop windows, up-to-16 split terminals and desktop editor integration need iOS adaptations or an explicit non-goal. | Product decision plus iPhone/iPad acceptance rows that cover the chosen adaptation. | G |
| G-02 | T-CONNECT, T-INDEX | Termius documents Telnet, Serial and Local Terminal in its protocol list, but the public index has no iOS-specific contract for all three. | Decide whether to implement native iOS transports or mark desktop/reference; tests must match the decision. | G |
| G-03 | T-PRODUCT, T-INDEX | Termius marketing advertises terminal multiplayer, hardware security keys/MFA, keygen, known hosts, logs, port forwarding and secure vault sharing; detailed multiplayer/export/import contracts are absent from the fetched docs. | Obtain product requirements or define our own wire/UI contract; do not use marketing copy as protocol proof. | G |
| G-04 | M-INDEX, M-HOOKS, M-CHAT (vendor reference) | Moshi host helpers (`moshi-hook`, gateway, CLI, `moshi` launcher) describe a useful optional integration, not a dependency or protocol requirement for cmux. Build a cmux-owned equivalent only where the product contract needs it. The iOS app must not ship or silently install competitor binaries, and native cmux-tui must remain a Swift protocol client. | Host-without-helper E2E plus direct cmux-tui protocol interop and cmux-owned helper/agent fixture. Vendor helper behavior is reference evidence only. | U |
| G-05 | M-WATCH, M-LIVE, M-NOTIFY | Watch, Live Activity and APNs require app extensions, entitlements and physical-device verification; simulator-only evidence cannot prove them. | Physical iPhone/Watch run with delivery receipts and revocation/offline behavior. | U |

## Completion gate

The feature is not complete while any required row is `U`, `F`, or unresolved
`G`. The orchestrator must attach a fresh evidence manifest for every row,
record separate implementer, interaction/profiling and verifier identities,
and send every rejected row back for implementation plus fresh artifacts. A
source page, a passing unit test, a compile, or a screenshot of a happy path
cannot close an end-to-end row by inference.

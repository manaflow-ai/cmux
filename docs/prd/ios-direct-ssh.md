# PRD: Direct SSH from cmux iOS

Status: **Product interview complete (D1-D19); D8 SSH library spike next** · Owner: Aziz · Started 2026-09-23 · Worktree `worktrees/feat-ios-direct-ssh`

## Goal

From the cmux iPhone app, open a terminal on any computer by connecting to it directly over SSH. No iroh, no cmux relay, no paired cmux Mac in the middle.

## How iOS connects today (for contrast)

The phone never talks to a computer's shell directly. It pairs with a **cmux Mac app**, and the Mac streams terminal bytes to the phone over our own transports (irx / DO relay, earlier iroh). The phone renders those bytes in an embedded Ghostty surface (`Packages/iOS/CmuxMobileTerminal`). The target machine must run cmux, be signed into the same account, and be reachable through our relay.

Useful fact: because the phone already renders a raw byte stream in Ghostty, an SSH channel's output can feed the same surface. The renderer is reusable; the transport is new.

The macOS app already has SSH (`Sources/RemoteTmuxSSHTransport.swift`, remote tmux via the system `ssh` binary). iOS cannot run `/usr/bin/ssh`, so iOS needs an in-process SSH library.

## SSH in 60 seconds

- **SSH server (sshd)** listens on the target, usually TCP port 22. Linux servers have it on; macOS needs *System Settings → General → Sharing → Remote Login*.
- **Reachability**: the phone must open a TCP connection to `host:22`. Easy on the same Wi-Fi. Across the internet it needs a public IP + port forward, a VPN like Tailscale, or a jump host. This is the single biggest product constraint, since we are removing the relay that solved it.
- **Host key**: the server proves its identity with a key. Client remembers it on first connect (TOFU, "trust on first use") and warns loudly if it changes (possible man-in-the-middle).
- **User auth**: password, or a keypair (private key stays on phone, public key goes in the server's `~/.ssh/authorized_keys`). Keys are the norm; passwords are the easy on-ramp.
- **Channels**: one SSH connection multiplexes many channels (a shell with a PTY, port forwards, SFTP file transfer).
- **iOS backgrounding**: iOS suspends the app ~30s after backgrounding and the TCP socket dies. The remote shell then gets hung up and its processes may die, unless the remote side runs `tmux`/`screen`, or we use **mosh** (UDP, survives roaming and sleep, needs `mosh-server` on the host).

## Decisions

_Filled in as the interview answers them._

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | What counts as "any computer" | **Any machine with an SSH server.** Plain/tmux give a shell; **cmux-tui mode adds cmux's own primitives (workspaces, persistent terminals, multi-device attach) over SSH**, so an SSH host feels like a cmux computer without the Mac app. v1 phone surfaces workspaces, terminals, and browser surfaces (D23); not cmux-tui pane layouts. | Universal reach, cmux UX where cmux-tui is installed. Unverified: which agent notifications / sidebar features cmux-tui exposes to clients. |
| D2 | Network paths supported | **All of them.** Connect to any `host:port` the phone can route to (LAN, Tailscale/VPN, public IP, IPv6, custom ports, DNS names) plus multi-hop jump hosts (ProxyJump). | Accommodate every user. SSH is network-agnostic, so LAN/VPN/public need no special work; only jump hosts need explicit support. |
| D3 | Auth methods | **Keys only**: phone-generated Secure Enclave key (P-256, Face ID optional) + imported existing key (Ed25519/RSA/ECDSA, OpenSSH format, passphrase support). No password in v1. | Security first; keys are the norm. Password used only once to install the key (D16). |
| D4 | Surviving app backgrounding | **Persistent PTY: closing the connection never kills the shell.** Offer every option and let the user pick per host (see Persistence modes). | User wants Moshi-style persistence and choice. |
| D5 | cmux sign-in required? host sync? | **No account needed. Hosts stored locally on this phone only**, no sync. Keys in Keychain / Secure Enclave. | Simplest and most private; SSH usable right after install. |
| D6 | Where it lives in the UI | **Computers list, in its own "SSH" section**, the same way Tailscale and iroh routes get their own sections today. "Add Computer" gains an SSH option. | One place for all computers, with the connection type still visible. |
| D7 | MVP extras (tabs, SFTP, port fwd, agent fwd) | **v1: multiple sessions per host, port forwarding (opens in the native in-app browser), SFTP file browser.** `~/.ssh/config` import pending explanation. | User picks. |
| D8 | SSH library | _open (recommendation below)_ | |
| D9 | Persistence choice | **User picks per host on first connect: cmux-tui (recommended), tmux, Eternal Terminal (ET), mosh, plain.** | Aziz 09-23: use cmux-tui instead of cmuxd-remote; support plain/ET/mosh/tmux alongside. |
| D10 | cmux-tui install source | **Phone downloads the exact pinned cmux-tui build from npm (integrity-verified), caches it, and uploads it to the server over SSH** into `~/.local/bin/cmux-tui`. | App stays small; server needs no internet or Node. Phone needs internet once per cmux-tui version. |
| D11 | Screen restore on return | **Exact screen restore, free with cmux-tui**: attach sends a `vt-state` Ghostty replay (screen, colors, cursor, modes, images) before live output (`cmux-tui/docs/protocol.md:128-151`). | Replaces the replay+redraw workaround. |
| D12 | Session scrollback | **50 MB, cmux-tui's default** (`crates/cmux-tui-core/src/surface.rs:56`), identical to Mac terminals. Phone keeps 16 MB locally and pages older lines on demand (`read-scrollback`). | "Same scrollback as other cmux terminals." No helper change needed. |
| D13 | Idle session close | **User-configurable per host: 1 h / 24 h (default) / 7 days / never.** cmux-tui has **no idle reaping today** (runs until `server stop`), so this is new cmux-tui work, plus a running-sessions list to close forgotten ones. | User request. |
| D14 | `~/.ssh/config` import | **Later phase.** v1 = add-host form (with jump host field). | User pick. |
| D15 | Mode phasing | **v1: plain, cmux-tui, tmux** (SSH-only). **v1.1 ET, v1.2 mosh** (each needs an iOS client port + user-installed server). v1 picker lists ET/mosh as "coming soon". | Ship persistence fast; ET/mosh are large C++ ports. |
| D16 | First-time key install | **"Password once, then forget"**: user enters the server password one time; cmux logs in, appends the phone's public key to `~/.ssh/authorized_keys`, discards the password (never stored, never logged). All later logins use the key. | Smoothest onboarding; standard `ssh-copy-id` behavior. Users who imported a key the server already trusts skip this. |
| D17 | Server identity key changed | **Stop and ask.** Refuse to connect, explain in plain words (reinstalled server vs possible impersonation), show old/new fingerprints, offer "I reinstalled it, trust the new one" or Cancel. | OpenSSH-equivalent safety, protects on public Wi-Fi. |
| D18 | Face ID on keys | **Per-key setting, default off.** | Instant auto-reconnect after backgrounding; opt-in for stricter users. |
| D20 | cmux-tui stream format | _Proposed:_ **`bytes` attach mode** (one-time `vt-state` snapshot, then live PTY bytes into the phone's Ghostty). Alternative `render` mode mirrors the paired-Mac render-grid model. See *Rendering: paired Mac vs SSH*. | Phone owns geometry (D19) so the server and phone grids always match, both ends are Ghostty, and it reuses the phone's existing raw-bytes path. |
| D21 | Session presentation | **SSH sessions use the exact same workspace terminal screen as paired-Mac workspaces**: back button, toolbar buttons, title area, composer bar, keyboard accessory row, and all gestures. No separate SSH-specific terminal UI. | One consistent terminal experience. Implies the screen's Mac-backed actions (composer paste, image paste, file chips, title/theme) get an SSH-backed implementation behind the same UI (see *Preserving today's iOS terminal features*). |
| D22 | Host screen | **Tapping an SSH host opens its workspace list, exactly like a paired Mac.** cmux-tui: its real workspaces (shared with other attached clients). tmux: tmux sessions. plain: shells opened from this phone (gone when closed). `+` starts a new one. | Same mental model as Macs; realizes D7 "multiple sessions per host". |
| D23 | cmux-tui browser surfaces | **v1: show them in the existing streamed browser view** (`Packages/iOS/CmuxMobileBrowserStream`), via an adapter from cmux-tui's `browser-state` + base64 PNG `frame` events and its pointer-frame acknowledgment (`cmux-tui/docs/concepts.md:59`, `docs/protocol.md`). Only appears when the server runs a `cmux-browser` provider (cmux-tui never launches Chrome, `cmux-tui/README.md:105`). | Same model as Mac browser streaming; reuse screen, gestures, dialogs. Risk: PNG frames over SSH on cellular are heavier than the Mac stream (unmeasured). |
| D19 | Shared session resize | **Phone always wins**: attaching from the phone claims cmux-tui "geometry authority"; a simultaneously attached laptop crops/pans. | Phone is the constrained screen. |

## Keys explained (for D16-D18)

- **Your key pair** = padlock + key. Private key (the key) is created in the iPhone's Secure Enclave and never leaves it. Public key (the padlock) is safe to share. The server lists padlocks it accepts in `~/.ssh/authorized_keys`; at login the phone proves it can open the padlock without sending any secret.
- **Server identity key** = the server's own key pair, so the phone knows it reached the real server. Phone remembers its fingerprint on first connect and checks it every time. A change means either a reinstall/recreated VM/reassigned IP (common, harmless) or someone impersonating the server (rare, dangerous). The phone cannot tell which.

## Round 2 decisions (2026-09-24)

| # | Decision |
|---|---|
| D24 | tmux maps session = workspace, pane = tab (via tmux control mode), windows as groupings; New Terminal = new window. The phone attaches through its own linked session so the laptop's view never moves. |
| D25 | Plain mode: each shell is a workspace row; no terminal tabs. cmux-tui: New Terminal creates a terminal in the workspace. |
| D26 | Browser: one design (bottom controls). Streamed stays the default; a per-browser picker switches to On iPhone (native WebKit). SSH On iPhone routes through a SOCKS5 proxy over SSH plus a loopback port mirror. |
| D27 | On iPhone for paired Macs via a Mac-side TCP relay lane, default deny (Mac loopback only; opt-in for other hosts; metadata/link-local always refused). Separate PR #14301. |
| D28 | Files live on the terminal Files chip (opens at the shell's folder). No separate open-port feature: typing localhost in the browser works. |
| D29 | UX: quiet "Use with SSH only" sign-in option; mode-aware empty states with Mac-parity status; + asks which computer under All Computers; declined identity prompts pause auto-connect persistently. |
| D30 | tmux is never installed for the user; cmux-tui is the zero-install path. |

## Persistence modes (D4/D9 detail)

Every persistent mode needs a process on the server that outlives the SSH connection. The difference is who installs it.

| Mode | Server needs | User installs? | Survives | Screen on return | iOS client work |
|---|---|---|---|---|---|
| **cmux-tui** (recommended) | Linux/macOS x86_64/arm64 | **No**: cmux uploads it over SSH | disconnect, app kill | **exact** (`vt-state` replay) | Swift client for cmux-tui's attach protocol over SSH stdio (small; JSON lines) |
| **tmux** | `tmux` | Often preinstalled on Linux, not macOS | disconnect, app kill | exact (tmux redraws) | none beyond SSH |
| **Eternal Terminal (ET)** | `etserver` running, TCP port 2022 open | **Yes** | disconnect, app kill, network switch | as tmux if combined; plain otherwise | port ET client (C++, protobuf, crypto) |
| **mosh** | `mosh-server` + UDP 60000-61000 open | **Yes** | disconnect, network switch, sleep | exact (state sync) + instant local echo | port mosh client (C++, protobuf, OCB crypto) |
| **plain** | nothing | No | nothing | n/a | none |

## cmux-tui as the persistence layer

cmux-tui (`cmux-tui/`, Rust) is cmux's shipped terminal multiplexer: latest `cmux-tui-v0.13.4` (2026-09-16), published to npm/PyPI, very active (371 commits since 09-01). Mac app's `cmux ssh` still uses the older Go `cmuxd-remote`; the Cloud team is already moving VMs to cmux-tui because of cmuxd-remote's 1 MiB raw-replay corruption (`cmux-tui/docs/cloud-cmux-tui-daemon.md`).

**How the phone would use it**
1. SSH in, probe `uname`, check for `~/.local/bin/cmux-tui` (cmux-tui's own remote-install location).
2. If missing, install it (D10).
3. Open an SSH exec channel running `cmux-tui relay --session <name>`: it pipes the channel to the session's Unix socket, and starts a detached headless owner if none runs (`spec/transports.md:159-185`, `docs/getting-started.md:56-61`).
4. Attach in `bytes` mode: server sends a `vt-state` replay of the full screen, then live PTY output, which feeds the phone's existing Ghostty surface. Keystrokes and resizes go back the same way.
5. Disconnect = the client leaves; the session owner and its shells keep running.

**What it stores on the server**: session state in SQLite under the platform state dir (macOS `~/Library/Application Support/cmux-tui/sessions`, Linux XDG state dir); Unix socket at `$XDG_RUNTIME_DIR`/`$TMPDIR`/`/tmp` `cmux-tui-<uid>/<session>.sock`. Relay does no network listening; access is via your SSH login.

**Bonuses**: several clients can attach to one session at once (phone and laptop side by side); sessions hold workspaces/tabs, so D7 "multiple sessions per host" maps onto it; a Mac running cmux-tui could see the same sessions.

**Gaps to build**
- Idle close policy (D13): cmux-tui never reaps today.
- Attach protocol v12 is labelled a *private implementation interface*; we need the cmux-tui owners to treat the phone as a supported client (or use resource API v2).
- Resize: phone claims geometry authority on attach (D19).
- Binary size (~40-45 MB): handled by phone download+upload (D10); first upload over slow cellular takes a while, show progress.

## Rendering: paired Mac vs SSH

- **Paired Mac today**: the Mac is the only terminal emulator. It sends **render-grid frames** (the finished screen as rows of styled cells, then deltas; `Packages/iOS/CmuxMobileShell/.../TerminalOutputTransportSelection.swift`), and the phone paints them. Raw bytes are only a fallback for older hosts.
- **Plain / tmux over SSH**: no server-side emulator of ours. The SSH channel carries the raw PTY output and the phone's Ghostty emulates it, like any SSH app.
- **cmux-tui, `bytes` mode**: on attach the server sends one `vt-state` payload: a *synthesized* escape-sequence snapshot that rebuilds the current screen, cursor, colors, modes, and images in one shot. It is **not** a replay of every byte ever printed. Then live PTY bytes stream and the phone's Ghostty emulates them; a resize brings a fresh `vt-state` (`cmux-tui/docs/protocol.md:128-151`). Older scrollback is paged via `read-scrollback`. _Unverified: whether `vt-state` itself carries any scrollback._
- **cmux-tui, `render` mode**: server sends `render-state` / `render-delta` (styled text runs, like the Mac's render grid), phone just paints (`cmux-tui/spec/render.md`). Different wire format from the Mac's, so it needs a new painter.

| | `bytes` (proposed) | `render` |
|---|---|---|
| Emulators | two (server + phone), both Ghostty, same grid size (phone owns size) | one (server) |
| Bandwidth | lowest (raw output) | higher (styled rows) |
| Phone work | reuse existing raw-bytes path + snapshot reset | new painter for cmux-tui render format |
| Divergence risk | low, only if Ghostty versions differ in edge cases | none |

**Per-mode behavior.** Live phase is the same everywhere except mosh: raw PTY bytes into the phone's Ghostty. Modes differ only on reconnect, which needs a server-side emulator that has been tracking the screen.

| Mode | Server-side emulator | Reconnect |
|---|---|---|
| plain | none | nothing to restore; shell died |
| tmux | tmux | tmux redraws the screen (its own snapshot). Loses some modern features (e.g. images); history stays inside tmux, so native phone scroll covers only post-attach output unless we use tmux control mode (`-CC`, already used by the Mac) to fetch history |
| ET | none (buffers unacked bytes) | resends missed bytes after a network drop; no help after app kill |
| cmux-tui | Ghostty | exact `vt-state` snapshot |
| mosh | mosh's own | screen diffs, not raw bytes; needs its own painter (v1.2) |

Cross-mode requirement: keep the phone's Ghostty surface in memory across suspension, so short disconnects need only missed output; snapshots matter mainly after iOS kills the app.

**Live output path (`bytes`)**: server reads a PTY chunk, feeds it to its own emulator (source of the next `vt-state`), and forwards the identical bytes as an `output` frame in order; the phone feeds them straight into its Ghostty. No re-rendering in between.

**Terminal query replies: one answerer per mode (avoidable, not inevitable).** Programs ask the terminal questions (cursor position, device attributes, colors). Exactly one emulator must reply. The rule is a single per-session setting chosen by mode, never both:
- **cmux-tui → server answers.** cmux-tui's emulator already writes its replies into the PTY (`cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs:5292-5298, 5380-5387`). The phone keeps today's rule of dropping every byte its Ghostty generates (`Packages/iOS/CmuxMobileTerminal/.../GhosttySurfaceView.swift:5546-5559`); real keystrokes use a separate path (`inputProxy`), so they're unaffected. The `vt-state` snapshot is synthesized state, not old output, so stale queries are never replayed (the root cause of the Mac bug #10332).
- **plain / tmux / ET → phone answers.** No emulator of ours on the server (tmux answers its programs itself and asks the phone as its terminal), so the phone must forward its Ghostty's replies to the SSH channel.
- Phone-generated input that is *not* a reply (mouse wheel/click in TUIs, focus reports, bracketed paste) is routed explicitly in both modes, never through the drop/forward switch.
- Guard with tests per mode: send `ESC[6n` and assert exactly one reply reaches the PTY.

## Preserving today's iOS terminal features

Audit of which features depend on the paired Mac (full inventory with citations in the audit notes, summarized here). SSH sessions feed the phone's own Ghostty, so most features are local already; the rest need an SSH-native replacement.

**Work unchanged**: native scroll mechanics, scroll-to-bottom on keystroke, keyboard top reveal, font zoom, title, bell, "View as Text" copy, OSC 52 clipboard write, rendering pipeline (output parsed off-main, display-link coalesced 30-120 Hz: same path that makes today's rendering fast).

**Need a small adapter**
- **Pixel-precise scrolling + uncapped momentum + docked-at-tail**: the engine only uses local Ghostty (`GhosttySurfaceView+LocalPixelScroll.swift`), but it's gated to Mac render-grid sessions. Open the gate for SSH, detect primary vs alternate screen locally (today learned from Mac frames), add a rows-pushed counter for scrollback eviction. Today's raw-bytes fallback is whole-row with momentum cut at 0.45 s, so this is required for parity.
- **Scrollback**: phone owns it; never wipe it after the first snapshot (today's raw-bytes replay prefix clears it).
- **Input latency**: keystrokes go straight onto the SSH channel, no RPC ACK fences. Echo latency = network round trip to the server (no local echo prediction today either; mosh would add it later).
- **Resize**: send SSH `window-change` with the phone's natural grid; no letterboxing needed.
- **Liveness**: SSH keepalives + channel EOF instead of Mac event-stream watchdogs.
- **Render-pipeline rebuild**: refetch cmux-tui `vt-state` (or `^L` redraw for tmux/plain) instead of a Mac replay.
- **Output overflow**: needs its own policy (today leans on a Mac replay).

**Mac-only today, need SSH versions**: TUI tap/mouse clicks and alt-screen wheel (encode mouse locally), composer paste (local bracketed-paste wrap), image paste and file chips (SFTP), theme (local default), notifications (handle OSC 9/777 locally). Keystroke encoder ignores cursor-key/kitty keyboard modes today; worth fixing with local Ghostty modes.

## Port forwarding (D7 detail)

SSH "local forwarding": the app opens a listener on the phone's own `127.0.0.1:<port>`; anything connecting to it is carried through the SSH connection and comes out on the server as a connection to `localhost:3000` (or any host:port the server can reach). The native in-app browser (`Packages/iOS/CmuxMobileBrowser`, a real `WKWebView`, the Safari engine) then loads `http://localhost:<port>`. This is **not** the streamed browser (`CmuxMobileBrowserStream`), which shows video frames of a browser running on a paired Mac. Forwarding gives real native scrolling, text input, and websockets (dev-server hot reload works). Limits: the tunnel lives only while the app is foregrounded (iOS suspends it), and Safari.app itself can't use it reliably, only the in-app browser.

## SFTP (D7 detail)

SFTP is a file-transfer protocol that runs inside the same SSH connection. It does not grant anything new: it acts as the SSH user you logged in as, with exactly that user's Unix file permissions, the same files `ls`/`cat` could already touch in the terminal. It is on by default in almost every sshd, so it needs nothing installed. v1 UI: browse folders, preview text/images, download to Files, upload from Files/Photos.

## Requirements (draft, v0)

_To be written after D1-D7._

## Non-goals (draft)

- Password as an ongoing login method (only used once for key install, D16).
- cmux-tui pane layouts on the phone.
- Replacing the paired-Mac transport for cmux Macs (unless D1 says otherwise).
- Running an SSH **server** on the phone.

## Technical notes

- **Library options (D8)**: SwiftNIO SSH (Apple, pure Swift, Ed25519/ECDSA, no RSA, no SFTP) · Citadel (built on NIO SSH, adds RSA keys, SFTP, convenience client) · libssh2 (C, battle-tested, needs OpenSSL build) · mosh would need its own C++ client port. Leaning **Citadel/NIO SSH** for a Swift-native stack; verify RSA + `ssh-ed25519` + OpenSSH key format support before committing.
- **Secure Enclave keys are P-256 (ECDSA) only**, not Ed25519. Servers accept `ecdsa-sha2-nistp256` by default, so it works, but users with an existing Ed25519 key need import (stored in Keychain, not SE).
- **Local Network permission**: connecting to LAN IPs triggers the iOS Local Network prompt (we already request it for pairing).
- **App Store**: SSH clients are allowed (Termius, Blink ship). No review risk expected.
- Terminal rendering reuses the Ghostty surface; resize must send SSH `window-change`.

## Build status (2026-09-24)

Branch `feat-ios-direct-ssh`, PR https://github.com/manaflow-ai/cmux/pull/14149, dev tag `dssh`. Videos in `artifacts/dssh/` (simulator, isolated device `cmux-dev-dssh`, lab sshd on 127.0.0.1:2222).

| Area | Status | Evidence |
|---|---|---|
| No-account entry, add host, import key, TOFU trust (D5, D16-prompt, D17 first-use) | Verified on video | `01-*.mp4`: fingerprint matches `ssh-keygen -lf` |
| cmux-tui session: create, type, phone geometry (D19), survive app kill (exact screen) | Verified on video | `01-*.mp4`: `stty size` 52x66; PERSIST-MARK after kill |
| SFTP browse, text/image preview, new folder, photo upload (D7) | Verified on video | `02-*.mp4` + server `ls` |
| Port forward into native browser (D7) | Verified on video | `02-*.mp4` + server access log |
| Computers SSH section, jump host, tmux persistence across app kill (D2, D6, D9) | Verified on video | `03-*.mp4`: same `top` PID after relaunch |
| Host identity changed: stop and ask, cancel blocks login, trust new key (D17) | Verified on video | `04-*.mp4`: sshd auth count unchanged on cancel |
| Secure Enclave key generate + login; encrypted key import wrong/right passphrase (D3, D18) | Verified on video | `05-*.mp4` + sshd `Accepted publickey ECDSA SHA256:Up8z…` |
| Engine: exec, PTY, resize, jump hosts, SFTP, forwards, key parsing/decryption, installer, cmux-tui client | Lab tests (51 + 11) | `swift test` vs real sshd |
| cmux-tui idle close policy (D13) | Hosted CI green (Linux + macOS) | Needs a cmux-tui release; phone gated on capability |
| Bugs found on video and fixed (timeout during trust prompt, cancel message, auto-connect, Mac sheets in SSH mode, autocorrect, replayed query leak) | Fixed + tests; re-verification pending on rebuild | |
| tmux first open sometimes blank (B6) | **Open**: renders after reopen; root cause unconfirmed | |
| Password-once key install (D16) | **Unverified in app**: lab sshd has no password auth; installer command lab-tested with key auth | |
| cmux-tui browser surfaces (D23) | **Unverified live**: no cmux-browser provider in lab; wire tests only | |
| Native pixel scrolling on SSH surfaces | **Unverified**: simulator harness cannot synthesize scroll gestures | |
| Scrollback above a running full-screen app after reattach | Needs cmux-tui server change (`vt-state` sends only the alternate screen) | |

## Backlog

- ET client (v1.1), mosh client (v1.2).

- `~/.ssh/config` import (D14).
- Embedded Tailscale for unreachable hosts (Q-net-beyond).

## Changelog

- 2026-09-23: PRD created, recon of current iOS transport done, interview round 1 queued.
- 2026-09-23: Round 1 answered: D1 plain shell, D2 all networks + jump hosts, D3 keys only, D4 persistent PTY with user choice. Found `cmuxd-remote` persistent PTY as a zero-install option.
- 2026-09-23: Round 3: D9 user picks among all 4 persistence modes, D10 bundle, D11 replay+redraw, D12 16 MB scrollback, D13 configurable idle close, D14 ssh config later.
- 2026-09-23: Round 4: D15 mosh to backlog, D16 password-once key install, D17 stop-and-ask on host key change, D18 Face ID per-key default off.
- 2026-09-23: Aziz: use cmux-tui instead of cmuxd-remote; support plain, ET, mosh, tmux too. D9/D11/D12/D13/D15 updated, D10 reopened.
- 2026-09-23: D10 phone downloads+uploads cmux-tui, D15 v1 = plain+cmux-tui+tmux (ET v1.1, mosh v1.2), D19 phone wins resize.
- 2026-09-23: D21 SSH sessions presented exactly like workspace terminal sessions.
- 2026-09-23: D22 SSH host opens a workspace list like a Mac.
- 2026-09-23: D1 updated: cmux-tui mode brings cmux workspaces over SSH.
- 2026-09-23: D23 cmux-tui browser surfaces in v1 via the streamed browser view.

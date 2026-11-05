# cmux Remote: one host for Computer Use and Screen Sharing

cmux Remote is the one process on a Mac that holds the macOS grants for
Accessibility and Screen Recording. Both features that need them run under it:
cmux Computer Use (agents see and use apps) and cmux Screen Sharing (another
Mac or an iPhone sees and controls this Mac). A person grants the two
permissions once, to **cmux Remote**, and never quits or relaunches the cmux app
afterwards: a grant reaches the feature by restarting only the worker that
needs it.

## Process tree

```
cmux.app (the person's app; never holds a grant)
  └─ cmux-tui daemon          (started by the app, outlives it; setsid)
       └─ cmux Remote host    (posix_spawn with responsibility disclaimed:
          │                    macOS checks grants against cmux Remote itself)
          ├─ Computer Use worker   (`cmux-remote worker computer-use`)
          └─ Screen Sharing worker (`cmux-remote worker screen-sharing`)
```

- **Identity.** One signed bundle, `cmux Remote.app` (`com.cmuxterm.remote`;
  DEV builds `cmux Remote (dev).app`, `com.cmuxterm.remote.dev`), with the
  cmux icon on a remote-screen badge. Its designated requirement (bundle id +
  team) stays the same across builds, so a grant survives every update. DEV
  builds embed one pinned, Apple Development signed copy
  (`scripts/cmux-next/cmux-remote-dev.pin.json`), as the Computer Use helper
  did; Release signs it with Developer ID.
- **Responsibility.** The daemon starts the host with
  `responsibility_spawnattrs_setdisclaim`, so the host is its own responsible
  process. Workers are the host's ordinary children: macOS attributes their
  Accessibility and Screen Recording checks to the host. Shells, agents and the
  cmux app never inherit the grants.
- **Outside the app bundle.** macOS 26 checks Screen Recording for a process
  that runs from inside an app bundle as the outermost app. The daemon runs a
  verified copy at `~/Library/Application Support/cmux/remote/<scope>/` (one
  per app build, replaced atomically when the embedded copy changes; never
  followed through a symlink).
- **Two workers.** A crash, a hang or a grant restart of one feature never
  stops the other. Each worker is the same executable in another mode, so it
  carries the same code identity.

## Lifecycle

The daemon owns the host the way it owns its browser host
(`cmux-tui-core/src/browser_host.rs`), plus adoption across a daemon upgrade,
which `docs/cloud-guest-upgrades.md` requires of every long-lived child:

| Event | What happens |
| --- | --- |
| Daemon start | Reads `remote-host/host.json`. A live host of this user that answers on its supervisor socket is **adopted** (hello with `min`/`max` protocol; the host answers with the version both speak, its build and whether it is busy). Otherwise the daemon starts one when Computer Use or Mac Screen sharing is on, or on the first `remote-host-*` command. |
| Host crash | The daemon restarts it with `Backoff` (200 ms to 30 s; reset after 30 s healthy). The host restarts a crashed worker the same way. |
| Daemon handoff (`shutdown-daemon`, upgrade) | The host keeps running and keeps serving. The new daemon adopts it within the host's adoption grace (60 s), else the host exits, so no host outlives every daemon. |
| New cmux build (another host build) | An idle host is replaced at once (`drain`, exit, start the new copy). A busy host (a Screen Sharing session) stays, with `upgrade: "pending"`; it reports `idle` when the session ends, and the daemon replaces it then. A session is never cut to upgrade. |
| macOS "Quit & Reopen" after a grant | The host answers the quit with a worker restart and cancels it: the grant reaches the feature, the host and its supervisor link stay. A copy that LaunchServices opens without the daemon exits at once. |
| Feature off (both) | The daemon stops the host (EOF on its supervisor link). |

The adoption record (`host.json`, 0600 in a 0700 directory) holds the host's
pid and start time, build, protocol range and supervisor socket. The daemon
accepts a peer only when its pid and start time match the record and its code
satisfies cmux Remote's requirement.

## IPC

| Who | Path | What |
| --- | --- | --- |
| daemon ↔ host | supervisor socket (`remote-host/s.sock`), JSON lines | hello, status, permission requests, worker control, drain |
| app ↔ host | app socket (`remote-host/a.sock`), JSON lines plus channels | credentials from `remote-host-app` (verified app only, as `browser-host-provider`): the Computer Use control channel, device signing, the device hub push relay |
| CLI, MCP | daemon commands `remote-host-status`, `remote-host-call` | status, requests, restart, sharing switch, viewer permission |
| agents (Computer Use) | the Computer Use worker's sockets (unchanged: `endpoint.json`, acpmux admission, app consent) | tools |

The app socket admits a peer only when it presents the per-launch secret and
its audit token is the cmux app that asked the daemon. Secrets travel only over
inherited pipes and the daemon's verified-app reply; nothing is in argv, env
or logs.

## Permissions

- **Status** comes from a fresh probe process, `cmux-remote probe`, which
  starts, reads `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`
  and exits. A running process can keep an old Screen Recording answer; a
  new one cannot.
- **Refresh** is event driven: the app becoming active (after System
  Settings), macOS's Accessibility change notification
  (`com.apple.accessibility.api`), a Quit & Reopen, an explicit refresh
  (palette, CLI, MCP), and each feature start. Nothing polls.
- **Grant reaches the feature.** When a refresh shows a grant that a worker
  started without, the host restarts that worker (an idle Screen Sharing
  worker at once, a busy one after its session).
- **Requests** (`accessibility`, `screenRecording`) run in the host, so
  macOS names cmux Remote in its prompt; each opens the matching System
  Settings pane when macOS will not prompt again. A permission is requested at
  most once per 30 s.
- **Setup.** When Computer Use turns on under cmux Remote (Settings, the
  palette, `cmux settings set computerUse.enabled true --confirm`,
  `cmux setup computer-use`, or a launch with it on) and a grant is off, the
  app shows its setup card (top right, never activating; only the person's
  press answers it). It names both permissions as macOS 27 shows them, with
  the older names in brackets: "Device Control and Data Access
  (Accessibility)" and "Screen & System Audio Recording (Screen Recording)".
  On macOS 27 the Accessibility prompt is titled "Device Control and Data
  Access". Continue requests Accessibility in the host, then, once it is on,
  Screen Recording, one request each. The card follows the refresh events
  above and closes when both are on. Not Now stops asking until Computer Use
  is turned off and on, or the app starts again. Computer Use Setup
  (`computer_use.status`) then reports cmux Remote's grants
  (`grant_holder: "cmux_remote"`), so an agent's computer use call before
  setup asks the person on the permission card
  (`permissions.request {kind: computer_use}`) as it does for the legacy
  helper.

## Screen Sharing worker

The Screen Sharing worker is this Mac's device on the device hub
(`docs/device-hub/PROTOCOL.md`): it owns the Secure Enclave device keys, the
one User DO socket of this device, the approval banner (top right, never
activating), the menu bar indicator, and every `ScreenStreamHost` session. It
works with the cmux app quit:

- Its hub session comes from the app's sign-in while the app runs, and from
  **device-key renewal** when it does not: `POST /v1/auth/device`, signed by
  this device's key, returns a host-scoped 1 h session while this device is
  anchored. The signed-in app anchors it (`POST /v1/auth/device/anchor`) at
  each start and hourly; an anchor lapses after 30 days, on sign-out, on device
  removal and when Mac Screen sharing is turned off. A host-scoped session can
  only serve: the socket, reads, the host's own session decisions, ends and
  ICE, sharing off and a viewer's access to None.
- The app signs its own hub requests (the viewer side) through the worker, so
  this Mac is one device.
- The iOS and Mac viewers are unchanged: the same hub session flow, ticket
  signaling and ScreenStream wire (including the input `caps` message).

## Settings and controls

Every control exists in the command palette, the CLI and MCP:

| Control | Palette | CLI | MCP |
| --- | --- | --- | --- |
| Status (host, workers, grants, upgrade) | cmux Remote: Show Status | `cmux remote status` | `remote_status` |
| Request Accessibility / Screen Recording | cmux Remote: Allow Accessibility / Allow Screen Recording | `cmux remote request accessibility\|screen-recording` | `remote_request_permission` |
| Refresh permissions | cmux Remote: Refresh Permissions | `cmux remote refresh` | `remote_refresh` |
| Restart a worker | cmux Remote: Restart Computer Use / Restart Screen Sharing | `cmux remote restart computer-use\|screen-sharing` | `remote_restart` |
| Share This Mac | Mac Screen: Share This Mac / Stop Sharing This Mac | `cmux remote share on\|off` | `remote_share` |
| A viewer's access | Mac Screen: Set Device Access… | `cmux remote access <device> none\|ask\|view\|full` | `remote_set_access` |
| Keep sharing when cmux is quit (`remote.headless`, default on) | Settings | `cmux settings set remote.headless` | `settings_set` |
| Computer Use engine (`computerUse.driver`: `remote` default, `legacy` opt-out for one release) | Settings | `cmux settings set computerUse.driver` | `settings_set` |

## Windows and Linux

The same architecture runs on Windows and Linux (decision D10): the daemon's
`remote_host` supervises a cmux Remote host, the host supervises a Computer Use
worker, and the worker runs upstream Cua Driver in process
(`cua-driver-sdk`, the same commit `b0968e1b12834e485dda68789541a3cc57664a9f`
as the macOS pin), over the same `remote-host-v1` supervisor wire. Only the host
executable differs: `cmux-remote-host` is Rust
(`cmux-tui/crates/cmux-remote-host`, its own Cargo workspace pinned to
upstream's toolchain), because the Swift host is AppKit and macOS only. Screen
Sharing stays macOS only; its worker reports `unsupported`.

```
cmux-tui daemon            (remote_host/linux.rs, remote_host/windows.rs)
  └─ cmux-remote-host host         (in the person's desktop session)
       └─ cmux-remote-host worker computer-use   (upstream Cua Driver in process)
```

### Starting the host in the desktop session

| | Linux | Windows |
| --- | --- | --- |
| Shipped binary | `cmux-remote-host` beside the daemon (or `../lib/cmux/`), optional `cmux-remote-host.sha256` pin beside it | `cmux-remote-host.exe` beside the daemon, same optional pin |
| Staged copy | `~/.local/state/cmux-tui/remote/bin/<sha256[..16]>/` (0700), re-hashed before every start; two newest kept | `%LOCALAPPDATA%\cmux-tui\remote\bin\<sha256[..16]>\` |
| Started as | a transient user unit, `systemd-run --user --unit cmux-remote-host-<rh-leaf> Type=notify`, so it runs with the graphical session's environment even when the daemon runs over SSH; without a user manager (containers, headless Xvfb) a direct spawn in its own session | from inside the interactive session: a direct child; from Session 0 (SSH, services): the on-demand task `cmux Remote <rh-leaf>` with an interactive logon (`schtasks /Create /XML`, then `/Run`), never Session 0 |
| Bootstrap (secret, switches, acpmux) | fd 3 (direct) or `<runtime>/bootstrap.json` (0600, deleted once read) | `<runtime>\bootstrap.json`, deleted once read |
| Ready | `READY=1` to systemd, or `ready` on stdout | the event `Global\cmux-remote-<rh-leaf>-ready` |
| Supervisor endpoint | `<runtime>/rh-<digest>/s.sock` (0600 in 0700) | `\\.\pipe\cmux-remote-<rh-leaf>`, DACL `D:P(A;;GA;;;<user SID>)`, remote clients rejected |
| Host checks the daemon | `SO_PEERCRED` uid, and the peer is the process serving the daemon socket | the client's token SID is this user's, its image is the daemon executable, and it is the daemon that started the host (`daemon_pid` and `daemon_start`, its creation FILETIME, from the bootstrap) or the process now serving the daemon socket (a handoff's new daemon) |
| Daemon checks the host | pid and start time (`/proc/<pid>/stat` field 22) match `host.json`, peer pid from `SO_PEERCRED` | pid and creation time match, server pid from `GetNamedPipeServerProcessId` |

Adoption, backoff, drain and the 60 s orphan grace are the macOS rules
(Lifecycle above); `host.json` keeps the same fields (`start_sec` holds the
Linux start ticks or the Windows creation FILETIME, `start_usec` is 0).
A daemon in an SSH session reaches the host in the desktop session over its
endpoint, as upstream's SSH proxy does (`cua-driver` guides, "Windows over SSH").

The unit and task templates ship in `cmux-tui/crates/cmux-remote-host/dist/`:
`cmux-remote-host@.service` (for packagers who prefer an installed unit to the
transient one) and `cmux-remote-host-task.xml` (the daemon fills in the user
SID and paths).

### The Computer Use worker

- **Socket**: `<runtime>/w-cu.sock` (Linux) or `\\.\pipe\cmux-remote-<rh-leaf>-cu`
  (Windows); `endpoint.json` (socket, secret, pid) in `<runtime>/cu/`, the
  folder acpmux reads as `CMUX_NEXT_CUA_V2_DIR`.
- **Admission** (as the macOS helper): same user; the peer's running image is
  this build's acpmux by SHA-256 (`/proc/<pid>/exe`, or the image file on
  Windows); a registered acpmux daemon (pid and start time) is an ancestor; then
  the per-launch secret. The daemon passes its acpmux path and socket at start;
  the worker registers the process serving that socket when it runs the trusted
  image (`computer_use.register_acpmux` does the same on request).
- **Sessions**: one admitted connection is one trusted upstream session
  (`CuaDriver::create_trusted_session`), closed with the connection. The
  approval contract (docs/computer-use-approvals.md) is implemented in the
  worker: a call on an app outside the session asks the host
  (`app_approval` on the worker's control lines), waits 2 minutes, and a late
  Allow still grows the session or the saved list.
- **Linux display**: X11 (XTest, MIT-SHM) or Wayland (xdg-desktop-portal
  RemoteDesktop and libei, upstream's `portal-libei` features), chosen by
  upstream at runtime from `WAYLAND_DISPLAY` and `DISPLAY`. The worker runs with
  `XDG_CONFIG_HOME` inside the host's private state, so upstream keeps the
  portal's restore token there (0600): the person grants the portal once.
- **Status permissions**: Linux `{"display":"wayland","portal":"granted|ask"}`
  or `{"display":"x11","x11":"granted"}`; Windows `{"interactive-session":true}`.

### Mode and collectors

The mode comes only from configuration the machine's owner controls
(`dist/computer-use.toml.example`):

| | Linux | Windows |
| --- | --- | --- |
| File | `/etc/cmux/computer-use.toml` | `%ProgramData%\cmux\computer-use.toml` |
| Trusted when | a regular root-owned file not writable by group or others, in root-owned directories no one else can write | owned by SYSTEM or Administrators; no ACE grants anyone else write on the file, or delete-child, delete, DAC or owner rights on `%ProgramData%\cmux` (the "create files" every user inherits there cannot replace an existing file) |
| Unrestricted | `mode = "unrestricted"` plus both `CUA_DRIVER_PERMISSION_MODE = "unrestricted"` and `CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS = "1"` under `[environment]` in that file; the host passes exactly these to the worker and the unit unsets them from everything else | same |

No file means `ask`; a file that is present but untrusted or invalid refuses
every call. The host reads the file once at start and hands that reading to
its worker (`configure.config`), its driver environment and the device hub
collector, so all three use one reading; `computer_use.status` reports it
(`mode`, `config`, `device_hub`) and sets `pending_reload` when the file
differs. `computer_use.reload` reads it again: questions waiting under the old
reading end unanswered, the hub collector is rebuilt with the new pins and the
worker restarts with the new mode. Only two callers reach it: the daemon over
the supervisor link, and a root (Linux, `SO_PEERCRED` uid 0) or elevated
(Windows: the person's own SID with an elevated token, or SYSTEM) process,
which the host admits for that one `{"type":"reload"}` line without the
supervisor secret. That is `cmux computer-use setup`'s elevated run, right
after it wrote the file (`computer_use.status` names the endpoint as
`reload_endpoint`; the elevated run opens a Windows pipe with
identification-only QoS). A reload re-reads only the root- or SYSTEM-owned
file, so a caller cannot raise trust with it; the daemon's `remote-host-call`
still refuses it, so an agent cannot restart the worker's sessions through it
(`restart` already can, and keeps the reading in force). Local collectors:

- **Linux**: polkit actions `com.cmux.computer-use.approve` and
  `com.cmux.computer-use.approve-always` (`dist/com.cmux.computer-use.policy`,
  installed to `/usr/share/polkit-1/actions/`, `auth_self`). The host calls
  `CheckAuthorization` for itself with `AllowUserInteraction` and no details:
  polkit refuses details from a caller that is neither uid 0 nor the action's
  owner, and an `org.freedesktop.policykit.owner` annotation for the person's
  uid would let agents (the same uid) pass details too. The dialog therefore
  shows the action's fixed message; the person reads the agent and the app in
  `cmux computer-use approvals pending`, which marks the question whose dialog
  is up (`on_screen`, and its short id at the top level), or on the phone. So
  the mark is never ambiguous, one dialog is up at a time: automatic prompts
  wait their turn, `computer_use.approvals.prompt` answers `dialog_up` while
  one is up, and a question that ends (another collector answered, the worker
  withdrew it) closes its dialog (`CancelCheckAuthorization`) and ignores its
  answer (`ended` to a waiting `prompt`). Offered only in a
  graphical session (`XDG_SESSION_TYPE` x11 or wayland), where the desktop
  runs a polkit agent. Authenticating answers the offered scope (this session
  by default); dismissing answers deny. Not yet verified on a real GNOME or
  KDE session.
- **Windows**: Windows Hello (`UserConsentVerifier`, through
  `IUserConsentVerifierInterop::RequestVerificationForWindowAsync` on a small
  host-owned "cmux Remote" window), when Hello is available. The window and
  the request run on a thread of their own that pumps its messages; when
  another collector answers first the host cancels the request and closes the
  window. Verifying answers the offered scope; closing the dialog is no answer
  (it has no Deny button), so the phone can still answer and the question
  otherwise times out unanswered. One dialog at a time, as for polkit. Not yet
  verified on a real Windows desktop.
- **Device hub**: `cmux-remote-host/src/hub.rs` over the hub client's
  `HubApprover`, started when the config has `[device_hub]` and at least one
  pinned `[[approvers]]` entry (docs/computer-use-approvals.md, "Device hub
  approvals"); otherwise there is no hub collector and `computer_use.status`
  says why under `device_hub`. The host is a device of the account with the
  key in this user's store (`$XDG_STATE_HOME/cmux/device-hub`, else the
  Secret Service; `%LOCALAPPDATA%\cmux\device-hub` or CNG on Windows), and gets
  the account's token from `token_command`. An Allow applies only when a
  pinned device signed it with the approval key whose fingerprint the owner
  pinned (a deny needs the decider's signing key); the first answer with the
  request's digest wins. For now only iPhones can be pinned: the cmux iPhone
  app registers an approval key, the macOS app does not yet.

`cmux computer-use approvals approve <id>` sends
`computer_use.approvals.prompt`, which opens the local collector (offering
Allow for This Session, or `once` when asked; never Always, which only the
phone or Mac offers); it never decides by itself, and shows one question at
most once every 10 seconds (`cooldown` otherwise). `computer_use.status`,
`computer_use.approvals.list`, `.pending`, `.deny` and `.revoke` are open to any
local caller (they read or lower trust). Question ids are the first 16 hex
digits of the request digest, as on macOS (docs/computer-use-approvals.md,
"Controls").

### Known limits

- **Same user.** As upstream documents, this protects against agents limited to
  cmux's tools. The saved approvals (`remote/worker/approvals/<client>.json`,
  0600; on Windows a protected owner-only DACL, and a file another SID may use
  is refused on read), the daemon's host record and bootstrap file (the same
  owner-only DACL on Windows) and `endpoint.json` are files of the person's user; a process that
  already runs arbitrary code as that user can change them or drive the desktop
  directly. Isolate such agents with a VM, a separate user or a second device.
- **Targets.** Before a call runs, the worker resolves every app it names
  (`worker/target_guard.rs`, the Rust twin of the macOS `CuaTargetGuard`):
  each `pid` and `window_id` (a window owned by another pid is checked too),
  `bundle_id` (none on these systems, so refused), `app_name` and
  `launch_app`'s `name` (an executable on `PATH`, symlinks resolved), typed
  `target`s, and every step of `run_steps` / `run_actions`. Upstream's loose
  `app` / `window` selectors, unknown target shapes, desktop input without a
  pid or window, and an `element_token` without its pid are refused;
  `run_script` and `replay_trajectory` are refused. Each app outside the
  session is asked about before any of the call runs, and a batch is never
  rerun after upstream reports an app outside the manifest. An input call that
  names no app (screen coordinates, the focused window) is refused in every
  mode (`target_unresolved`) so it cannot land on a never-allowed app.
  The never-allowed list matches the running executable: a terminal that runs
  under an interpreter (terminator and guake are `python3`) is matched as
  `python3`, so do not approve an interpreter app on a machine where agents run.
- **Windows bridge.** `acpmux cua-mcp` reaches the worker's pipe
  (`\\.\pipe\cmux-remote-<rh-leaf>-cu`): it reads `endpoint.json` only when
  the file's owner and DACL make it private to the person (SYSTEM and
  Administrators aside), accepts only a local pipe name, opens it with
  identification-only QoS (waiting up to 5 s on `WaitNamedPipeW` while every
  instance is busy) and sends the secret only after the pipe's server process
  runs as the person. A session gets the bridge while the worker (`pid`,
  `start`) runs and the pipe has a server; a file whose worker is gone is
  removed, as on macOS. The daemon names the standalone `acpmux.exe` daemon's
  socket (`ACPMUX_SOCKET`, else `ACPMUX_HOME` or `~\.acpmux`) to the host at
  start, so the worker registers it. Only a daemon running `acpmux.exe` (the
  image beside the daemon the worker trusts) is admitted, not `cmux acp`.
- **Where acpmux finds the endpoint (Windows and Linux).** The endpoint folder
  is the host's runtime folder plus `cu` (`remote_host::computer_use_endpoint_dir`,
  a function of the daemon socket path only). An acpmux the daemon starts
  itself (Linux, `cmux acp daemon start` from the session daemon) gets it as
  `CMUX_NEXT_CUA_V2_DIR`. For an acpmux the daemon did not start (Windows'
  standalone `acpmux.exe`), the daemon writes the folder's path into
  `<acpmux home>/cua-v2-dir` at start (owner-only, replaced atomically), and
  acpmux reads it at each session start when the variable is unset. A pointer
  that is not private to the person, not one absolute path, or names a missing
  folder is ignored, and the bridge still checks `endpoint.json` itself.

### Distro matrix

| Environment | Display path | Collector | Notes |
| --- | --- | --- | --- |
| Ubuntu 24.04, GNOME, Wayland | portal RemoteDesktop + libei, portal capture | polkit (gnome-shell agent) | the portal asks once; the restore token stays in the host's state |
| Ubuntu 24.04, GNOME on Xorg | XTest, MIT-SHM | polkit | |
| Fedora (GNOME, Wayland) | portal + libei | polkit | SELinux: the user unit runs unconfined_t like other user services |
| KDE Plasma 6, Wayland | portal (xdg-desktop-portal-kde) + libei | polkit (polkit-kde-agent-1) | Plasma 5.27 is rejected by upstream |
| Headless Xvfb (CI, VMs) | XTest on the Xvfb display | none (device hub only) | direct spawn when no systemd user manager |
| Windows 11, console or RDP | UI Automation | Windows Hello | from SSH the daemon starts the interactive task; `query session` must show the user Active or Disc |

Build dependencies (Debian and Ubuntu package names): `pkg-config clang
libclang-dev libx11-dev libxi-dev libxtst-dev libxext-dev libxcb1-dev
libxkbcommon-dev libpipewire-0.3-dev libdbus-1-dev libwayland-dev`; Fedora:
`pkgconf clang-devel libX11-devel libXi-devel libXtst-devel libxkbcommon-devel
pipewire-devel dbus-devel wayland-devel`. Runtime: the same libraries plus
`xdg-desktop-portal` with the desktop's backend and a polkit agent.
`cargo build --no-default-features` builds a host without Cua Driver (no
system libraries; every tool call answers `driver_unavailable`), which the
protocol tests use.

### Conformance

`schemas/remote-host/v1-conformance.json` is the supervisor exchange every
host passes: hello negotiation and its refusals (wrong secret, a peer that is
not the daemon, a first line that is not a hello, no common protocol), status,
config and its `status` push, error codes, drain. The Rust host replays it in
`cmux-tui/crates/cmux-remote-host/tests/conformance.rs` over an in-memory
stream. The Swift host replays it the same way: create `HostCore(secret:,
daemonBuild:, daemonSocket:)` with the file's `secret` and `bootstrap`, open a
socket pair as a `LineChannel`, run `serveSupervisor` with `isDaemon` forced to
the case's `peer_is_daemon`, and play the steps with the matching rules in the
file's `description` (skip `{"type":"event"}` lines unless the step is
`expect_event`).

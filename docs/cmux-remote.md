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

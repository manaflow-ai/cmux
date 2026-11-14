# cmux Remote: one host for Computer Use and Screen Sharing

cmux Remote supervises the workers that need macOS grants, while the NEXT app
serves an attached Mac Screen session. Computer Use always runs in the cmux
Remote worker. When the app is attached, its `MacScreenHubHost` serves the
current `cmux.rd/1` and WebRTC sessions and macOS checks the app's own
Accessibility and Screen Recording grants. When no app channel is attached,
the Screen Sharing worker may serve its standalone legacy stream and macOS
checks the worker's grants. A person may therefore see a grant for cmux Remote
for worker use and a grant for cmux for the app's active capture.

## Process tree

```
cmux.app (the person's app; serves attached cmux.rd/1 + WebRTC sessions,
          using the app's own TCC grants)
  └─ cmux-tui daemon          (started by the app, outlives it; setsid)
       └─ cmux Remote host    (posix_spawn with responsibility disclaimed:
          │                    macOS checks worker grants against cmux Remote)
          ├─ Computer Use worker   (`cmux-remote worker computer-use`)
          └─ Screen Sharing worker (`cmux-remote worker screen-sharing`;
                                     identity/push relay, or standalone stream)
```

- **Identity.** One signed bundle, `cmux Remote.app` (`com.cmuxterm.remote`;
  DEV and NIGHTLY builds currently use the pinned `cmux Remote (dev).app`,
  `com.cmuxterm.remote.dev`), with the cmux icon on a remote-screen badge. Its
  designated requirement (bundle id + team) stays the same across builds, so a
  grant survives every update. The Release phase embeds the pinned asset from
  `scripts/cmux-next/cmux-remote-dev.pin.json`; a missing or mismatched asset
  is visible in the build log and fails when `CMUX_NEXT_REQUIRE_CMUX_REMOTE=1`.
- **Responsibility.** The daemon starts the Remote host with
  `responsibility_spawnattrs_setdisclaim`, so the host is its own responsible
  process. Workers are the host's ordinary children: macOS attributes their
  Accessibility and Screen Recording checks to the host. The app's attached
  `MacScreenHubHost` is separate and uses the app's own TCC identity; shells
  and agents never inherit either grant.
- **Outside the app bundle.** macOS 26 checks Screen Recording for a process
  that runs from inside an app bundle as the outermost app. The daemon runs a
  verified Remote copy at `~/Library/Application Support/cmux/remote/<scope>/`
  (one per app build, replaced atomically when the embedded copy changes; never
  followed through a symlink). This rule applies to the worker grants; the
  attached app capture is evaluated under the cmux app's own TCC identity.
- **Two workers.** A crash, a hang or a grant restart of one feature never
  stops the other. Each worker is the same executable in another mode, so it
  carries the same code identity.

## Lifecycle

The daemon owns the host the way it owns its browser host
(`cmux-tui-core/src/browser_host.rs`), plus adoption across a daemon upgrade,
which `docs/cloud-guest-upgrades.md` requires of every long-lived child:

| Event | What happens |
| --- | --- |
| Daemon start | Reads `remote-host/host.json`. A live host of this user that answers on its supervisor socket is **adopted** (hello with `min`/`max` protocol; the host answers with the version both speak, its build and whether it is busy). Otherwise the daemon starts one when Computer Use (Upstream driver) is on or the person is signed in for Mac Screen sharing. Every build that embeds cmux Remote uses it; there is no switch. |
| Host crash | The daemon restarts it with `Backoff` (200 ms to 30 s; reset after 30 s healthy). The host restarts a crashed worker the same way. |
| Daemon handoff (`shutdown-daemon`, upgrade) | The host keeps running and keeps serving. The new daemon adopts it within the host's adoption grace (60 s), else the host exits, so no host outlives every daemon. |
| New cmux build (another host build) | An idle host is replaced at once (`drain`, exit, start the new copy). A busy host (a Screen Sharing session) stays, with `upgrade: "pending"`; it reports `idle` when the session ends, and the daemon replaces it then. A session is never cut to upgrade. |
| macOS "Quit & Reopen" after a grant | The host answers the quit with a worker restart and cancels it; the host and its supervisor link stay. The app rechecks its own TCC state when it becomes active. A copy that LaunchServices opens without the daemon exits at once. |
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
| app screen host | in-process `MacScreenHubHost` → `MacScreenRdHost` | attached `cmux.rd/1` and WebRTC capture, signaling and input; uses the app's TCC grants |
| CLI, MCP | daemon commands `remote-host-status`, `remote-host-call` | status, requests, restart, sharing switch, viewer permission |
| agents (Computer Use) | the Computer Use worker's sockets (unchanged: `endpoint.json`, acpmux admission, app consent) | tools |

The app socket admits a peer only when it presents the per-launch secret and
its audit token is the cmux app that asked the daemon. Secrets travel only over
inherited pipes and the daemon's verified-app reply; nothing is in argv, env
or logs.

## Permissions

- **Status** for worker grants comes from a fresh `cmux-remote probe` process,
  which reads `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`
  and exits. The attached app host reports its own TCC reads from
  `MacScreenShareHost`; the two identities are shown separately.
- **Refresh** is event driven: the app becoming active (after System
  Settings), macOS's Accessibility change notification
  (`com.apple.accessibility.api`), a Quit & Reopen, an explicit refresh
  (palette, CLI, MCP), and each feature start. Nothing polls.
- **Grant reaches the feature.** When a worker refresh shows a grant it started
  without, the Remote host restarts that worker (an idle standalone Screen
  Sharing worker at once, a busy one after its session). The app host refreshes
  and requests its own grants for attached capture; it is not repaired by
  restarting the worker.
- **Requests** (`accessibility`, `screenRecording`) made through
  `cmux remote-host request …` run in the Remote host, so macOS names cmux
  Remote. The app's Share action and `remote.confirm` guided sheet use the
  app's own `MacScreenShareHost` permission flow and app hub session. Each
  opens the matching System Settings pane when macOS will not prompt again. A
  permission is requested at most once per 30 s.

## Screen Sharing worker

The Screen Sharing worker is this Mac's device on the device hub
(`docs/device-hub/PROTOCOL.md`): it owns the Secure Enclave device keys, the
one User DO socket of this device, the approval banner (top right, never
activating), and the menu bar indicator. When the cmux app has an app channel
open, the app owns the current `cmux.rd/1` host ticket and approval flow; the
worker becomes identity and push relay only and never serves or ends that
ticket. If no app channel is open, the worker may host its legacy
`ScreenStreamHost` session so sharing can continue with the app quit:

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

The NEXT app keeps its app-owned `MacScreenHubHost` active for the current
`cmux.rd/1` host protocol while attached. `MacScreenRdHost` also accepts a
WebRTC offer and serves it in-process. The pinned worker supplies device
identity, signing and push relay, and switches to relay-only while an app
channel is open. This compatibility bridge is deliberate: switching
`remoteHosted` to the worker's older `ScreenStreamHost` path would make a
Release viewer connect to a host speaking a different protocol.

## Settings and controls

Every control exists in the command palette, the CLI and MCP:

| Control | Palette | CLI | MCP |
| --- | --- | --- | --- |
| Status (host, workers, grants, upgrade) | cmux Remote: Show Status | `cmux remote-host status` | `remote_status` |
| Request Accessibility / Screen Recording for workers | cmux Remote: Allow Accessibility / Allow Screen Recording | `cmux remote-host request accessibility\|screen-recording` | `remote_request_permission` |
| Refresh permissions | cmux Remote: Refresh Permissions | `cmux remote-host refresh` | `remote_refresh` |
| Restart a worker | cmux Remote: Restart Computer Use / Restart Screen Sharing | `cmux remote-host restart computer-use\|screen-sharing` | `remote_restart` |
| Share This Mac | Mac Screen: Share This Mac / Stop Sharing This Mac | `cmux remote-host share on\|off` (on uses the app's `remote.confirm` sheet; off uses the app path first, with worker fallback when unattached) | `remote_share` |
| A viewer's access | Mac Screen: Set Device Access… | `cmux remote-host access <device> none\|ask\|view\|full` | `remote_set_access` |
| Stop the current session | Mac Screen: Stop Current Session | `cmux remote-host stop` (app canonical action first; worker fallback only when app transport is absent) | `remote_stop_session` |
| Stop the current session directly in the attached app | Mac Screen: Stop Sharing | `cmux action run macScreen.stopSharing` | app action (no worker round-trip) |
| End sharing when cmux quits (`remote.endSharingOnQuit`, default off) | Settings | `cmux settings set remote.endSharingOnQuit` | `settings_set` (refused: user-only) |
| Ultra Connection Mode (`remote.ultraMode`, default off: cmux-wg tunnels this Mac starts send Reed-Solomon repair data, about 2-3x the bytes, and the peer agrees inside the tunnel to send it too, so both directions are protected; `CMUX_WG_ULTRA` overrides it) | Settings | `cmux settings set remote.ultraMode true` | `settings_set` (refused: user-only) |
| Computer Use driver (`computerUse.driver`, default `upstream`: Computer Use runs in cmux Remote; `legacy` keeps the cmux-cua 0.8.12 helper) | Settings | `cmux settings set computerUse.driver` | `settings_set` (refused: user-only) |

The two stop paths are intentionally distinct. `cmux remote-host stop` routes
through the app's canonical stop action when app transport is available, then
falls back to the standalone worker only when the app is absent. A worker in
relay-only mode refuses the stop instead of claiming success. `cmux action run
macScreen.stopSharing` is the app's direct one-click stop for the session
currently served by `MacScreenHubHost`.

The architecture and routing above are documented from source and focused
tests. End-to-end Mac-to-Mac operation on Leo's NIGHTLY has not been run or
read back here.

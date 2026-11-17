# cmux Remote: one host for Computer Use and Screen Sharing

cmux Remote is the one app that holds Accessibility and Screen Recording.
Computer Use runs in its Computer Use worker. Mac Screen's capture, encoding
and input injection run in its Screen Sharing worker, whether the cmux app is
attached or not: an attached app keeps the device hub ticket, the signaling
and the approval UI, and hands each session's capture to the worker (see
[Attached capture](#attached-capture)). macOS therefore prompts for, lists and
restarts cmux Remote only, never the cmux app, and a grant never relaunches
cmux. A build without cmux Remote (and a cmux Remote older than this split)
keeps the earlier behavior: the app's Screen Sharing helper or the app itself
captures and holds the grants.

## Process tree

```
cmux.app (the person's app; tickets, signaling and approval for attached
          sessions; no capture and no TCC grant of its own)
  └─ cmux-tui daemon          (started by the app, outlives it; setsid)
       └─ cmux Remote host    (posix_spawn with responsibility disclaimed:
          │                    macOS checks worker grants against cmux Remote)
          ├─ Computer Use worker   (`cmux-remote worker computer-use`)
          └─ Screen Sharing worker (`cmux-remote worker screen-sharing`;
             │                      identity/push relay, attached WebRTC
             │                      sessions, or standalone stream)
             └─ cmux.rd/1 host     (`Contents/MacOS/cmux-screen-sharing serve`,
                                    one per attached cmux.rd/1 session)
```

- **Identity.** One signed bundle, `cmux Remote.app` (`com.cmuxterm.remote`;
  DEV builds, and a NIGHTLY build that is asked to embed it, currently use the
  pinned `cmux Remote (dev).app`, `com.cmuxterm.remote.dev`), with the cmux
  icon on a remote-screen badge. Its designated requirement (bundle id + team)
  stays the same across builds, so a grant survives every update. A Release
  build embeds the pinned asset from
  `scripts/cmux-next/cmux-remote-dev.pin.json` only with
  `CMUX_NEXT_EMBED_CMUX_REMOTE_IN_RELEASE=1` (decision of 2026-11-16). No build
  sets the variable, so a NIGHTLY build has no cmux Remote: the third-party
  notices and the load-command check of a published build do not cover the
  embedded bundle yet. Without the variable a Release build prints one note
  line and embeds nothing; with `CMUX_NEXT_REQUIRE_CMUX_REMOTE=1` and not the
  variable it fails. With the variable a Release build fails without the
  asset, and a mismatched asset fails each build that embeds. Only with
  `CMUX_NEXT_ALLOW_NO_CMUX_REMOTE=1` added, a Release build on a Mac with no
  source for the asset prints one `NOT EMBEDDED` warning line and has no cmux
  Remote. A DEV build warns in the build log and fails only when
  `CMUX_NEXT_REQUIRE_CMUX_REMOTE=1`.
- **Responsibility.** The daemon starts the Remote host with
  `responsibility_spawnattrs_setdisclaim`, so the host is its own responsible
  process. Workers are the host's ordinary children: macOS attributes their
  Accessibility and Screen Recording checks to the host, and so are the
  cmux.rd/1 hosts the Screen Sharing worker starts. Shells and agents never
  inherit a grant.
- **Outside the app bundle.** macOS 26 checks Screen Recording for a process
  that runs from inside an app bundle as the outermost app. The daemon runs a
  verified Remote copy at `~/Library/Application Support/cmux/remote/<scope>/`
  (one per app build, replaced atomically when the embedded copy changes; never
  followed through a symlink). The cmux.rd/1 host is inside that copy, so
  macOS checks it as cmux Remote too.
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
| The person quits cmux Remote (Activity Monitor, `quit app`, logout) | The host sends the daemon a `quit` event, ends its workers and exits. On that event the daemon writes a stop intent (`stop-intent.json` in the remote state folder, cmux-supervise-core `intent`) before the host stops, so nothing starts it again: not the restart after its exit, not the next daemon start, not a request (an agent's, the app's hourly anchor) and not the app sending the same switches at launch. Status reads `unavailable` with the reason. Only an explicit start clears the intent: `cmux remote-host restart`, or the person turning a feature on. An intent file that cannot be read counts as a stop. |
| macOS "Quit & Reopen" after a grant (the quit sent by System Settings) | The host answers the quit with a worker restart and cancels it; the host and its supervisor link stay. The app rereads cmux Remote's grants (`remote-host refresh`) when it becomes active. A copy that LaunchServices opens without the daemon exits at once. |
| Feature off (both) | The daemon stops the host (EOF on its supervisor link). |

The adoption record (`host.json`, 0600 in a 0700 directory) holds the host's
pid and start time, build, protocol range and supervisor socket. The daemon
accepts a peer only when its pid and start time match the record and its code
satisfies cmux Remote's requirement.

## IPC

| Who | Path | What |
| --- | --- | --- |
| daemon ↔ host | supervisor socket (`remote-host/s.sock`), JSON lines | hello, status, permission requests, worker control, drain |
| app ↔ host | app socket (`remote-host/a.sock`), JSON lines plus channels | credentials from `remote-host-app` (verified app only, as `browser-host-provider`): the Computer Use control channel, device signing, the device hub push relay, and one `screen-sharing` channel per attached session (`screen.rd_serve`, `screen.webrtc_serve`) |
| app screen host | in-process `MacScreenHubHost` → `MacScreenRdHost` | attached tickets, signaling and approval; capture through the worker's attached sessions |
| CLI, MCP | daemon commands `remote-host-status`, `remote-host-call` | status, requests, restart, sharing switch, viewer permission |
| agents (Computer Use) | the Computer Use worker's sockets (unchanged: `endpoint.json`, acpmux admission, app consent) | tools |

The app socket admits a peer only when it presents the per-launch secret and
its audit token is the cmux app that asked the daemon. Secrets travel only over
inherited pipes and the daemon's verified-app reply; nothing is in argv, env
or logs.

## Permissions

- **Status** comes from a fresh `cmux-remote probe` process, which reads
  `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` and exits. The
  app's Mac Screen page, Settings > Devices and the Share This Mac sheet read
  the same snapshot (`MacScreenShareHost` asks `remote-host refresh`) and name
  cmux Remote. The app still reports its own reads to the daemon
  (`app.permissions`), which only matter in a build without cmux Remote.
- **Refresh** is event driven: the app becoming active (after System
  Settings), macOS's Accessibility change notification
  (`com.apple.accessibility.api`), a Quit & Reopen, an explicit refresh
  (palette, CLI, MCP), and each feature start. Nothing polls.
- **Grant reaches the feature.** When a worker refresh shows a grant it started
  without, the Remote host restarts that worker (an idle Screen Sharing worker
  at once, a busy one, including one serving an attached session, after its
  session). Each attached cmux.rd/1 session is a fresh process, so it reads
  the grant as it is when the session starts.
- **Requests** (`accessibility`, `screenRecording`) run in the Remote host, so
  macOS names cmux Remote: `cmux remote-host request …`, the palette, and the
  app's Share action and `remote.confirm` guided sheet (`MacScreenShareHost`
  sends `remote-host request`). Each opens the matching System Settings pane
  when macOS will not prompt again. A permission is requested at most once per
  30 s. The viewer's Send System Shortcuts tap is the one Accessibility use
  left in the app: it is the viewer's own keyboard, not this Mac's sharing.

## Screen Sharing worker

The Screen Sharing worker is this Mac's device on the device hub
(`docs/device-hub/PROTOCOL.md`): it owns the Secure Enclave device keys, the
one User DO socket of this device, the approval banner (top right, never
activating), and the menu bar indicator. When the cmux app has an app channel
open, the app owns the current `cmux.rd/1` host ticket and approval flow; the
worker becomes identity and push relay only and never serves or ends that
ticket, but still serves the app's attached sessions on their own channels
([Attached capture](#attached-capture)). If no app channel is open, the worker
may host its legacy `ScreenStreamHost` session so sharing can continue with
the app quit:

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

## Attached capture

While the app is attached it keeps `MacScreenHubHost` and `MacScreenRdHost`:
the ticket, consent and approval, the signaling, the viewer-facing protocol
choice (a cmux.rd/1 offer or a WebRTC offer) and the menu bar indicator. What
needs a grant moves to the Screen Sharing worker, one app channel per session
(`AttachedScreenHost` in `Packages/Shared/CmuxVNCWebRTC`):

| Viewer offers | App (`MacScreenRdHost`) | Worker (`AttachedScreenSessions`) |
| --- | --- | --- |
| cmux.rd/1 | sends `screen.rd_serve`, then drives the host exactly as a local one: setup, candidates, `stop`, reading its answer, candidates and state lines with the Rust line reader | starts `Contents/MacOS/cmux-screen-sharing serve` (cmux-tui/crates/cmux-rd-host, the binary the app's Screen Sharing helper ships) as its child; the channel is its stdin and stdout, byte for byte |
| WebRTC | sends `screen.webrtc_serve` (name, View Only, ICE servers), then relays the ticket's signals both ways | serves it with its `ScreenStreamHost`, the same host it uses unattached, and reports `viewer_connected`, `viewer_ended`, `source_failed` |

Closing the channel ends the session (Stop, a revocation, a newer session);
the worker's end of it is the host's end. Viewers are unchanged on the wire:
the bytes a viewer sees come from the same cmux.rd/1 host and the same
`ScreenStreamHost` as before, only in another process. The worker lists
`serves: ["cmux.rd/1", "webrtc"]` in its status and `attached: N` while
sessions run; the host counts `attached` as busy, so an upgrade or a grant
restart waits for the session. The app uses the worker only when it lists both
kinds; an older pinned cmux Remote lists none, and the app then captures with
its Screen Sharing helper or itself as before, and shows those grants.

What a fresh Mac sees for Mac Screen:

| | Before | After |
| --- | --- | --- |
| Screen Recording | cmux (WebRTC viewer) or "cmux NIGHTLY Screen Sharing" (cmux.rd/1), and cmux Remote for the unattached stream | cmux Remote only |
| Accessibility (control) | the same split | cmux Remote only |
| Grant restarts | the app (Quit & Reopen) for an in-app capture | the Screen Sharing worker; the app keeps running |

## Settings and controls

Every control exists in the command palette, the CLI and MCP:

| Control | Palette | CLI | MCP |
| --- | --- | --- | --- |
| Status (host, workers, grants, upgrade) | cmux Remote: Show Status | `cmux remote-host status` | `remote_status` |
| Request Accessibility / Screen Recording for workers | cmux Remote: Allow Accessibility / Allow Screen Recording | `cmux remote-host request accessibility\|screen-recording` | `remote_request_permission` |
| Refresh permissions | cmux Remote: Refresh Permissions | `cmux remote-host refresh` | `remote_refresh` |
| Restart a worker | cmux Remote: Restart Computer Use / Restart Screen Sharing | `cmux remote-host restart computer-use\|screen-sharing` | `remote_restart` |
| Share This Mac | Mac Screen: Share This Mac / Stop Sharing This Mac | `cmux remote-host share on\|off` (on uses the app's `remote.confirm` sheet; off uses the app path first, with worker fallback when unattached) | `remote_share` |
| Share another Mac of yours, confirmed on the device you are at (the target admits it only from a same-account machine its owner granted; until the approval can be delivered there, the answer is `share.needs_same_account_control`) | | `cmux remote-host share on --device DEVICE` | `remote_share` with `device` |
| Which grant a Mac lacks, its pane opened there, and whether Screen Sharing or Remote Management lets an agent click it | | `cmux remote-host grants [--device DEVICE] [--open]` | |
| A viewer's access | Mac Screen: Set Device Access… | `cmux remote-host access <device> none\|ask\|view\|full` | `remote_set_access` |
| Stop the current session | Mac Screen: Stop Current Session | `cmux remote-host stop` (app canonical action first; worker fallback only when app transport is absent) | `remote_stop_session` |
| Stop the current session directly in the attached app | Mac Screen: Stop Sharing | `cmux action run macScreen.stopSharing` | app action (no worker round-trip) |
| End sharing when cmux quits (`remote.endSharingOnQuit`, default off) | Settings | `cmux settings set remote.endSharingOnQuit` | `settings_set` (refused: user-only) |
| Ultra Connection Mode (`remote.ultra`: `off`, `auto` (the default) or `always`. Auto sends no repair data on a clean link and Reed-Solomon repair data from the first lost packet, within about one round trip, until the link is clean again; on a metered network the repair bytes stay within the data bytes. Always sends it on every datagram, about 2-3x the bytes. The peer agrees inside the tunnel to send it too, so both directions are protected; `CMUX_WG_ULTRA` overrides it) | Settings | `cmux settings set remote.ultra always` | `settings_set` (refused: user-only) |
| Computer Use driver (`computerUse.driver`, default `upstream`: Computer Use runs in cmux Remote; `legacy` keeps the cmux-cua 0.8.12 helper) | Settings | `cmux settings set computerUse.driver` | `settings_set` (refused: user-only) |

The two stop paths are intentionally distinct. `cmux remote-host stop` routes
through the app's canonical stop action when app transport is available, then
falls back to the standalone worker only when the app is absent. A worker in
relay-only mode refuses the stop instead of claiming success. `cmux action run
macScreen.stopSharing` is the app's direct one-click stop for the session
currently served by `MacScreenHubHost`.

The architecture and routing above are documented from source and focused
tests (the worker's channel and process tests, the app's routing tests).
End-to-end Mac-to-Mac operation on Leo's NIGHTLY has not been run or read back
here; NIGHTLY embeds no cmux Remote yet.

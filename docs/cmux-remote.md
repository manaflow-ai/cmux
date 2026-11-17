# cmux Remote: one app for Computer Use and Screen Sharing permissions

Computer Use and Screen Sharing ask macOS for Accessibility and Screen
Recording as one app, **cmux Computer Use**. Lawrence: "ensure screen sharing +
computer use uses same app for permissions, unless there's a good reason for
having different apps for requesting screen sharing/accessibility". A process
separate from the cmux app is a reason to stay out of the app (a grant never
relaunches cmux); it is no reason for the two features to differ. So there is
one signed helper app, and everything that needs a grant runs from it:

- `cmux-cua`, the legacy Computer Use driver (the helper's main executable);
- `cmux-screen-sharing`, the `cmux.rd/1` host (`cmux-tui/crates/cmux-rd-host`);
- `cmux-remote`, the supervisor ("cmux Remote host") and its two workers
  (`Packages/macOS/CmuxRemote`).

There is no separate cmux Remote app any more, in Release or in DEV.

## Identity and where it ships

| Build | Helper | Bundle id | Signed by |
| --- | --- | --- | --- |
| Release, NIGHTLY, RC | `cmux.app/Contents/Library/cmux Computer Use.app` | `com.cmuxterm.cua` (every channel) | Developer ID, team 7WLXT3NR37 |
| DEV | `Contents/Library/cmux Computer Use (dev).app` | `com.cmuxterm.cua.dev` | the team (pinned, `cua-helper-dev.pin.json`) |

Its designated requirement (identifier + team) is the same across builds and
channels, so a grant survives every update, and anyone who allowed Computer Use
already has the grants Screen Sharing needs. Inside the helper:

```
cmux Computer Use.app/Contents/
  MacOS/cmux-cua                        the bundle's executable (Release); DEV: cmux-cua-helper
  MacOS/cmux-screen-sharing             signed --identifier <helper id>   (when the build has it)
  MacOS/cmux-remote                     signed --identifier <helper id>   (always)
  Frameworks/libWebRTC.dylib            WebRTC.framework as a plain dylib (cmux-remote links it)
  Frameworks/libcua_driver_sdk.dylib    the pinned Cua Driver SDK, cua-driver-sdk.pin.json; the
                                        Computer Use worker dlopens it from
                                        Bundle.main.privateFrameworksPath (arm64 only)
  Resources/CmuxRemote_*.bundle, ...    cmux-remote's SwiftPM resource bundles
  Resources/Licenses/cmux-remote.txt    and the SDK's licenses
```

Each nested executable carries the helper's identifier, so macOS finds the same
permission row whether it attributes the process to the outermost bundle
(macOS 26) or to the code's own signature (older macOS).

### Release, NIGHTLY and RC

The nightly's "Assemble the Computer Use helper"
(`scripts/ci/nightly-steps/app-assemble-computer-use-helper.sh`) builds and
places everything, with no flag:

1. `scripts/build-cmux-cua.sh --helper-app` assembles the helper around
   `cmux-cua` (a rebuild keeps the nested code below);
2. `scripts/cmux-next/bundle-screen-sharing-helper.sh --into-computer-use`
   moves `cmux-screen-sharing` in;
3. `scripts/cmux-next/bundle-cmux-remote.sh --into ... --identifier
   com.cmuxterm.cua --archs "$HELPER_ARCHS"` runs `swift build -c release` for
   each shipped slice, joins them with `lipo`, converts `WebRTC.framework` to
   `libWebRTC.dylib` (install name rewritten, only the shipped slices), strips
   toolchain rpaths, places the SDK dylib, the resource bundles and the
   licenses, and signs the nested code ad hoc before re-sealing the helper;
4. `scripts/ci/verify-computer-use-helper.sh layout` checks the result.

The SDK tarball comes from the private R2 bucket. Only the nightly's
background "Fetch the Chromium engine" step has the read key, so it fills the
cache (`cef-cache-root.sh/cua-helper-v2`) that step 3 reads.

Architectures: `cmux-remote` and `libWebRTC.dylib` carry every shipped slice
(arm64, and x86_64 in a universal build). The pinned SDK has only an arm64
slice: the universal app carries it arm64-only, and the thin x86_64 variant
drops it before thinning (`drop-cua-sdk-without-arch.sh`), so on an Intel Mac
the Computer Use worker reports the driver unavailable while Screen Sharing
works. `prepare-verify-binary-architectures.sh` checks exactly that.

Every signer signs the nested code before it seals the helper: the dylibs, then
`cmux-screen-sharing` and `cmux-remote` with Developer ID, the hardened runtime,
`--identifier com.cmuxterm.cua` and no entitlements (library validation holds:
the dylibs carry the same team's signature). The four signers are
`scripts/sign-cmux-bundle.sh`, `scripts/ci/notarize-computer-use-helper.sh`
(the helper's own notarization), `scripts/ci/release-signer/sign-app.sh` and
`scripts/ci/rcodesign-sign-bundle.sh`. `verify-computer-use-helper.sh signed`
then requires `cmux-remote` to satisfy the `com.cmuxterm.cua` Developer ID
requirement with the hardened runtime, the dylibs to carry the team's
signature, and `Contents/Library` to hold exactly one app.

### DEV

`scripts/cmux-next/build-cua-helper-dev.sh` builds the unsigned
`cmux Computer Use (dev).app` on a fleet Mac, with `bundle-cmux-remote.sh
--identifier com.cmuxterm.cua.dev --archs arm64 --no-seal` for cmux-remote.
`scripts/cmux-next/sign-cua-helper-dev.sh` signs the dylibs, then `cmux-remote`
with `--identifier com.cmuxterm.cua.dev`, then the app, and publishes the zip
and its pin (`cua-helper-dev.pin.json`). Every DEV build embeds those exact
bytes (`embed-cua-helper-dev.sh`), so the DEV grant also survives every build
until the pin changes.

## Process tree

```
cmux.app (the person's app; holds no Accessibility or Screen Recording grant)
  └─ cmux-tui daemon            (started by the app, outlives it; setsid)
       └─ cmux-remote host      (from the staged Computer Use helper; posix_spawn
          │                      with responsibility disclaimed: macOS checks the
          │                      grants of cmux Computer Use)
          ├─ Computer Use worker   (`cmux-remote worker computer-use`)
          └─ Screen Sharing worker (`cmux-remote worker screen-sharing`; this Mac's
                                     device, its sessions, and `cmux-screen-sharing
                                     serve` as its child for cmux.rd/1)
```

- **Staged, verified, outside the app.** macOS 26 checks Screen Recording for
  a process that runs from inside an app bundle as the outermost app. The
  daemon copies the embedded Computer Use helper to
  `~/Library/Application Support/cmux/remote/<scope>/` (one per app build,
  replaced atomically when the embedded copy changes; never followed through a
  symlink), verifies the copy's designated requirement (identifier
  `com.cmuxterm.cua`, DEV `com.cmuxterm.cua.dev`, and team 7WLXT3NR37), and runs
  `Contents/MacOS/cmux-remote host` from it.
- **Responsibility.** The daemon starts the host with
  `responsibility_spawnattrs_setdisclaim`, so the host is its own responsible
  process. Workers are the host's ordinary children: macOS attributes their
  checks to the helper. Shells and agents never inherit a grant.
- **Two workers.** A crash, a hang or a grant restart of one feature never
  stops the other. Each worker is the same executable in another mode, so it
  carries the same code identity.

## Lifecycle

The daemon owns the host the way it owns its browser host
(`cmux-tui-core/src/browser_host.rs`), plus adoption across a daemon upgrade,
which `docs/cloud-guest-upgrades.md` requires of every long-lived child:

| Event | What happens |
| --- | --- |
| Daemon start | Reads `remote-host/host.json`. A live host of this user that answers on its supervisor socket is **adopted** (hello with `min`/`max` protocol; the host answers with the version both speak, its build and whether it is busy). Otherwise the daemon starts one when Computer Use (Upstream driver) is on or the person is signed in for Mac Screen sharing. Every Release, NIGHTLY, RC and DEV build carries it; there is no switch. |
| Host crash | The daemon restarts it with `Backoff` (200 ms to 30 s; reset after 30 s healthy). The host restarts a crashed worker the same way. |
| Daemon handoff (`shutdown-daemon`, upgrade) | The host keeps running and keeps serving. The new daemon adopts it within the host's adoption grace (60 s), else the host exits, so no host outlives every daemon. |
| New cmux build (another helper build) | An idle host is replaced at once (`drain`, exit, stage and start the new helper copy). A busy host (a Screen Sharing session) stays, with `upgrade: "pending"`; it reports `idle` when the session ends, and the daemon replaces it then. A session is never cut to upgrade. The helper's identity does not change, so neither do the grants. |
| A grant arrives (System Settings) | The host restarts the worker that started without it (an idle Screen Sharing worker at once, a busy one after its session), so the grant reaches the feature without restarting anything else. |
| macOS "Quit & Reopen" after a grant | macOS asks the responsible process, the host, to quit: the host answers with a worker restart and cancels the quit; the host and its supervisor link stay. cmux is never relaunched: the app holds no grant and is not the responsible process. A copy that LaunchServices opens without the daemon exits at once. |
| Feature off (both) | The daemon stops the host (EOF on its supervisor link). |

The adoption record (`host.json`, 0600 in a 0700 directory) holds the host's
pid and start time, build, protocol range and supervisor socket. The daemon
accepts a peer only when its pid and start time match the record and its code
satisfies the Computer Use helper's requirement.

## IPC

| Who | Path | What |
| --- | --- | --- |
| daemon ↔ host | supervisor socket (`remote-host/s.sock`), JSON lines | hello, status, permission requests, worker control, drain |
| app ↔ host | app socket (`remote-host/a.sock`), JSON lines plus channels | credentials from `remote-host-app` (verified app only, as `browser-host-provider`): the Computer Use control channel, Mac Screen sessions, device signing, the device hub push relay |
| CLI, MCP | daemon commands `remote-host-status`, `remote-host-call` | status, requests, restart, sharing switch, viewer permission |
| agents (Computer Use) | the Computer Use worker's sockets (unchanged: `endpoint.json`, acpmux admission, app consent) | tools |

The app socket admits a peer only when it presents the per-launch secret and
its audit token is the cmux app that asked the daemon. Secrets travel only over
inherited pipes and the daemon's verified-app reply; nothing is in argv, env
or logs.

## Permissions

- **Status** comes from a fresh `cmux-remote probe` process (from the staged
  helper), which reads `AXIsProcessTrusted()` and
  `CGPreflightScreenCaptureAccess()` and exits.
- **Refresh** is event driven: the app becoming active (after System
  Settings), macOS's Accessibility change notification
  (`com.apple.accessibility.api`), a Quit & Reopen, an explicit refresh
  (palette, CLI, MCP), and each feature start. Nothing polls.
- **Requests** (`accessibility`, `screenRecording`) run in the host, so macOS
  names cmux Computer Use; the app asks the host for them and never asks macOS
  itself. Each opens the matching System Settings pane when macOS will not
  prompt again. A permission is requested at most once per 30 s.

## Screen Sharing worker

The Screen Sharing worker is this Mac's device on the device hub
(`docs/device-hub/PROTOCOL.md`): it owns the Secure Enclave device keys, the
one User DO socket of this device, the approval banner (top right, never
activating), and the menu bar indicator. It serves Mac Screen sessions: the
app asks the host over its app socket channel, and the worker serves WebRTC
(`ScreenStreamHost`) and `cmux.rd/1` (running `cmux-screen-sharing serve`, from
the same helper, as its own child). Sharing continues with the app quit:

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
| Status (host, workers, grants, upgrade) | cmux Remote: Show Status | `cmux remote-host status` | `remote_status` |
| Request Accessibility / Screen Recording | cmux Remote: Allow Accessibility / Allow Screen Recording | `cmux remote-host request accessibility\|screen-recording` | `remote_request_permission` |
| Refresh permissions | cmux Remote: Refresh Permissions | `cmux remote-host refresh` | `remote_refresh` |
| Restart a worker | cmux Remote: Restart Computer Use / Restart Screen Sharing | `cmux remote-host restart computer-use\|screen-sharing` | `remote_restart` |
| Share This Mac | Mac Screen: Share This Mac / Stop Sharing This Mac | `cmux remote-host share on\|off` (on uses the app's `remote.confirm` sheet) | `remote_share` |
| Share another Mac of yours, confirmed on the device you are at (the target admits it only from a same-account machine its owner granted; until the approval can be delivered there, the answer is `share.needs_same_account_control`) | | `cmux remote-host share on --device DEVICE` | `remote_share` with `device` |
| Which grant a Mac lacks, its pane opened there, and whether Screen Sharing or Remote Management lets an agent click it | | `cmux remote-host grants [--device DEVICE] [--open]` | |
| A viewer's access | Mac Screen: Set Device Access… | `cmux remote-host access <device> none\|ask\|view\|full` | `remote_set_access` |
| Stop the current session | Mac Screen: Stop Current Session | `cmux remote-host stop` | `remote_stop_session` |
| End sharing when cmux quits (`remote.endSharingOnQuit`, default off) | Settings | `cmux settings set remote.endSharingOnQuit` | `settings_set` (refused: user-only) |
| Ultra Connection Mode (`remote.ultra`: `off`, `auto` (the default) or `always`. Auto sends no repair data on a clean link and Reed-Solomon repair data from the first lost packet, within about one round trip, until the link is clean again; on a metered network the repair bytes stay within the data bytes. Always sends it on every datagram, about 2-3x the bytes. The peer agrees inside the tunnel to send it too, so both directions are protected; `CMUX_WG_ULTRA` overrides it) | Settings | `cmux settings set remote.ultra always` | `settings_set` (refused: user-only) |
| Computer Use driver (`computerUse.driver`, default `upstream`: Computer Use runs in the cmux-remote worker; `legacy` keeps the cmux-cua 0.8.12 helper) | Settings | `cmux settings set computerUse.driver` | `settings_set` (refused: user-only) |

The packaging, signing and checks above are tested by
`tests/test_one_permission_identity.py`,
`tests/test_nightly_next_computer_use_helper.py` and the signer tests.
End-to-end operation of the one app on a NIGHTLY has not been run or read back
yet.

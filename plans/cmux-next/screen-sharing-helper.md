# Screen Sharing helper: capture and input out of the app's process

Leo, 2026-11-15: "are we using the "different process from the basline cmux nightly app" for the
screen sharing so we dont have to restart the app when the permissions are asked? we need to do
that if we're not already".

We were not. `cmux rd serve`, which captures the screen and injects input for a device hub session,
ran as a plain child of the app (`Contents/Resources/bin/cmux`). macOS charged its Screen Recording
and Accessibility checks to the app, so granting either one meant macOS's "Quit & Reopen" for all
of cmux: every terminal, chat and agent pane. Now the grants belong to a separate helper app. A
grant restarts only the helper, and since the helper is a fresh process for every use, the restart
needs no step from anyone.

## One permission identity with Computer Use (2026-11-17)

Lawrence, forwarded by Leo: "ensure screen sharing + computer use uses same app for permissions,
unless there's a good reason for having different apps for requesting screen sharing/accessibility".
Leo, 2026-11-16: "the screen sharing should just be able to come with as the bonus and be in the
separate process from teh app so it doesn't have to restart the app to grant permissions or
whatever". A process apart from the app is the reason to stay out of cmux; it is no reason for
screen sharing and computer use to differ. So release, NIGHTLY and RC builds ship the executable
inside the Computer Use helper:

```
cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app     com.cmuxterm.cua, every channel
  Contents/MacOS/cmux-cua               the Computer Use driver (the bundle's executable)
  Contents/MacOS/cmux-screen-sharing    the cmux.rd/1 host below, signed --identifier com.cmuxterm.cua
```

- **One row, already granted.** com.cmuxterm.cua is the Developer ID identity Computer Use has had
  since 2026-08, shared by every channel. Anyone who allowed Computer Use has both grants; anyone
  else is asked once, for "cmux Computer Use", by the one guide (`CmuxRemoteSharingSetup`), which
  now names that app. Either attribution model gives this row: the outermost bundle (macOS 26
  checks nested code as the outermost app; tried on Leo's Mac: the helper nested in cmux NIGHTLY
  read cmux NIGHTLY's grant, the same code anywhere else read none) or the code's own identifier
  (older macOS: the nested executable carries com.cmuxterm.cua and the helper's Developer ID
  requirement).
- **One staged copy.** The app stages the Computer Use helper once,
  `.../cmux-next/cmux-cua/helper/next-<scope>/cmux Computer Use.app`
  (`ComputerUseHelperStaging.legacy`), and both roles start from it with responsibility disclaimed;
  staging takes turns per copy, so one role never swaps out the copy the other runs. acpmux stages
  its own copy under `.../screen-sharing/com.cmuxterm.cua/daemon/`.
- **Packaging.** The Release build's phase still wraps the executable in its own app (the
  Computer Use helper does not exist yet then); the nightly's "Assemble the Computer Use helper"
  then moves it in (`bundle-screen-sharing-helper.sh --into-computer-use`), and
  `verify-computer-use-helper.sh` fails an app whose `Contents/Library` holds any app beside the
  Computer Use helper. Every signer signs `cmux-screen-sharing` with the helper's identifier before
  it seals the helper (`sign-cmux-bundle.sh`, `notarize-computer-use-helper.sh --start`,
  `release-signer/sign-app.sh`, `rcodesign-sign-bundle.sh`), so the helper's own notarization
  ticket covers it.
- **DEV keeps the separate helper below.** A DEV build's Computer Use helper is the pinned
  `cmux Computer Use (dev).app` (`embed-cua-helper-dev.sh`), signed with a certificate CI does not
  hold, so no executable can be added to it, and `reload.sh` drops any ad hoc com.cmuxterm.cua
  helper (a grant to one would replace the release row). DEV's screen sharing grants stay under
  "<app> Screen Sharing", ad hoc. Builds made before this change keep their separate helper too;
  the app and acpmux fall back to it.
- **The fleet** pins com.cmuxterm.cua in its MDM profile (cmuxterm-hq
  `build-fleet/mdm/cmux-screen-sharing.mobileconfig`) and keeps the old `.screen-sharing` ids until
  every fleet Mac runs a NIGHTLY with this layout.

The rest of this page describes the separate helper, which is what DEV builds still carry.

## Process layout

```
cmux NIGHTLY.app/Contents/Library/cmux NIGHTLY Screen Sharing.app
  Contents/MacOS/cmux-screen-sharing    the cmux.rd/1 host: cmux-tui/crates/cmux-rd-host's
                                        `cmux-rd`, built with only the `link` feature
                                        (the same code bin/cmux links in for `cmux rd serve`)
  Contents/Info.plist                   CFBundleIdentifier <app id>.screen-sharing
                                        (com.cmuxterm.app.nightly.screen-sharing),
                                        CFBundleName "<app name> Screen Sharing", LSUIElement
```

- **The name is per channel.** It comes from the app's own CFBundleName, so System Settings lists
  "cmux NIGHTLY Screen Sharing" next to "cmux NIGHTLY", and DEV, NIGHTLY and stable keep separate
  grants.
- **It is a Rust binary, not a launcher for bin/cmux.** macOS 26 checks a helper that runs inside
  another app's bundle against the outer app. So the helper runs from a verified copy outside the
  bundle (below), and copying the 140 MB CLI binary there for every build was not an option. The
  rd-host binary is a few MB.
- **Signing.**
  - Xcode builds sign it with the build's identity: ad hoc for local builds, or the developer's
    identity with hardened runtime.
  - Release signing (`scripts/sign-cmux-bundle.sh`, step 2b) runs
    `bundle-screen-sharing-helper.sh --stamp`. The nightly and RC rename the app after the build,
    and the stamp gives the helper the final bundle id and name. The script then signs the helper
    with the app's Developer ID, hardened runtime and a timestamp, before the app's own signature
    seals it. Notarization covers it as part of the app.
  - It needs no entitlements. The hardened runtime does not gate ScreenCaptureKit, CGEvent posting
    or AX.
- **A grant survives updates.** TCC keys a grant to the designated requirement, which is bundle id
  plus team (Developer ID). Ad-hoc dev builds key it to the cdhash, so a dev build asks again after
  every rebuild, as the app itself does today.

## Launch and supervision

- **Prior art.** The Computer Use helper (CmuxNextComputerUse) already solved both hard parts:
  - `ComputerUseHelperStaging` copies a signed helper to `~/Library/Application Support/cmux/...`
    and checks the copy against the bundled helper's designated requirement before it runs it.
  - `DisclaimedHelperSpawner` spawns with `responsibility_spawnattrs_setdisclaim`, so the child is
    its own "responsible process" and TCC charges it, not cmux.

  The new `SignedHelperLaunch` reuses both. It stages to
  `~/Library/Application Support/cmux-next/screen-sharing/<scope of the app's bundle id>/`. Its spawn
  takes stdin/stdout/stderr pipes, because `serve` speaks JSON lines.
- **Launch on first use.** `MacScreenHelper` (CmuxNextMacScreen) finds the bundled helper, stages
  it once per app run, and spawns:
  - `cmux-screen-sharing serve` for each session ticket (`MacScreenRdProcess.startServe`), the same
    JSON-lines protocol the in-app `cmux rd serve` child spoke;
  - `cmux-screen-sharing permissions` for a one-line `{"screen_recording":…,"accessibility":…}`
    probe;
  - `cmux-screen-sharing request-permission screen-recording|accessibility`, which shows the OS's
    own prompt, under the helper's name.
- **Restart after a grant.** Every probe and every session is a new process, so the first spawn
  after a grant reads the new state. If macOS opens the helper by itself ("Quit & Reopen" runs it
  through Launch Services with no arguments, or only `-psn_*`), it exits at once
  (`cmux_rd_host::is_launch_services_open`). The next share starts a fresh one.
- **Exit with the owner.**
  - A session's helper is the app's child: the app reaps it (`SignedHelperLaunch.reap`) and closes
    its stdin when the session ends, as it did for the in-app child.
  - When the app dies, its pipes close and `serve` exits on EOF.
  - The app keeps a session helper's stdout and stderr pipes for the session's life
    (`MacScreenRdProcess.startSpawned`). No `Process` holds them, and a released `Pipe` closes
    its read end under its reader. That left the helper's answer unread and the viewer at
    "Connecting..." (cmuxterm-hq#13721).
  - Probes have a 10 s deadline, then SIGKILL.
  - A started host that has not answered within 15 s fails the session. A viewer whose connect
    shows no picture within 15 s fails naming the stage it reached (no answer, no link, no
    frame). `mac_screen.state` reports it as `connect_stage` / `timed_out_at`.
- **No fallback across the line.** If a build carries the helper but staging fails, the share
  fails. Running capture in the app would silently move the grant back to cmux. A build without the
  helper (a local build with no cached Rust binary) keeps the old in-app path, so a dev build still
  works.

## IPC

- Unchanged: cmux.rd/1 JSON lines on the helper's stdin and stdout (the `serve` protocol that
  `MacScreenRdHost` already speaks), and diagnostics on stderr.
- The secure link, its keys and its framing stay inside the Rust host, as before.
- The permission probes are one JSON line on stdout.

## Permission state, read from the helper

`MacScreenShareHost` keeps its public surface: `screenRecordingGranted`, `accessibilityGranted`,
`refreshPermissions()`, `requestScreenRecording()`, `requestAccessibility()`, `openSettings` and
`computerName`. The Settings rows need no change.

- With a helper, `refreshPermissions()` asks the helper and the app makes no TCC check of its own.
- The request calls show the helper's prompt, then refresh. If the grant is still off, they open
  the matching Privacy pane.
- As before, the rows are read again when the app becomes active, which is when the person
  comes back from System Settings.
- New:
  - `grantHolderName` is the name System Settings lists, for row copy ("Allow cmux NIGHTLY
    Screen Sharing").
  - `requestAppAccessibility()` is for the one grant that stays the app's: the viewer's
    system-shortcut tap (`MacScreenSystemShortcuts`) runs in the app while you control another Mac.

## Consent

`~/.acpmux/machine-consent/consent.json` is owned by finish-remote (cmux#43983 and its Swift PR)
and its format is still moving. For now the app's existing `consentGate` in `MacScreenHubHost`
decides before any helper starts. The helper serves only a ticket the gated app hands it. Once
#43983 lands, the follow-up is for `serve` to read the same file through acpmux's
`_acpmux/machine_consent_get` and refuse a session the file does not allow. That gives a second
check outside the app.

## Build pipeline

The helper follows the iPhone host (cmux-mobile-host):

| Step | Script |
| --- | --- |
| Cargo build, cached by the source of `cmux-tui/crates` and `cmux-tui/vendor`; runs on CI and fleet builds only | `scripts/cmux-next/build-screen-sharing-helper.sh` |
| Xcode phase "Bundle Screen Sharing helper"; skips (old in-app path) without a binary | `scripts/cmux-next/bundle-screen-sharing-helper.sh` |
| Local reloads export the cached binary | `scripts/reload.sh` |
| Nightly: background build beside xcodebuild | `scripts/ci/nightly-steps/app-build-mobile-host.sh` |
| Nightly: bundle after xcodebuild, with `CMUX_NEXT_REQUIRE_SCREEN_HELPER=1` | `scripts/ci/nightly-steps/app-bundle-chief-and-mobile-host.sh` |
| Nightly: architecture check | `scripts/ci/nightly-steps/prepare-verify-binary-architectures.sh` |
| Developer ID signing before notarization | `scripts/sign-cmux-bundle.sh` |
| Notices; dependency budget for its lockfile | `scripts/cmux-next/notices/bundle-map.json`; `scripts/cmux-next/bundle-size-budget.json` |

## Left

- The WebRTC path for iPhone viewers (`ScreenStreamHost`, CmuxScreenKit) still captures in the
  app. Moving it means a WebRTC peer in the helper, or the helper capturing and handing IOSurfaces
  to the app.
- Consent read inside the helper, after #43983 (above).
- Notices: the helper maps to the `rust-cmux-cli` section, because bin/cmux links the same crates.
  A dedicated section built from `cmux-rd-host/Cargo.lock` would also list its exact versions.

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
  - Probes have a 10 s deadline, then SIGKILL.
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

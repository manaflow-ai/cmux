# cmux-next macOS support matrix and UI fuzz

## Supported versions

The floor is **macOS 14.0**. It is set in `MACOSX_DEPLOYMENT_TARGET = 14.0` (the `cmux-next` targets in
`cmux.xcodeproj`), in `.macOS(.v14)` (every first-party package), and in `LSMinimumSystemVersion = 14.0` (the
shipped nightly). Every Mach-O in nightly 3934457894701 has a minos of 14.0 or lower (`vtool -show-build`):
7 files have 11.0, 4 have 12.0, 5 have 13.0 and 11 have 14.0. The nightly is arm64 only. A Tart VM on Apple
silicon cannot run Intel macOS, so this matrix does not cover Intel Macs.

| Major | Name         | Where it runs                                        | Image / host OS                                        |
|-------|--------------|------------------------------------------------------|--------------------------------------------------------|
| 14    | Sonoma       | Tart VM | `macos-sonoma-base` 14.8.7 / `macos-sonoma-vanilla:14.8.7` |
| 15    | Sequoia      | Tart VM                                              | `macos-sequoia-base` 15.7.7 / `macos-sequoia-vanilla:15.7.7` |
| 26    | Tahoe        | Tart VM                                              | `macos-tahoe-base` 26.6.2 / `macos-tahoe-vanilla:26.6.2` |
| 27    | Golden Gate  | Tart VM on a macOS 27 host (no pinned image)            | `macos-golden-gate-vanilla:27.0`                       |

The vanilla images (login admin/admin) run with `FUZZ_IMAGE_<major>=ghcr.io/cirruslabs/macos-…-vanilla:<ver>`
and `FUZZ_HOST_LOCK=none` on a non-fleet Tart host. A macOS 27 guest needs a macOS 27 host.

The image pins are in `scripts/fuzz/macos-matrix/images.json`. These images are public Cirrus Labs images and
cost nothing. At this time the only host that holds all three images is `aws-m4pro-6`
(`/Volumes/ephemeral0/cmux-agent-work/mfloor/tart-home`). All fleet workers run macOS 26 or 27. None of them runs
14 or 15 natively.

## Fuzzer

`scripts/fuzz/macos-matrix/vm.sh BUILD` runs on the Tart host. For each major, it:

1. Takes the fleet host lock, clones the pinned image and boots it headless with
   Virtualization.framework's VNC server (`--vnc-experimental`).
2. Copies the build (`.app`, `.zip` or nightly `.dmg`) into the guest and starts it with the automation socket.
3. Runs `fuzz.py`. It does a scripted feature tour first (Settings, new workspace, splits, browser tab, Home,
   sidebar, window style, wallpaper, update card, What's New, extensions, Markdown, groups). Then it does a
   seeded random walk:
   - It runs CLI app actions with random enum, string and number arguments. The list comes from
     `cmux action list` (about 900 actions). Quit, update, sign-out, uninstall and cloud or billing actions
     are excluded.
   - It runs GUI-only actions by typing their title into the Cmd+Shift+P palette.
   - It sends real keys over VNC: Cmd+1-9, Ctrl+1-9, Cmd+D, Cmd+Shift+D, Cmd+W, Cmd+T, Cmd+N, Cmd+P,
     Cmd+Shift+P and every bound shortcut in the action table.
   - It sends clicks, right-clicks, double-clicks, drags (resizes, tab and sidebar drags), scrolls and typed
     text.
4. After every step, it pings the main thread from inside the guest. A ping over `--hang-ms` (1000 ms) counts
   as a hang and the fuzzer `sample`s the app. New `.ips` or `.hang` reports count as crashes. When the app
   has died, the fuzzer records a screenshot and starts the app again. At the end, it collects the unified-log
   faults of the cmux processes.
5. Copies the results out and deletes the clone.

The nightly app itself sends its crashes and its main-thread lag spikes of 250 ms or more to Sentry (the
`CmuxSentryTelemetry` package). Each event carries its OS version, so the Sentry issues split by OS.

Reproduce a finding: `vm.sh --majors 15 --replay <run>/15/steps.jsonl BUILD`. The same seed with the same
build gives the same steps. `fuzz.py --replay … --minimize` delta-debugs a crashing replay to a minimal step list
(`minimal.jsonl`). At each death the fuzzer saves the app's stderr (`dead-N.stderr.txt`): the Swift runtime's
fatal-error text is not in the `.ips`. For allocator bugs, `FUZZ_DYLIB=<dylib>` loads a diagnostic dylib into the
app (the guest copy is re-signed ad hoc without the hardened runtime).

The guest helpers use `/usr/bin/perl` and `osascript`, not `python3`: a guest without the Command Line Tools has
only the `python3` stub.

## Results

See `RESULTS.md` (one line per run: build, major, seed, steps, crashes, hangs, deaths, faults).

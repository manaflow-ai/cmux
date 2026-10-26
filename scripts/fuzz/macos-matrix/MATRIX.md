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
| 27    | Golden Gate  | Tart VM on a macOS 27 host only                      | `macos-golden-gate-base` (pinned 2026-10-24, 34 GB compressed) / `macos-golden-gate-vanilla:27.0` |

The vanilla images (login admin/admin) run with `FUZZ_IMAGE_<major>=ghcr.io/cirruslabs/macos-…-vanilla:<ver>`
and `FUZZ_HOST_LOCK=none` on a non-fleet Tart host. A macOS 27 guest needs a macOS 27 host.

The image pins are in `scripts/fuzz/macos-matrix/images.json`. These images are public Cirrus Labs images and
cost nothing. At this time the only host that holds all three images is `aws-m4pro-6`
(`/Volumes/ephemeral0/cmux-agent-work/mfloor/tart-home`, about 30 GB each). All fleet workers run macOS 26 or 27
(aws-m4pro-1..4: 27, aws-m4pro-5..9: 26). None of them runs 14 or 15 natively.

macOS 27 is pinned in images.json but no Tart host has it yet: a 27 guest needs a 27 host (aws-m4pro-1..4),
and those hosts have no Tart home for this matrix. vm.sh refuses a major whose `host_os_min` is above the host's
macOS. The fleet controller accepts majors 14, 15 and 26 only until the image is cached on a 27 worker and the
controller's `matrixMajors` gets 27.

## Run it on the fleet (agents)

`scripts/cmux-next/os-matrix.sh` is the one command. It is a tool agents run on demand, not a CI gate. From a
cmux worktree, with a done fleet DEV build job (`cmux-ci build cmux --ref SHA --tag TAG ...`):

```bash
scripts/cmux-next/os-matrix.sh --build JOB_ID --os 14,15                         # smoke, about 3 min a major
scripts/cmux-next/os-matrix.sh --build JOB_ID --os 15 --suite fuzz --seed 7 --minutes 20
scripts/cmux-next/os-matrix.sh --build JOB_ID --os 14 --suite repro:incognito-close-14
```

It submits one `cmux-ci run --class vm --script scripts/fuzz/macos-matrix/vm.sh` step with one `tart-<digest>`
label per major, waits, downloads the step's artifact (`os-matrix-results.tgz`) into
`artifacts/os-matrix/<build>-<suite>-<UTC>/` and prints one line per major and `MATRIX VERDICT PASS|FAIL|NO-VERDICT`. Exit
0 is PASS, 1 is FAIL, 75 is no verdict (a wait timeout leaves the step running: `cmux-ci wait ID`, never
resubmit). Per major the results hold `result.json` (smoke) or `summary.json` and `steps.jsonl` (fuzz), the app
log (`app.log`, the app's stdout and stderr), a VNC screenshot per smoke step (`shot-<step>.png`) or every 50 fuzz
steps, every `.ips`, `.hang` and `.diag` report of the cmux processes, and the unified-log faults
(`faults.ndjson`).

- The build may be of any commit; `--ref` (default: the feat-cmux-next tip) picks the runner. The fleet runs
  only a reviewed (landed) runner: the worker checks that the whole `scripts/fuzz/macos-matrix/` directory at
  the ref is the feat-cmux-next version, because vm.sh runs its helpers on the host. A change to the runner
  takes effect on the fleet after it lands.
- The smoke needs a DEV build (it drives the app through `cmux app call`, which a release build refuses). The
  fuzz and repro suites take any build; run a shipped DMG by hand (hq `build-fleet/AGENT-BUILDS.md`, "Run vm.sh
  by hand").
- One VM at a time on the Tart host (the worker has one VM token, see the keychain note below). The step never
  pulls an image: vm.sh pulls only with `FUZZ_ALLOW_PULL=1`. Do not delete or re-pull the cached images.
- **A VM is not a perf host.** It has a paravirtual GPU and no ProMotion. Use it for correctness, crashes, hangs,
  launch, functional checks and OS-behavior differences (Foundation, AppKit, SwiftUI and WebKit change between
  majors, issue #4529). Never report a VM timing as perf evidence; label any timing from a VM "VM, not
  comparable". The smoke records main-thread stalls of 1 s or more with that label.

### Smoke suite

`smoke.py` runs on the Tart host and drives the guest over SSH (`cmux app call`) and VNC (screenshots). Steps,
each ok/FAIL in `result.json`: `launch` (the app answers a ping), `window` (`debug.windows`), `terminal` (New Tab
makes a live terminal), `echo` (keys typed with `debug.key` run `echo cmux-matrix-$((6*7))` in the shell, and the
terminal shows the output line `cmux-matrix-42`), `split` (Split Right makes a second pane), `chromium` (a Chromium
tab loads a page served in the guest, and `debug.cef` says ready with no `unavailable` reason and no WebKit
fallback), `webkit` (a WebKit tab loads the same page), then WebKit's gesture-free scripts on a second WebKit
tab (port 8738): `favicon` (the favicon URL FaviconScript reads reaches the store), `type_waits`
(`browser.page.insert_text` answers only after the page handled the text: the page holds 1.2 s in its input handler,
under the router's 2 s request deadline),
`design_on` and `design_off` (Ctrl-Opt-Cmd-D over VNC adds and removes the design-mode overlay), `page_info` (View
Site Information opens its panel), `settings` (Settings opens and paints), `alive`, `quit`
(`quitEndEverything` ends the process within 30 s; else a `sample` and a kill). A crash report fails the run.

### Exec suite (OS probes)

`os-matrix.sh --build JOB --os 14,15,26 --suite exec:NAME` runs one OS probe, `probes/NAME.swift`, in each guest.
A probe is one self-contained Swift file (Foundation and system frameworks only). vm.sh compiles it on the Tart
host with the host's Xcode (`swiftc -O -target arm64-apple-macos14.0`, an ad hoc signature, 5 min bound),
copies only the binary into each guest and runs it there as the guest user `admin` with a 5 min bound. It
never runs on the host. Exit 0 is PASS, 1 is FAIL, and anything else (a crash, a trap, a timeout, exit 2
"cannot test") is no verdict: a probe must catch its errors and exit 1 for a FAIL. A probe that does not
compile is no verdict for that step only, with the compiler's error in the step log. The compile runs in its
own process group from an empty folder with its own module cache, bounded to 5 min. `result.json` per major
has the exit code, stdout, stderr, the runner commit (`runner_ref`) and the source's sha256.

- The source comes from the runner ref, not from the build: a probe tests the OS. It is review-gated like the
  rest of this folder: the fleet runs only a reviewed `scripts/fuzz/macos-matrix/` tree.
- NAME is a-z, 0-9 and `-`; `probes/` and `probes/NAME.swift` must be a real folder and a regular file, not
  links. `test_probe_names.sh` checks each refusal (run it on a fleet host).
- `CMUX_MATRIX_APP` holds the build's app path in the guest, for a later probe that needs the app.
- Probes: `url-root-parent` (issue #4529): `"/.."` on 14.8.7 and 15.7.7, `"/"` on 26.6.2 (2026-10-24).
- `key-change-cost` (issue #24913): ms of one key-window change between a window and its child window, with
  0-120 hidden workspace-like view trees in the window and out of it (does a hidden tree cost a key change?).

### cmux-unit and xctrace in the guest

Not supported by the pinned base images: they have no Xcode, so neither Swift Testing (`swift test`,
`xcodebuild test`) nor `xctrace` runs in them. A guest with Xcode can do both. Measured 2026-10-24 on
aws-m4pro-6 with a CoW clone of the local `cmux-ci-sequoia-xcode-26-3` VM (macOS 15.7.3, Xcode 26.3, Swift
6.2.4): `xctrace record --template "Time Profiler" --launch` records and `xctrace export` reads the
`time-profile` table (4960 rows in 5 s); `CPU Counters` fails (a VM has no CPU performance counters).
Images: `ghcr.io/cirruslabs/macos-sequoia-xcode` (Xcode 26.x, about 68 GB compressed, 140 GB disk) and
`macos-sonoma-xcode` (newest Xcode 16.2 beta 3, about 63 GB compressed). Xcode 26 needs macOS 15.6 or later,
so a macOS 14 guest has only Xcode 16, which cannot build cmux-next (Swift tools 6.2); there it could run
a test bundle built on the fleet (`xctest`) or record with xctrace 16. A Time Profiler trace from a VM is
correctness evidence (where the time goes), never a timing number. Adding an Xcode image is a decision for the
fleet owner (disk and pull time).

### Host keychain

Virtualization.framework keeps a host key in the login keychain. Tart fails with "Failed to get current host
key" in a session without a keychain search list (Tailscale SSH) or with a locked keychain (OpenSSH without a
GUI login, as a fleet step). On the fleet the worker unlocks the login keychain from `CMUX_CI_TART_KEYCHAIN_PASSWORD_FILE` when it is locked
and locks it again in its cleanup (also after a cancel or a timeout). By hand, vm.sh does the same for each VM
from `FUZZ_KEYCHAIN_PASSWORD_FILE` (a 0600 file, read on stdin: run without a tty). So the worker has one VM
token: a second VM could lose the keychain while it boots.

### Guest prompts that are not cmux

The macOS 15 and 26 images show "Allow sshd-session to find devices on local networks?" over the app: the
guest SSH session that drives the run asks for Local Network access. It is not cmux, and the smoke and the fuzz
drive the app through the control socket, so it does not change a verdict. It covers part of the screenshots.


## Fuzzer

`scripts/fuzz/macos-matrix/vm.sh --suite fuzz [--minutes N] BUILD` runs on the Tart host (os-matrix.sh starts it
there). For each major, it:

1. Takes the fleet host lock (a fleet step holds it already: `FUZZ_HOST_LOCK=none`), clones the pinned image and
   boots it headless with
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
   as a hang. A ping still unanswered at `--hang-ms` starts a 5 s `sample` of the app in the guest while the hang
   lasts (`hang-N.live-sample.txt`; `sudo -n` first, because the hardened runtime refuses a non-root sampler), and
   a 2 s sample follows after the ping. New `.ips` or `.hang` reports count as crashes. When the app
   has died, the fuzzer records a screenshot and starts the app again. At the end, it collects the unified-log
   faults of the cmux processes.
5. Copies the results out and deletes the clone.

The nightly app itself sends its crashes and its main-thread lag spikes of 250 ms or more to Sentry (the
`CmuxSentryTelemetry` package). Each event carries its OS version, so the Sentry issues split by OS.

Reproduce a finding: `vm.sh --majors 15 --replay <run>/15/steps.jsonl BUILD`. Save a minimal repro as
`repros/<name>.jsonl`; after it lands, `os-matrix.sh --suite repro:<name>` replays it on the fleet. The same seed with the same
build gives the same steps. `fuzz.py --replay … --minimize` delta-debugs a crashing replay to a minimal step list
(`minimal.jsonl`). At each death the fuzzer saves the app's stderr (`dead-N.stderr.txt`): the Swift runtime's
fatal-error text is not in the `.ips`. For allocator bugs, `FUZZ_DYLIB=<dylib>` loads a diagnostic dylib into the
app (the guest copy is re-signed ad hoc without the hardened runtime).

The guest helpers use `/usr/bin/perl` and `osascript`, not `python3`: a guest without the Command Line Tools has
only the `python3` stub.

## Results

See `RESULTS.md` (one line per run: build, major, seed, steps, crashes, hangs, deaths, faults).

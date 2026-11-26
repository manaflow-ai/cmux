#!/usr/bin/env bash
# cmux-next-ios on an iOS simulator, as a fleet step of class `simulator`
# (the M4 Pro minis that advertise the `simulator` label; never the M6 perf
# hosts). Agents cannot build cmux-next-ios on their own Mac (fleet guard) and
# the fleet's `build ios` target builds the classic app, so this is the route
# for the new app:
#
#   cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
#     --arg MODE --artifact artifacts/ios-sim/evidence.zip
#
# Add `--sim-features none` (or the features the step needs, e.g. push,storekit) to a `test` or
# `shots` step that needs no photo picker, voice, document picker or App Intents: it gets a slim
# simulator (about 1/5 of a stock one's memory), from the warm pool when one is booted (leased in
# under a second, 2026-11-25), so more steps fit per Mac and they start sooner. Only `build` is slim
# by default. BrowserOpenDefaultUITests and WelcomeGlideUITests pass slim with `none`.
#
# Any MODE that boots a simulator also takes, as further `--arg`s (see "The simulator's options"
# below): device=NAME (an iPhone type other than the default, e.g. --arg device=iPhone,16e or
# --arg device=iPhone,17,Pro,Max; commas stand for spaces; an unknown type exits 3 with the list)
# and reducemotion=1 (Reduce Motion on, read back in the simulator and in SUMMARY.md).
# Through the fleet controller (hq build-fleet/cmd/controller/ios_next_sim_step.go), until its
# change for these lands, they pass only after `shots` with at least one real scene, e.g.
#   --arg shots --arg device=iPhone,16e --arg reducemotion=1 --arg settings=-cmux-mobile-tab,settings
# The controller's argument pattern has no spaces or parentheses: a name with parentheses goes in
# its identifier form (device=iPhone-SE-3rd-generation).
#
# MODE:
#   release-build
#           CmuxMobileLinkFFI.xcframework, xcodegen, and an unsigned Release app
#           for generic iOS Simulator, without injected DEBUG or demo conditions.
#           Compile only: no simulator runtime, install, launch or publication.
#           Takes no further arguments; retains build logs and evidence.zip.
#   build   CmuxMobileLinkFFI.xcframework, xcodegen, and the app for the
#           simulator (Demo: optimized, with the DEBUG developer surface); then
#           boot one iPhone, install, launch, screenshot.
#   test    build, plus `xcodebuild test` of CmuxMobileKit on that iPhone.
#           Optional arguments after it (each one `--arg`; the controller's
#           argument pattern has no spaces, so lists are comma-separated):
#             only=TARGET/SUITE[,TARGET/SUITE...]   run only those kit tests
#               (-only-testing), e.g. only=CmuxMobileLiveTests/LinkRecoveryTests
#               (a suite, or TARGET/SUITE/test for an XCTest method).
#               A filter naming TickHarnessCellsTests also sets
#               CMUX_TICK_HARNESS=1, the suite's opt-in (it allocates and
#               runs for seconds, so the kit's full run skips it)
#             ui=SUITE[,SUITE...]   also run those CmuxMobileAppUITests suites
#               against the app in config= (below); with ui= and no only=, the kit run is skipped.
#               A suite named *ColdUITests or *ColdLiveUITests runs each of its test*Cold methods
#               on a freshly booted iPhone, CMUX_LAUNCH_COLD_RUNS (10) times
#               (LaunchTTIColdUITests); LAUNCHTTI lines go to launch-tti.jsonl.
#               LaunchColdLiveUITests also accepts repeatable net=lte|lossy-3|off
#               and runs against the paired live daemon (the duress link knob shapes
#               replay delivery when duress= is enabled).
#             duress=SPEC   run the UI suites under the offline duress simulator
#               (cmux-next-ios/design/duress-sim.md): cmux-duress (cmux-tui Rust) expands a
#               recorded Claude Code PTY stream and chat-sim's recorded chat into replay files
#               on this host, and the simulator's global defaults point the app at them
#               (CmuxMobileDuress), so every bench runs under that load unchanged. SPEC is
#               PRESET[,knob=value...] (presets idle, duress, heavy; `cmux-duress presets`),
#               or off (no duress). Repeat it (duress=off --arg duress=heavy) to run the
#               same suites once per SPEC on one simulator after one build: the before
#               and after of the same harness, each run's logs under ui-duress-SLUG*
#               and its resolved knobs (duress.json) under duress/SLUG/.
#             config=debug|demo   the configuration the UI tests' app is built in.
#               Default: demo (optimized -O, with the DEBUG developer surface, mock
#               sign-in and demo drivers) when every ui= suite is a LaunchTTI* suite,
#               so launch timings are of an optimized app as every shipped build is;
#               debug otherwise. A -Onone Debug app with its debug dylib launches
#               far slower than anything a person installs, so its launch numbers
#               measure the build, not the app.
#             video   record the UI tests' iPhone screen (simctl recordVideo)
#               to ui-video.mp4 in the artifact: before/after videos of a change;
#               with ffmpeg on the host (Homebrew), also ui-video-small.mp4:
#               540 wide, H.264 CRF 30, no audio, small enough for PR media
#               (lane-gh media takes at most 25 MiB); with ffmpeg, also
#               ui-video-shifts.md and ui-video.mp4.shifts.json: the jumps
#               (layout shifts), blinks and staggered settles in the video
#               (scripts/cmux-next/recording-shifts-report.py, report only)
#             profile record a CPU stack-sampling profile of the UI test run:
#               `xctrace record --instrument 'Time Profiler' --all-processes`
#               on the host (a simulator app is a host process, so every launch
#               the tests make is in it); needs ui=. Not the 'Time Profiler'
#               template: its os_log data source scans the host's whole log
#               store when the recording stops and never finishes on the
#               fleet's long-running hosts, and `--device <simulator>` never
#               starts (Xcode 26.6, 2026-11-14). The artifact gets
#               ui-profile.trace.zip (open it in Instruments; dropped above
#               2 GiB), ui-profile-toc.xml, ui-profile.log and
#               ui-profile-summary.md/.json (scripts/ci/ios_sim_time_profile.py):
#               per process, CPU and main-thread ms, and the symbols with the
#               most main-thread time, self and total. A profile that has no
#               time-profile samples fails the step. Profiled runs are slower;
#               do not read timings from them next to unprofiled ones.
#           The artifact keeps each run's log, its console output (a test's
#           print lines, e.g. benchmark numbers) and its per-test results.
#   bench   build, plus the in-app flood benchmark (TerminalFloodBench,
#           verify/terminal-flood.md) on PTY recordings made on the worker:
#             cat     `cat` of a 6 MB source file
#             vim     vim scrolling that file a line per redraw (Ctrl-E)
#             top     top refreshing once a second (htop when installed)
#           Each recording is replayed at the rate the program wrote it (capped
#           at 50 Mbit/s), with screenshots during and after the flood.
#   screen-proof
#           Protected manual ios-screen-sharing-proof.yml only: a completed
#           tagged Mac bundle, mounted phone start/input/Stop, sanitized receipt.
#   all     build, test and bench.
#   shots   build, plus one screenshot per scene, in dark and in light, from
#           the app's own DEBUG launch arguments and demo drivers (mock data,
#           setup marked complete). Each later argument is one scene,
#           `name=WORD,WORD,...`: the words are launch arguments (commas stand
#           for spaces, which fleet step arguments cannot hold), and leading
#           KEY=VALUE words are the app's environment, e.g.
#             --arg shots --arg devices=-cmux-mobile-settings-page,devices \
#               --arg feed=CMUX_MOBILE_FEED_STRESS=60,-cmux-mobile-tab,feed
#           Run it at the base and at the head for a PR's before and after.
#           A scene's leading SHOT_WAIT=N word (seconds, 1-60) is not passed to
#           the app: it is that scene's wait before the shot (default 5).
#           The scene `appstore=iphone-6.9` (not a screen) makes the run App Store
#           screenshots: the 6.9" iPhone (iPhone 17 Pro Max, else 16 Pro Max;
#           no other phone), the status bar overridden to 9:41 with full
#           signal and battery (`simctl status_bar override`), and each shot
#           checked to be the 6.9" display's portrait size (1320x2868 or
#           1290x2796) and written without an alpha channel (png_opaque.py),
#           or the step fails, e.g.
#             --arg shots --arg appstore=iphone-6.9 --arg 01-home=-cmux-mobile-tab,home
#   clips   build, plus the What's New clip of one iPhone highlight
#           (release-notes/next/clips/ID.json with "app": "iphone"): the app
#           runs the spec's scene (DEBUG launch arguments, demo drivers, mock
#           data) while `simctl io recordVideo` records the screen, and
#           whats-new-clips.py record-iphone writes whats-new-clips/ROLE/ID/
#           (manifest.json, capture.mp4) for publish-auto. Arguments (each `--arg`):
#             id=ID              the highlight (required)
#             roles=after,before what to record (default after); before is
#                                the app at base= on the same simulator
#             base=SHA           the commit before the highlight (with before)
#           The artifact whats-new-clips.zip holds only the clips folder; the
#           media workflow's iphone-clips job fetches it.
#   theme-relaunch [N]   (through the fleet controller: shots theme-relaunch=N, the same step)
#           build, plus the cached Mac theme across relaunch (R&D card rc-3586df8c): mock data,
#           setup marked complete, no Mac. One launch with no theme ever applied (the stock
#           reference), one with `-cmux-mobile-mac-appearance mocha-wallpaper` (a dark Mac theme
#           and a wallpaper, applied and kept as hostd's frame would be: the themed reference),
#           then N (1-20, default 10) terminate-and-relaunch cycles with no fixture and no Mac,
#           each a burst of screenshots from launch and a settled one, and the cache file's
#           digest before each. ios_theme_relaunch_count.py counts the relaunches with a frame
#           nearer the stock screen than the themed one; SUMMARY.md has "theme lost on K of N".
#           The artifact keeps theme-relaunch/ (every frame, verdict.json).
#   chief-live-perf / chief-live-perf-baseline
#           Three Chief layout measurements on one simulator, reusing test
#           DerivedData. Copy the identical head benchmark test to the baseline
#           tree; baseline mode selects its original-view adapter.
#           bench/ retains each log, console output and result bundle.
#   pair-e2e
#           build, plus a tagged DEBUG cmux NEXT Mac app built here
#           (reload.sh), and pairing by its QR code end to end
#           (cmux_next_pair_e2e.py): the Mac's Mobile Pairing link, opened on
#           the iPhone, pairs it with no Allow prompt and no test seed. Screens
#           of the Mac page (never while it shows a code: its image carries
#           the token), the phone's Settings > Devices (a base ref gives
#           the "before") and its scanner with the camera off; the Mac's
#           pairing log, hostd's log and paired-devices.json, keys redacted.
#           Then the upload leg: the phone streams a sparse ~150 MB file (past
#           the old 100 MiB cap) to the Mac with its own LinkUpload, and the
#           stored file's size and SHA-256 must match (UploadProbe.swift).
#           Optional upload words (each one `--arg`): upload-mb=N (N MiB, 1-4096,
#           instead of ~150 MB), upload-random (random bytes, as a video's, not a
#           sparse file), upload-relay (the phone's link relay only),
#           upload-block-udp (the phone's link with UDP blocked), upload-wait=S
#           (seconds to wait for the probe's result, 60-3600, default 300).
#   listperf
#           build, plus the list frame-rate rig (ListStressRig,
#           verify/listperf/): each case launches the Demo app with
#           CMUX_MOBILE_LIST_SCREEN and its settings, waits for it to exit after
#           its scroll passes, and keeps its framelog.jsonl and summary
#           (verify/feedperf/summarize.py: the POOLED autoscroll line and each
#           -open window). Optional arguments (each one `--arg`):
#             base=SHA     also build SHA (a commit with the rig's files, e.g. the
#                          PR's base with them grafted on) in a worktree of this
#                          checkout, and run every case on both apps, base then
#                          head, on the one simulator: a same-harness before/after
#             reps=N       repetitions of every case (1-5, default 2)
#             cases=A,B    cases by label (default ws-200-live4, chat-40-stream,
#                          chat-40, diff-2400, tabs-30-stream); the labels (a
#                          branch's verify/listperf/final.sh runs the same):
#                          ws-200 ws-200-live4 ws-500-live8 home-300
#                          home-25-live (300 rows, 25 live Chiefs: 60 typing or
#                          new-message changes a second through MacHomeFeed's event
#                          path) home-5000 (5000 rows, idle; one pass at 4000 pt/s,
#                          so both windows fit the 300 s launch bound)
#                          chat-40 chat-200 chat-40-stream tabs-30 tabs-30-stream
#                          tabs-80 diff-2400 diff-2400-pan artifacts-40 feed-ref
#                          subagent-200 (a finished subagent, 200 transcript items)
#                          subagent-stream (a running subagent, 40 items, a token
#                          every 20 ms, 5 siblings changing state)
#                          subagent-2000 (2000 items; one pass, for the 300 s bound)
#                          subagents-list-60 (60 subagents 3 deep, 10 changing 4 Hz)
#                          events-500 (Event Inspector, 500 records, some ~160 KB)
#                          events-burst (events-500, then 2000 records in 1 s)
#                          events-filter (events-500 at 20 records/s while "tool_call"
#                          is typed into Filter and cleared, repeating)
#                          ws-heavy-live feed-live ws-2000 (the first two: a
#                          busy Mac on the real live path, ListStressSettings
#                          CMUX_MOBILE_LIST_FLOOD)
#                          coord-sim (a heavy coordinator chat from coord-sim
#                          streaming at 10x while it scrolls; its attach ms and
#                          memory lines are in listperf/<run>.jsonl)
#                          A row's rig knobs may exist only on a feature branch's
#                          app; the table is data.
#           SUMMARY.md gets one row per window; the artifact keeps listperf/.
#   energy
#           build, plus the battery and memory bench (cmux-next-ios/verify/energy.md):
#           each case launches the Demo app in mock mode on a list rig screen
#           (CMUX_MOBILE_LIST_*), waits for the rig's ready line in its log,
#           then reads the app process's kernel counters once a second
#           (proc_pid_rusage, energy_rusage.py: CPU %, wakeups/s, energy in
#           mW, memory footprint). The first rep of a busy case (stream,
#           scroll) then records 15 s of `xctrace --instrument 'Time Profiler'`
#           on each side: the main-thread top symbols go to the step log and
#           energy/profile-RUN/ (summary.md, summary.json, time.trace.zip).
#           Optional arguments (each one `--arg`):
#             base=SHA     also build SHA and run every case on both apps, base
#                          then head, on the one simulator (as listperf's base=)
#             reps=N       repetitions of every case (1-5, default 1)
#             seconds=S    seconds sampled per case (10-1800, default 30)
#             cases=A,B    cases by label (default: every case but drift-30m,
#                          hidden-terminals-4 and the running-chat ones):
#                          idle-home idle-home-5000 idle-chat-400 tabs-10
#                          scroll-chat-200 stream-chat background-home drift-30m
#                          hidden-terminals-4 (4 warm terminal tabs streaming,
#                          hidden behind the workspaces list)
#                          idle-chat-40 working-chat working-chat-away working-chat-bg
#                          (a chat with one running turn, its elapsed time live: on screen,
#                          scrolled away, the app in the background; each counts the
#                          time's redraws, `label ticks` in SUMMARY.md)
#                          typical-hour-pty typical-hour-lean (10 minutes of a
#                          visible Claude Code terminal replaying its recorded
#                          session, as PTY bytes or as lean frames, the app's own
#                          DaemonTerminalSession on a fake Mac; x6 for an hour)
#           SUMMARY.md gets one row per run; the artifact keeps energy/.
#   handoff tag=TAG   (through the fleet controller: shots handoff=TAG, the same step)
#           the end-of-task build of the cmux-next iPhone app for one task tag
#           (cmux-next-ios/scripts/review.sh runs it): the Demo configuration
#           (optimized, DEBUG developer surface, so automated dev sign-in
#           works) with bundle dev.cmux.mobile.TAG, display name "cmux TAG"
#           and this commit in Info.plist, for the simulator and for devices.
#           The device app is unsigned (CODE_SIGNING_ALLOWED=NO); the person's
#           Mac signs it with its Apple Development identity. Then the
#           simulator check: the app signed in with the agent account's session
#           from the submitter's Mac (cmux-ci run --sign-in agent, read with
#           scripts/lib/fleet-signin-session.sh, never printed), proven by
#           its DEBUG readiness receipt (session auto_login), then relaunched
#           with no credentials and proven again (session restored), with a
#           screenshot of each and a recording. The artifact (evidence.zip)
#           holds both apps zipped, handoff.json (the build's identity and the
#           simulator verdict), the screens and the recording. A simulator
#           check that fails keeps the step green with the verdict in
#           handoff.json, so the device app still comes back.
#   try     (through the fleet controller until it lists try: shots try=dev, the same step)
#           the cmux Dev iPhone app for `cmux-next-ios/scripts/try.sh`: only the
#           unsigned device app, no simulator, no sign-in. The Demo configuration
#           (optimized, DEBUG developer surface) with bundle dev.cmux.mobile.dev,
#           home-screen name "cmux Dev" and this commit in Info.plist, and no dev
#           tag: it sends no X-Cmux-Build-Space, so like the shared Demo build it
#           pairs with the person's NIGHTLY Mac and shows their real data. Every try
#           build has the same bundle id, so it installs over the last one and keeps
#           its sign-in and pairing (cmuxterm-hq docs/design/ios-dev-channels.md).
#           The artifact (evidence.zip) holds CmuxMobileApp-Dev-device-unsigned.app.zip,
#           try.json (commit, bundle id, build seconds) and SUMMARY.md.
#
# Isolation: the step makes its own simulator device set under its checkout
# (`simctl --set`), so it never lists, boots or deletes another simulator, and
# deletes the set when it ends. Every simulator comes from sim_create, which a
# fleet worker may serve slim (see sim_create below). The artifact holds the screenshots, each
# benchmark's flood-bench.json, the app log, the test summary, SUMMARY.md, the
# built app (zipped) and the PTY recordings with their replay rates.
set -euo pipefail
trap 'echo "cmux-next-ios-sim.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

# shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet cmux-next-ios-sim.sh "xcodebuild and an iOS simulator" "cmux-next-ios kit tests" \
  "cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg bench --artifact artifacts/ios-sim/evidence.zip"

mode="${1:-build}"
# The simulator's options, taken out of the arguments before each mode reads its own, so they go
# after any MODE that boots a simulator, in any order (each at most once):
#   device=NAME      that iPhone device type instead of the default (the first of ios_sim_runtime.py's
#                    PHONES): its name ("iPhone 16e"), the same with commas for spaces
#                    (device=iPhone,16e: fleet step arguments hold no spaces) or its identifier's last
#                    part (device=iPhone-SE-3rd-generation, for a name with parentheses). Every
#                    simulator of the step (the app's, the kit and UI tests', the Chief benchmark's)
#                    is that type. A type the runtime lacks fails the step with exit 3 and the
#                    runtime's iPhone types, before anything is built; never another device.
#   reducemotion=1   Reduce Motion on in every simulator of the step, before the app first launches
#                    (`defaults write com.apple.Accessibility ReduceMotionEnabled` inside the booted
#                    simulator), read back there and written to SUMMARY.md; the DEBUG app logs
#                    UIAccessibility.isReduceMotionEnabled at launch and SUMMARY.md quotes that line.
# SUMMARY.md names the device type the step ran on. shots therefore has no scene named device or
# reducemotion.
sim_device=""
reduce_motion=0
if [[ $# -gt 1 ]]; then
  sim_rest=()
  for arg in "${@:2}"; do
    case "$arg" in
      device=*)
        [[ -z "$sim_device" ]] || { echo "cmux-next-ios-sim.sh: device= given twice" >&2; exit 2; }
        sim_device="${arg#device=}"
        device_pattern='^[A-Za-z0-9][A-Za-z0-9 ,._()-]*$'
        [[ "$sim_device" =~ $device_pattern ]] ||
          { echo "cmux-next-ios-sim.sh: device= wants an iPhone device type name, e.g. device=iPhone,16e, got '$sim_device'" >&2; exit 2; } ;;
      reducemotion=1) reduce_motion=1 ;;
      reducemotion=*) echo "cmux-next-ios-sim.sh: reducemotion takes only reducemotion=1, got '$arg'" >&2; exit 2 ;;
      *) sim_rest+=("$arg") ;;
    esac
  done
  set -- "$1" ${sim_rest[@]+"${sim_rest[@]}"}
fi
if [[ "$mode" == release-build && ( -n "$sim_device" || $reduce_motion -eq 1 ) ]]; then
  echo "cmux-next-ios-sim.sh: release-build boots no simulator; it takes no device= or reducemotion=" >&2; exit 2
fi
# handoff through the fleet controller's shots form: the controller's MODE list (hq
# build-fleet/cmd/controller/ios_next_sim_step.go iosNextSimModes) does not name handoff yet, and
# shots takes name=WORDS scenes, so `shots handoff=TAG` (exactly that one scene) is handoff tag=TAG.
if [[ "$mode" == shots && $# -eq 2 && "${2:-}" == handoff=* ]]; then
  set -- handoff "tag=${2#handoff=}"
  mode=handoff
fi
# theme-relaunch through the shots form too (shots theme-relaunch=N), until the controller lists it.
if [[ "$mode" == shots && $# -eq 2 && "${2:-}" == theme-relaunch=* ]]; then
  set -- theme-relaunch "${2#theme-relaunch=}"
  mode=theme-relaunch
fi
# try through the shots form too (shots try=dev), until the controller lists try.
if [[ "$mode" == shots && $# -eq 2 && "${2:-}" == try=dev ]]; then
  set -- try
  mode=try
fi
case "$mode" in build|release-build|test|bench|all|pair-e2e|screen-proof|shots|clips|chief-live-perf|chief-live-perf-baseline|listperf|energy|handoff|try|theme-relaunch) ;; *) echo "cmux-next-ios-sim.sh: MODE is build, release-build, test, bench, all, pair-e2e, screen-proof, shots, clips, chief-live-perf, chief-live-perf-baseline, listperf, energy, handoff, try or theme-relaunch, got '$mode'" >&2; exit 2 ;; esac
if [[ ( "$mode" == release-build || "$mode" == try ) && $# -ne 1 ]]; then
  echo "cmux-next-ios-sim.sh: $mode takes no further arguments" >&2; exit 2
fi
if [[ "$mode" == screen-proof ]]; then
  [[ $# -eq 1 && "${GITHUB_ACTIONS:-}" == true ]] || {
    echo "screen-proof requires its protected Actions workflow" >&2; exit 2;
  }
  for key in CMUX_SCREEN_PROOF_SOURCE CMUX_SCREEN_PROOF_MAC_JOB CMUX_SCREEN_PROOF_ARTIFACT; do
    [[ -n "${!key:-}" ]] || { echo "screen-proof missing artifact binding" >&2; exit 2; }
  done
  [[ "$(git rev-parse HEAD)" == "$CMUX_SCREEN_PROOF_SOURCE" ]] || exit 2
  python3 -I scripts/ci/cmux_next_screen_sharing_proof.py --preflight
fi
scenes=()
appstore=0
for scene in "${@:2}"; do
  if [[ "$mode" == shots && "$scene" == appstore=iphone-6.9 ]]; then appstore=1; else scenes+=("$scene"); fi
done
theme_relaunches=10
if [[ "$mode" == theme-relaunch ]]; then
  [[ $# -le 2 ]] || { echo "cmux-next-ios-sim.sh: theme-relaunch takes at most one argument, the relaunch count" >&2; exit 2; }
  if [[ $# -eq 2 ]]; then theme_relaunches="$2"; fi
  [[ "$theme_relaunches" =~ ^([1-9]|1[0-9]|20)$ ]] ||
    { echo "cmux-next-ios-sim.sh: theme-relaunch wants a count of 1-20, got '$theme_relaunches'" >&2; exit 2; }
fi
# handoff's one argument: the task tag (already a slug: lowercase letters, digits, dashes).
handoff_tag=""
if [[ "$mode" == handoff ]]; then
  [[ $# -eq 2 && "${2:-}" == tag=* ]] || { echo "cmux-next-ios-sim.sh: handoff takes one argument, tag=TAG" >&2; exit 2; }
  handoff_tag="${2#tag=}"
  # The one tag rule of every build entry point (reload.sh, review.sh): a canonical tag (its own slug, so
  # no two spellings share the space dev:<tag>), and none of the reserved ones: default, dev (the cmux Dev
  # app, try mode, which shows the person's real data), demo and prod (demo-build.sh's installs).
  # shellcheck source=scripts/lib/mobile-attach.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../lib/mobile-attach.sh"
  cmux_attach_validate_dev_tag "$handoff_tag" || { echo "cmux-next-ios-sim.sh: handoff tag=$handoff_tag refused" >&2; exit 2; }
fi
if [[ "$mode" == shots && ${#scenes[@]} -eq 0 ]]; then
  echo "cmux-next-ios-sim.sh: shots needs one or more scenes after it, name=WORD,WORD,..." >&2; exit 2
fi

# pair-e2e's optional upload words (see MODE above), checked before anything is built.
pair_upload=()
if [[ "$mode" == pair-e2e && $# -gt 1 ]]; then
  for word in "${@:2}"; do
    case "$word" in
      upload-mb=*)
        n="${word#upload-mb=}"
        [[ "$n" =~ ^[1-9][0-9]{0,3}$ && "$n" -le 4096 ]] || { echo "cmux-next-ios-sim.sh: upload-mb= wants 1-4096, got '$n'" >&2; exit 2; }
        pair_upload+=(--upload-bytes "$((n << 20))") ;;
      upload-wait=*)
        n="${word#upload-wait=}"
        [[ "$n" =~ ^[1-9][0-9]{1,3}$ && "$n" -ge 60 && "$n" -le 3600 ]] || { echo "cmux-next-ios-sim.sh: upload-wait= wants 60-3600, got '$n'" >&2; exit 2; }
        pair_upload+=(--upload-wait "$n") ;;
      upload-random) pair_upload+=(--upload-random) ;;
      upload-relay) pair_upload+=(--upload-relay-only) ;;
      upload-block-udp) pair_upload+=(--upload-block-udp) ;;
      *) echo "cmux-next-ios-sim.sh: pair-e2e takes upload-mb=N, upload-wait=S, upload-random, upload-relay and upload-block-udp, got '$word'" >&2; exit 2 ;;
    esac
  done
fi

# test's optional selection (see MODE above), checked before anything is built.
kit_only=()
kit_env=()
ui_suites=()
ui_cold=()
ui_video=0
ui_profile=0
ui_config=""
duress_specs=()
net_profiles=()
if [[ "$mode" == test && $# -gt 1 ]]; then
  for sel in "${@:2}"; do
    case "$sel" in
      only=?*)
        IFS=',' read -r -a items <<< "${sel#only=}"
        for item in "${items[@]}"; do
          [[ "$item" =~ ^[A-Za-z0-9_]+(/[A-Za-z0-9_]+){0,2}$ ]] ||
            { echo "cmux-next-ios-sim.sh: only= wants TARGET/SUITE names, got '$item'" >&2; exit 2; }
          kit_only+=("-only-testing:$item")
          [[ "$item" == */TickHarnessCellsTests* ]] && kit_env=(TEST_RUNNER_CMUX_TICK_HARNESS=1)
        done ;;
      ui=?*)
        IFS=',' read -r -a items <<< "${sel#ui=}"
        for item in "${items[@]}"; do
          [[ "$item" =~ ^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?$ ]] ||
            { echo "cmux-next-ios-sim.sh: ui= wants CmuxMobileAppUITests suite names, got '$item'" >&2; exit 2; }
          # A suite named *ColdUITests or *ColdLiveUITests (SUITE or SUITE/test) runs each of its
          # test*Cold methods on a freshly booted simulator, CMUX_LAUNCH_COLD_RUNS times (default 10):
          # one cold launch per run.
          if [[ "${item%%/*}" == *ColdUITests || "${item%%/*}" == *ColdLiveUITests ]]; then ui_cold+=("$item"); else ui_suites+=("-only-testing:CmuxMobileAppUITests/$item"); fi
        done ;;
      duress=?*)
        [[ "${sel#duress=}" =~ ^[a-z][a-z0-9_-]*(,[a-z_]+=[A-Za-z0-9._-]+)*$ ]] ||
          { echo "cmux-next-ios-sim.sh: duress= wants off or PRESET[,knob=value...], got '$sel'" >&2; exit 2; }
        duress_specs+=("${sel#duress=}") ;;
      net=?*)
        [[ "${sel#net=}" =~ ^(off|lte|lossy-3)$ ]] ||
          { echo "cmux-next-ios-sim.sh: net= wants off, lte or lossy-3, got '$sel'" >&2; exit 2; }
        net_profiles+=("${sel#net=}") ;;
      config=debug) ui_config=Debug ;;
      config=demo) ui_config=Demo ;;
      video) ui_video=1 ;;
      profile) ui_profile=1 ;;
      *) echo "cmux-next-ios-sim.sh: test takes only=LIST, ui=LIST, duress=SPEC, net=PROFILE, config=debug|demo, video and profile, got '$sel'" >&2; exit 2 ;;
    esac
  done
  if [[ $ui_profile -eq 1 && $((${#ui_suites[@]} + ${#ui_cold[@]})) -eq 0 ]]; then
    echo "cmux-next-ios-sim.sh: profile records the UI test run; give it ui=SUITE,..." >&2; exit 2
  fi
  if [[ -z "$ui_config" ]]; then
    # Launch timing suites alone: an optimized (Demo) app, as every shipped build is (see config= above).
    ui_config=Debug
    if [[ $((${#ui_suites[@]} + ${#ui_cold[@]})) -gt 0 ]]; then
      ui_config=Demo
      # Guarded expansions: Bash 3.2 under set -u treats an empty array as unbound (only warm or only cold suites).
      for item in ${ui_suites[@]+"${ui_suites[@]#-only-testing:CmuxMobileAppUITests/}"} ${ui_cold[@]+"${ui_cold[@]}"}; do
        [[ "${item%%/*}" == LaunchTTI* ]] || { ui_config=Debug; break; }
      done
    fi
  fi
  if [[ ${#duress_specs[@]} -gt 0 && ( ${#ui_suites[@]} -eq 0 || $ui_profile -eq 1 || $ui_video -eq 1 ) && ${#ui_cold[@]} -eq 0 ]]; then
    echo "cmux-next-ios-sim.sh: duress= runs UI suites, without profile or video" >&2; exit 2
  fi
  if [[ ${#net_profiles[@]} -gt 0 && ${#ui_cold[@]} -eq 0 ]]; then
    echo "cmux-next-ios-sim.sh: net= is supported by a cold UI suite" >&2; exit 2
  fi
fi
run_kit=1

# listperf's cases (label, screen, settings), as verify/listperf/final.sh runs them.
listperf_table=(
  "ws-200          workspaces  LIST_COUNT=200"
  "ws-200-live4    workspaces  LIST_COUNT=200 LIST_LIVE_HZ=4"
  "ws-500-live8    workspaces  LIST_COUNT=500 LIST_LIVE_HZ=8"
  "home-300        home        LIST_COUNT=300"
  "home-25-live    home        LIST_COUNT=300 LIST_LIVE_HZ=20 LIST_LIVE_ROWS=3"
  "home-5000       home        LIST_COUNT=5000 LIST_PASSES=1 LIST_SPEED=4000"
  "chat-40         chat        LIST_COUNT=40"
  "chat-200        chat        LIST_COUNT=200"
  "chat-40-stream  chat        LIST_COUNT=40 LIST_STREAM=1"
  "tabs-30         tabs        LIST_COUNT=30"
  "tabs-30-stream  tabs        LIST_COUNT=30 LIST_STREAM=1"
  "tabs-80         tabs        LIST_COUNT=80"
  "diff-2400       diff        LIST_COUNT=3"
  "diff-2400-pan   diff        LIST_COUNT=3 LIST_PAN=1 LIST_PASSES=4 LIST_SPEED=800"
  "artifacts-40    artifacts   LIST_COUNT=40"
  "feed-ref        feed        FEED_STRESS=320"
  "subagent-200       subagent    LIST_COUNT=200"
  "subagent-stream    subagent    LIST_COUNT=40 LIST_STREAM=1"
  "subagent-2000      subagent    LIST_COUNT=2000 LIST_PASSES=1"
  "subagents-list-60  subagents   LIST_COUNT=60 LIST_LIVE_HZ=4"
  "events-500         inspector   LIST_COUNT=500"
  "events-burst       inspector   LIST_COUNT=500 LIST_STREAM=1"
  "events-filter      inspector   LIST_COUNT=500 LIST_LIVE_HZ=20 LIST_FILTER=tool_call"
  "ws-heavy-live   workspaces  LIST_FLOOD=45 LIST_FLOOD_ROWS=200 LIST_FLOOD_ADD_SECONDS=3 LIST_FLOOD_BURST=500 LIST_PASSES=3 LIST_SPEED=2400"
  "feed-live       feed        LIST_FLOOD=45 LIST_FLOOD_ROWS=200 LIST_FLOOD_ADD_SECONDS=3 FEED_STRESS=320 LIST_PASSES=2 LIST_SPEED=2400"
  "ws-2000         workspaces  LIST_COUNT=2000 LIST_PASSES=1"
  "coord-sim       chat        LIST_EVENTS=coord-sim LIST_PASSES=3"
)
listperf_base="" listperf_reps=2
listperf_cases=(ws-200-live4 chat-40-stream chat-40 diff-2400 tabs-30-stream)
if [[ "$mode" == listperf ]]; then
  for sel in "${@:2}"; do
    case "$sel" in
      base=*)
        listperf_base="${sel#base=}"
        [[ "$listperf_base" =~ ^[0-9a-f]{40}$ ]] || { echo "cmux-next-ios-sim.sh: base= wants a 40-character commit SHA, got '$listperf_base'" >&2; exit 2; } ;;
      reps=*)
        listperf_reps="${sel#reps=}"
        [[ "$listperf_reps" =~ ^[1-5]$ ]] || { echo "cmux-next-ios-sim.sh: reps= wants 1 to 5, got '$listperf_reps'" >&2; exit 2; } ;;
      cases=?*)
        IFS=',' read -r -a listperf_cases <<< "${sel#cases=}"
        for item in "${listperf_cases[@]}"; do
          printf '%s\n' "${listperf_table[@]}" | awk '{ print $1 }' | grep -qxF -- "$item" ||
            { echo "cmux-next-ios-sim.sh: no listperf case '$item'" >&2; exit 2; }
        done ;;
      *) echo "cmux-next-ios-sim.sh: listperf takes base=SHA, reps=N and cases=LIST, got '$sel'" >&2; exit 2 ;;
    esac
  done
fi
# energy's cases (label, screen, phase, seconds or "-", settings). The phase is what the app does
# while it is sampled: idle (holding the screen), scroll (the rig's passes), stream (a long answer
# streaming), background (another app in front). A seconds column overrides seconds=.
energy_table=(
  "idle-home        home    idle        -     LIST_COUNT=20 LIST_PASSES=0"
  "idle-home-5000   home    idle        -     LIST_COUNT=5000 LIST_PASSES=0"
  "idle-chat-400    chat    idle        -     LIST_COUNT=400 LIST_PASSES=0"
  "tabs-10          tabs    idle        -     LIST_COUNT=10 LIST_PASSES=0"
  "hidden-terminals-4 terminals stream -    LIST_COUNT=4 LIST_STREAM=1 LIST_PASSES=0"
  "idle-terminal     terminals idle   -     LIST_COUNT=1 LIST_PASSES=0 LIST_TERMINAL_VISIBLE=1"
  "visible-busy-terminal terminals stream - LIST_COUNT=1 LIST_STREAM=1 LIST_PASSES=0 LIST_TERMINAL_VISIBLE=1"
  "scroll-chat-200  chat    scroll      -     LIST_COUNT=200 LIST_PASSES=50 LIST_SETTLE=1"
  "stream-chat      chat    stream      -     LIST_COUNT=40 LIST_STREAM=1 LIST_PASSES=0"
  "background-home  home    background  -     LIST_COUNT=20 LIST_PASSES=0"
  "drift-30m        home    idle        1800  LIST_COUNT=20 LIST_PASSES=0"
  "idle-chat-40      chat    idle        -     LIST_COUNT=40 LIST_PASSES=0"
  "working-chat      chat    idle        -     LIST_COUNT=40 LIST_PASSES=0 LIST_SEND=1 LIST_HOLD_TURN=1 LIST_LEAVE_NEWEST=0"
  "working-chat-away chat    idle        -     LIST_COUNT=40 LIST_PASSES=0 LIST_SEND=1 LIST_HOLD_TURN=1"
  "working-chat-bg   chat    background  -     LIST_COUNT=40 LIST_PASSES=0 LIST_SEND=1 LIST_HOLD_TURN=1 LIST_LEAVE_NEWEST=0"
  "typical-hour-pty  hybrid  stream      600   HYBRID_BENCH_LOOP=1 HYBRID_BENCH_MODE=pty HYBRID_BENCH_FILE=@REPO@/cmux-next-ios/verify/agent-cli-hybrid/claude-code-2.1.310.json"
  "typical-hour-lean hybrid  stream      600   HYBRID_BENCH_LOOP=1 HYBRID_BENCH_MODE=lean HYBRID_BENCH_FILE=@REPO@/cmux-next-ios/verify/agent-cli-hybrid/claude-code-2.1.310.json"
)
energy_reps=1 energy_seconds=30
energy_cases=(idle-home idle-home-5000 idle-chat-400 tabs-10 scroll-chat-200 stream-chat background-home)
if [[ "$mode" == energy ]]; then
  for sel in "${@:2}"; do
    case "$sel" in
      base=*)
        listperf_base="${sel#base=}"
        [[ "$listperf_base" =~ ^[0-9a-f]{40}$ ]] || { echo "cmux-next-ios-sim.sh: base= wants a 40-character commit SHA, got '$listperf_base'" >&2; exit 2; } ;;
      reps=*)
        energy_reps="${sel#reps=}"
        [[ "$energy_reps" =~ ^[1-5]$ ]] || { echo "cmux-next-ios-sim.sh: reps= wants 1 to 5, got '$energy_reps'" >&2; exit 2; } ;;
      seconds=*)
        energy_seconds="${sel#seconds=}"
        [[ "$energy_seconds" =~ ^[0-9]+$ && "$energy_seconds" -ge 10 && "$energy_seconds" -le 1800 ]] ||
          { echo "cmux-next-ios-sim.sh: seconds= wants 10 to 1800, got '$energy_seconds'" >&2; exit 2; } ;;
      cases=?*)
        IFS=',' read -r -a energy_cases <<< "${sel#cases=}"
        for item in "${energy_cases[@]}"; do
          printf '%s\n' "${energy_table[@]}" | awk '{ print $1 }' | grep -qxF -- "$item" ||
            { echo "cmux-next-ios-sim.sh: no energy case '$item'" >&2; exit 2; }
        done ;;
      *) echo "cmux-next-ios-sim.sh: energy takes base=SHA, reps=N, seconds=S and cases=LIST, got '$sel'" >&2; exit 2 ;;
    esac
  done
fi
# clips' arguments (see MODE above). The before is built like listperf's base= (listperf_base).
clip_id="" clip_roles=(after)
if [[ "$mode" == clips ]]; then
  for sel in "${@:2}"; do
    case "$sel" in
      id=*)
        clip_id="${sel#id=}"
        [[ "$clip_id" =~ ^[a-z0-9][a-z0-9-]{0,79}$ ]] || { echo "cmux-next-ios-sim.sh: id= wants a highlight id, got '$clip_id'" >&2; exit 2; } ;;
      roles=after|roles=before|roles=after,before)
        IFS=',' read -r -a clip_roles <<< "${sel#roles=}" ;;
      base=*)
        listperf_base="${sel#base=}"
        [[ "$listperf_base" =~ ^[0-9a-f]{40}$ ]] || { echo "cmux-next-ios-sim.sh: base= wants a 40-character commit SHA, got '$listperf_base'" >&2; exit 2; } ;;
      *) echo "cmux-next-ios-sim.sh: clips takes id=ID, roles=after|before|after,before and base=SHA, got '$sel'" >&2; exit 2 ;;
    esac
  done
  [[ -n "$clip_id" ]] || { echo "cmux-next-ios-sim.sh: clips needs id=ID" >&2; exit 2; }
  if [[ " ${clip_roles[*]} " == *" before "* && -z "$listperf_base" ]]; then
    echo "cmux-next-ios-sim.sh: roles=...before needs base=SHA" >&2; exit 2
  fi
fi
if [[ $((${#ui_suites[@]} + ${#ui_cold[@]})) -gt 0 && ${#kit_only[@]} -eq 0 ]]; then run_kit=0; fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# listperf needs the rig in the app it measures (ListStressRig reads
# CMUX_MOBILE_LIST_SCREEN; summarize.py reads its frame log). A tree without it
# would launch the ordinary app and time out on every case, so refuse up front.
listperf_rig=(cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/ListStressRig.swift cmux-next-ios/verify/feedperf/summarize.py)
if [[ "$mode" == listperf || "$mode" == energy ]]; then
  for f in "${listperf_rig[@]}"; do
    [[ -f "$f" ]] || { echo "cmux-next-ios-sim.sh: listperf needs $f in the head; this tree has no list frame-rate rig" >&2; exit 2; }
  done
fi
if [[ "$mode" == clips ]]; then
  [[ -f "release-notes/next/clips/$clip_id.json" ]] ||
    { echo "cmux-next-ios-sim.sh: no release-notes/next/clips/$clip_id.json at $(git rev-parse HEAD)" >&2; exit 2; }
fi
out="$root/artifacts/ios-sim"
work="$root/.build/ios-sim"
rm -rf "$out" "$work"
mkdir -p "$out/screens" "$out/bench" "$work"
summary="$out/SUMMARY.md"
note() { printf '%s\n' "$*" | tee -a "$summary"; }

# Steps run with a per-step HOME; Homebrew tools live outside it. Appended, not
# prepended: on a fleet worker the first PATH entry is the worker's rustup shim,
# which takes the shared RUSTUP_HOME's install lock for every `rustup target add`
# and cargo auto-install. Homebrew's rustup ahead of it installed the iOS std
# targets with no lock, and concurrent simulator steps left the toolchain's
# component records disagreeing (cmuxs-Mac-mini-4 and cmux14, 2026-11-19:
# "detected conflict: 'lib/rustlib/aarch64-apple-ios-sim/...'" and "the 'cargo'
# binary ... is not applicable"). It also kept Homebrew's bun ahead of the pin.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin"

# The host-side cargo builds (cmux-duress, coord-sim) run from the checkout's root
# with --manifest-path, and rustup looks for rust-toolchain.toml from the working
# directory, not the manifest's: the pin in cmux-tui/ was never read, so a worker
# with no default toolchain failed them (2026-11-24: "rustup could not
# choose a version of cargo to run"). Name the pinned channel for every cargo here.
if [[ -z "${RUSTUP_TOOLCHAIN:-}" && -f cmux-tui/rust-toolchain.toml ]]; then
  rust_pin=$(sed -n 's/^channel *= *"\(.*\)".*/\1/p' cmux-tui/rust-toolchain.toml | head -1)
  [[ -n "$rust_pin" ]] && export RUSTUP_TOOLCHAIN="$rust_pin"
fi

# Everything this step makes outside its checkout goes away when it ends: the
# pinned xcodegen's temp dir and, once made, the simulator device set.
xcodegen_dir=""
sims=""
perf_udid=""
cleanup() {
  local result=$?
  # A cancelled UI test profile: stop xctrace before its simulator goes.
  if [[ -n "${profile_waiter:-}" ]]; then kill "$profile_waiter" 2>/dev/null || true; fi
  if [[ -n "${profiler:-}" ]]; then stop_profiler "$profiler" 60; fi
  # The test iPhones in the default device set, when a step is cut short.
  local d
  for d in "${test_udid:-}" "${ui_udid:-}" "${perf_udid:-}"; do
    [[ -n "$d" ]] || continue
    xcrun simctl shutdown "$d" >/dev/null 2>&1 || true
    xcrun simctl delete "$d" >/dev/null 2>&1 || true
  done
  if [[ -n "$sims" ]]; then
    xcrun simctl --set "$sims" shutdown all >/dev/null 2>&1 || { [[ "$mode" != screen-proof ]] || result=1; }
    xcrun simctl --set "$sims" delete all >/dev/null 2>&1 || { [[ "$mode" != screen-proof ]] || result=1; }
    rm -rf "$sims" || { [[ "$mode" != screen-proof ]] || result=1; }
  fi
  # Attempted even when the simulator set's removal failed.
  if [[ -n "$xcodegen_dir" ]]; then rm -rf "$xcodegen_dir" || true; fi
  # listperf's base worktree (its build is under $work, which the next step's checkout clears).
  if [[ -n "${base_src:-}" ]]; then
    git -C "$root" worktree remove --force "$base_src" >/dev/null 2>&1 || rm -rf "$base_src" || true
    git -C "$root" worktree prune >/dev/null 2>&1 || true
  fi
  # pair-e2e's Mac app build (its DerivedData, app included), reload.sh's
  # /tmp/cmux-<tag> link to it, and the host's last-debug-log pointer as it was.
  if [[ -n "${mac_dd:-}" ]]; then
    # The tag is this run's own (its PID is in it), so its link and state are too. The rig removes
    # them in its own finally; this runs the same list (forget_tag) for a rig cut short.
    if [[ -n "${mac_tag:-}" ]]; then
      if [[ -L "/tmp/cmux-$mac_tag" ]]; then rm -f "/tmp/cmux-$mac_tag" || true; fi
      if [[ -n "${mac_app:-}" && -d "$mac_app" ]]; then
        python3 -I scripts/ci/cmux_next_pair_e2e.py --forget-tag "$mac_app" >/dev/null 2>&1 || true
      fi
    fi
    rm -rf "$work/pair-rig" || true
    if [[ -n "${mac_tag:-}" ]] && grep -qF -- "$mac_tag" /tmp/cmux-last-debug-log-path 2>/dev/null; then
      if [[ -n "${prev_last_log:-}" ]]; then printf '%s\n' "$prev_last_log" > /tmp/cmux-last-debug-log-path || true
      else rm -f /tmp/cmux-last-debug-log-path || true; fi
    fi
    rm -rf "$mac_dd" || true
  fi
  # Cloud routing payloads contain machine/team/session ids; remove this exact
  # file even when SIGTERM/INT interrupts the Python leg before its finally.
  if [[ -n "${work:-}" ]]; then rm -f "$work/cloud-routing-push.json" || true; fi
  if [[ "$mode" == release-build ]]; then
    # Keep failure evidence too, including FFI or project-generation failures.
    local log
    for log in ffi xcodegen build; do
      if [[ -f "$work/$log.log" ]]; then cp "$work/$log.log" "$out/$log.log" || result=1; fi
    done
    note "- exit status: $result" || result=1
    (cd "$out" && zip -qr evidence.zip . -x evidence.zip) || result=1
  fi
  if [[ -n "${CMUX_IOS_CLOUD_PROOF_FILE:-}" || "${CMUX_IOS_OWNER_ACCESS_PROOF:-0}" == 1 ]]; then
    python3 -I scripts/ci/cmux_next_cloud_pair_proof.py --export-out "$out" --status "$result" || result=1
  fi
  if [[ "$mode" == screen-proof ]]; then
    python3 -I scripts/ci/cmux_next_screen_sharing_proof.py --finalize-cleanup --status "$result" --sims "$sims" --out "$out" || result=1
    exit "$result"
  fi
  return "$result"
}
trap cleanup EXIT
# A cancelled step gets SIGTERM: exit, so the EXIT trap cleans up.
trap 'exit 143' TERM
trap 'exit 130' INT

# sim_create NAME DEVICE_TYPE RUNTIME [SET]: every simulator this step makes, printed as its UDID and
# shut down. On a build fleet worker that offers it, $CMUX_CI_SIM_CREATE (hq
# build-fleet/cmd/worker/sim_slim.go) makes it: slim (simslim, about a quarter of a stock
# simulator's memory) when the step declared the simulator features it needs (cmux-ci run
# --sim-features, or the controller's default for the mode) and the worker slims, checked by
# `simslim doctor --requires` before the step gets it, else stock; a slim failure is the worker's and
# gives a stock simulator, never a failed step. Without it (Blacksmith, an older worker, a local
# run) it is the stock `simctl create` it always was. Mid-step, a test that finds it needs a feature
# after all can turn it on with no reboot: "$CMUX_CI_SIMSLIM" [--set SET] enable UDID icloud,photos.
#
# A creation that fails is tried again, twice: CoreSimulator can leave a new device "allocated but
# stuck in creation state" (2026-11-16 and 17: 7 of 40 simulator steps of one lane failed so, each
# after its 3-11 min build). Before a retry, the devices of that exact name in that set are deleted:
# the step's own set, or a name with the step key in it in the default set, so never another step's.
sim_create() {
  local attempt udid
  for attempt in 1 2 3; do
    if udid="$(sim_create_once "$@")"; then
      printf '%s\n' "$udid"
      return 0
    fi
    [[ $attempt -lt 3 ]] || break
    echo "sim_create: creating $1 failed (attempt $attempt of 3); deleting what it left, then again" >&2
    sim_delete_named "$1" "${4:-}"
  done
  echo "error: sim_create: could not create $1 in 3 attempts" >&2
  return 1
}
sim_create_once() {
  local name=$1 type=$2 rt=$3 set=${4:-}
  if [[ -n "${CMUX_CI_SIM_CREATE:-}" && -x "${CMUX_CI_SIM_CREATE}" ]]; then
    "${CMUX_CI_SIM_CREATE}" "$name" "$type" "$rt" ${set:+"$set"}
  elif [[ -n "$set" ]]; then
    xcrun simctl --set "$set" create "$name" "$type" "$rt"
  else
    xcrun simctl create "$name" "$type" "$rt"
  fi
}
# sim_delete_named NAME [SET]: deletes every device named exactly NAME in SET (default set without one).
sim_delete_named() {
  local name=$1 set=${2:-} d
  local list=(xcrun simctl)
  [[ -z "$set" ]] || list+=(--set "$set")
  while read -r d; do
    [[ -n "$d" ]] || continue
    "${list[@]}" shutdown "$d" >/dev/null 2>&1 || true
    "${list[@]}" delete "$d" >/dev/null 2>&1 || true
  done < <("${list[@]}" list -j devices 2>/dev/null | python3 -I -c '
import json, sys
try:
    devices = json.load(sys.stdin).get("devices", {})
except ValueError:
    devices = {}
for runtime in devices.values():
    for d in runtime:
        if d.get("name") == sys.argv[1] and d.get("udid"):
            print(d["udid"])
' "$name" || true)
}
# sim_set_dir WORK MOUNT: the step's simulator device set. WORK/sims when WORK's volume (MOUNT) is the boot
# volume; else a fresh directory under $TMPDIR. TCC refuses CoreSimulatorService on another volume: aws-m4pro-3's
# job root is the instance store /Volumes/ephemeral0, where every `simctl --set ... create` failed EINVAL
# (2026-11-17..21; tests/test_ios_sim_set_volume.py). The EXIT trap's cleanup removes either.
sim_set_dir() {
  case "$2" in
    /|/System/Volumes/Data) mkdir -p "$1/sims" && printf '%s\n' "$1/sims" ;;
    *) local root="${CMUX_CI_SIM_SET_ROOT:-${TMPDIR:-/tmp}}"; mkdir -p "$root" && mktemp -d "${root%/}/cmux-ios-sim-sims.XXXXXX" ;;
  esac
}
# --- end sim_create

# sim_reduce_motion UDID [SET] and reduce_motion_app_verdict LOG (reducemotion=1).
# shellcheck source-path=SCRIPTDIR source=lib/ios-sim-reduce-motion.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ios-sim-reduce-motion.sh"
# sim_boot_reduce_motion UDID WHAT: boots a default-set simulator (unless booted) and turns Reduce Motion on.
sim_boot_reduce_motion() {
  local value
  xcrun simctl boot "$1" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$1" -b >/dev/null
  value="$(sim_reduce_motion "$1")" || {
    note "- reduce motion ($2 simulator): FAIL: ReduceMotionEnabled read back in the simulator: '$value'"; exit 3; }
  note "- reduce motion ($2 simulator): on, ReduceMotionEnabled read back in the simulator: $value"
}

# xcodegen: a pinned release, checksum-verified, in a temp dir of this step's
# own, never the host's (aws-m4pro-2 has none, and the fleet's AWS Macs are not
# provisioned by hand). Bump the version and the zip's sha256 together.
xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
xcodegen_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-ios-sim-xcodegen.XXXXXX")"
# The helper caches per host, authenticates when a token or gh is there, and verifies the sha256.
xcodegen="$(bash "$(dirname "${BASH_SOURCE[0]}")/fetch-xcodegen.sh" "$xcodegen_version" "$xcodegen_sha256" "$xcodegen_dir")" || exit 3
[[ -x "$xcodegen" ]] || exit 3
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -n "${CMUX_CI_XCODE_APP:-}" ]]; then
    export DEVELOPER_DIR="$CMUX_CI_XCODE_APP/Contents/Developer"
  else
    major="$(sw_vers -productVersion | cut -d. -f1)"
    pin="$(awk -v m="$major" '$1 == m { print $2 }' scripts/ci/xcode-pins.txt)"
    export DEVELOPER_DIR="/Applications/Xcode_${pin}.app/Contents/Developer"
  fi
fi
[[ -d "$DEVELOPER_DIR" ]] || { echo "error: no Xcode at $DEVELOPER_DIR" >&2; exit 3; }
# The simulator runtime and iPhone, chosen before anything is built: the runtime the fleet declares
# (CMUX_CI_IOS_SIM_RUNTIME, set by the build fleet's controller), else the newest (ios_sim_runtime.py).
# A host without the declared runtime fails here, with the runtimes it has.
if [[ "$mode" != release-build && "$mode" != try ]]; then
  phone_class=()
  if [[ "$appstore" == 1 ]]; then phone_class=(--phone-class appstore-6.9); fi
  sim_choice="$(xcrun simctl list -j runtimes devicetypes |
    python3 -I scripts/ci/ios_sim_runtime.py --with-name ${phone_class[@]+"${phone_class[@]}"} ${sim_device:+--device "$sim_device"})" || exit 3
  read -r runtime device_type device_name <<< "$sim_choice"
  echo "cmux-next-ios-sim.sh: simulator device type: $device_name ($device_type)${sim_device:+, from device=$sim_device}"
  # The step's iPhone is made before anything is built (booted after the build), so a creation that
  # cannot succeed fails the step in seconds, not after the build.
  sims="$(sim_set_dir "$work" "$(df -P "$work" | awk 'NR==2 {print $6}')")"
  sim_name=cmux-next-ios-sim
  if [[ "$mode" == screen-proof ]]; then
    sim_name="screen-proof-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
  fi
  udid="$(sim_create "$sim_name" "$device_type" "$runtime" "$sims")"
fi
simctl() { xcrun simctl --set "$sims" "$@"; }

note "# cmux-next-ios simulator step ($mode)"
note ""
note "- commit: $(git rev-parse HEAD)"
note "- host: $(hostname -s), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)"
note "- Xcode: $(xcodebuild -version | tr '\n' ' ')"
note "- xcodegen: $xcodegen_version (pinned, sha256 verified)"

# --- Build ------------------------------------------------------------------
t0=$SECONDS
# The FFI comes from the worker's source-keyed cache when an earlier step built the same
# inputs with the same toolchain (scripts/ci/ios_ffi_cache.py: key, verified restore). A
# miss builds it and publishes it under its own key for the next step with the same inputs,
# a branch's build as well as a landed one (the probe beside the build only records which). The cache never fails the
# step: a miss or no key builds. Everything else (a key command that failed, a failed probe or
# store, a helper error) is a warning in the log and SUMMARY.md, then the step builds.
ffi_cache=(python3 -I scripts/ci/ios_ffi_cache.py)
ffi_log="$work/ffi-cache.log"
: >"$ffi_log"
ffi_warn() {
  echo "warning: ios-ffi cache: $1 (exit $2); building the FFI" >&2
  tail -20 "$ffi_log" >&2 || true
  note "- FFI cache warning: $1 (exit $2)"
}
ffi_key="" ffi_rc=0
ffi_key="$("${ffi_cache[@]}" key "$root" "$work/ffi-inputs.json" 2>>"$ffi_log")" || ffi_rc=$?
if [[ $ffi_rc -ne 0 ]]; then
  [[ $ffi_rc -eq 3 ]] || ffi_warn "key failed" "$ffi_rc"
  ffi_key=""
elif ! [[ "$ffi_key" =~ ^[0-9a-f]{64}$ ]]; then
  ffi_warn "key printed '${ffi_key:0:80}', not a sha256" 0
  ffi_key=""
fi
ffi_xcf=cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework
ffi_swift=cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift
ffi_how=""
if [[ -n "$ffi_key" ]]; then
  ffi_rc=0
  "${ffi_cache[@]}" restore "$root" "$ffi_key" >>"$ffi_log" 2>&1 || ffi_rc=$?
  if [[ $ffi_rc -eq 0 && -f "$ffi_xcf/Info.plist" && -s "$ffi_swift" ]]; then
    ffi_how="cache hit ${ffi_key:0:12}"
  elif [[ $ffi_rc -eq 0 ]]; then
    ffi_warn "restore reported a hit but left no $ffi_xcf/Info.plist" 0
  elif [[ $ffi_rc -ne 1 ]]; then
    ffi_warn "restore failed" "$ffi_rc"
  fi
fi
if [[ -z "$ffi_how" ]]; then
  ffi_probe=""
  if [[ -n "$ffi_key" ]]; then
    "${ffi_cache[@]}" probe "$work/ffi-inputs.json" "$work/ffi-tip.json" >>"$ffi_log" 2>&1 &
    ffi_probe=$!
  fi
  JOBS="${JOBS:-8}" bash cmux-next-ios/rust/scripts/build-xcframework.sh >"$work/ffi.log" 2>&1 || {
    tail -60 "$work/ffi.log"; echo "error: CmuxMobileLinkFFI.xcframework build failed" >&2; exit 1; }
  ffi_how="built"
  if [[ -n "$ffi_probe" ]]; then
    ffi_how="built, cache miss ${ffi_key:0:12}"
    ffi_rc=0
    wait "$ffi_probe" || ffi_rc=$?
    if [[ $ffi_rc -ne 0 ]]; then
      ffi_warn "probe of the feat-cmux-next tip failed, stored as a branch build" "$ffi_rc"
      rm -f "$work/ffi-tip.json"
    fi
    "${ffi_cache[@]}" store "$root" "$work/ffi-inputs.json" "$work/ffi-tip.json" >>"$ffi_log" 2>&1 || {
      ffi_rc=$?; ffi_warn "store failed" "$ffi_rc"; }
  fi
fi
grep -h '^ios-ffi cache:' "$ffi_log" || true
note "- FFI: $((SECONDS - t0)) s ($ffi_how)"
(cd cmux-next-ios && "$xcodegen" generate -q) >"$work/xcodegen.log" 2>&1 || {
  cat "$work/xcodegen.log"; echo "error: xcodegen failed" >&2; exit 1; }
# A runner with the glaeda disk registry exports CMUX_DERIVED_DATA_SLOT: its per-stream DerivedData root.
dd_root="${CMUX_DERIVED_DATA_SLOT:-$work}"
dd="$dd_root/dd"
# Demo builds the Swift packages as Release (no DEBUG), so the flood benchmark
# and terminal demo would be missing; the command-line conditions reach the
# packages too (verify/terminal-flood.md, Reproducing).
configuration=Demo
build_settings=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO')
if [[ "$mode" == release-build ]]; then
  configuration=Release
  build_settings=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi
if [[ "$mode" == handoff ]]; then
  # The task's own install beside every other build: its bundle id, home-screen name and commit, and
  # its tag's cloud data space (Info.plist CmuxMobileDevTag, `X-Cmux-Build-Space: dev:<tag>`), the space
  # its same-tag Mac app's hostd registers in. project.yml sets CMUX_MOBILE_DEV_TAG only for Debug: a
  # shared Demo build (demo-build.sh) stays in the default space, and only the hand-off's Demo build gets
  # one. The tag is already a slug (checked above), so the space is `dev:<tag>` as the Mac's is.
  build_settings+=("CMUX_MOBILE_TAG=.$handoff_tag" "CMUX_MOBILE_DEV_TAG=.$handoff_tag" "CMUX_MOBILE_DISPLAY_NAME=cmux $handoff_tag"
    "CMUX_MOBILE_SOURCE_COMMIT=$(git rev-parse HEAD)")
fi
if [[ "$mode" == pair-e2e ]]; then
  # A tag of this run only for the Mac app built below: its own bundle id, socket, settings and state.
  # A tagged dev Mac's hostd registers in the build space dev:<tag> (CMUX_BUILD_SPACE, #43648), and a
  # phone lists only the Macs of its own space: the plain Demo build (no CMUX_MOBILE_DEV_TAG) is in the
  # default space, lists 0 Macs, refuses the Mac's code ("pairing code for a space this account is not
  # in") and never asks to pair. So the phone gets the Mac's tag as its dev tag: both are in dev:<tag>, as a
  # hand-off's same-tag Mac and iPhone are. It is that tag's app too (`dev.cmux.mobile.<tag>`, as a
  # hand-off's): the tagged Mac's dev auto-approve pairs only its own tag's phone (IPhoneDevAutoApprove),
  # the one way a phone pairs with no person since the QR code went (#48532). The rig installs by the
  # bundle id the build reports (CFBundleIdentifier, below).
  mac_tag="iospair-$(git rev-parse --short=8 HEAD)-$$"
  build_settings+=("CMUX_MOBILE_DEV_TAG=.$mac_tag")
  build_settings+=("CMUX_MOBILE_TAG=.$mac_tag")
fi
if [[ "$mode" == try ]]; then
  # The cmux Dev app: device only. No CMUX_MOBILE_DEV_TAG (Demo's is empty), so no build space: the
  # person's real data, paired with their NIGHTLY Mac. Unsigned; try.sh signs it on the Mac with the phone.
  build_settings+=("CMUX_MOBILE_TAG=.dev" "CMUX_MOBILE_DISPLAY_NAME=cmux Dev" "CMUX_MOBILE_SOURCE_COMMIT=$(git rev-parse HEAD)")
  set +e
  xcodebuild -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo \
    -destination 'generic/platform=iOS' -derivedDataPath "$dd_root/dd-device" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=7WLXT3NR37 \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "${build_settings[@]}" build >"$work/build-device.log" 2>&1
  status=$?
  set -e
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$work/build-device.log" | sort -u | head -40 || true
  cp "$work/build-device.log" "$out/build-device.log" 2>/dev/null || true
  [[ $status -eq 0 ]] || { tail -40 "$work/build-device.log"; exit 1; }
  device_app="$dd_root/dd-device/Build/Products/Demo-iphoneos/CmuxMobileApp.app"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$device_app/Info.plist")"
  [[ "$bundle_id" == dev.cmux.mobile.dev ]] || { echo "error: the cmux Dev app is $bundle_id, not dev.cmux.mobile.dev" >&2; exit 1; }
  build_s=$((SECONDS - t0))
  note "- try build: $build_s s (FFI + xcodegen + Demo device app, unsigned), bundle $bundle_id"
  ditto -c -k --keepParent "$device_app" "$out/CmuxMobileApp-Dev-device-unsigned.app.zip"
  printf '{"schema": "cmux.ios-try.v1", "sha": "%s", "bundle_id": "%s", "build_seconds": %s, "host": "%s"}\n' \
    "$(git rev-parse HEAD)" "$bundle_id" "$build_s" "$(hostname -s)" >"$out/try.json"
  (cd "$out" && rm -f evidence.zip && zip -qr evidence.zip . -x evidence.zip)
  cat "$summary"
  exit 0
fi
build_command=(xcodebuild -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration "$configuration"
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd"
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  "${build_settings[@]}" build)
if [[ "$mode" == release-build ]]; then
  printf '%q ' "${build_command[@]}" >"$out/build-command.txt"
  printf '\n' >>"$out/build-command.txt"
  note "- configuration: Release; destination: generic/platform=iOS Simulator; signing: disabled"
  note "- compilation conditions: Release defaults; no injected DEBUG or CMUX_MOBILE_DEMO"
fi
# The UI tests' own build (test ui=SUITE, $ui_config in dd-ui), started beside the Demo build: the two
# share no DerivedData, so the step no longer waits for one compile and then the other. Only for plain
# UI suites (no cold suites, duress, net or profile, which build on their own below). The UI section
# waits for it and runs test-without-building; a failed prebuild leaves that section's `test` (it
# builds and reports the error as before). Every app still comes from the same sources and settings.
ui_prebuild_pid="" ui_prebuild_t0=0
ui_prebuild_args=()
if [[ "$mode" == test && ${#ui_suites[@]} -gt 0 && ${#ui_cold[@]} -eq 0 && ${#duress_specs[@]} -eq 0 &&
  ${#net_profiles[@]} -eq 0 && $ui_profile -eq 0 ]]; then
  ui_prebuild_args=(-project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration "$ui_config"
    -destination 'generic/platform=iOS Simulator' -enableCodeCoverage NO -derivedDataPath "$dd_root/dd-ui"
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CMUX_MOBILE_APPLE_SIGN_IN=YES
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -quiet)
  [[ "$ui_config" != Demo ]] || ui_prebuild_args+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO')
  ui_prebuild_t0=$SECONDS
  xcodebuild build-for-testing "${ui_prebuild_args[@]}" >"$work/ui-build.log" 2>&1 &
  ui_prebuild_pid=$!
fi
set +e
"${build_command[@]}" >"$work/build.log" 2>&1
status=$?
set -e
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$work/build.log" | sort -u | head -40 || true
[[ $status -eq 0 ]] || {
  [[ -z "$ui_prebuild_pid" ]] || kill "$ui_prebuild_pid" 2>/dev/null || true
  tail -40 "$work/build.log"; exit 1; }
app="$dd/Build/Products/$configuration-iphonesimulator/CmuxMobileApp.app"
if [[ "$mode" == release-build ]]; then
  [[ -d "$app" ]] || { echo "error: Release app missing at $app" >&2; exit 1; }
  note "- build: $((SECONDS - t0)) s (FFI + xcodegen + Release simulator app)"
  ditto -c -k --keepParent "$app" "$out/CmuxMobileApp-Release-simulator.app.zip"
  note "- compile only: no simulator install or launch, TestFlight upload or publication"
  exit 0
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
note "- build: $((SECONDS - t0)) s (FFI + xcodegen + Demo simulator app), bundle $bundle_id"

# --- handoff: the device app ------------------------------------------------
device_app=""
if [[ "$mode" == handoff ]]; then
  [[ "$bundle_id" == "dev.cmux.mobile.$handoff_tag" ]] ||
    { echo "error: the simulator app is $bundle_id, not dev.cmux.mobile.$handoff_tag" >&2; exit 1; }
  t0=$SECONDS
  # Unsigned: the person's Mac signs it for its phones. DEVELOPMENT_TEAM still names the team, so
  # Info.plist's CmuxMobileKeychainGroup is the group the local signature grants.
  set +e
  xcodebuild -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo \
    -destination 'generic/platform=iOS' -derivedDataPath "$dd_root/dd-device" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=7WLXT3NR37 \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "${build_settings[@]}" build >"$work/build-device.log" 2>&1
  status=$?
  set -e
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$work/build-device.log" | sort -u | head -40 || true
  [[ $status -eq 0 ]] || { tail -40 "$work/build-device.log"; exit 1; }
  device_app="$dd_root/dd-device/Build/Products/Demo-iphoneos/CmuxMobileApp.app"
  device_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$device_app/Info.plist")"
  [[ "$device_bundle" == "$bundle_id" ]] || { echo "error: the device app is $device_bundle, not $bundle_id" >&2; exit 1; }
  note "- device build: $((SECONDS - t0)) s (Demo, unsigned), bundle $device_bundle"
fi

# --- listperf: the base app -------------------------------------------------
base_app=""
# build_base_app: the app at $listperf_base in $base_src, as base_app; exits on a failure.
build_base_app() {
  t0=$SECONDS
  # A fleet step's checkout has no origin: the base comes the way the step's own commit
  # does (glaeda's mirror, the host reference, else GitHub by URL; cmux#31442).
  bash scripts/ci/ios-sim-fetch-commit.sh "$listperf_base" ||
    { echo "error: could not fetch base $listperf_base" >&2; exit 1; }
  base_src="$work/base-src"
  for f in "${listperf_rig[@]:0:1}"; do
    [[ "$mode" != clips ]] || break  # a clip's before needs no rig
    git cat-file -e "$listperf_base:$f" 2>/dev/null ||
      { echo "error: base $listperf_base has no $f (graft the rig onto the base first)" >&2; exit 2; }
  done
  git worktree add --quiet --detach "$base_src" "$listperf_base" || exit 1
  base_ffi="$("${ffi_cache[@]}" key "$base_src" "$work/ffi-inputs-base.json" 2>>"$ffi_log")" || base_ffi=""
  if [[ -n "$ffi_key" && "$base_ffi" == "$ffi_key" ]]; then
    # The same FFI inputs as the head: its build.
    { mkdir -p "$base_src/$(dirname "$ffi_xcf")" "$base_src/$(dirname "$ffi_swift")" &&
      rm -rf "${base_src:?}/$ffi_xcf" &&
      cp -R "$ffi_xcf" "$base_src/$ffi_xcf" &&
      cp "$ffi_swift" "$base_src/$ffi_swift"; } || exit 1
    base_ffi_how="the head's (same inputs)"
  else
    (cd "$base_src" && JOBS="${JOBS:-8}" bash cmux-next-ios/rust/scripts/build-xcframework.sh) >"$work/ffi-base.log" 2>&1 || {
      tail -60 "$work/ffi-base.log"; echo "error: base CmuxMobileLinkFFI.xcframework build failed" >&2; exit 1; }
    base_ffi_how="built"
  fi
  (cd "$base_src/cmux-next-ios" && "$xcodegen" generate -q) >"$work/xcodegen-base.log" 2>&1 || {
    cat "$work/xcodegen-base.log"; echo "error: base xcodegen failed" >&2; exit 1; }
  set +e
  xcodebuild -project "$base_src/cmux-next-ios/CmuxMobileApp.xcodeproj" -scheme CmuxMobileApp -configuration Demo \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd_root/dd-base" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    "${build_settings[@]}" build >"$work/build-base.log" 2>&1
  status=$?
  set -e
  cp "$work/build-base.log" "$out/build-base.log" 2>/dev/null || true
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$work/build-base.log" | sort -u | head -40 || true
  [[ $status -eq 0 ]] || { tail -40 "$work/build-base.log"; exit 1; }
  base_app="$dd_root/dd-base/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app"
  base_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$base_app/Info.plist")" || exit 1
  [[ "$base_bundle" == "$bundle_id" ]] || { echo "error: base bundle $base_bundle is not the head's $bundle_id" >&2; exit 1; }
  note "- base build: $((SECONDS - t0)) s at $listperf_base (FFI: $base_ffi_how)"
}
base_src=""
if [[ ( "$mode" == listperf || "$mode" == energy ) && -n "$listperf_base" ]]; then
  build_base_app
elif [[ "$mode" == clips && -n "$listperf_base" ]]; then
  # A clip's before is its own: a base that does not fetch or build leaves the after to record.
  base_src="$work/base-src"  # set here, so the EXIT trap removes a worktree the subshell made
  if ( build_base_app ) >"$work/base-app.log" 2>&1; then
    base_app="$dd_root/dd-base/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app"
  else
    tail -40 "$work/base-app.log" || true
    note "- before: no app at $listperf_base: $(tail -n 1 "$work/base-app.log")"
  fi
fi

# --- Simulator --------------------------------------------------------------
# The UI tests' build (started beside the Demo build above) ends before anything is timed on a simulator.
ui_prebuild_status=""
if [[ -n "$ui_prebuild_pid" ]]; then
  ui_prebuild_status=0
  wait "$ui_prebuild_pid" || ui_prebuild_status=$?
  note "- UI test build (build-for-testing, beside the Demo build): exit $ui_prebuild_status, $((SECONDS - ui_prebuild_t0)) s from its start"
  if [[ $ui_prebuild_status -ne 0 ]]; then
    tail -40 "$work/ui-build.log"
    cp "$work/ui-build.log" "$out/ui-build.log" 2>/dev/null || true
  fi
fi
simctl boot "$udid"
simctl bootstatus "$udid" -b >/dev/null
if [[ "${CMUX_CI_SIM_SLIM:-0}" == 1 && -f "${CMUX_CI_SIM_STATE:-/nonexistent}/fallback" ]]; then
  note "- simulators: stock (slimming fell back: $(head -c 300 "$CMUX_CI_SIM_STATE/fallback"))"
elif [[ "${CMUX_CI_SIM_SLIM:-0}" == 1 ]]; then
  note "- simulators: slim (features: ${CMUX_CI_SIM_FEATURES:-none})"
else
  note "- simulators: stock"
fi
simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
note "- simulator: ${device_type##*.} on ${runtime##*.}"
if [[ -n "$sim_device" ]]; then
  note "- device: $device_name ($device_type), from device=$sim_device"
else
  note "- device: $device_name ($device_type), the default"
fi
if [[ $reduce_motion -eq 1 ]]; then
  rm_value="$(sim_reduce_motion "$udid" "$sims")" || {
    note "- reduce motion: FAIL: com.apple.Accessibility ReduceMotionEnabled read back in the simulator: '$rm_value'"; exit 3; }
  note "- reduce motion: on, com.apple.Accessibility ReduceMotionEnabled read back in the simulator: $rm_value"
fi
simctl install "$udid" "$app"
simctl launch "$udid" "$bundle_id" >/dev/null
# Until the first screen has drawn and holds still: three screenshots in a row the same, 0.5 s apart, at most 30 s.
# Best effort: past it, the capture below shows whatever is on screen.
settle_png="$out/screens/.launch-settle.png" settle_last="" settle_same=0
for _ in $(seq 60); do
  settle_hash="$(simctl io "$udid" screenshot "$settle_png" >/dev/null 2>&1 && shasum -a 256 "$settle_png" | awk '{ print $1 }')" || settle_hash=""
  if [ -n "$settle_hash" ] && [ "$settle_hash" = "$settle_last" ]; then settle_same=$((settle_same + 1)); else settle_same=0; fi
  [ "$settle_same" -ge 2 ] && break
  settle_last="$settle_hash"
  sleep 0.5
done
rm -f "$settle_png"
[ "$settle_same" -ge 2 ] || note "- launch: the screen never held still in 30 s; captured as it is"
simctl io "$udid" screenshot "$out/screens/launch.png" >/dev/null
simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
note "- launch: ok, screens/launch.png"
# What the app itself read: its DEBUG launch line (CmuxMobileApp.init), from the simulator's log.
# With reducemotion=1 the app must have seen it: false or no line fails the step (exit 3).
a11y_log="$(simctl spawn "$udid" log show --last 5m --style compact \
  --predicate 'subsystem == "dev.cmux.mobile" AND category == "accessibility"' 2>/dev/null || true)"
a11y_ok=1
a11y_seen="$(reduce_motion_app_verdict "$a11y_log")" || a11y_ok=0
note "- app at launch: UIAccessibility.isReduceMotionEnabled: $a11y_seen"
if [[ $reduce_motion -eq 1 && $a11y_ok -eq 0 ]]; then
  note "- reduce motion: FAIL: the app did not see Reduce Motion at launch (isReduceMotionEnabled: $a11y_seen)"
  exit 3
fi
[[ $reduce_motion -eq 0 ]] || note "- reduce motion: PASS: the app saw isReduceMotionEnabled=true at launch"
# The simulator's memory at launch (simslim measure: phys_footprint of its processes, slim or stock),
# for the fleet's stock-versus-slim comparison. Read-only; never fails the step.
if [[ -n "${CMUX_CI_SIMSLIM:-}" && -x "${CMUX_CI_SIMSLIM}" ]] &&
  "${CMUX_CI_SIMSLIM}" --set "$sims" measure "$udid" --json >"$out/simulator-memory.json" 2>/dev/null; then
  note "- simulator memory at launch: $(tr -d '\n' <"$out/simulator-memory.json" | head -c 300)"
else
  rm -f "$out/simulator-memory.json"
fi

# --- handoff: the simulator check, signed in ---------------------------------
# The agent account the worker keeps for simulator sign-in (hq build-fleet README, "Sign-in"):
# KEY=VALUE lines, read here without sourcing the file and never printed. The app proves each
# launch with its DEBUG readiness receipt (cmux-next-ios/scripts/handoff_receipt.py checks it):
# first signed in from the injected account (auto_login), then relaunched with no credentials
# and signed in from its own Keychain (restored). A check that fails is recorded, not fatal.
handoff_sim_status="" handoff_sim_reason=""
if [[ "$mode" == handoff ]]; then
  t0=$SECONDS
  handoff_check() {
    # The step's own sign-in session, sealed from the submitter's Mac (cmux-ci run --sign-in agent,
    # hq build-fleet `sign_in`): no worker account file, no password. Only the auto_login launch
    # gets its refresh token, and it is dropped from this shell after the legs.
    local receipt client nonce data rec_pid=""
    # shellcheck source=scripts/lib/fleet-signin-session.sh
    source scripts/lib/fleet-signin-session.sh
    cmux_fleet_signin_load || { handoff_sim_reason="$CMUX_FLEET_SIGNIN_ERROR"; return 1; }
    local account
    account="$CMUX_FLEET_SIGNIN_EMAIL"
    client="$(python3 -I -c 'import uuid,sys; print(uuid.uuid5(uuid.NAMESPACE_URL, "cmux-ios-dogfood-client:%s:%s" % (sys.argv[1], sys.argv[2])))' "$bundle_id" "$udid")"
    receipt="$work/readiness.json"
    # xcrun itself in the background, never the simctl() wrapper: `wrapper &` is a subshell, which
    # ignores SIGINT (an async command in a non-interactive shell) and waits on its xcrun, so the
    # SIGINT below never reached the recorder and the step hung until its 6 h timeout (2026-11-18).
    xcrun simctl --set "$sims" io "$udid" recordVideo --codec h264 --force "$out/recording.mp4" >"$work/recording.log" 2>&1 &
    rec_pid=$!
    # Until the recorder says "Recording started" (simctl prints it once its first frame is in), at most 10 s.
    for _ in $(seq 100); do
      grep -q "Recording started" "$work/recording.log" 2>/dev/null && break
      kill -0 "$rec_pid" 2>/dev/null || break
      sleep 0.1
    done
    grep -q "Recording started" "$work/recording.log" 2>/dev/null ||
      note "- recording: the recorder never said it started in 10 s ($(tail -n 1 "$work/recording.log" 2>/dev/null))"
    for leg in auto_login restored; do
      nonce="$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')"
      simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
      if [[ "$leg" == auto_login ]]; then
        SIMCTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE="$nonce" SIMCTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$client" \
          cmux_fleet_signin_simctl --set "$sims" launch "$udid" "$bundle_id" >/dev/null ||
          { handoff_sim_reason="simctl launch failed ($leg)"; break; }
      else
        SIMCTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE="$nonce" SIMCTL_CHILD_CMUX_DOGFOOD_CLIENT_ID="$client" \
          xcrun simctl --set "$sims" launch "$udid" "$bundle_id" >/dev/null ||
          { handoff_sim_reason="simctl launch failed ($leg)"; break; }
      fi
      data="$(simctl get_app_container "$udid" "$bundle_id" data)"
      local deadline=$((SECONDS + 120)) verdict="" rc=1
      while (( SECONDS < deadline )); do
        rm -f "$receipt"
        cp "$data/Library/Application Support/cmux-dogfood/readiness.json" "$receipt" 2>/dev/null || { sleep 2; continue; }
        rc=0
        verdict="$(python3 -I cmux-next-ios/scripts/handoff_receipt.py check "$receipt" --nonce "$nonce" \
          --client-id "$client" --bundle-id "$bundle_id" --account "$account" --session "$leg" \
          --git-sha "$(git rev-parse HEAD)" --dev-tag "$handoff_tag" 2>&1)" || rc=$?
        [[ $rc -eq 1 ]] || break
        sleep 2
      done
      sleep 3  # the signed-in screen settles after the receipt (bounded; for the screenshot only)
      simctl io "$udid" screenshot "$out/screens/signed-in-$leg.png" >/dev/null 2>&1 || true
      cp "$receipt" "$out/readiness-$leg.json" 2>/dev/null || true
      if [[ $rc -ne 0 ]]; then
        handoff_sim_reason="$leg: ${verdict:-no readiness receipt in 120 s}"
        break
      fi
      note "- simulator $leg: $verdict (screens/signed-in-$leg.png)"
    done
    cmux_fleet_signin_forget
    # recordVideo finishes the file on SIGINT; one that has not stopped in 30 s is ended (bounded).
    if [[ -n "$rec_pid" ]]; then kill -INT "$rec_pid" 2>/dev/null || true; for _ in $(seq 1 30); do kill -0 "$rec_pid" 2>/dev/null || break; sleep 1; done; ! kill -0 "$rec_pid" 2>/dev/null || kill -TERM "$rec_pid" 2>/dev/null || true; wait "$rec_pid" 2>/dev/null || true; fi
    simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    [[ -z "$handoff_sim_reason" ]]
  }
  if handoff_check; then
    handoff_sim_status=pass
  else
    handoff_sim_status=fail
    note "- simulator check: FAIL: $handoff_sim_reason"
  fi
  note "- simulator check: $((SECONDS - t0)) s, $handoff_sim_status"
fi

# keep_test_logs LOG XCRESULT NAME: the run's log, console output (print
# lines), per-test results, counts and failures into the artifact as NAME-*.
keep_test_logs() {
  local log=$1 bundle=$2 name=$3
  cp "$log" "$out/$name-test.log" 2>/dev/null || true
  xcrun xcresulttool get log --type console --path "$bundle" > "$out/$name-console.txt" 2> "$out/$name-console-error.txt" || true
  xcrun xcresulttool get test-results tests --path "$bundle" --compact > "$out/$name-tests.json" 2>/dev/null || true
  # XCTAttachments (UI tests' keepAlways screenshots) as files, with the
  # manifest.json that maps each one to its test.
  mkdir -p "$out/$name-attachments"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$out/$name-attachments" > "$out/$name-attachments-export.log" 2>&1 || true
  xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("passed %s, failed %s, skipped %s" % (d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))
' > "$out/$name-tests-counts.txt" 2>/dev/null || rm -f "$out/$name-tests-counts.txt"
  python3 -c '
import json, sys
def walk(node, path):
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
        print("FAILED:", " / ".join(path))
        for child in node.get("children", []):
            if child.get("nodeType") == "Failure Message":
                print("   ", child.get("name"))
    for child in node.get("children", []):
        walk(child, path + [child.get("name", "")])
for root in json.load(open(sys.argv[1])).get("testNodes", []):
    walk(root, [root.get("name", "")])
' "$out/$name-tests.json" > "$out/$name-tests-failures.txt" 2>/dev/null || true
}

# --- Tests ------------------------------------------------------------------
if [[ ( "$mode" == test || "$mode" == all ) && $run_kit -eq 1 ]]; then
  t0=$SECONDS
  # xcodebuild sees only the default device set: the tests get their own new
  # iPhone there, deleted by its UDID afterwards (never another step's device).
  test_udid="$(sim_create "cmux-next-ios-sim-test-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  [[ $reduce_motion -eq 0 ]] || sim_boot_reduce_motion "$test_udid" "kit test"
  set +e
  (cd cmux-next-ios/CmuxMobileKit && env ${kit_env[@]+"${kit_env[@]}"} xcodebuild test -scheme CmuxMobileKit-Package \
    -destination "id=$test_udid,arch=arm64" -enableCodeCoverage NO -derivedDataPath "$dd_root/dd-test" \
    -resultBundlePath "$work/kit.xcresult" CODE_SIGNING_ALLOWED=NO -quiet ${kit_only[@]+"${kit_only[@]}"}) >"$work/test.log" 2>&1
  test_status=$?
  set -e
  xcrun simctl shutdown "$test_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$test_udid" >/dev/null 2>&1 || true
  test_udid=""
  counts="$(xcrun xcresulttool get test-results summary --path "$work/kit.xcresult" --compact 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("passed %s, failed %s, skipped %s" % (d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))
' || echo "no result bundle")"
  # The failed test cases and their messages, from the result bundle.
  xcrun xcresulttool get test-results tests --path "$work/kit.xcresult" --compact 2>/dev/null | python3 -c '
import json, sys
def walk(node, path):
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
        print("FAILED:", " / ".join(path))
        for child in node.get("children", []):
            if child.get("nodeType") == "Failure Message":
                print("   ", child.get("name"))
    for child in node.get("children", []):
        walk(child, path + [child.get("name", "")])
for root in json.load(sys.stdin).get("testNodes", []):
    walk(root, [root.get("name", "")])
' > "$out/test-failures.txt" 2>/dev/null || true
  cat "$out/test-failures.txt"
  keep_test_logs "$work/test.log" "$work/kit.xcresult" kit
  # -only-testing that names no test (a suite in another target, a typo) runs nothing and exits 0:
  # a filtered run that selected no test fails, naming the filter (ios_sim_test_filter.py).
  if [[ ${#kit_only[@]} -gt 0 ]] && ! python3 -I scripts/ci/ios_sim_test_filter.py "$out/kit-tests.json" "${kit_only[@]}" | tee "$out/kit-filter.txt"; then
    note "- kit filter selected no test: $(tr '\n' ' ' < "$out/kit-filter.txt")"
    [[ $test_status -ne 0 ]] || test_status=1
  fi
  [[ ${#kit_only[@]} -eq 0 ]] || note "- kit filter: ${kit_only[*]}"
  note "- CmuxMobileKit tests (iOS simulator): exit $test_status, $counts, $((SECONDS - t0)) s"
fi

# --- UI test profile (test ui=... profile) ----------------------------------
# Time Profiler on the host, every process, for the UI test run. The
# recording counts as started when xctrace says so (its started notice, or the
# "Ctrl-C to stop the recording" line it prints at the same moment), within
# 120 s; otherwise it is stopped and the profile fails.
profiler="" profile_waiter="" profile_trace="" profile_status=0 profile_t0=0

# stop_profiler PID SECONDS: SIGINT makes xctrace save the trace (it
# symbolicates; a 10 s recording of every process took 45 s to save on a busy
# aws-m4pro-6); after SECONDS, TERM, then KILL. A step is never held by a stuck
# xctrace, also not in cleanup.
stop_profiler() {
  local pid=$1 limit=${2:-900} i
  kill -INT "$pid" 2>/dev/null || return 0
  for ((i = 0; i < limit; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "cmux-next-ios-sim.sh: xctrace did not save within $limit s of SIGINT; stopping it" >&2
    kill -TERM "$pid" 2>/dev/null || true
    for ((i = 0; i < 30; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

# profile_fail MESSAGE: one loud line in SUMMARY.md, and the step fails.
profile_fail() {
  note "- UI test profile: FAILED, $1"
  profile_status=1
}

ui_profile_start() {
  profile_trace="$work/ui-profile.trace"
  rm -rf "$profile_trace"
  local notice="dev.cmux.ci.ios-sim.profile.$$" log="$work/ui-profile.log" i started=0 why t0=$SECONDS
  notifyutil -1 "$notice" >/dev/null 2>&1 &
  profile_waiter=$!
  xcrun xctrace record --instrument 'Time Profiler' --all-processes --no-prompt \
    --notify-tracing-started "$notice" --output "$profile_trace" >"$log" 2>&1 &
  profiler=$!
  # A bounded wait on xctrace's own started signal (notifyutil exits 0 on the
  # notice; any other exit is no notice), its started line, or its exit.
  why="did not start recording within 120 s"
  for ((i = 0; i < 120; i++)); do
    if grep -q 'Ctrl-C to stop the recording' "$log" 2>/dev/null; then
      started=1
      break
    fi
    if [[ -n "$profile_waiter" ]] && ! kill -0 "$profile_waiter" 2>/dev/null; then
      if wait "$profile_waiter" 2>/dev/null; then started=1; profile_waiter=""; break; fi
      profile_waiter=""
    fi
    if ! kill -0 "$profiler" 2>/dev/null; then
      why="exited before it started recording"
      break
    fi
    sleep 1
  done
  if [[ -n "$profile_waiter" ]]; then
    kill "$profile_waiter" 2>/dev/null || true
    wait "$profile_waiter" 2>/dev/null || true
    profile_waiter=""
  fi
  if [[ $started -eq 1 ]] && kill -0 "$profiler" 2>/dev/null; then
    profile_t0=$SECONDS
    note "- UI test profile: recording (Time Profiler, all host processes), started in $((SECONDS - t0)) s"
    return 0
  fi
  if kill -0 "$profiler" 2>/dev/null; then
    stop_profiler "$profiler" 30
  else
    wait "$profiler" 2>/dev/null || true
  fi
  profiler=""
  cp "$log" "$out/ui-profile.log" 2>/dev/null || true
  profile_fail "xctrace $why (ui-profile.log)"
}

# ui_profile_finish: stop the recording (SIGINT saves the trace), check it has
# time-profile samples, summarize them into the artifact and keep the trace.
ui_profile_finish() {
  [[ -n "$profiler" ]] || return 0
  local t0=$SECONDS table="$work/ui-time-profile.xml" bytes=0 rows limit
  # Saving scales with what was recorded: 8 s per recorded second, 5 to 60 minutes.
  limit=$(( (SECONDS - profile_t0) * 8 ))
  (( limit >= 300 )) || limit=300
  (( limit <= 3600 )) || limit=3600
  stop_profiler "$profiler" "$limit"
  profiler=""
  # Without the dylib-overlap warnings xctrace prints for every simulator runtime library.
  grep -v -e 'dylibs overlap' -e '^ *0x[0-9a-f]*-0x' "$work/ui-profile.log" > "$out/ui-profile.log" 2>/dev/null || true
  note "- UI test profile: saved in $((SECONDS - t0)) s"
  if [[ ! -d "$profile_trace" ]]; then
    profile_fail "xctrace saved no trace (ui-profile.log)"
    return 0
  fi
  xcrun xctrace export --input "$profile_trace" --toc --output "$out/ui-profile-toc.xml" >"$work/ui-profile-export.log" 2>&1 ||
    echo "toc export exit $?" >>"$work/ui-profile-export.log"
  if ! grep -q 'schema="time-profile"' "$out/ui-profile-toc.xml" 2>/dev/null; then
    cat "$work/ui-profile-export.log" >>"$out/ui-profile.log" 2>/dev/null || true
    profile_fail "the trace has no time-profile table (ui-profile-toc.xml, ui-profile.log)"
  elif ! xcrun xctrace export --input "$profile_trace" \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output "$table" >>"$work/ui-profile-export.log" 2>&1; then
    cat "$work/ui-profile-export.log" >>"$out/ui-profile.log" 2>/dev/null || true
    profile_fail "exporting the time-profile table failed (ui-profile.log)"
  elif ! python3 -I scripts/ci/ios_sim_time_profile.py "$table" \
      --markdown "$out/ui-profile-summary.md" --json "$out/ui-profile-summary.json" > "$work/ui-profile-brief.txt"; then
    profile_fail "the time-profile table has no samples (ui-profile-summary.json)"
  else
    rows=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["rows"])' "$out/ui-profile-summary.json" 2>/dev/null || echo "?")
    note "- UI test profile: $rows samples, ui-profile-summary.md"
    # The processes with the most main-thread time, one line each.
    while IFS= read -r line; do note "  - $line"; done < "$work/ui-profile-brief.txt"
  fi
  rm -f "$table"
  ditto -c -k --keepParent "$profile_trace" "$out/ui-profile.trace.zip" || true
  if [[ -f "$out/ui-profile.trace.zip" ]]; then bytes=$(wc -c < "$out/ui-profile.trace.zip"); fi
  if (( bytes > 2147483648 )); then
    rm -f "$out/ui-profile.trace.zip"
    note "- UI test profile: the zipped trace was $((bytes >> 20)) MiB, over 2 GiB; dropped (the summary stays)"
  elif (( bytes > 0 )); then
    note "- UI test profile trace: ui-profile.trace.zip ($((bytes >> 20)) MiB)"
  fi
  rm -rf "$profile_trace"
}

# Cold suites (ui=*ColdUITests, ui=*ColdLiveUITests): each test*Cold method of the suite, once per fresh boot of the
# UI tests' iPhone (shut down, booted, then the one test), CMUX_LAUNCH_COLD_RUNS times (default 10,
# at most 30). The app's LAUNCHTTI lines from every run go to launch-tti.jsonl; each run's console
# and per-test results to ui-cold/.
ui_cold_tests() {
  local matrix_slug="${1:-plain}"
  local runs="${CMUX_LAUNCH_COLD_RUNS:-10}" suite file test run status
  if [[ -z "${CMUX_LAUNCH_COLD_RUNS:-}" && " ${ui_cold[*]} " == *" LaunchColdLiveUITests "* ]]; then runs=20; fi
  [[ "$runs" =~ ^[0-9]+$ ]] && (( runs >= 1 && runs <= 30 )) || runs=10
  ui_cold_runs=$runs
  mkdir -p "$out/ui-cold"
  export CMUX_MOBILE_DURESS_PROFILE="${CMUX_MOBILE_DURESS_PROFILE:-off}"
  export CMUX_MOBILE_NET_PROFILE="${CMUX_MOBILE_NET_PROFILE:-off}"
  for suite in "${ui_cold[@]}"; do
    file="$(grep -lw "class ${suite%%/*}" cmux-next-ios/UITests/*.swift | head -1)"
    local tests=()
    if [[ "$suite" == */* ]]; then
      tests=("${suite#*/}")
    elif [[ -n "$file" ]]; then
      while IFS= read -r test; do tests+=("$test"); done < <(grep -oE 'func test[A-Za-z0-9_]*Cold\(' "$file" | sed -E 's/func (.*)\(/\1/')
    fi
    if [[ ${#tests[@]} -eq 0 ]]; then
      note "- cold UI suite $suite: no test*Cold methods found"; ui_status=1; continue
    fi
    for test in "${tests[@]}"; do
      for ((run = 1; run <= runs; run++)); do
        xcrun simctl shutdown "$ui_udid" >/dev/null 2>&1 || true
        # A run counts as cold only after a confirmed fresh boot; a failed transition is no sample.
        if ! { xcrun simctl boot "$ui_udid" && xcrun simctl bootstatus "$ui_udid" -b >/dev/null; }; then
          ui_status=1; note "- cold $suite/$test run $run: simulator reboot failed, no sample"; continue
        fi
        local bundle="$work/ui-cold-${test}-${run}.xcresult"
        xcodebuild test-without-building "${ui_xcodebuild[@]}" -resultBundlePath "$bundle" \
          "-only-testing:CmuxMobileAppUITests/${suite%%/*}/$test" >"$work/ui-cold-${matrix_slug}-${test}-${run}.log" 2>&1
        status=$?
        keep_test_logs "$work/ui-cold-${matrix_slug}-${test}-${run}.log" "$bundle" "ui-cold/${matrix_slug}-${test}-${run}"
        (( status == 0 )) || { ui_status=$status; note "- cold $suite/$test run $run: exit $status"; }
        rm -rf "$bundle"
      done
    done
  done
  note "- cold UI suites ${ui_cold[*]}: $runs runs per test, one fresh boot each"
}

# ui_cold_matrix: cold live suites for every requested load x link profile. The
# cmux-duress link knob is the existing seeded cmux-fault shaper used by the
# duress replay generator. `idle,link=PROFILE` gives a shaped, otherwise idle,
# run when the caller asks for net= with duress=off.
# Rust builds here run from inside cmux-tui: rustup picks the toolchain from the current
# directory's rust-toolchain.toml (cmux-tui/rust-toolchain.toml), and --manifest-path does not
# count. From the repo root a worker with no rustup default fails ("rustup could not choose a
# version of cargo to run"; two Mac workers, 2026-11-24, steps 93ff6323 and
# 83a54e14 lost every duress= UI pass).
ui_cold_matrix() {
  local spec net effective slug dir t1
  local specs=() nets=()
  if [[ ${#duress_specs[@]} -gt 0 ]]; then specs=("${duress_specs[@]}"); else specs=(off); fi
  if [[ ${#net_profiles[@]} -gt 0 ]]; then nets=("${net_profiles[@]}"); else nets=(off); fi
  if [[ " ${specs[*]} " != " off " || " ${nets[*]} " != " off " ]]; then
    t1=$SECONDS
    if ! (cd cmux-tui && cargo build --release --quiet -p cmux-duress --no-default-features) >"$work/duress-build.log" 2>&1; then
      tail -40 "$work/duress-build.log"; cp "$work/duress-build.log" "$out/duress-build.log" 2>/dev/null || true
      note "- duress: cmux-duress did not build (duress-build.log)"; ui_status=1; return
    fi
    note "- duress: cmux-duress built in $((SECONDS - t1)) s"
  fi
  for net in "${nets[@]}"; do
    for spec in "${specs[@]}"; do
      effective="$spec"
      if [[ "$net" != off ]]; then
        if [[ "$spec" == off ]]; then effective="idle,link=$net"
        elif [[ "$spec" == *,link=* ]]; then effective="${spec%%,link=*},link=$net"
        else effective="$spec,link=$net"
        fi
      fi
      slug="${spec}+${net}"
      slug="$(printf '%s' "$slug" | tr ',=' '__')"
      export CMUX_MOBILE_DURESS_PROFILE="$spec" CMUX_MOBILE_NET_PROFILE="$net"
      if [[ "$effective" == off ]]; then
        xcrun simctl spawn "$ui_udid" defaults delete -g CmuxMobileDuress >/dev/null 2>&1 || true
      else
        dir="$work/duress/$slug"
        mkdir -p "$dir"
        if ! cmux-tui/target/release/cmux-duress gen --spec "$effective" --out "$dir" --repo "$root" >"$dir/gen.log" 2>&1; then
          cat "$dir/gen.log"; note "- cold $spec/$net: cmux-duress gen failed"; ui_status=1; continue
        fi
        mkdir -p "$out/duress/$slug"; cp "$dir/duress.json" "$dir/gen.log" "$out/duress/$slug/" 2>/dev/null || true
        xcrun simctl spawn "$ui_udid" defaults write -g CmuxMobileDuress "$dir"
      fi
      ui_cold_tests "$slug"
    done
  done
  xcrun simctl spawn "$ui_udid" defaults delete -g CmuxMobileDuress >/dev/null 2>&1 || true
}

# ui_duress_runs: the warm UI suites once per duress= SPEC (cmux-next-ios/design/duress-sim.md), after
# one build-for-testing, on the one simulator. cmux-duress writes each SPEC's replay files under
# $work/duress/SLUG (duress.json copied to $out/duress/SLUG); the simulator's global defaults name that folder (CmuxMobileDuress), which the
# DEBUG app reads at launch, so the benches need no change. off deletes the key: no duress.
ui_duress_runs() {
  local spec slug dir status bundle t1
  t1=$SECONDS
  xcodebuild build-for-testing "${ui_xcodebuild[@]}" >"$work/ui-build.log" 2>&1
  ui_status=$?
  note "- UI test build (build-for-testing, for duress= runs): exit $ui_status, $((SECONDS - t1)) s"
  if [[ $ui_status -ne 0 ]]; then
    tail -40 "$work/ui-build.log"; cp "$work/ui-build.log" "$out/ui-build.log" 2>/dev/null || true; return
  fi
  ui_action=test-without-building
  if [[ " ${duress_specs[*]} " != " off " ]]; then
    t1=$SECONDS
    if ! (cd cmux-tui && cargo build --release --quiet -p cmux-duress --no-default-features) >"$work/duress-build.log" 2>&1; then
      tail -40 "$work/duress-build.log"; cp "$work/duress-build.log" "$out/duress-build.log" 2>/dev/null || true
      note "- duress: cmux-duress did not build (duress-build.log)"; ui_status=1; return
    fi
    note "- duress: cmux-duress built in $((SECONDS - t1)) s"
  fi
  xcrun simctl boot "$ui_udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$ui_udid" -b >/dev/null
  for spec in "${duress_specs[@]}"; do
    slug="$(printf '%s' "$spec" | tr ',=' '__')"
    # The replay files stay in the work folder (heavy's history is tens of MB); the artifact keeps
    # duress.json (the resolved knobs and counts) and gen.log.
    dir="$work/duress/$slug"
    if [[ "$spec" == off ]]; then
      xcrun simctl spawn "$ui_udid" defaults delete -g CmuxMobileDuress >/dev/null 2>&1 || true
      note "- duress $spec: no duress (CmuxMobileDuress unset)"
    else
      mkdir -p "$dir"
      t1=$SECONDS
      if ! cmux-tui/target/release/cmux-duress gen --spec "$spec" --out "$dir" --repo "$root" >"$dir/gen.log" 2>&1; then
        cat "$dir/gen.log"; note "- duress $spec: cmux-duress gen failed (duress/$slug/gen.log)"; ui_status=1; continue
      fi
      mkdir -p "$out/duress/$slug"; cp "$dir/duress.json" "$dir/gen.log" "$out/duress/$slug/" 2>/dev/null || true
      note "- duress $spec: $(tail -1 "$dir/gen.log") ($((SECONDS - t1)) s)"
      xcrun simctl spawn "$ui_udid" defaults write -g CmuxMobileDuress "$dir"
      [[ "$(xcrun simctl spawn "$ui_udid" defaults read -g CmuxMobileDuress 2>/dev/null)" == "$dir" ]] ||
        { note "- duress $spec: the simulator did not keep CmuxMobileDuress"; ui_status=1; continue; }
    fi
    bundle="$work/ui-duress-$slug.xcresult"
    t1=$SECONDS
    xcodebuild test-without-building "${ui_xcodebuild[@]}" -resultBundlePath "$bundle" \
      "${ui_suites[@]}" >"$work/ui-duress-$slug-test.log" 2>&1
    status=$?
    keep_test_logs "$work/ui-duress-$slug-test.log" "$bundle" "ui-duress-$slug"
    # The run named first is also the plain ui-* set, so the summary's readers keep working.
    if [[ ! -d "$work/ui.xcresult" ]]; then cp -R "$bundle" "$work/ui.xcresult"; cp "$work/ui-duress-$slug-test.log" "$work/ui-test.log"; fi
    note "- duress $spec: UI suites exit $status, $(cat "$out/ui-duress-$slug-tests-counts.txt" 2>/dev/null || echo "no result bundle"), $((SECONDS - t1)) s"
    (( status == 0 )) || ui_status=$status
  done
  xcrun simctl spawn "$ui_udid" defaults delete -g CmuxMobileDuress >/dev/null 2>&1 || true
}

# --- UI tests (test ui=...) -------------------------------------------------
if [[ $((${#ui_suites[@]} + ${#ui_cold[@]})) -gt 0 ]]; then
  t0=$SECONDS
  # A build of the app and its UI test bundle in $ui_config (config= above), on a new iPhone in the
  # default device set (xcodebuild sees no other), deleted by its UDID after.
  # CMUX_MOBILE_APPLE_SIGN_IN=YES shows Sign in with Apple, as the App Store
  # configurations and ios-review-gate.yml do: Debug hides it, so
  # AppReviewGateUITests failed here on every commit for want of the button.
  # CMUX_CI_SIM_WARM_OK=1: this iPhone may come already booted from the worker's warm pool (hq
  # build-fleet/cmd/worker/sim_warm.go), leased in seconds instead of made and booted; every boot below
  # tolerates a booted device.
  ui_udid="$(CMUX_CI_SIM_WARM_OK=1 sim_create "cmux-next-ios-sim-ui-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  recorder=""
  if [[ $ui_video -eq 1 || $ui_profile -eq 1 ]]; then
    # Booted first so the recording covers the whole run; the test run uses the booted device.
    xcrun simctl boot "$ui_udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$ui_udid" -b >/dev/null
  fi
  [[ $reduce_motion -eq 0 ]] || sim_boot_reduce_motion "$ui_udid" "UI test"
  ui_xcodebuild=(-project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration "$ui_config"
    -destination "id=$ui_udid,arch=arm64" -enableCodeCoverage NO -derivedDataPath "$dd_root/dd-ui"
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CMUX_MOBILE_APPLE_SIGN_IN=YES -quiet)
  if [[ "$ui_config" == Demo ]]; then
    # Demo builds the Swift packages as Release (no DEBUG): the app's DEBUG code would reference package
    # symbols that are not built (LaunchMarksProbe). The same conditions as the Demo app build above.
    ui_xcodebuild+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO')
  fi
  ui_action=test
  ui_status=0
  # Built beside the Demo build: only the run is left. A failed prebuild builds again here (`test`).
  [[ "$ui_prebuild_status" != 0 ]] || ui_action=test-without-building
  if [[ $ui_profile -eq 0 && ${#ui_cold[@]} -gt 0 ]]; then
    # Cold suites run test-without-building once per fresh boot: built once, first.
    ui_t0=$SECONDS
    set +e
    xcodebuild build-for-testing "${ui_xcodebuild[@]}" >"$work/ui-build.log" 2>&1
    ui_status=$?
    set -e
    note "- UI test build (build-for-testing, for the cold suites): exit $ui_status, $((SECONDS - ui_t0)) s"
    if [[ $ui_status -ne 0 ]]; then
      tail -40 "$work/ui-build.log"
      cp "$work/ui-build.log" "$out/ui-build.log" 2>/dev/null || true
    else
      ui_action=test-without-building
    fi
  fi
  if [[ $ui_profile -eq 1 ]]; then
    # Built first, so the recording (every host process) holds the tests and not the compiler.
    ui_t0=$SECONDS
    set +e
    xcodebuild build-for-testing "${ui_xcodebuild[@]}" >"$work/ui-build.log" 2>&1
    ui_status=$?
    set -e
    note "- UI test build (build-for-testing, before the profile): exit $ui_status, $((SECONDS - ui_t0)) s"
    if [[ $ui_status -ne 0 ]]; then
      tail -40 "$work/ui-build.log"
      cp "$work/ui-build.log" "$out/ui-build.log" 2>/dev/null || true
      profile_fail "the UI tests did not build, nothing was recorded (ui-build.log)"
    else
      ui_action=test-without-building
      ui_profile_start
    fi
  fi
  if [[ $ui_video -eq 1 ]]; then
    xcrun simctl io "$ui_udid" recordVideo --codec h264 --force "$out/ui-video.mp4" >"$work/ui-video.log" 2>&1 &
    recorder=$!
    # The wall-clock time of the recording's first frame, for scripts/mobile-bench/cut.py: simctl prints
    # "Recording started" once it writes frames (bounded: 10 s). Without that line the time is the launch's,
    # marked source=launch so a reader knows it is early by the recorder's start-up.
    # Read every 10 ms, so the stamp is within about 10 ms of the line.
    python3 -c '
import sys, time
log, t0 = sys.argv[1], time.time()
while time.time() - t0 < 10:
    try:
        if "Recording started" in open(log, errors="replace").read():
            print(f"MOBILEBENCH video-start t={time.time():.3f} source=recorder")
            sys.exit(0)
    except OSError:
        pass
    time.sleep(0.01)
print(f"MOBILEBENCH video-start t={t0:.3f} source=launch")
' "$work/ui-video.log" >"$out/ui-video-start.txt" || true
  fi
  set +e
  ui_t0=$SECONDS
  if [[ $ui_status -eq 0 && ${#duress_specs[@]} -gt 0 && ${#ui_cold[@]} -eq 0 ]]; then
    ui_duress_runs
  elif [[ $ui_status -eq 0 && ${#ui_suites[@]} -gt 0 ]]; then
    xcodebuild "$ui_action" "${ui_xcodebuild[@]}" -resultBundlePath "$work/ui.xcresult" \
      "${ui_suites[@]}" >"$work/ui-test.log" 2>&1
    ui_status=$?
  fi
  if [[ $ui_status -eq 0 && ${#ui_cold[@]} -gt 0 ]]; then
    if [[ ${#duress_specs[@]} -gt 0 || ${#net_profiles[@]} -gt 0 ]]; then
      ui_cold_matrix
    else
      ui_cold_tests plain
    fi
  fi
  ui_seconds=$((SECONDS - ui_t0))
  if [[ -n "$recorder" ]]; then
    # recordVideo finishes the file on SIGINT.
    kill -INT "$recorder" 2>/dev/null
    wait "$recorder"
    note "- UI test video: ui-video.mp4 ($(du -h "$out/ui-video.mp4" 2>/dev/null | cut -f1 || echo missing))"
    ffmpeg_bin="$(command -v ffmpeg || true)"
    [[ -n "$ffmpeg_bin" || ! -x /opt/homebrew/bin/ffmpeg ]] || ffmpeg_bin=/opt/homebrew/bin/ffmpeg
    if [[ -s "$out/ui-video.mp4" && -n "$ffmpeg_bin" ]]; then
      if "$ffmpeg_bin" -v error -y -i "$out/ui-video.mp4" -vf "scale=540:-2" -c:v libx264 -preset veryfast \
          -crf 30 -pix_fmt yuv420p -an -movflags +faststart "$out/ui-video-small.mp4" </dev/null; then
        note "- UI test video, small copy: ui-video-small.mp4 ($(du -h "$out/ui-video-small.mp4" | cut -f1))"
      else
        rm -f "$out/ui-video-small.mp4"
        note "- UI test video, small copy: ffmpeg failed, none"
      fi
    elif [[ -s "$out/ui-video.mp4" ]]; then
      note "- UI test video, small copy: no ffmpeg on this host, none"
    fi
    # Layout shifts in the recording (Leo, 2026-11-24: "this on reviving had tons of layout shifts"): blocks that
    # jump in one frame, blinks and staggered settles, as ui-video.mp4.shifts.json and a table in the notes.
    # A report, never this step's failure; the seeded recordings in CI are what gate the detector.
    if [[ -s "$out/ui-video.mp4" && -n "$ffmpeg_bin" ]]; then
      PATH="$(dirname "$ffmpeg_bin"):$PATH" python3 -I scripts/cmux-next/recording-shifts-report.py "$out/ui-video.mp4" \
        --title "Layout shifts in ui-video.mp4" >"$out/ui-video-shifts.md" 2>"$work/ui-video-shifts.log" || true
      note "- UI test video, layout shifts (ui-video-shifts.md): $(grep -m1 '^| `' "$out/ui-video-shifts.md" 2>/dev/null || echo "not read, see ui-video-shifts.log")"
      cp "$work/ui-video-shifts.log" "$out/" 2>/dev/null || true
    fi
  fi
  if [[ $ui_profile -eq 1 ]]; then
    ui_profile_finish
  fi
  set -e
  xcrun simctl shutdown "$ui_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$ui_udid" >/dev/null 2>&1 || true
  ui_udid=""
  keep_test_logs "$work/ui-test.log" "$work/ui.xcresult" ui
  if [[ ${#ui_suites[@]} -gt 0 && -d "$work/ui.xcresult" ]] && ! python3 -I scripts/ci/ios_sim_test_filter.py "$out/ui-tests.json" "${ui_suites[@]}" | tee "$out/ui-filter.txt"; then
    note "- UI filter selected no test: $(tr '\n' ' ' < "$out/ui-filter.txt")"
    [[ $ui_status -ne 0 ]] || ui_status=1
  fi
  grep -h "^FAILED:" -A3 "$out/ui-tests-failures.txt" 2>/dev/null || true
  # Bash 3.2 treats an empty array as unset under nounset (warm-only or cold-only).
  note "- UI tests ${ui_suites[*]-} ${ui_cold[*]-}: exit $ui_status, $(cat "$out/ui-tests-counts.txt" 2>/dev/null || echo "no result bundle"), xcodebuild $ui_action $ui_seconds s, $((SECONDS - t0)) s in all"
  # Launch marks (LaunchTTIUITests): every LAUNCHTTI line, and per flow and phase the p50 of each span.
  if ! python3 -I scripts/ci/ios_launch_samples.py "$out" --cold-runs "${ui_cold_runs:-10}" \
    --suites ${ui_suites[@]+"${ui_suites[@]}"} ${ui_cold[@]+"${ui_cold[@]}"}; then
    note "- ERROR: launch measurements are missing or invalid; see launch-tti-error.txt and the attachment export logs."
    ui_status=1
  fi
  if [[ -s "$out/launch-tti.jsonl" ]]; then
    python3 - "$out/launch-tti.jsonl" <<'PY' | while IFS= read -r line; do note "$line"; done
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
groups = {}
for row in rows:
    groups.setdefault((row["flow"], row["phase"]), []).append(row)
print("- Launch to first interaction (LaunchTTIUITests, ms since process start, p50 [min-max], n):")
for (flow, phase), items in sorted(groups.items()):
    parts = []
    for key in ["first_frame", "shell_frame", "list_ms", "open_ms", "echo_ms", "tti_ms"]:
        values = sorted(item[key] for item in items if key in item)
        if values:
            parts.append("%s %.0f [%.0f-%.0f]" % (key, values[len(values) // 2], values[0], values[-1]))
    print("  - %s %s (n=%d): %s" % (flow, phase, len(items), ", ".join(parts)))
PY
  fi
  if compgen -G "$out/ui-cold/*-console.txt" >/dev/null; then
    python3 - "$out/ui-cold" <<'PY' | while IFS= read -r line; do note "$line"; done
import json, pathlib, re, statistics, sys
rows = []
for path in sorted(pathlib.Path(sys.argv[1]).glob("*-console.txt")):
    for line in path.read_text(errors="replace").splitlines():
        match = re.search(r"LAUNCHCOLDLIVE (\{.*\})", line)
        if match:
            try: rows.append(json.loads(match.group(1)))
            except json.JSONDecodeError: pass
groups = {}
for row in rows:
    groups.setdefault((row.get("net", "off"), row.get("load", "off"), row.get("flow", "?")), []).append(row)
print("- Live cold launch marks (ms since process start, p50/p90, n):")
print("  - Limits: the terminal flow is the mock session (no Mac, no network: its link time is not in these rows);"
      " cold is a cold process and a freshly booted simulator, not a cold disk (the host's file cache stays warm).")
for (net, load, flow), items in sorted(groups.items()):
    parts = []
    for key in ("first_frame", "chat_first_row_frame", "terminal_first_row_frame"):
        values = sorted(float(item[key]) for item in items if isinstance(item.get(key), (int, float)))
        if values:
            p50 = values[len(values) // 2]
            p90 = values[min(len(values) - 1, int(len(values) * .9))]
            parts.append("%s %.0f/%.0f" % (key, p50, p90))
    print("  - net=%s load=%s flow=%s n=%d: %s" % (net, load, flow, len(items), ", ".join(parts)))
PY
    if [[ " ${ui_cold[*]} " == *" LaunchColdLiveUITests "* ]] &&
       ! grep -Rqs 'LAUNCHCOLDLIVE {' "$out/ui-cold"; then
      note "- ERROR: LaunchColdLiveUITests produced no live samples; check paired workspace environment and daemon connection"
      ui_status=1
    fi
  fi
fi

# --- Chief layout benchmark -------------------------------------------------
if [[ "$mode" == chief-live-perf || "$mode" == chief-live-perf-baseline ]]; then
  perf_udid="$(sim_create "cmux-chief-perf-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  [[ $reduce_motion -eq 0 ]] || sim_boot_reduce_motion "$perf_udid" "Chief benchmark"
  perf_flags=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited)')
  if [[ "$mode" == chief-live-perf-baseline ]]; then
    perf_flags=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CHIEF_LIVE_BASELINE')
  fi
  note "## Chief live layout ($mode): three runs, one warm-up + three samples per run"
  note "- harness sha256: $(shasum -a 256 cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileChiefTests/ChiefLiveLayoutPerformanceTests.swift | awk '{print $1}')"
  perf_status=0
  for run in 1 2 3; do
    # TEST_RUNNER_ forwards this opt-in to the simulator test process. No
    # controller env allowlist change is needed: the mode owns the setting.
    # Keep one simulator and DerivedData for all runs; only the result path varies.
    set +e
    (cd cmux-next-ios/CmuxMobileKit && TEST_RUNNER_CMUX_CHIEF_LIVE_PERF=1 xcodebuild test \
      -scheme CmuxMobileKit-Package -destination "id=$perf_udid,arch=arm64" \
      -enableCodeCoverage NO -parallel-testing-enabled NO \
      -only-testing:CmuxMobileChiefTests/ChiefLiveLayoutPerformanceTests \
      -derivedDataPath "$dd_root/dd-chief-perf" \
      -resultBundlePath "$out/bench/chief-live-$run.xcresult" \
      CODE_SIGNING_ALLOWED=NO "${perf_flags[@]}") > "$out/bench/chief-live-$run.log" 2>&1
    run_status=$?
    set -e
    note "- run $run: xcodebuild exit $run_status"
    if [[ "$run_status" -ne 0 ]]; then
      tail -60 "$out/bench/chief-live-$run.log"
      perf_status=$run_status
      break
    fi
    xcrun xcresulttool get log --type console --path "$out/bench/chief-live-$run.xcresult" \
      > "$out/bench/chief-live-$run-console.log" 2>/dev/null || true
    if ! grep -h 'CHIEF_LIVE_LAYOUT main_thread_ms_per_1000_tokens=' "$out/bench/chief-live-$run.log" "$out/bench/chief-live-$run-console.log" \
      > "$out/bench/chief-live-$run.txt"; then
      note "- ERROR: run $run produced no measurement; a skipped test is not a benchmark pass. See its log and xcresult."
      perf_status=1
      break
    fi
    cat "$out/bench/chief-live-$run.txt" | tee -a "$summary"
  done
  xcrun simctl shutdown "$perf_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$perf_udid" >/dev/null 2>&1 || true
  perf_udid=""
fi

# --- Benchmarks -------------------------------------------------------------
if [[ "$mode" == bench || "$mode" == all ]]; then
  corpus="$work/corpus"
  mkdir -p "$corpus"
  # A 6 MB real text file: this checkout's Swift sources.
  # head closes the pipe early; the SIGPIPE upstream is expected (pipefail).
  { git ls-files -z '*.swift' | xargs -0 cat 2>/dev/null | head -c 6000000 > "$corpus/big.txt"; } || true
  [[ -s "$corpus/big.txt" ]] || { echo "error: empty benchmark corpus" >&2; exit 1; }
  # Record each workload through a real PTY at a phone-like grid (50 x 45).
  record() { # name, command...
    local name=$1; shift
    local start end
    start=$(python3 -c 'import time; print(time.time())')
    TERM=xterm-256color script -q "$corpus/$name.typescript" sh -c "stty rows 45 cols 50; $*" </dev/null >/dev/null 2>&1 || true
    end=$(python3 -c 'import time; print(time.time())')
    python3 - "$corpus/$name.typescript" "$start" "$end" > "$corpus/$name.rate" <<'PY'
import os, sys
size = os.path.getsize(sys.argv[1]); secs = max(float(sys.argv[3]) - float(sys.argv[2]), 0.05)
print(f"{min(size * 8 / secs / 1e6, 50.0):.3f} {size} {secs:.2f}")
PY
  }
  record cat "cat '$corpus/big.txt'"
  cat > "$corpus/scroll.vim" <<'VIM'
set number
set filetype=c
syntax on
for i in range(1500)
  execute "normal! \<C-e>"
  redraw
endfor
qa!
VIM
  record vim "vim -u NONE -i NONE -N -n -S '$corpus/scroll.vim' '$corpus/big.txt'"
  if command -v htop >/dev/null; then top_cmd="htop -d 10"; top_name="htop"; else top_cmd="top -s 1"; top_name="top (htop not installed)"; fi
  # In the foreground (a background job is stopped by SIGTTOU when it sets the
  # tty mode); the alarm survives exec and ends it after 12 s.
  record top "perl -e 'alarm 12; exec @ARGV' $top_cmd"
  note ""
  note "## Flood benchmark (Demo build, in-app TerminalFloodBench, fake Mac daemon, real DaemonClient + Ghostty renderer)"
  note ""
  note "| Workload | Bytes | Replay Mbit/s | Main CPU ms/s | App CPU ms/s | Frames/s | Frame p50 / p95 / max ms | Echo p50 / p90 / max ms | Idle echo p50 / p90 ms | Drain ms |"
  note "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  for name in cat vim top; do
    read -r mbps size _secs < "$corpus/$name.rate"
    simctl launch "$udid" "$bundle_id" -CmuxMobileFloodBench -CmuxMobileFloodBenchFile "$corpus/$name.typescript" \
      -CmuxMobileFloodBenchMbps "$mbps" -CmuxMobileFloodBenchSeconds 10 >/dev/null
    data="$(simctl get_app_container "$udid" "$bundle_id" data)"
    result="$data/Documents/flood-bench.json"
    rm -f "$result"
    # Screens at fixed points of the run (3 s idle, 10 s flood, 6 s after): bounded delays, not a sync.
    sleep 9; simctl io "$udid" screenshot "$out/screens/$name-flood.png" >/dev/null
    deadline=$((SECONDS + 60))
    until [[ -s "$result" ]] || (( SECONDS > deadline )); do sleep 1; done
    simctl io "$udid" screenshot "$out/screens/$name-after.png" >/dev/null
    simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    if [[ ! -s "$result" ]]; then note "| $name | $size | $mbps | no result (timed out) | | | | | | |"; continue; fi
    cp "$result" "$out/bench/$name.json"
    python3 - "$out/bench/$name.json" "$name" "$size" "$mbps" >> "$summary" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["summary"]; f = s["flood"]; i = s.get("idle", {})
print(f"| {sys.argv[2]} | {int(sys.argv[3]):,} | {float(sys.argv[4]):.2f} | {f['mainCPUmsPerSecondAvg']} | {f.get('processCPUmsPerSecondAvg', '-')} | "
      f"{f['presentsPerSecondAvg']:.0f} | {f.get('frameIntervalP50ms', '-')} / {f.get('frameIntervalP95ms', '-')} / {f.get('frameIntervalMaxms', '-')} | "
      f"{f['echoP50ms']} / {f['echoP90ms']} / {f['echoMaxms']} | {i.get('echoP50ms', '-')} / {i.get('echoP90ms', '-')} | {s['drainAfterStopMs']:.0f} |")
PY
  done
  note ""
  note "Workload top ran: $top_name. Recordings: 50 columns x 45 rows; replayed in a loop for 10 s at the rate the program wrote them (capped at 50 Mbit/s)."
  tail -n +1 "$summary" | tail -8
fi

# --- Screens ----------------------------------------------------------------
if [[ "$mode" == shots ]]; then
  t0=$SECONDS
  # Setup marked complete, so a deep link lands on its screen instead of "Choose a space".
  simctl spawn "$udid" defaults write "$bundle_id" cmuxMobile.setupComplete -bool YES
  note ""
  note "## Screens (mock data, DEBUG launch arguments)"
  note ""
  if [[ "$appstore" == 1 ]]; then
    # App Store screenshots: Apple's clean status bar (9:41, full signal, Wi-Fi and battery).
    simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
    note "- App Store screenshots: ${device_type##*.}, status bar overridden (9:41, full signal and battery)"
  fi
  for scene in "${scenes[@]}"; do
    name="${scene%%=*}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$scene" == *=?* ]] || { note "- skipped scene '$scene': want name=WORD,WORD,..."; continue; }
    IFS=',' read -r -a words <<< "${scene#*=}"
    envs=(SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1)
    args=()
    wait_s="${CMUX_NEXT_IOS_SHOT_WAIT:-5}"
    for w in ${words[@]+"${words[@]}"}; do
      if [[ ${#args[@]} -eq 0 && "$w" =~ ^SHOT_WAIT=([1-9]|[1-5][0-9]|60)$ ]]; then wait_s="${w#SHOT_WAIT=}"
      elif [[ ${#args[@]} -eq 0 && "$w" =~ ^[A-Z_][A-Z0-9_]*= ]]; then envs+=("SIMCTL_CHILD_$w"); else args+=("$w"); fi
    done
    for look in dark light; do
      simctl ui "$udid" appearance "$look" >/dev/null 2>&1 || true
      env "${envs[@]}" xcrun simctl --set "$sims" launch "$udid" "$bundle_id" ${args[@]+"${args[@]}"} >/dev/null
      # A bounded wait for the scene to draw; demo drivers have no signal to wait on.
      sleep "$wait_s"
      simctl io "$udid" screenshot "$out/screens/$name-$look.png" >/dev/null
      simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
      if [[ "$appstore" == 1 ]]; then
        size="$(sips -g pixelWidth -g pixelHeight "$out/screens/$name-$look.png" | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w "x" h }')"
        [[ "$size" == 1320x2868 || "$size" == 1290x2796 ]] ||
          { note "- $name-$look: $size is not a 6.9\" iPhone portrait size (1320x2868 or 1290x2796)"; exit 1; }
        # App Store Connect refuses an alpha channel; simctl writes RGBA even when every pixel is opaque.
        python3 -I scripts/ci/png_opaque.py "$out/screens/$name-$look.png" ||
          { note "- $name-$look: could not drop its alpha channel"; exit 1; }
      fi
    done
    note "- $name: screens/$name-dark.png, screens/$name-light.png"
  done
  simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
  note "- screens: $((SECONDS - t0)) s"
fi

# --- theme-relaunch: the cached Mac theme across relaunch --------------------
if [[ "$mode" == theme-relaunch ]]; then
  t0=$SECONDS
  tr_dir="$out/theme-relaunch"
  tr_small="$work/theme-relaunch-small"
  mkdir -p "$tr_dir" "$tr_small"
  simctl spawn "$udid" defaults write "$bundle_id" cmuxMobile.setupComplete -bool YES
  tr_data="$(simctl get_app_container "$udid" "$bundle_id" data)"
  tr_cache="$tr_data/Library/Application Support/cmux-mac-appearance"
  tr_launch() { env SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl --set "$sims" launch "$udid" "$bundle_id" "$@" >/dev/null; }
  tr_shot() { simctl io "$udid" screenshot "$1" >/dev/null 2>&1 || true; }
  tr_digest() { if [[ -f "$tr_cache/appearance.json" ]]; then shasum -a 256 "$tr_cache/appearance.json" | awk '{ print substr($1, 1, 16) }'; else echo none; fi; }
  note ""
  note "## Mac theme across relaunch (mock data, no Mac)"
  note ""
  rm -rf "$tr_cache"
  # The stock reference: no theme was ever applied on this install.
  tr_launch
  sleep 6
  tr_shot "$tr_dir/stock.png"
  simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  # The themed reference: a dark Mac theme with a wallpaper, applied and kept (CmuxMobileMacTheme.apply).
  tr_launch -cmux-mobile-mac-appearance mocha-wallpaper
  for _ in $(seq 40); do
    [[ -f "$tr_cache/appearance.json" ]] && ls "$tr_cache"/chat-wallpaper-*.img >/dev/null 2>&1 && break
    sleep 0.5
  done
  sleep 4
  tr_shot "$tr_dir/themed.png"
  simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  note "- applied mocha-wallpaper; cache: appearance.json $(tr_digest), $(ls "$tr_cache" 2>/dev/null | tr '\n' ' ')"
  launches=()
  for i in $(seq -w 1 "$theme_relaunches"); do
    d="$tr_dir/launch-$i"
    mkdir -p "$d"
    before="$(tr_digest)"
    tr_launch
    # The first frames: as fast as simctl takes them (about 0.2-0.4 s each), for about 4 s.
    start=$SECONDS k=0
    while (( SECONDS - start < 4 && k < 20 )); do
      k=$((k + 1))
      tr_shot "$d/f$(printf '%02d' "$k").png"
    done
    sleep 3
    tr_shot "$d/settled.png"
    simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    note "- launch $i: cache before $before, after $(tr_digest), $k early frames"
    launches+=("$tr_small/launch-$i")
  done
  # Downscaled copies for the count (pure-Python decoding of full stills is slow).
  for f in "$tr_dir"/*.png "$tr_dir"/launch-*/*.png; do
    rel="${f#"$tr_dir"/}"
    mkdir -p "$tr_small/$(dirname "$rel")"
    sips -s format png --resampleHeightWidth 160 74 "$f" --out "$tr_small/$rel" >/dev/null 2>&1 || true
  done
  python3 -I scripts/ci/ios_theme_relaunch_count.py --stock "$tr_small/stock.png" --themed "$tr_small/themed.png" \
    --out "$tr_dir/verdict.json" "${launches[@]}" | tee -a "$summary" || note "- theme-relaunch: the count failed"
  note "- theme-relaunch: $((SECONDS - t0)) s"
fi

# --- What's New clip (clips) ----------------------------------------------
if [[ "$mode" == clips ]]; then
  t0=$SECONDS
  clip_status=0
  note ""
  note "## What's New clip: $clip_id"
  note ""
  for role in "${clip_roles[@]}"; do
    side_app="$app"
    [[ "$role" == after ]] || side_app="$base_app"
    if [[ -z "$side_app" ]]; then
      clip_status=1
      note "- $role: no clip: no app at ${listperf_base:-its commit} (see above)"
      continue
    fi
    if python3 -I scripts/cmux-next/media/whats-new-clips.py record-iphone "$clip_id" --simctl-set "$sims" \
        --udid "$udid" --bundle-id "$bundle_id" --app "$side_app" --out "$out/whats-new-clips/$role" \
        >"$work/clip-$role.log" 2>&1; then
      note "- $role: whats-new-clips/$role/ ($( [[ "$role" == after ]] && git rev-parse --short=12 HEAD || echo "${listperf_base:0:12}"))"
    else
      clip_status=1
      note "- $role: no clip: $(tail -n 1 "$work/clip-$role.log")"
    fi
  done
  if [[ -d "$out/whats-new-clips" ]]; then
    (cd "$out" && rm -f whats-new-clips.zip && zip -qr whats-new-clips.zip whats-new-clips)
  fi
  note "- clips: $((SECONDS - t0)) s"
fi

# --- List frame rate (listperf) --------------------------------------------
if [[ "$mode" == listperf ]]; then
  t0=$SECONDS
  lp="$out/listperf"
  mkdir -p "$lp"
  sides=(head)
  [[ -z "$base_app" ]] || sides=(base head)
  note ""
  note "## List frame rate (ListStressRig, Demo build, ${device_type##*.} on ${runtime##*.})"
  note ""
  note "| Run | Window | Frames | p99 ms | Max ms | Hitch ms/s | Main CPU ms/s |"
  note "| --- | --- | --- | --- | --- | --- | --- |"
  for rep in $(seq 1 "$listperf_reps"); do
    for case_name in "${listperf_cases[@]}"; do
      line="$(printf '%s\n' "${listperf_table[@]}" | awk -v c="$case_name" '$1 == c')"
      read -r _label screen settings <<< "$line"
      for side in "${sides[@]}"; do
        run="$side-$case_name-r$rep"
        side_app="$app"
        [[ "$side" == head ]] || side_app="$base_app"
        envs=(SIMCTL_CHILD_CMUX_MOBILE_FRAMELOG=1 SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1
          "SIMCTL_CHILD_CMUX_MOBILE_LIST_SCREEN=$screen" SIMCTL_CHILD_CMUX_MOBILE_LIST_EXIT_WHEN_DONE=1)
        coord_sim=0
        for kv in $settings; do
          if [[ "$kv" == LIST_EVENTS=coord-sim ]]; then coord_sim=1; continue; fi
          envs+=("SIMCTL_CHILD_CMUX_MOBILE_$kv")
        done
        # A clean install of this side's app: no data container carried over from the other side.
        simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
        simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
        simctl install "$udid" "$side_app"
        if [[ "$coord_sim" == 1 ]]; then
          # One heavy coordinator's records from coord-sim (cmux-tui/crates/coord-sim, serde only: a few seconds to
          # build), written once, copied into this install's data container for CoordSimReplaySource.
          if [[ ! -s "$lp/coord-sim/coord-sim-chat.ndjson" ]]; then
            (cd cmux-tui/crates/coord-sim && cargo build --quiet --release) &&
              cmux-tui/crates/coord-sim/target/release/coord-sim surface --target ios --out "$lp/coord-sim" \
                --history "${COORD_SIM_HISTORY:-3000}" --rate "${COORD_SIM_RATE:-10}" --seconds 90 \
                --max-event-bytes 65536 >"$lp/coord-sim.txt" 2>&1 ||
              { echo "$run: coord-sim failed (see listperf/coord-sim.txt)"; listperf_status=1; }
          fi
          if [[ ! -s "$lp/coord-sim/coord-sim-chat.ndjson" ]]; then
            # No records: launching would measure an empty chat, so skip the run (listperf_status is already 1).
            echo "$run: skipped (no coord-sim records)"
            listperf_status=1
            continue
          fi
          events_dir="$(simctl get_app_container "$udid" "$bundle_id" data)/Library/Caches"
          mkdir -p "$events_dir"
          cp "$lp/coord-sim/coord-sim-chat.ndjson" "$events_dir/"
          history="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["history"])' \
            "$lp/coord-sim/coord-sim-chat.json" 2>/dev/null || echo 0)"
          envs+=("SIMCTL_CHILD_CMUX_MOBILE_LIST_EVENTS=$events_dir/coord-sim-chat.ndjson"
            "SIMCTL_CHILD_CMUX_MOBILE_LIST_EVENTS_HISTORY=$history")
        fi
        started=$SECONDS
        # The rig exits the app after its last pass; bounded at 300 s (rig.sh's WAIT).
        env "${envs[@]}" perl -e 'alarm shift; exec @ARGV' 300 xcrun simctl --set "$sims" launch --console-pty \
          --terminate-running-process "$udid" "$bundle_id" -cmuxMobile.setupComplete YES -cmux-mobile-no-restore \
          >"$lp/$run.console.txt" 2>&1 || { echo "$run: launch exited $? (142: the 300 s bound)"; listperf_status=1; }
        simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
        caches="$(simctl get_app_container "$udid" "$bundle_id" data)/Library/Caches"
        cp "$caches/framelog.jsonl" "$lp/$run.jsonl" 2>/dev/null || : >"$lp/$run.jsonl"
        simctl spawn "$udid" log show --last "$(( SECONDS - started + 30 ))s" --style compact \
          --predicate 'subsystem == "dev.cmux.mobile" AND category == "frames"' 2>/dev/null |
          grep -E 'list-stress' | sed 's/^/# /' >>"$lp/$run.jsonl" || true
        python3 -I cmux-next-ios/verify/feedperf/summarize.py "$lp/$run.jsonl" >"$lp/$run.txt" 2>&1 || true
        echo "== $run ($(( SECONDS - started )) s)"
        grep -E 'POOLED|-open' "$lp/$run.txt" || { echo "$run: no windows"; listperf_status=1; }
        if [[ "$coord_sim" == 1 ]]; then
          grep -hoE "list-stress (coord-sim .*|memory .*)" "$lp/$run.jsonl" | sed "s/^/$run: /" | tee -a "$lp/coord-sim-summary.txt" || true
        fi
        python3 -I - "$lp/$run.txt" "$run" >>"$summary" <<'PY'
import sys
path, run = sys.argv[1], sys.argv[2]
rows = 0
for line in open(path):
    words = line.split()
    if not words or not (words[0] == "POOLED" or "-open" in words[0]):
        continue
    kv = dict(w.split("=", 1) for w in words if "=" in w)
    print(f"| {run} | {words[0]} | {kv.get('frames', '-')} | {kv.get('p99', '-')} | {kv.get('max', '-')} | "
          f"{kv.get('hitch_ms_per_s', '-')} | {kv.get('main_cpu_ms_per_s', '-')} |")
    rows += 1
if not rows:
    print(f"| {run} | no windows | | | | | |")
PY
      done
    done
  done
  simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
  note "- listperf: $((SECONDS - t0)) s; sides: ${sides[*]}; reps: $listperf_reps; logs: listperf/"
  if [[ -s "$lp/coord-sim-summary.txt" ]]; then
    while IFS= read -r coord_line; do note "- $coord_line"; done <"$lp/coord-sim-summary.txt"
  fi
  [[ "${listperf_status:-0}" -eq 0 ]] || note "- listperf: FAILED (a run did not finish or measured no windows; see listperf/)"
fi

# --- Battery and memory (energy) -------------------------------------------
if [[ "$mode" == energy ]]; then
  t0=$SECONDS
  en="$out/energy"
  mkdir -p "$en"
  sides=(head)
  label_ticks=()
  [[ -z "$base_app" ]] || sides=(base head)
  rusage=cmux-next-ios/verify/energy_rusage.py
  # Where a busy case's CPU goes: a 15 s CPU stack-sampling recording of the app right after its
  # sampled window (first rep, each side), summarized per main-thread symbol by
  # ios_sim_time_profile.py. The instrument, not the 'Time Profiler' template (its os_log source
  # never finishes saving on the fleet's hosts, as for `test profile`); attached to the app, else
  # every process (the summary groups by process). energy/profile-RUN/ keeps the summary and the trace.
  energy_time_profile() {
    local run=$1 pid=$2 d="$en/profile-$1" table bytes=0
    mkdir -p "$d"
    perl -e 'alarm shift; exec @ARGV' 600 xcrun xctrace record --instrument 'Time Profiler' --attach "$pid" \
      --time-limit 15s --output "$d/time.trace" --no-prompt >"$d/record.txt" 2>&1 ||
      echo "$run: xctrace Time Profiler --attach exited $?" >>"$d/record.txt"
    if [[ ! -d "$d/time.trace" ]]; then
      perl -e 'alarm shift; exec @ARGV' 600 xcrun xctrace record --instrument 'Time Profiler' --all-processes \
        --time-limit 15s --output "$d/time.trace" --no-prompt >>"$d/record.txt" 2>&1 ||
        echo "$run: xctrace Time Profiler --all-processes exited $?" >>"$d/record.txt"
    fi
    if [[ ! -d "$d/time.trace" ]]; then
      echo "$run: no Time Profiler trace (energy/profile-$run/record.txt): $(tail -n 1 "$d/record.txt" | cut -c1-200)"
      return 0
    fi
    table="$d/time-profile.xml"
    if perl -e 'alarm shift; exec @ARGV' 600 xcrun xctrace export --input "$d/time.trace" \
         --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output "$table" >>"$d/record.txt" 2>&1 &&
       python3 -I scripts/ci/ios_sim_time_profile.py "$table" --markdown "$d/summary.md" --json "$d/summary.json" >"$d/brief.txt" 2>&1; then
      echo "== $run: Time Profiler, 15 s, main thread (energy/profile-$run/summary.md)"
      cat "$d/brief.txt"
      head -n 80 "$d/summary.md"
    else
      echo "$run: the Time Profiler trace exported no samples (energy/profile-$run/record.txt)"
    fi
    rm -f "$table"
    ditto -c -k --keepParent "$d/time.trace" "$d/time.trace.zip" 2>/dev/null || true
    rm -rf "$d/time.trace"
    if [[ -f "$d/time.trace.zip" ]]; then bytes=$(wc -c < "$d/time.trace.zip"); fi
    if (( bytes > 536870912 )); then rm -f "$d/time.trace.zip"; echo "$run: trace over 512 MiB zipped, dropped (the summary stays)"; fi
  }
  # The last `received-bytes total=N` the app logged (0 before the first).
  energy_received_total() {
    local n
    n="$(grep -oE 'FRAMELOG list-stress received-bytes total=[0-9]+' "$1" | tail -n 1 | sed 's/.*total=//')"
    echo "${n:-0}"
  }
  note ""
  note "## Battery and memory (Demo build, mock mode, ${device_type##*.} on ${runtime##*.}; cmux-next-ios/verify/energy.md)"
  note ""
  note "Kernel counters for the app's process (proc_pid_rusage, no root): CPU time, interrupt wakeups, ri_energy_nj as mW, phys_footprint."
  note ""
  note "| Run | Phase | s | CPU % | Wakeups/s | Energy mW | Received B/s | MEM start MB | MEM end MB | MEM max MB |"
  note "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  for rep in $(seq 1 "$energy_reps"); do
    for case_name in "${energy_cases[@]}"; do
      line="$(printf '%s\n' "${energy_table[@]}" | awk -v c="$case_name" '$1 == c')"
      read -r _label screen phase case_seconds settings <<< "$line"
      [[ "$case_seconds" != "-" ]] || case_seconds="$energy_seconds"
      # The rig's frames log says when its screen is ready: `holding SCREEN` once a still
      # (LIST_PASSES=0: idle, stream, background) has opened and settled, `list-stress SCREEN scroll=`
      # as the scroll case's passes begin. A loaded host takes longer, so the bench waits for the line.
      ready="FRAMELOG list-stress holding $screen"
      [[ "$phase" != scroll ]] || ready="FRAMELOG list-stress $screen scroll="
      for side in "${sides[@]}"; do
        run="$side-$case_name-r$rep"
        side_app="$app"
        [[ "$side" == head ]] || side_app="$base_app"
        envs=(SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 "SIMCTL_CHILD_CMUX_MOBILE_LIST_SCREEN=$screen")
        # @REPO@ is this checkout: a simulator app reads the host's files (the typical-hour session).
        for kv in $settings; do envs+=("SIMCTL_CHILD_CMUX_MOBILE_${kv//@REPO@/$PWD}"); done
        # A clean install of this side's app: no data container carried over from the other side.
        simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
        simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
        simctl install "$udid" "$side_app"
        logf="$en/$run.frames.txt"
        simctl spawn "$udid" log stream --style compact --level default \
          --predicate 'subsystem == "dev.cmux.mobile" AND category == "frames"' >"$logf" 2>&1 &
        log_pid=$!
        sleep 2  # log stream attaches before the app starts
        # `simctl launch` prints "BUNDLE: PID"; the simulator's app is a process of this Mac.
        launched=$SECONDS
        pid="$(env "${envs[@]}" xcrun simctl --set "$sims" launch --terminate-running-process "$udid" "$bundle_id" \
          -cmuxMobile.setupComplete YES -cmux-mobile-no-restore | awk -F': ' '{ print $NF }' | tr -dc '0-9')"
        if [[ -z "$pid" ]]; then
          echo "$run: no PID from simctl launch"; energy_status=1
          kill "$log_pid" 2>/dev/null || true; wait "$log_pid" 2>/dev/null || true
          continue
        fi
        until grep -qF -- "$ready" "$logf"; do
          (( SECONDS - launched < 180 )) || break
          sleep 1
        done
        if ! grep -qF -- "$ready" "$logf"; then
          echo "$run: no '$ready' within 180 s of launch; not sampled"; energy_status=1
          kill "$log_pid" 2>/dev/null || true; wait "$log_pid" 2>/dev/null || true
          simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
          continue
        fi
        echo "$run: ready $(( SECONDS - launched )) s after launch"
        if [[ "$phase" == background ]]; then
          simctl launch "$udid" com.apple.Preferences >/dev/null 2>&1 || { echo "$run: could not put Settings in front"; energy_status=1; }
          sleep 3
        fi
        # One kernel reading a second for case_seconds (energy_rusage.py); top beside it as a cross-check.
        top -l "$(( case_seconds + 1 ))" -s 1 -pid "$pid" -stats pid,cpu,idlew,power,mem >"$en/$run.top.txt" 2>&1 &
        top_pid=$!
        # A running chat (LIST_HOLD_TURN=1) logs each redraw of its elapsed time: count those in the sample.
        ticks_before="$(grep -cF -- "FRAMELOG list-stress label-tick" "$logf" || true)"
        # The bytes the app received (ReceivedByteCount.swift: the link's daemon channels, or the mock
        # shells' output in mock mode): its last logged total before and after the window.
        received_before="$(energy_received_total "$logf")"
        python3 -I "$rusage" sample "$pid" "$case_seconds" "$en/$run.rusage.jsonl" || echo "$run: rusage sampler exited $?"
        wait "$top_pid" 2>/dev/null || true
        sleep 1  # the counter logs its total a second after bytes arrive
        received_per_s=$(( ( $(energy_received_total "$logf") - received_before ) / case_seconds ))
        # An app without the counter (an older base) logs no total: `-`, not 0.
        grep -qF -- "FRAMELOG list-stress received-bytes" "$logf" || received_per_s=-
        if [[ " $settings " == *" LIST_HOLD_TURN=1 "* ]]; then
          ticks_after="$(grep -cF -- "FRAMELOG list-stress label-tick" "$logf" || true)"
          label_ticks+=("- $run: label ticks $(( ticks_after - ticks_before )) in $case_seconds s (elapsed-time redraws while sampled)")
        fi
        if [[ "$rep" == 1 && ( "$phase" == stream || "$phase" == scroll ) ]]; then energy_time_profile "$run" "$pid"; fi
        simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
        simctl terminate "$udid" com.apple.Preferences >/dev/null 2>&1 || true
        kill "$log_pid" 2>/dev/null || true; wait "$log_pid" 2>/dev/null || true
        python3 -I cmux-next-ios/verify/energy_summary.py "$en/$run.rusage.jsonl" "$en/$run.top.txt" "$pid" "$run" "$phase" "$received_per_s" >"$en/$run.json" ||
          { echo "$run: no samples"; energy_status=1; continue; }
        python3 -I cmux-next-ios/verify/energy_summary.py --row "$en/$run.json" | tee -a "$summary"
      done
    done
  done
  simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
  for line in ${label_ticks[@]+"${label_ticks[@]}"}; do note "$line"; done
  note "- energy: $((SECONDS - t0)) s; sides: ${sides[*]}; reps: $energy_reps; samples: energy/"
  [[ "${energy_status:-0}" -eq 0 ]] || note "- energy: FAILED (a run had no PID, no ready line or no samples; see energy/)"
fi

# --- Mounted iOS Screen Sharing --------------------------------------------
if [[ "$mode" == screen-proof ]]; then
  python3 -I scripts/ci/cmux_next_screen_sharing_proof.py \
    --source-sha "$CMUX_SCREEN_PROOF_SOURCE" --mac-job "$CMUX_SCREEN_PROOF_MAC_JOB" \
    --artifact-sha256 "$CMUX_SCREEN_PROOF_ARTIFACT" --sims "$sims" --udid "$udid" \
    --viewer-name "$sim_name" --bundle-id "$bundle_id" --out "$out"
  # This proof publishes only its allowlisted receipt. Logs and screenshots
  # stay private; the ordinary simulator archive below must not package them.
  exit 0
fi

# --- Pairing by QR code ----------------------------------------------------
if [[ "$mode" == pair-e2e ]]; then
  t0=$SECONDS
  # mac_tag: this run's own tag, set before the phone build (the phone shares its build space).
  prev_last_log="$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || true)"
  mac_dd="$work/mac-dd"
  # A fleet step checks out no submodules (only their empty gitlink directories): the Mac app
  # needs Ghostty's headers, the ghostty-next tree and GhosttyKit.xcframework (a prebuilt
  # download), as the measure steps do (scripts/measure/action-signposts.sh). Without them
  # reload.sh stops at once: "ghostty/include/ghostty.h is missing" (step 4baf44ec, 2026-10-27).
  for sub in ghostty ghostty-next; do
    [[ -e "$sub/.git" ]] || git submodule update --init --depth 1 "$sub" >"$work/submodules.log" 2>&1 ||
      { tail -20 "$work/submodules.log"; echo "error: could not check out the $sub submodule" >&2; exit 1; }
  done
  if [[ ! -f GhosttyKit.xcframework/Info.plist ]]; then
    rm -rf GhosttyKit.xcframework
    if [[ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" && -n "${CI_SHARED_CACHE_DIR:-}" ]]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh >"$work/ghosttykit.log" 2>&1 ||
      { tail -20 "$work/ghosttykit.log"; echo "error: could not download GhosttyKit.xcframework" >&2; exit 1; }
  fi
  # ghostty-vt-sys (ghostty-next) needs the fleet's pinned Zig 0.17 (the worker's tools, as
  # its probe reports); PATH can name /usr/local's 0.16, which it refuses ("Your Zig version
  # v0.16.0 does not meet the required build version of v0.17.0", steps
  # e00987962032845838c55ef5 and b9658de920bf40d484a998ac). Only ZIG, which ghostty-vt-sys
  # reads first: the classic Ghostty CLI helper reads CMUX_ZIG and needs its own 0.16, as
  # scripts/measure/projection.sh sets it.
  fleet_zig=/Users/Shared/cmux-build-fleet/tools/bin/zig
  vt_zig="${ZIG:-}"
  [[ -z "$vt_zig" && -x "$fleet_zig" ]] && vt_zig="$fleet_zig"
  # A fleet build (CMUX_FLEET_BUILD_TAG) builds acpmux, optchat-chief and
  # cmux-mobile-host on a cache miss and requires them in the bundle.
  set +e
  ZIG="$vt_zig" CMUX_FLEET_BUILD_TAG="$mac_tag" ./scripts/reload.sh --tag "$mac_tag" --derived-data "$mac_dd" \
    --no-global-cli-links >"$work/mac-build.log" 2>&1
  status=$?
  set -e
  cp "$work/mac-build.log" "$out/mac-build.log"
  mac_app="$mac_dd/Build/Products/Debug/cmux DEV $mac_tag.app"
  [[ $status -eq 0 && -d "$mac_app" ]] || { tail -60 "$work/mac-build.log"; echo "error: tagged cmux NEXT Mac app build failed" >&2; exit 1; }
  note "- Mac app: $((SECONDS - t0)) s (reload.sh --tag $mac_tag, Debug)"
  set +e
  python3 -I scripts/ci/cmux_next_pair_e2e.py --mac-app "$mac_app" --ios-app "$app" --sims "$sims" \
    --udid "$udid" --bundle-id "$bundle_id" --work "$work" --out "$out" --summary "$summary" \
    ${pair_upload[@]+"${pair_upload[@]}"}
  pair_status=$?
  set -e
fi

# Cloud proof mode exports an allowlisted receipt only. The ordinary pair-e2e
# mode keeps its existing diagnostics and app artifact. This boundary runs
# after Python teardown, so a Python failure cannot leave raw Cloud captures in
# the public archive; a missing receipt makes the step fail.
if [[ -n "${CMUX_IOS_CLOUD_PROOF_FILE:-}" || "${CMUX_IOS_OWNER_ACCESS_PROOF:-0}" == 1 ]]; then
  python3 -I scripts/ci/cmux_next_cloud_pair_proof.py --export-out "$out" --status "${pair_status:-0}" || pair_status=1
  cat "$out/SUMMARY.md"
  [[ "${pair_status:-0}" -eq 0 ]] || pair_status=1
else
  # The app log goes through the pairing redactor: a pairing link or token it logged never reaches the artifact.
  simctl spawn "$udid" log show --last 10m --style compact --predicate 'process == "CmuxMobileApp"' 2>/dev/null |
    python3 -I scripts/ci/cmux_next_pair_e2e.py --redact > "$out/app-log.txt" || true
  cp "$work/build.log" "$out/build.log" 2>/dev/null || true
  # The app (so the same build runs on another Mac's simulator) and the recordings.
  ditto -c -k --keepParent "$app" "$out/CmuxMobileApp-Demo-simulator.app.zip"
  if [[ "$mode" == handoff ]]; then
    ditto -c -k --keepParent "$device_app" "$out/CmuxMobileApp-Demo-device-unsigned.app.zip"
    python3 -I cmux-next-ios/scripts/handoff_receipt.py manifest "$out/handoff.json" --tag "$handoff_tag" \
      --sha "$(git rev-parse HEAD)" --bundle-id "$bundle_id" --host "$(hostname -s)" \
      --simulator "${device_type##*.} on ${runtime##*.}" --sim-status "$handoff_sim_status" --sim-reason "$handoff_sim_reason"
  fi
  if [[ -d "$work/corpus" ]]; then
    mkdir -p "$out/corpus"
    cp "$work/corpus/"*.typescript "$work/corpus/"*.rate "$out/corpus/" 2>/dev/null || true
  fi
  (cd "$out" && rm -f evidence.zip && zip -qr evidence.zip . -x evidence.zip)
fi
if [[ -z "${CMUX_IOS_CLOUD_PROOF_FILE:-}" && "${CMUX_IOS_OWNER_ACCESS_PROOF:-0}" != 1 ]]; then
  cat "$summary"
fi
if [[ "${test_status:-0}" -ne 0 ]]; then exit "$test_status"; fi
if [[ "${ui_status:-0}" -ne 0 ]]; then exit "$ui_status"; fi
if [[ "${profile_status:-0}" -ne 0 ]]; then exit "$profile_status"; fi
if [[ "${pair_status:-0}" -ne 0 ]]; then exit "$pair_status"; fi
if [[ "${listperf_status:-0}" -ne 0 ]]; then exit "$listperf_status"; fi
if [[ "${energy_status:-0}" -ne 0 ]]; then exit "$energy_status"; fi
if [[ "${clip_status:-0}" -ne 0 ]]; then exit "$clip_status"; fi

if [[ "${perf_status:-0}" -ne 0 ]]; then exit "$perf_status"; fi

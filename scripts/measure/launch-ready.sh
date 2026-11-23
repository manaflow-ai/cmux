#!/usr/bin/env bash
# What a person sees when cmux NEXT opens from the Dock (CMUX-629 "startup time less than 100ms", CMUX-631 "app
# bounces on the dock once when it opens"), timed from outside the app on a fleet Mac's console session:
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/launch-ready.sh --ref <sha> [--arg=dmg=nightly|URL|build] [--arg=base=<sha>] \
#     [--arg=head=<sha>] [--arg=runs=5] [--arg=profile=1] --artifact .build/launch-ready/report.tgz --timeout 3600
#   dmg=nightly  the newest build the NIGHTLY feed offers (default); dmg=https://... one DMG
#   dmg=build    this checkout built as nightly-fresh-launch.sh builds it (a tagged Release app, ad-hoc signed)
#   base=SHA     with dmg=build: SHA built too, its runs interleaved with this checkout's (base 1, head 1, ...)
#                A base that is the head's commit is dropped: the head runs alone (a second copy of the same build
#                in its own home never got a loaded topology at its first launch, so it measured an unseeded app)
#   head=SHA     with dmg=build: build SHA as the head instead of this checkout (a pull request's head: the controller
#                runs this script only at a commit of feat-cmux-next, so an A/B of a PR names it here)
#   dmg=swap     each side a clone of ONE signed nightly with only its executable and resource bundles built Release at
#                the side's commit (head=, else this checkout; base= too when given, or base=nightly for the nightly's
#                own binary), every side re-sealed ad hoc the same way (scripts/measure/swap-nightly.sh). Refused, exit 3,
#                when a commit changes what a swap cannot carry. nightly=URL|sha256:HEX pins that nightly (default newest)
#   runs=N       measured relaunches per side (1 to 10, default 5), after one priming launch
#   session=stress3  before the measured relaunches, each side's home gets a 3-window, 60-workspace session: one more
#                launch after the priming one, in which launch-ready-seed.py opens 3 windows, makes 60 workspaces across
#                them (a terminal each), shows Home in the front window and quits with Keep Sessions (LR-SEED). The
#                default, session=small, measures the priming launch's session (one window on Home).
#   workspaces=N with session=stress3: exactly N workspaces reported by snapshot.get, including Home and the initial
#                windows' workspaces (1 to 200; at least the initial fixture's total). Without it, add 60 as before.
#   windows=N   with session=stress3: use 1 to 3 windows (default 3). windows=1 workspaces=5 and workspaces=120
#                compare workspace count with one window in both fixtures. LR-SEED reports the actual total.
#   profile=1    also record the first measured launch of each side with Instruments' Time Profiler (all processes)
#                and print its main thread from process start to the window on screen (launch-ready-profile.py); its
#                SIDE-run1.samples.json.gz in report.tgz names a nightly's stripped frames offline with --dsym
#   state=bare   every launch, the priming one included, starts with an empty home: nothing to restore, as a fresh
#                install's window after its copy's first exec (the priming launch pays that exec). Default state=kept:
#                the priming launch makes the home's state and every measured launch relaunches into it. With state=bare
#                the probe also opens a terminal once Home takes keys (window_usable): shell_requested, first_shell_live.
#   prerun=S     before each measured launch, one full run of the same copy and home that stays up S seconds after its
#                window shows (1 to 600; 60 for "a launch after a 60 s full run"), then quits as the measured ones do.
#                The time before main differs by case: 30 to 80 ms when launches follow each other closely, 600 to 1170
#                ms when about 60 s have passed since a full run began. Default prerun=0: launches back to back.
#   machines=N   before every launch after the priming one, each side's sidebar snapshot gets N Cloud machine sections
#                with no workspaces (0 to 200; default 0), as a person signed in to Cloud with N machines quits with
#                (launch-ready-machines.py, LR-MACHINES). A fleet Mac has no Cloud sign-in, so its own quits save none.
#   copy=fresh   each measured launch is the first exec of a new copy: just before it, the side's copy is deleted and
#                copied again from the DMG's (new files at the same path, the same code signature), as an update in
#                place leaves it. The home stays. Default copy=same: every launch runs the one copy.
#   labs=KEY     every side's home gets its own settings file, cmux-next.json with labs.KEY=true (the app reads it
#                through CMUX_NEXT_CONFIG_FILE): labs=launchShellFirst with base= measures a Labs toggle's launch against a
#                base without it (a base ignores a key it lacks). The priming launch applies it, so measured ones see it.
#   engines=E[,E2]  with a DMG (not dmg=build): one side per engine (chromium or webkit), named for it, each a copy of the
#                one DMG whose home has its own settings file, cmux-next.json with browser.defaultEngine=E (the app reads
#                it through CMUX_NEXT_CONFIG_FILE). engines=chromium,webkit interleaves Chromium as launch has it now with
#                Chromium not started at launch (AppDelegate starts it only for the chromium engine). After each launch
#                launch-ready-cef.py adds Chromium's start from the app's log (cef.ready, cef.initialize_start,
#                cef.initialize_dur, cef.load_dur, cef.map_dur, cef_started): a release build serves no debug.cef.
#   late=MS      a third side, late: its own copy of the head's DMG and its own home, interleaved after head, whose measured
#                launches wait MS ms (0 to 10000) between the previous launch's quit and their open request. It tells a
#                head cost that comes from overlapping the quit before it from one the head pays anyway. Default 0.
#   layout=1     with dmg=build: both sides built with --config bench (Release optimization with the debug.* commands)
#                and every launch samples its layout from the first on-screen frame (launch-ready.swift `layout`): the
#                window's frame and the sidebar's edge until neither changed for 1 s or 3 s passed. Each LR-RUN row gets
#                `layout`; LR-FRAMES per side: the median and highest move (points) and change count after the first frame.
#   layout=movequit  layout=1 in DEBUG builds (--config debug: sidebar-width is a DEBUG command), and just before every
#                quit the probe moves the window to the other of two frames and the sidebar to the other of two widths,
#                then quits at once: the next launch starts from a record the launch snapshot may lag (row `movequit`).
#                It times nothing a release build pays; read only its LR-FRAMES.

#   type=1       every launch types one key the moment its first window frame is in (the app's LaunchTypeProbe: a space,
#                then Delete, so the line stays as it was) and marks terminal.probe_key_typed, terminal_input_accepted (the
#                key left the app for the restored terminal's PTY) and terminal_echo (its echo came back): with front=tab,
#                launch to the first key echoed in the restored terminal (startup-tti). Needs a build with the probe.
#   preflight=1  just before the first launch, ~10 s of top: a system indexer (launch-ready-preflight.sh's INDEXERS)
#                above preflight_cpu=N % CPU (default 30), or cmux-ci's CMUX_CI_HOST_NOISY=1, fails the step with
#                LR-HOT-HOST and exit 5. preflight=0 skips it.
#   keys=1       each measured launch types into the app from the moment its window shows: one key every 100 ms (a-z
#                then 0-9, 36 at most, posted to the app's pid), 3 more once Home's first page is up and took keys, then
#                Return, and the probe reads the sent message back from the app's daemon. Its row carries first_key_ms
#                (when the earliest key the sent message holds went out, ms from process start), keys_sent, keys_landed
#                and keys_text; LR-KEYS SIDE MEDIAN N/M prints the side's median first_key_ms and how many of its M
#                launches sent a message holding any key. A keys=1 launch opens no terminal (state=bare's shell
#                request moves focus). It takes no front=tab: that launch reopens a terminal, which would take the keys
#                and run them as a command. Default keys=0: no keys.
#   preflight_wait=S  a hot host is checked again every 60 s for up to S s (default 900) before it fails the step: an
#                indexer's batch (mediaanalysisd at 70-200 %) often ends in minutes, and the builds before it took ~20.
#   guest=1      a run on a person's own Mac while they work on it, beside their running NIGHTLY (Leo, 2026-11-20: "why
#                havent breakdowns of startup times ran on my cosmic things"). The copy gets its own bundle id
#                (<id>.launch-ready, re-signed ad hoc with no entitlements, its URL schemes and document types removed,
#                unregistered from LaunchServices at exit; LR-GUEST), so the defaults set aside, cleared and put back
#                are the guest's domain, never the NIGHTLY's; every launch opens without activating and with
#                CMUX_NEXT_NO_ACTIVATE=1 (the app drops every activation and opens its windows behind; no focus taken,
#                `active` stays null); and wait_load is skipped (the caller gates load and idle itself). Takes a DMG
#                (not dmg=build or dmg=swap) and no case=update, copy=fresh, late=, engines=, profile=1 or state=bare.
#                An ad hoc copy's time before main is not a Developer ID copy's: compare guest runs with guest runs.
# Each side gets one copy of the app and one home. The priming launch makes the home's state (a person's second
# launch on), then every measured launch is a relaunch through LaunchServices, activated, as a Dock click is.
# scripts/measure/launch-ready.swift times each one: finished_launching (the Dock's bounce ends), the first
# on-screen window, and the app's own marks. Prints LR-RUN per launch, LR-MEDIAN per side, LR-PROFILE with profile=1.
# Each launch waits (at most 10 min, LR-LOAD-WAIT) until the Mac's 1-minute load is under 8, then its row carries
# load_1m, the load just before it (LR-MEDIAN: the side's highest).
# Each side has its own app defaults (side_defaults, through launch-ready-defaults.py); the account's are set aside for
# the run and put back at its end. A launch that left a launch snapshot path outside its own side's home read the
# other side's state: LR-CROSS-ARM, and the step fails. Each row's front is what the launch had in front just before
# its quit; a measured launch whose front is not its side's previous launch's front did not reopen what was open last
# (Leo, 2026-11-17: "my recently opened thing"): an LR-FAIL row, counted in LR-REOPENED SIDE N/M. The stress3 seed
# writes its own front just before it quits the app. A launch whose previous launch left no readable front is an
# LR-SKIP, outside N/M.
# Restore cases (Leo, 2026-11-18: "fresh startup opening home is obv fine but if it's not first time and the user was
# on a workspace and a tab, obv just take them there"; "ofc reopening home if they were prev on home is fine"): each
# measured launch must land exactly where the person was, Home included. Each case's expectation is one entry of
# EXPECT in launch-ready-summary.py (LR-CASE, LR-REOPENED SIDE N/M):
#   state=fresh  the same as state=bare: no saved state, so Home
#   front=home|tab|chat  with state=kept (and any kept case below): the priming launch's front is made Home (a
#                workspace made, then Home shown), a terminal tab (a workspace made and left in front) or an agent chat
#                tab (palette.newAgentChat in that workspace, left in front) by launch-ready-seed.py --front, and every
#                measured launch must reopen that front: Home, or that (workspace, tab). front=chat is the case where
#                Chromium starts at launch, so launch-ready-cef.py's cef.* marks time it against the first frame. With
#                session=stress3 the stress seed leaves the same front: Home, or its last workspace's terminal tab
#                (front=tab: typing into a restored terminal of a large session, type=1 windows=1 workspaces=120)
#   case=update  with base= (dmg=build): base is the old copy, head the new one, both at head's path with head's home.
#                The priming launch and one launch before each measured one run the old copy (its state, its front);
#                then the copy is replaced by head's, whose first launch is measured (copy=fresh's first exec). It
#                must reopen the old copy's last front. Only head is measured.
#   daemon=cold  before each measured launch the side's kept daemons end, as a reboot ends them (state kept, daemon
#                cold): the launch must still reopen the last front. Default daemon=warm
#   snapshot=unknown  the launch snapshot's front workspace no longer exists in the daemon (same session, same registry
#                id, so not foreign): the priming launch leaves a tab in front (front=tab, the default here); its launch
#                snapshot file (cmuxNext.launchSnapshotPath.<session>) and defaults are kept; one more launch closes that
#                workspace through the control socket (closeWorkspace, launch-ready-seed.py --close-workspace KEY);
#                then, before each measured launch, the kept snapshot and defaults are put back. Expects Home
# Per side: LR-SURFACE SIDE first=<home|tabs> home_page_drawn=N/M, the surface the launches showed first; an A/B whose
# arms differ there prints LR-SURFACE-DIFF ...: not like for like.
set -uo pipefail

main() {
  cd "$(dirname "$0")/../.." || exit 3
  local out="$PWD/.build/launch-ready" dmg=nightly nightly="" base="" headsha="" runs=5 profile=0 session=small workspaces="" windows=3 prerun=0 copy=same machines=0 late=0 engines="" labs="" config=release arg rc=0 i side

  local preflight=1 preflight_cpu=30 preflight_wait=900 waited=0
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  LR_STATE=kept LR_CASE="" LR_DAEMON=warm LR_SNAPSHOT=own LR_FRONT="" LR_KEYS=0 LR_LAYOUT=0 LR_TYPE=0
  # Each side's control socket (SIDE.sock). A socket path must fit sun_path (104 bytes with its NUL), and on a fleet
  # worker "$out/home-SIDE/app.sock" is 112: the app bound no socket there and stress3's seed never got an answer.
  LR_SOCKETS="$(mktemp -d /tmp/lr.XXXXXX)" && chmod 0777 "$LR_SOCKETS" || exit 3
  LR_ASIDE="" LR_GUEST=0 LR_GUEST_APPS=""
  trap 'rm -rf "$LR_SOCKETS"; guest_forget; defaults_restore "$out" || exit 4' EXIT
  for arg in "$@"; do
    case "$arg" in
      dmg=nightly|dmg=build|dmg=swap|dmg=https://*) dmg="${arg#dmg=}" ;;
      nightly=https://*|nightly=sha256:*) nightly="${arg#nightly=}" ;;
      base=*) base="${arg#base=}" ;;
      head=*) headsha="${arg#head=}" ;;
      runs=*) runs="${arg#runs=}" ;;
      profile=0|profile=1) profile="${arg#profile=}" ;;
      state=kept|state=bare) LR_STATE="${arg#state=}" ;;
      state=fresh) LR_STATE=bare ;;
      case=update) LR_CASE=update ;;
      daemon=warm|daemon=cold) LR_DAEMON="${arg#daemon=}" ;;
      snapshot=own|snapshot=unknown) LR_SNAPSHOT="${arg#snapshot=}" ;;
      front=home|front=tab|front=chat) LR_FRONT="${arg#front=}" ;;
      keys=0|keys=1) LR_KEYS="${arg#keys=}" ;;
      session=small|session=stress3) session="${arg#session=}" ;;
      prerun=*) prerun="${arg#prerun=}" ;;
      copy=same|copy=fresh) copy="${arg#copy=}" ;;
      late=*) late="${arg#late=}" ;;
      machines=*) machines="${arg#machines=}" ;;
      workspaces=*) workspaces="${arg#workspaces=}" ;;
      windows=*) windows="${arg#windows=}" ;;
      engines=*) engines="${arg#engines=}" ;;
      labs=*) labs="${arg#labs=}" ;;
      preflight_wait=*) preflight_wait="${arg#preflight_wait=}" ;;
      preflight=0|preflight=1) preflight="${arg#preflight=}" ;;
      preflight_cpu=*) preflight_cpu="${arg#preflight_cpu=}" ;;
      layout=0|layout=1|layout=movequit) LR_LAYOUT="${arg#layout=}" ;;
      guest=0|guest=1) LR_GUEST="${arg#guest=}" ;;
      type=0|type=1) LR_TYPE="${arg#type=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$runs" =~ ^([1-9]|10)$ ]] || { echo "runs= must be 1 to 10" >&2; exit 2; }
  [[ "$LR_LAYOUT" == 0 || "$dmg" == build ]] || { echo "layout= takes dmg=build (the sidebar edge needs a bench or debug build)" >&2; exit 2; }
  [[ "$LR_LAYOUT" == 1 ]] && config=bench
  [[ "$LR_LAYOUT" == movequit ]] && config=debug
  [[ "$machines" =~ ^[0-9]+$ && "$machines" -le 200 ]] || { echo "machines= takes 0 to 200" >&2; exit 2; }
  [[ -z "$workspaces" || ( "$workspaces" =~ ^[1-9][0-9]*$ && "$workspaces" -le 200 ) ]] || { echo "workspaces= takes 1 to 200" >&2; exit 2; }
  [[ "$windows" =~ ^[1-3]$ ]] || { echo "windows= takes 1 to 3" >&2; exit 2; }
  [[ "$session" == stress3 || ( -z "$workspaces" && "$windows" == 3 ) ]] || { echo "workspaces= and windows= size session=stress3" >&2; exit 2; }
  LR_WORKSPACES="$workspaces"
  LR_WINDOWS="$windows"
  [[ "$preflight_cpu" =~ ^[1-9][0-9]*$ ]] || { echo "preflight_cpu= takes a whole percent >= 1" >&2; exit 2; }
  [[ "$preflight_wait" =~ ^[0-9]+$ && "$preflight_wait" -le 3600 ]] || { echo "preflight_wait= takes 0 to 3600 s" >&2; exit 2; }
  [[ "$LR_STATE" == kept || ( "$session" == small && "$machines" == 0 ) ]] \
    || { echo "state=bare empties the home before each launch: it takes no session=$session or machines=$machines" >&2; exit 2; }
  [[ "$prerun" =~ ^[0-9]+$ && "$prerun" -le 600 ]] || { echo "prerun= takes 0 to 600 seconds" >&2; exit 2; }
  [[ "$late" =~ ^[0-9]+$ && "$late" -le 10000 ]] || { echo "late= takes 0 to 10000 ms" >&2; exit 2; }
  LR_LATE="$late"
  [[ -z "$base" || ( "$dmg" =~ ^(build|swap)$ && "$base" =~ ^[0-9a-f]{40}$ ) || "$dmg:$base" == swap:nightly ]] \
    || { echo "base= takes a 40-hex commit, with dmg=build or dmg=swap (or nightly, with dmg=swap)" >&2; exit 2; }
  [[ -z "$headsha" || ( "$dmg" =~ ^(build|swap)$ && "$headsha" =~ ^[0-9a-f]{40}$ ) ]] || { echo "head= takes a 40-hex commit, with dmg=build or dmg=swap" >&2; exit 2; }
  [[ -z "$labs" || ( -z "$engines" && "$labs" =~ ^[A-Za-z][A-Za-z0-9]{0,63}$ ) ]] \
    || { echo "labs= takes one Labs setting key (letters and digits), without engines=" >&2; exit 2; }
  [[ -z "$engines" || "$late" == 0 ]] || { echo "engines= takes no late= (the late side would have no engine of its own)" >&2; exit 2; }
  [[ -z "$engines" || ( ! "$dmg" =~ ^(build|swap)$ && "$engines" =~ ^(chromium|webkit)(,(chromium|webkit))?$ && "$engines" != chromium,chromium && "$engines" != webkit,webkit ) ]] \
    || { echo "engines= takes chromium, webkit or both (comma), with a DMG (not dmg=build or dmg=swap)" >&2; exit 2; }
  case_args_ok "$base" "$session" || exit 2
  guest_args_ok "$dmg" "$copy" "$late" "$engines" "$profile" || exit 2
  if [[ "$LR_SNAPSHOT" == unknown ]]; then LR_FRONT=tab; fi # the workspace closed is the priming launch's front tab's
  echo "LR state $LR_STATE"
  echo "LR case case=${LR_CASE:-none} daemon=$LR_DAEMON snapshot=$LR_SNAPSHOT front=${LR_FRONT:-as-left}"
  [[ "$LR_KEYS" == 0 ]] || echo "LR keys 1: one key per 100 ms from the window, then Return, read back from the daemon"
  echo "LR host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  # Everything this run reads from the checkout is compiled or copied now: the builds below check out other commits.
  xcrun swiftc -O -o "$out/launch-ready" scripts/measure/launch-ready.swift >"$out/swiftc.log" 2>&1 \
    || { echo "LR probe build failed"; cat "$out/swiftc.log"; exit 3; }
  cp scripts/measure/launch-ready-profile.py "$out/profile.py"
  cp scripts/measure/launch-ready-seed.py "$out/seed.py"
  cp scripts/measure/launch-ready-machines.py "$out/machines.py"
  cp scripts/measure/launch-ready-defaults.py "$out/defaults.py"
  cp scripts/measure/launch-ready-preflight.sh "$out/preflight.sh"

  cp scripts/measure/launch-ready-summary.py "$out/summary.py"
  cp scripts/ci/fresh_home_launch_smoke.py "$out/fresh_home_launch_smoke.py"
  cp scripts/measure/launch-ready-cef.py "$out/cef.py"
  echo "LR session $session workspaces ${workspaces:-add60} windows $windows prerun $prerun copy $copy machines $machines engines ${engines:-none}"
  local sides=(head)
  if [[ -n "$engines" ]]; then
    IFS=, read -r -a sides <<<"$engines"
    for side in "${sides[@]}"; do
      mkdir -p "$out/home-$side" && chmod 0777 "$out/home-$side"
      printf '{"browser": {"defaultEngine": "%s"}}\n' "$side" >"$out/home-$side/cmux-next.json" && chmod 0666 "$out/home-$side/cmux-next.json" || exit 3
    done
  fi
  if [[ -n "$labs" ]]; then echo "LR labs $labs=true"; fi
  if [[ "$dmg" == swap ]]; then
    source scripts/measure/swap-nightly.sh
    swap_nightly "$out" "$nightly" ${base:+base="$base"} head="${headsha:-$(git rev-parse HEAD)}" || exit 3
    [[ -z "$base" ]] || sides=(base head)
  elif [[ "$dmg" == build ]]; then
    # nightly-fresh-launch.sh's build_dmg, without running its main. From a file: macOS's bash 3.2 sources nothing
    # from a process substitution.
    sed '/^main "\$@"; exit \$?$/d' scripts/measure/nightly-fresh-launch.sh >"$out/nightly-fresh-launch-lib.sh"
    source "$out/nightly-fresh-launch-lib.sh"
    declare -F build_dmg >/dev/null || { echo "LR build_dmg missing from nightly-fresh-launch.sh"; exit 3; }
    # build_dmg resolves each side's acpmux with this copy: a base commit may predate resolve-acpmux.sh. Each side's
    # Screen Sharing helper phase runs this copy too (NFL_SCREEN_HELPER_PHASE).
    cp scripts/cmux-next/resolve-acpmux.sh "$out/resolve-acpmux.sh" && export NFL_RESOLVE_ACPMUX="$out/resolve-acpmux.sh"
    cp scripts/cmux-next/bundle-screen-sharing-helper.sh "$out/bundle-screen-sharing-helper.sh" \
      && export NFL_SCREEN_HELPER_PHASE="$out/bundle-screen-sharing-helper.sh"
    local here; here="$(git rev-parse HEAD)"
    local head="${headsha:-$here}" want
    for want in $base $head; do
      git cat-file -e "$want^{commit}" 2>/dev/null \
        || git fetch --quiet --recurse-submodules=no https://github.com/manaflow-ai/cmux.git "$want" || { echo "LR cannot fetch $want"; exit 3; }
    done
    if [[ -n "$base" && "$LR_CASE" != update && "$(git rev-parse "$base^{commit}")" == "$(git rev-parse "$head^{commit}")" ]]; then
      echo "LR one build: base is head ($head), so the head runs alone"
      base=""
    fi
    if [[ -n "$base" ]]; then
      git -c advice.detachedHead=false checkout --quiet --detach "$base" || exit 3
      build_dmg "$out" base "$config"; rc=$?
      [[ $rc == 0 ]] || { git -c advice.detachedHead=false checkout --quiet --detach "$here"; exit "$rc"; }
      sides=(base head)
    fi
    git -c advice.detachedHead=false checkout --quiet --detach "$head" || exit 3
    build_dmg "$out" head "$config"; rc=$?
    git -c advice.detachedHead=false checkout --quiet --detach "$here" || exit 3
    [[ $rc == 0 ]] || exit "$rc"
  else
    if [[ "$dmg" == nightly ]]; then
      dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
        | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
    fi
    [[ "$dmg" == https://* ]] || { echo "LR no nightly DMG in the feed"; exit 3; }
    echo "LR dmg $dmg"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-ready/1 -o "$out/head.dmg" "$dmg" || { echo "LR download failed"; exit 3; }
  fi
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  [[ "$late" == 0 ]] || sides+=(late)

  # A system indexer busy now (mediaanalysisd, Spotlight) voids every launch: fail in ~10 s, not after the run.
  if [[ "$preflight" == 1 ]]; then
    until bash "$out/preflight.sh" "$preflight_cpu"; do
      (( waited + 60 <= preflight_wait )) || { echo "LR-FAIL hot host: a system indexer above ${preflight_cpu}% CPU or cmux-ci's noisy mark, still after ${waited} s (preflight=0 skips this check)"; exit 5; }
      sleep 60 # a bounded wait (preflight_wait) for the indexer's batch to end
      waited=$((waited + 60)); echo "LR-PREFLIGHT waited ${waited} s"
    done
  fi
  for side in "${sides[@]}"; do
    local mount="$out/mnt-$side" image="$side"
    [[ "$side" != late && -z "$engines" ]] || image=head # the late side, and every engines= side, runs the head's DMG
    mkdir -p "$mount" "$out/$side"
    if [[ -n "$labs" ]]; then
      mkdir -p "$out/home-$side" && chmod 0777 "$out/home-$side"
      printf '{"labs": {"%s": true}}\n' "$labs" >"$out/home-$side/cmux-next.json" && chmod 0666 "$out/home-$side/cmux-next.json" || exit 3
    fi
    local found
    if [[ "$dmg" == swap ]]; then
      found="$(find "$out/swap-$image" -maxdepth 1 -name '*.app' | head -1)" # swap_nightly's sealed copy
    else
      hdiutil attach "$out/$image.dmg" -nobrowse -readonly -mountpoint "$mount" >/dev/null || { echo "LR attach $side failed"; exit 3; }
      found="$(find "$mount" -maxdepth 1 -name '*.app' | head -1)"
    fi
    ditto "$found" "$out/$side/$(basename "$found")" || exit 3
    if [[ "$copy" == fresh || "$LR_CASE" == update ]]; then mkdir -p "$out/$side-dmg" && ditto "$found" "$out/$side-dmg/$(basename "$found")" || exit 3; fi
    [[ "$dmg" == swap ]] || hdiutil detach "$mount" >/dev/null || hdiutil detach -force "$mount" >/dev/null
    # guest=1: the copy's own bundle id before anything reads it (LR app, sign_line, defaults_aside, side_defaults).
    if [[ "$LR_GUEST" == 1 ]]; then guest_copy "$out" "$side" "$out/$side/$(basename "$found")" || exit 3; fi
    local info="$out/$side/$(basename "$found")/Contents/Info.plist"
    [[ -f "$info" ]] || { echo "LR-FAIL $side $(basename "$found") has no Contents/Info.plist"; exit 3; }
    echo "LR app $side $(basename "$found") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info" 2>/dev/null)"
    sign_line "$side" "$out/$side/$(basename "$found")"
    defaults_aside "$out" "$out/$side/$(basename "$found")" || { echo "LR-FAIL $side defaults not set aside"; exit 3; }
    if [[ "$LR_CASE" == update && "$side" == base ]]; then continue; fi # the old copy: launched at head's path below
    if [[ "$LR_CASE" == update ]]; then old_copy "$out" "$side" || rc=1; fi
    if [[ -n "$LR_FRONT" ]]; then front_prime "$out" "$side" || rc=1; else probe "$out" "$side" prime 10 0 || rc=1; fi
    if [[ "$session" == stress3 ]]; then seed "$out" "$side" || rc=1; fi
    if [[ "$LR_SNAPSHOT" == unknown ]]; then unknown_seed "$out" "$side" || rc=1; fi
  done
  if [[ "$LR_CASE" == update ]]; then sides=(head); fi
  for ((i = 1; i <= runs; i++)); do
    for side in "${sides[@]}"; do
      if [[ "$prerun" != 0 ]]; then probe "$out" "$side" "full$i" "$prerun" 0 || rc=1; fi
      if [[ "$LR_CASE" == update ]]; then
        old_copy "$out" "$side" && probe "$out" "$side" "old$i" 6 0 || rc=1
      fi
      if [[ "$copy" == fresh || "$LR_CASE" == update ]]; then fresh_copy "$out" "$side" "$i" || rc=1; fi
      if [[ "$LR_SNAPSHOT" == unknown ]]; then unknown_restore "$out" "$side" || rc=1; fi
      probe "$out" "$side" "run$i" 6 "$([[ $profile == 1 && $i == 1 ]] && echo 1 || echo 0)" || rc=1
    done
  done
  # Every process a launch left (the daemons a quit keeps): only ones started from this run's copies.
  end_left "$out/"
  # Each case's expectation, LR-REOPENED, LR-SURFACE and LR-SURFACE-DIFF: launch-ready-summary.py.
  python3 -I "$out/summary.py" "$out/runs.jsonl" --state "$LR_STATE" --case "$LR_CASE" --daemon "$LR_DAEMON" \
    --snapshot "$LR_SNAPSHOT" --front "$LR_FRONT" --keys "$LR_KEYS" --out "$out"
  tar -czf "$out.tgz" -C "$out" --exclude '*.dmg' --exclude '*.app' --exclude '*.trace' . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

# sign_line SIDE APP: LR-SIGN, how SIDE's copy is signed (codesign: signature, flags, team, first authority) and what
# Gatekeeper says of it (spctl's source), the checks a launch before main may wait on.
sign_line() {
  local cs gk
  cs="$(codesign -dv --verbose=2 "$2" 2>&1 | awk -F= '/^Signature=|^CodeDirectory|^TeamIdentifier=|^Authority=/ {
    if ($1 == "Authority" && seen++) next; sub(/^CodeDirectory v=[^ ]* size=[^ ]* /, "", $0); printf "%s; ", $0 }')"
  gk="$(spctl -a -vv -t exec "$2" 2>&1 | awk '/source=/ { sub(/.*source=/, ""); print; exit } /rejected/ { print "rejected"; exit }')"
  echo "LR-SIGN $1 ${cs:-no codesign output}gatekeeper=${gk:-unknown}"
}

# checker_cpu: the CPU ms so far of the processes that check code before it runs; checker_delta BEFORE AFTER: each
# one's ms between the two readings (a launch's checks, plus whatever else they did in those seconds).
checker_cpu() {
  ps -axo time=,comm= | awk '{ n = $NF; sub(".*/", "", n); k = split($1, t, ":"); s = 0
    for (i = 1; i <= k; i++) s = s * 60 + t[i]
    if (n == "syspolicyd" || n == "XprotectService" || n == "amfid" || n == "trustd" || n == "taskgated") c[n] += s * 1000 }
    END { printf "%d %d %d %d %d", c["syspolicyd"], c["XprotectService"], c["amfid"], c["trustd"], c["taskgated"] }'
}
checker_delta() {
  awk -v b="$1" -v a="$2" 'BEGIN { split(b, x, " "); split(a, y, " ")
    printf "syspolicyd_ms=%d xprotect_ms=%d amfid_ms=%d trustd_ms=%d taskgated_ms=%d", y[1]-x[1], y[2]-x[2], y[3]-x[3], y[4]-x[4], y[5]-x[5] }'
}

# exe_stat APP: the main executable's hard-link count and ctime ("links:ctime"); a launch that changes either
# (a code-sign clone that hard-links it) is what makes the checkers scan it again before the next launch.
exe_stat() {
  local name
  name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist" 2>/dev/null)"
  stat -f '%l:%c' "$1/Contents/MacOS/$name" 2>/dev/null || echo unknown
}

# probe OUT SIDE LABEL SETTLE_S PROFILE: one launch of SIDE's copy with SIDE's home, in the console session; with
# PROFILE 1 under an all-processes Time Profiler recording.
probe() {
  local out="$1" side="$2" label="$3" settle="$4" profile="$5" app line load recorder="" trace cross checkers exe
  trace="$out/$side-$label.trace" # its own line: bash 3.2 expands a `local` line's words before it assigns any
  app="$(find "$out/$side" -maxdepth 1 -name '*.app' | head -1)"
  mkdir -p "$out/home-$side" && chmod 0777 "$out/home-$side"
  if [[ "${machines:-0}" != 0 && "$label" != prime ]]; then
    # As the console user, as the app: it saves the snapshot owner-only (folder 0700, file 0600).
    GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$out/machines.py" "$out/home-$side" "$machines" \
      | sed "s/^LR-MACHINES /LR-MACHINES $side $label /"
    [[ "${PIPESTATUS[0]}" == 0 ]] || { echo "LR-FAIL $side $label no sidebar snapshot to seed machines into"; return 1; }
  fi
  quiesce "$app" "$side" "$label"
  # state=bare: the launch finds no daemon (the ones the last launch kept end first, as daemon=cold ends them: a kept
  # daemon survived the emptied home, and the next launch's ensure found it, so it never showed Home's first page), an
  # empty home (launch-ready.swift makes its folders again) and empty defaults (no defaults.plist, so the load leaves
  # the side's domain clear). Only this run's own copy's processes and home.
  if [[ "$LR_STATE" == bare ]]; then
    cold_daemon "$out" "$side" "$label" | sed 's/^LR-COLD /LR-BARE-STOP /'
    rm -rf "$out/home-$side/h" "$out/home-$side/t" "$out/home-$side/defaults.plist"
  fi
  side_defaults "$out" load "$app" "$out/home-$side/defaults.plist" \
    || { echo "LR-FAIL $side $label defaults not loaded"; return 1; }
  # daemon=cold: a measured launch finds no daemon running.
  if [[ "$label" == run* && "${LR_DAEMON:-warm}" == cold ]]; then
    cold_daemon "$out" "$side" "$label" || return 1
  fi
  [[ "${LR_GUEST:-0}" == 1 ]] || wait_load "$side" "$label" # guest=1: the caller gates load (and idle) itself
  load="$(load_1m)"
  if [[ "$profile" == 1 ]]; then
    local log_from
    log_from=$(($(wc -c <"$out/xctrace.log" 2>/dev/null || echo 0) + 1))
    xcrun xctrace record --template 'Time Profiler' --all-processes --time-limit 15s --output "$trace" --no-prompt \
      >>"$out/xctrace.log" 2>&1 &
    recorder=$!
    # Until this recorder says it is recording ("Starting recording"), 30 s; or it exited (no profile, said below).
    for _ in $(seq 1 300); do
      tail -c "+$log_from" "$out/xctrace.log" 2>/dev/null | grep -q 'Starting recording' && break
      kill -0 "$recorder" 2>/dev/null || break
      sleep 0.1
    done
    tail -c "+$log_from" "$out/xctrace.log" 2>/dev/null | grep -q 'Starting recording' \
      || echo "LR-PROFILE $side $label xctrace did not report recording within 30 s"
  fi
  if [[ "$side" == late && "$label" == run* ]]; then
    sleep "$(awk -v ms="${LR_LATE:-0}" 'BEGIN { printf "%.3f", ms / 1000 }')" # late=MS, just before the open request
  fi
  checkers="$(checker_cpu)" exe="$(exe_stat "$app")"
  line="$(GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$out/launch-ready" "$app" "$out/home-$side" "$label" "$settle" "$LR_SOCKETS/$side.sock" \
    $(probe_mode "$label") $([[ "$LR_LAYOUT" != 0 ]] && echo layout) $([[ "$LR_LAYOUT" == movequit ]] && echo movequit) \
    $([[ "$LR_TYPE" == 1 ]] && echo type) $([[ "${LR_GUEST:-0}" == 1 ]] && echo guest) 2>>"$out/probe.log" | grep '^LR-RUN ')"
  checkers="$(checker_delta "$checkers" "$(checker_cpu)") exe=$exe->$(exe_stat "$app")"
  # Every launch snapshot path the launch left must be in its own home: one in the other side's means it read that.
  # Unsaved defaults fail the same way, and the stale copy goes: the side's next launch starts empty, not from it.
  if side_defaults "$out" save "$app" "$out/home-$side/defaults.plist"; then
    cross="$(python3 -I "$out/defaults.py" check "$out/home-$side/defaults.plist" "$out/home-$side/")"
  else
    rm -f "$out/home-$side/defaults.plist"
    cross='{"defaults_not_saved": true}'
  fi
  if [[ -n "$recorder" ]]; then
    kill -INT "$recorder" 2>/dev/null; wait "$recorder" 2>/dev/null
  fi
  [[ -n "$line" ]] || { echo "LR-RUN $side $label no result"; return 1; }
  # engines=: Chromium's start, from the app's log, added to the row's marks (launch-ready-cef.py).
  if [[ -n "$engines" && -f "$out/home-$side/cmux-next.json" ]]; then
    local withcef
    withcef="$(echo "${line#LR-RUN }" | python3 -I "$out/cef.py" 2>>"$out/cef.log")" && [[ -n "$withcef" ]] && line="LR-RUN $withcef"
  fi
  echo "$line" | sed "s/^LR-RUN /LR-RUN $side /"
  echo "LR-LOAD $side $label load_1m=$load"
  echo "LR-CHECKERS $side $label $checkers"
  echo "${line#LR-RUN }" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); r["side"]=sys.argv[1]; r["load_1m"]=float(sys.argv[2]) if sys.argv[2] else None; r.update({"cross_arm": json.loads(sys.argv[3])} if sys.argv[3] else {}); print(json.dumps(r))' "$side" "$load" "$cross" >>"$out/runs.jsonl"
  if [[ -n "$recorder" && -d "$trace" ]]; then
    python3 -I "$out/profile.py" "$trace" "${line#LR-RUN }" "$side" 2>>"$out/xctrace.log" || echo "LR-PROFILE $side no profile (xctrace.log)"
  fi
  [[ -z "$cross" ]] || { echo "LR-CROSS-ARM $side $label $cross"; return 1; }
  [[ "$line" != *'"error"'* ]]
}

# probe_mode LABEL: the probe's last argument. keys=1 types into a measured launch (runN: keys) and opens no terminal;
# else state=bare opens one (shell).
probe_mode() {
  if [[ "${LR_KEYS:-0}" == 1 ]]; then
    if [[ "$1" == run* ]]; then echo keys; fi
  elif [[ "$LR_STATE" == bare ]]; then
    echo shell
  fi
}

# seed OUT SIDE: one more launch of SIDE's copy with SIDE's home, in which launch-ready-seed.py makes the stress3
# session and quits with Keep Sessions. The probe ends when the app does; its 600 s settle is only a backstop.
seed() {
  local out="$1" side="$2" launch status probed
  local seed_args=(--windows "${LR_WINDOWS:-3}" --front "${LR_FRONT:-home}") # front=tab: the last workspace's tab
  if [[ -n "${LR_WORKSPACES:-}" ]]; then seed_args+=(--total-workspaces "$LR_WORKSPACES"); fi
  rm -f "$LR_SOCKETS/$side.sock" # the priming launch's: the seed waits for this launch's own socket
  probe "$out" "$side" seed 600 0 >"$out/seed-$side.probe" &
  launch=$!
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$out/seed.py" "$LR_SOCKETS/$side.sock" \
    "${seed_args[@]}" --front-out "$out/seed-$side.front.json" 2>>"$out/seed.log" | sed "s/^LR-SEED /LR-SEED $side /"
  status=${PIPESTATUS[0]}
  wait "$launch"; probed=$?
  cat "$out/seed-$side.probe"
  [[ "$status" == 0 && "$probed" == 0 ]]
}

# quiesce APP SIDE LABEL: before a launch, wait until no process of APP's previous run is left (the app and its
# Chromium helpers: anything running from APP/Contents/MacOS or APP/Contents/Frameworks), at most 60 s, then 2 s
# more. The probe returns once the app's own pid exits; without this wait the next launch started while that copy's
# helpers were still tearing down, and every number counted it. The daemons in Contents/Resources/bin are left
# alone: a quit keeps them by design, so a person's relaunch finds them running too. Prints LR-SETTLE.
quiesce() {
  local app="$1" side="$2" label="$3" started now left waited
  started="$(python3 -I -c 'import time; print(int(time.time() * 1000))')"
  while :; do
    left="$(quiesce_left "$app")"
    now="$(python3 -I -c 'import time; print(int(time.time() * 1000))')"
    waited=$((now - started))
    [[ "$left" == 0 || "$waited" -ge 60000 ]] && break
    sleep 0.1
  done
  sleep 2  # sleep-ok: the bench's fixed cool-down between launches, the same on both sides (reported as settle_s=2)
  echo "LR-SETTLE $side $label waited_ms=$waited left=$left settle_s=2"
}

# side_defaults load|save APP PLIST: each side keeps its own app defaults. Both sides share one bundle id, and
# cfprefsd keeps an app's defaults in the console user's real ~/Library/Preferences whatever HOME and
# CFFIXED_USER_HOME say, so cmuxNext.launchSnapshotPath.<session> pointed each launch at the launch snapshot the
# other side wrote last: head's first launch adopted base's Home, then made a workspace of its own, and every
# prerun=60 relaunch of either side opened what the other side had left (cmux#44204's A/B). load clears the
# bundle's defaults (failing unless they read back empty) and imports PLIST when the side has one; save exports them
# to PLIST. Through OUT/defaults.py (launch-ready-defaults.py, on DefaultsAside), as the app's user.
side_defaults() {
  local out="$1" verb="$2" app="$3" plist="$4" bundle
  bundle="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" || return 1
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$out/defaults.py" "$verb" "$bundle" "$plist"
}

# defaults_aside OUT APP: the first time a run meets APP's bundle id, the account's defaults for it are set aside (a
# copy a killed run left is put back first). defaults_restore OUT, at exit, puts each one back.
defaults_aside() {
  local out="$1" bundle
  bundle="$(plutil -extract CFBundleIdentifier raw -o - "$2/Contents/Info.plist")" || return 1
  case " $LR_ASIDE " in *" $bundle "*) return 0 ;; esac
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$out/defaults.py" aside "$bundle" || return 1
  LR_ASIDE="$LR_ASIDE $bundle"
}

# Any domain not put back fails the step (the trap exits 4); its copy stays beside the lock for the next run.
defaults_restore() {
  local out="$1" bundle failed=0
  for bundle in $LR_ASIDE; do
    GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$out/defaults.py" restore "$bundle" \
      || { echo "LR-FAIL $bundle defaults not put back: they stay set aside for the next run to put back"; failed=1; }
  done
  return "$failed"
}

# fresh_copy OUT SIDE N: SIDE's copy deleted, once its processes are gone, and copied again from the DMG's.
fresh_copy() {
  local out="$1" side="$2" app name
  app="$(find "$out/$side" -maxdepth 1 -name '*.app' | head -1)"
  name="$(basename "$(find "$out/$side-dmg" -maxdepth 1 -name '*.app' | head -1)")" # case=update: the old copy's may differ
  quiesce "$app" "$side" "copy$3" >/dev/null
  rm -rf "$app" && ditto "$out/$side-dmg/$name" "$out/$side/$name"
}

# old_copy OUT SIDE: case=update's old copy: SIDE's copy replaced, once its processes are gone, by base's (from
# base-dmg) at the same folder, so the next launch runs the old build with SIDE's home, as before an update in place.
old_copy() {
  local out="$1" side="$2" app old
  app="$(find "$out/$side" -maxdepth 1 -name '*.app' | head -1)"
  old="$(find "$out/base-dmg" -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "$old" ]] || { echo "LR-FAIL $side case=update has no old copy"; return 1; }
  if [[ -n "$app" ]]; then quiesce "$app" "$side" old >/dev/null && rm -rf "$app"; fi
  ditto "$old" "$out/$side/$(basename "$old")"
}

# front_prime OUT SIDE: front=home|tab's priming launch. launch-ready-seed.py --front makes one workspace (a terminal
# in front) and, for home, shows Home, without quitting; the probe reads that front at its quit, and every measured
# launch is judged against it (launch-ready-summary.py). The 20 s settle leaves the seed its time after the window.
front_prime() {
  local out="$1" side="$2" launch status probed
  rm -f "$LR_SOCKETS/$side.sock"
  probe "$out" "$side" prime 20 0 >"$out/prime-$side.probe" &
  launch=$!
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$out/seed.py" "$LR_SOCKETS/$side.sock" \
    --windows 1 --workspaces 1 --front "$LR_FRONT" --stay 2>>"$out/seed.log" | sed "s/^LR-SEED /LR-FRONT $side /"
  status=${PIPESTATUS[0]}
  wait "$launch"; probed=$?
  cat "$out/prime-$side.probe"
  [[ "$status" == 0 && "$probed" == 0 ]]
}

# cold_daemon OUT SIDE LABEL: daemon=cold: every process still running from SIDE's copy (the daemons a quit keeps)
# ends, TERM then KILL after 10 s, as a reboot ends them. Prints LR-COLD. Only this run's copy: the path reaches awk
# through ENVIRON, as in quiesce_left.
cold_daemon() {
  local out="$1" side="$2" pids n=0
  end_left "$out/$side/"; pids="$LR_LEFT"
  if [[ -n "$pids" ]]; then
    n="$(echo "$pids" | wc -l | tr -d ' ')"
    for _ in $(seq 100); do ps -p "$(echo $pids | tr ' ' ,)" >/dev/null || break; sleep 0.1; done
    end_left "$out/$side/" KILL
  fi
  echo "LR-COLD $side $3 stopped=$n"
}

# end_left DIR [SIG]: SIG (TERM by default) to every process started from DIR, one of this run's copies, and nothing
# else; the path reaches awk through ENVIRON, as in quiesce_left. LR_LEFT holds the pids it signalled. The one kill in
# this script (the fleet rule lint allowlists one): a lookup by this run's own path, not by a name.
end_left() {
  LR_LEFT="$(ps -axo pid=,command= | LR_DIR="$1" awk 'index($0, ENVIRON["LR_DIR"]) { print $1 }')"
  if [[ -n "$LR_LEFT" ]]; then kill -"${2:-TERM}" $LR_LEFT 2>/dev/null; fi
  return 0
}

# unknown_seed OUT SIDE: snapshot=unknown's state. The priming launch left a tab in front of workspace KEY (its row's
# front). Its launch snapshot file (the defaults' cmuxNext.launchSnapshotPath.<session>) and SIDE's defaults plist are
# kept beside the home; one more launch (label forget) closes KEY through the control socket and stays up until the
# probe quits it; then unknown_restore puts the kept files back: the snapshot names KEY, with the same session and
# registry id, and the daemon no longer has it. As the console user: the app saves the snapshot owner-only.
unknown_seed() {
  local out="$1" side="$2" key snap launch status probed
  key="$(python3 -I -c 'import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(next(((r.get("front") or {}).get("workspace") or "" for r in reversed(rows) if r["side"] == sys.argv[2] and r["label"] == "prime"), ""))' \
    "$out/runs.jsonl" "$side")"
  snap="$(launch_snapshot_path "$out/home-$side/defaults.plist")"
  [[ -n "$key" && -n "$snap" ]] || { echo "LR-FAIL $side snapshot=unknown: no front workspace ($key) or launch snapshot ($snap)"; return 1; }
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh /bin/cp -p "$snap" "$out/home-$side/unknown-snapshot.keep" || return 1
  cp -p "$out/home-$side/defaults.plist" "$out/home-$side/unknown-defaults.keep" || return 1
  printf '%s\n' "$snap" >"$out/home-$side/unknown-snapshot.path"
  rm -f "$LR_SOCKETS/$side.sock"
  probe "$out" "$side" forget 20 0 >"$out/forget-$side.probe" &
  launch=$!
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$out/seed.py" "$LR_SOCKETS/$side.sock" \
    --close-workspace "$key" --stay 2>>"$out/seed.log" | sed "s/^LR-SEED /LR-UNKNOWN $side /"
  status=${PIPESTATUS[0]}
  wait "$launch"; probed=$?
  cat "$out/forget-$side.probe"
  unknown_restore "$out" "$side" && [[ "$status" == 0 && "$probed" == 0 ]]
}

# unknown_restore OUT SIDE: puts unknown_seed's kept launch snapshot and defaults back, before each measured launch.
unknown_restore() {
  local out="$1" side="$2" snap
  snap="$(cat "$out/home-$side/unknown-snapshot.path" 2>/dev/null)"
  [[ -n "$snap" ]] || { echo "LR-FAIL $side snapshot=unknown has no kept snapshot"; return 1; }
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh /bin/cp -p "$out/home-$side/unknown-snapshot.keep" "$snap" \
    && cp -p "$out/home-$side/unknown-defaults.keep" "$out/home-$side/defaults.plist"
}

# launch_snapshot_path PLIST: the value of the defaults plist's cmuxNext.launchSnapshotPath.<session> key, or nothing.
launch_snapshot_path() {
  python3 -I -c 'import plistlib, sys
try:
    data = plistlib.load(open(sys.argv[1], "rb"))
except (OSError, ValueError):
    data = {}
print(next((v for k, v in data.items() if k.startswith("cmuxNext.launchSnapshotPath.") and isinstance(v, str)), ""))' "$1"
}

# guest_args_ok DMG COPY LATE ENGINES PROFILE: guest=1 (LR_GUEST) takes one DMG copy per side that it can rename before
# anything reads it, and nothing that would make another copy, record every process on the person's Mac or build there.
guest_args_ok() {
  [[ "${LR_GUEST:-0}" == 1 ]] || return 0
  if [[ "$1" == build || "$1" == swap ]]; then echo "guest=1 takes a DMG (dmg=nightly or a URL), not dmg=$1: no build runs on a person's Mac" >&2; return 1; fi
  if [[ "$LR_CASE" == update || "$2" == fresh ]]; then echo "guest=1 takes no case=update or copy=fresh: each copy from the DMG would keep the NIGHTLY's bundle id" >&2; return 1; fi
  if [[ "$3" != 0 || -n "$4" ]]; then echo "guest=1 takes no late= or engines=: one side, one renamed copy" >&2; return 1; fi
  if [[ "$5" == 1 ]]; then echo "guest=1 takes no profile=1: an all-processes recording of a person's Mac" >&2; return 1; fi
  if [[ "$LR_STATE" == bare ]]; then echo "guest=1 takes no state=bare or state=fresh: a window that never takes focus never becomes key, so Home never marks window_usable and no terminal opens" >&2; return 1; fi
  if [[ "${LR_KEYS:-0}" == 1 ]]; then echo "guest=1 takes no keys=1: it posts key events to a window that never becomes key (type=1 types inside the app and is fine)" >&2; return 1; fi
  return 0
}

# guest_copy OUT SIDE APP: guest=1's copy made its own app: CFBundleIdentifier <id>.launch-ready (so cfprefsd's domain,
# the one defaults_aside and side_defaults clear and fill, is not the person's running NIGHTLY's), no URL schemes,
# document types, exported types or services (LaunchServices could hand the person's cmux links to it), and an ad hoc
# signature with no entitlements (the edited Info.plist breaks the Developer ID seal; a restricted entitlement would
# not launch ad hoc). Prints LR-GUEST.
guest_copy() {
  local out="$1" side="$2" app="$3" info="$3/Contents/Info.plist" id key
  id="$(plutil -extract CFBundleIdentifier raw -o - "$info")" || return 1
  [[ "$id" == *.launch-ready ]] || id="$id.launch-ready"
  plutil -replace CFBundleIdentifier -string "$id" "$info" || return 1
  for key in CFBundleURLTypes CFBundleDocumentTypes UTExportedTypeDeclarations NSServices; do
    plutil -remove "$key" "$info" 2>/dev/null || true # absent is fine
  done
  codesign --force --deep --sign - "$app" >>"$out/guest.log" 2>&1 || { echo "LR-FAIL $side guest copy not re-signed (guest.log)"; return 1; }
  LR_GUEST_APPS="${LR_GUEST_APPS:-}$app"$'\n'
  echo "LR-GUEST $side bundle=$id signed=adhoc"
}

# guest_forget: at exit, each guest copy unregistered from LaunchServices, so no record of it outlives the run.
guest_forget() {
  local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister app
  [[ -n "${LR_GUEST_APPS:-}" && -x "$lsregister" ]] || return 0
  while IFS= read -r app; do
    [[ -z "$app" ]] || "$lsregister" -u "$app" >/dev/null 2>&1 || true
  done <<<"$LR_GUEST_APPS"
  return 0
}

# case_args_ok BASE SESSION: the restore case arguments (LR_STATE, LR_CASE, LR_DAEMON, LR_SNAPSHOT, LR_FRONT) and
# LR_KEYS combine.
case_args_ok() {
  if [[ "$LR_STATE" == bare && ( -n "$LR_CASE" || "$LR_DAEMON" == cold || "$LR_SNAPSHOT" != own || -n "$LR_FRONT" ) ]]; then
    echo "state=fresh (bare) has no saved state: it takes no case=, daemon=cold, snapshot= or front=" >&2; return 1
  fi
  [[ "$LR_CASE" != update || -n "$1" ]] || { echo "case=update needs base= (the old copy), with dmg=build" >&2; return 1; }
  [[ "$LR_SNAPSHOT" != unknown || ( "$LR_FRONT" != home && "$2" == small ) ]] \
    || { echo "snapshot=unknown closes the front tab's workspace: it takes no front=home or session=$2" >&2; return 1; }
  # keys=1 types into Home's box from the window on; front=tab's launch reopens a terminal, which takes the keys and
  # runs them as a command at Return, and front=chat's reopens a chat, whose composer takes them. front=home and the
  # default front are Home's: no conflict (the priming launch, where front= seeds, types nothing).
  [[ "${LR_KEYS:-0}" != 1 || ( "$LR_FRONT" != tab && "$LR_FRONT" != chat ) ]] \
    || { echo "keys=1 types into Home: it takes no front=tab or front=chat (a terminal or chat in front would take the keys)" >&2; return 1; }
  return 0
}

# quiesce_left APP: how many processes run from APP/Contents/MacOS or APP/Contents/Frameworks. The paths reach awk
# through its environment (in its arguments, awk would match its own command line), so the prefix goes on awk: on
# ps, awk read empty strings, macOS awk's index($0, "") matched every line, and each launch waited the full 60 s.
quiesce_left() {
  ps -axo command= | LR_MACOS="$1/Contents/MacOS/" LR_FRAMEWORKS="$1/Contents/Frameworks/" \
    awk 'index($0, ENVIRON["LR_MACOS"]) || index($0, ENVIRON["LR_FRAMEWORKS"]) { n++ } END { print n + 0 }'
}

# wait_load SIDE LABEL: a launch starts only once the 1-minute load is under LR_LOAD_MAX (default 8), as
# launch-premain's pairs do. The step's own two builds leave the load at 12-21 for the first pairs, so without this
# every such step came back NOT VALID. At most LR_LOAD_WAIT_S (default 600) seconds; past that the launch runs and its
# row carries the load, as before. LR-LOAD-WAIT says how long it waited whenever it waited.
wait_load() {
  local max="${LR_LOAD_MAX:-8}" limit="${LR_LOAD_WAIT_S:-600}" waited=0 l
  while l="$(load_1m)"; [[ -n "$l" ]] && ! awk -v l="$l" -v m="$max" 'BEGIN { exit !(l < m) }'; do
    if (( waited >= limit )); then
      echo "LR-LOAD-WAIT $1 $2 waited_s=$waited load_1m=$l still over $max"
      return 0
    fi
    sleep 5 # the Mac's own load average settling (a measurement script, not runtime code)
    waited=$((waited + 5))
  done
  if (( waited > 0 )); then echo "LR-LOAD-WAIT $1 $2 waited_s=$waited load_1m=$l"; fi
  return 0
}

# load_1m: the Mac's 1-minute load average (`sysctl -n vm.loadavg` prints "{ 1.92 2.10 2.31 }"), empty if unread.
load_1m() {
  sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }'
}

# Sourced (tests/launch-ready-quiesce.test.sh, tests/launch-ready-defaults.test.sh, tests/launch-ready-keys.test.sh), it
# only defines its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit $?; fi

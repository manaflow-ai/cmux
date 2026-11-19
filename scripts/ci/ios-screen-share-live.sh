# shellcheck shell=bash
# The live Screen Sharing leg of cmux-next-ios-sim.sh, sourced by it: `test ui=ScreenSharingLiveUITests[/TEST]`
# (plus video) puts a real host behind the phone. The iPhone (Debug app, UITests/ScreenSharingLiveUITests.swift)
# signs in as the agent account, opens the host's screen through the device hub, taps, double-taps,
# two-finger-taps, drags and types "hello"; the host's own event log is read back and the step fails unless
# every one of them reached it (scripts/ci/ios_screen_share_live.py readback).
#
#   cmux-ci run --class simulator --display --sign-in agent --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
#     --arg test --arg ui=ScreenSharingLiveUITests --arg video --artifact artifacts/ios-sim/evidence.zip
#
# Targets (TEST picks one; the default test is the Mac):
#   mac    testSeeAndControlAMac: a tagged DEBUG cmux NEXT Mac app built here (build_mac_app) shares this
#          Mac's screen on the dev hub as the same account, InputProbe in front
#          (cmux-next-ios/verify/screen-sharing/InputProbe.swift), every viewer request approved always_full
#          through its debug socket (ios_screen_share_live.py approve). Needs Screen Recording and
#          Accessibility for the host: the step's own, else CmuxScreenEvalLauncher.app's
#          (scripts/measure/screen-stream-eval/launcher), which runs the host through
#          screen-stream-eval.sh ios-live-host=DIR.
#   linux  testSeeAndControlALinuxDesktop: a Linux desktop on its own fleet step (a Mac step cannot start
#          one), scripts/ci/ios-screen-share-linux-host.sh host NAME: cmux-rd linux-host on Xvfb, XTest
#          injection, registered on the dev hub as that step's own agent session, read back there from
#          `xinput test-xi2 --root` on its display. The two steps meet through the hub only: NAME is
#          cmux-ss-live-linux-<commit, 8>, and the phone waits up to 25 min for that row to come online.
#          This step keeps the phone's video and screenshots; the readback is the Linux step's.
#
# The session: the step's own (cmux-ci run --sign-in agent, scripts/lib/fleet-signin-session.sh). The phone
# gets it as CMUX_MOBILE_STACK_REFRESH_TOKEN (through TEST_RUNNER_CMUX_SS_REFRESH_TOKEN, that xcodebuild call
# only); the Mac gets it as its token file before launch (ios_screen_share_live.py seed-mac-session). Nothing
# prints it. Artifacts (in $out/screen-share/): probe.jsonl, readback.json, approvals.jsonl, host.log,
# probe.log, hub-state.json; the video and the step screenshots are the UI run's (ui-video.mp4,
# ui-attachments/).

ss_live=0 ss_target="" ss_dir="" ss_approver="" ss_host_pid="" ss_mac_name="" ss_status=0 ss_reason=""

# ss_live_select ITEM: called for each ui= item; turns the leg on for ScreenSharingLiveUITests.
ss_live_select() {
  case "$1" in
    ScreenSharingLiveUITests|ScreenSharingLiveUITests/testSeeAndControlAMac) ss_live=1 ss_target=mac ;;
    ScreenSharingLiveUITests/testSeeAndControlALinuxDesktop) ss_live=1 ss_target=linux ;;
    ScreenSharingLiveUITests/*) echo "cmux-next-ios-sim.sh: no live Screen Sharing target for $1 (mac: testSeeAndControlAMac, linux: testSeeAndControlALinuxDesktop)" >&2; exit 2 ;;
  esac
}

ss_fail() { ss_status=1; ss_reason="$1"; note "- Screen Sharing live: FAIL: $1"; }

# ss_granted JSON: whether a preflight answer (preflight.swift, the launcher's --status) holds both grants.
ss_granted() { grep -q '"accessibility":true' <<<"$1" && grep -q '"screen_recording":true' <<<"$1"; }

# ss_live_start: the host is up, shared, named, approving. Sets SS_TEST_ENV (no secret in it). Returns 1
# with ss_reason on a failure; the UI tests then do not run.
ss_live_start() {
  local t0=$SECONDS here="$root/scripts/measure/screen-stream-eval" grants home launcher
  ss_dir="$work/ss-live"
  mkdir -p "$ss_dir" "$out/screen-share"
  if [[ "$ss_target" == linux ]]; then
    ss_mac_name="cmux-ss-live-linux-$(git rev-parse --short=8 HEAD)"
    SS_TEST_ENV=(TEST_RUNNER_CMUX_SS_LIVE=1 TEST_RUNNER_CMUX_SS_TARGET=linux "TEST_RUNNER_CMUX_SS_MAC=$ss_mac_name"
      TEST_RUNNER_CMUX_SS_WAIT=1500)
    note "- Screen Sharing live: Linux desktop '$ss_mac_name' (its own step: ios-screen-share-linux-host.sh host $ss_mac_name)"
    return 0
  fi
  build_mac_app ssl
  swiftc -O -o "$ss_dir/InputProbe" cmux-next-ios/verify/screen-sharing/InputProbe.swift >"$ss_dir/swiftc.log" 2>&1 ||
    { tail -20 "$ss_dir/swiftc.log"; ss_fail "InputProbe did not compile"; return 1; }
  swiftc -O -o "$ss_dir/preflight" "$here/preflight.swift" >>"$ss_dir/swiftc.log" 2>&1 ||
    { tail -20 "$ss_dir/swiftc.log"; ss_fail "preflight did not compile"; return 1; }
  # The host's HOME: the step's own (the token file goes there and is removed with the step).
  local host_home="$ss_dir/home"
  mkdir -p "$host_home"
  local mac_bundle
  mac_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$mac_app/Contents/Info.plist")"
  if [[ -z "${CMUX_CI_SIGNIN_FILE:-}" ]]; then
    ss_fail "no sign-in session: send the step with cmux-ci run --sign-in agent (the controller takes it only for the modes it lists; cmuxterm-hq build-fleet/cmd/controller/sign_in_session.go)"
  else
    python3 -I scripts/ci/ios_screen_share_live.py seed-mac-session --signin "$CMUX_CI_SIGNIN_FILE" \
      --home "$host_home" --bundle "$mac_bundle" || { ss_fail "could not give the Mac the step's session"; }
  fi
  cat >"$ss_dir/host.env" <<EOF
MAC_APP=$(printf '%q' "$mac_app")
MAC_TAG=$(printf '%q' "$mac_tag")
PROBE=$(printf '%q' "$ss_dir/InputProbe")
HOST_HOME=$(printf '%q' "$host_home")
EOF
  grants="$("$ss_dir/preflight" 2>/dev/null)"
  note "- Screen Sharing live: step grants $grants"
  if ss_granted "$grants"; then
    bash scripts/ci/ios-screen-share-live-host.sh "$ss_dir" >"$ss_dir/host-run.log" 2>&1 &
    ss_host_pid=$!
    note "- Screen Sharing live: host runs under the step's own grants"
  else
    home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
    launcher="$home/Applications/CmuxScreenEvalLauncher.app"
    if [[ ! -x "$launcher/Contents/MacOS/CmuxScreenEvalLauncher" ]]; then
      ss_fail "the step's processes lack Screen Recording or Accessibility, and this worker has no CmuxScreenEvalLauncher.app ($grants)"
      return 1
    fi
    open -W -n -g -a "$launcher" --stdout "$ss_dir/launcher-grants.json" --args --status >/dev/null 2>&1 || true
    grants="$(cat "$ss_dir/launcher-grants.json" 2>/dev/null)"
    note "- Screen Sharing live: launcher grants ${grants:-none}"
    if ! ss_granted "$grants"; then
      ss_fail "neither the step nor $launcher holds Screen Recording and Accessibility (${grants:-none})"
      return 1
    fi
    open -n -g -a "$launcher" --stdout "$ss_dir/host-run.log" --stderr "$ss_dir/host-run.err" \
      --env "PATH=$PATH" --env "CMUX_SCREEN_EVAL_PARENT=$$" \
      --args "$root/scripts/measure/screen-stream-eval.sh" "$ss_dir/launcher-status" "ios-live-host=$ss_dir" ||
      { ss_fail "the launcher did not start the host"; return 1; }
    note "- Screen Sharing live: host runs inside CmuxScreenEvalLauncher.app"
  fi
  local sock="/tmp/cmux-debug-$mac_tag.sock" device
  device="$(python3 -I scripts/ci/ios_screen_share_live.py wait-ready "$sock" 240 2>>"$ss_dir/hub.log")" ||
    { tail -5 "$ss_dir/hub.log"; ss_fail "the Mac's hub client never came up on $sock"; return 1; }
  [[ $ss_status -eq 0 ]] || return 1
  ss_mac_name="cmux-ss-live-${mac_tag##*-}"
  python3 -I scripts/ci/ios_screen_share_live.py hub "$sock" rename "{\"id\":\"$device\",\"name\":\"$ss_mac_name\"}" >>"$ss_dir/hub.log" 2>&1 || true
  python3 -I scripts/ci/ios_screen_share_live.py hub "$sock" set_shared '{"shared":true}' >>"$ss_dir/hub.log" 2>&1 ||
    { ss_fail "set_shared failed (hub.log)"; return 1; }
  python3 -I scripts/ci/ios_screen_share_live.py approve "$sock" "$ss_dir/stop-approve" "$ss_dir/approvals.jsonl" &
  ss_approver=$!
  SS_TEST_ENV=(TEST_RUNNER_CMUX_SS_LIVE=1 TEST_RUNNER_CMUX_SS_TARGET=mac "TEST_RUNNER_CMUX_SS_MAC=$ss_mac_name")
  note "- Screen Sharing live: Mac '$ss_mac_name' ($device) shared and approving, $((SECONDS - t0)) s"
}

# ss_live_finish: stops what ss_live_start started, reads the host's events back, keeps the files.
ss_live_finish() {
  [[ -n "$ss_dir" ]] || return 0
  if [[ "$ss_target" == linux ]]; then
    note "- Screen Sharing live: the Linux desktop's readback is its own step's (artifacts/ios-screen-share-linux/readback.json)"
    python3 -I -c 'import json,sys; json.dump({"target":"linux","host":sys.argv[1],"status":int(sys.argv[2]),"reason":sys.argv[3],"readback":"on the Linux step"},open(sys.argv[4],"w"),indent=2)' \
      "$ss_mac_name" "$ss_status" "$ss_reason" "$out/screen-share/summary.json" || true
    return 0
  fi
  local sock="/tmp/cmux-debug-${mac_tag:-none}.sock"
  python3 -I scripts/ci/ios_screen_share_live.py hub "$sock" state >"$out/screen-share/hub-state.json" 2>/dev/null || true
  touch "$ss_dir/stop-approve" "$ss_dir/stop"
  if [[ -n "$ss_approver" ]]; then wait "$ss_approver" 2>/dev/null || true; ss_approver=""; fi
  if [[ -n "$ss_host_pid" ]]; then
    for _ in $(seq 1 30); do kill -0 "$ss_host_pid" 2>/dev/null || break; sleep 1; done
    kill -TERM "$ss_host_pid" 2>/dev/null || true
    wait "$ss_host_pid" 2>/dev/null || true
    ss_host_pid=""
  else
    for _ in $(seq 1 30); do [[ -s "$ss_dir/launcher-status" ]] && break; sleep 1; done
  fi
  local f
  for f in probe.jsonl probe.log host.log host-run.log host-run.err approvals.jsonl hub.log launcher-grants.json; do
    [[ -f "$ss_dir/$f" ]] && cp "$ss_dir/$f" "$out/screen-share/$f"
  done
  # The token file goes with the step's directory; removed here too, at once.
  find "$ss_dir/home/Library/Application Support" -name credentials.json -type f -delete 2>/dev/null || true
  if [[ $ss_status -eq 0 ]]; then
    if python3 -I scripts/ci/ios_screen_share_live.py readback --target "$ss_target" \
        --events "$ss_dir/probe.jsonl" --out "$out/screen-share/readback.json" >"$ss_dir/readback.txt"; then
      note "- Screen Sharing live readback ($ss_target): PASS $(cat "$ss_dir/readback.txt")"
    else
      ss_fail "readback ($ss_target): $(cat "$ss_dir/readback.txt")"
    fi
  fi
  python3 -I -c 'import json,sys; json.dump({"target":sys.argv[1],"mac":sys.argv[2],"status":int(sys.argv[3]),"reason":sys.argv[4]},open(sys.argv[5],"w"),indent=2)' \
    "$ss_target" "$ss_mac_name" "$ss_status" "$ss_reason" "$out/screen-share/summary.json" || true
}

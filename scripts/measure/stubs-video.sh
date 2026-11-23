#!/usr/bin/env bash
# A screen video of launch-ready.sh's A/B launches (stage 0 "stubs" against its base), for a person to judge what the
# launch looks like: the console session is recorded for each pass, and each LR-RUN row's start_epoch_ms says where
# its launch begins in the video (the .mov's first frame is VIDEO_START_EPOCH_MS in video-start.txt).
#   cmux-ci run --class exclusive --measurement --label measure --display --target-worker air-blue --pin-strict \
#     --script scripts/measure/stubs-video.sh --ref <sha> --arg=base=SHA --arg=head=SHA [--arg=runs=3] \
#     [--arg=passes=warm,cold] --artifact .build/stubs-video/report.tgz --timeout 7200
# Each pass is one launch-ready.sh run: dmg=build, keys=1 (keys typed from the window on, read back), front=home,
# runs=N; pass cold adds daemon=cold (the daemons end before each launch, as a reboot ends them).
# Records with screencapture -v (Screen Recording must be granted to the step's process); only the recorder this
# script started is stopped, by PID.
set -uo pipefail

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

main() {
  cd "$(dirname "$0")/../.." || exit 3
  local out="$PWD/.build/stubs-video" passes="warm,cold" pass rc=0 rec="" pass_args=() lr_args=() arg
  rm -rf "$out" && mkdir -p "$out" || exit 3
  for arg in "$@"; do
    case "$arg" in
      passes=*) passes="${arg#passes=}" ;;
      *) pass_args+=("$arg") ;;
    esac
  done
  trap '[[ -n "$rec" ]] && kill -0 "$rec" 2>/dev/null && kill -INT "$rec" 2>/dev/null' EXIT
  IFS=, read -r -a plist <<<"$passes"
  for pass in "${plist[@]}"; do
    lr_args=(dmg=build keys=1 front=home "${pass_args[@]}")
    [[ "$pass" == cold ]] && lr_args+=(daemon=cold)
    echo "SV pass $pass: launch-ready.sh ${lr_args[*]}"
    # 3600 s at most per pass; the recorder stops at the pass's end.
    screencapture -v -x -V 3600 "$out/$pass.mov" >"$out/$pass-recorder.log" 2>&1 &
    rec=$!
    echo "VIDEO_START_EPOCH_MS $(now_ms)" >"$out/$pass-video-start.txt"
    sleep 1
    kill -0 "$rec" 2>/dev/null || { echo "SV recorder did not start (Screen Recording?):"; cat "$out/$pass-recorder.log"; }
    bash scripts/measure/launch-ready.sh "${lr_args[@]}" 2>&1 | tee "$out/$pass-launch-ready.log" | grep -E '^LR-(RUN|MEDIAN|KEYS|REOPENED|SURFACE|FAIL)|^LR (host|case)'
    [[ "${PIPESTATUS[0]}" == 0 ]] || rc=1
    echo "VIDEO_END_EPOCH_MS $(now_ms)" >>"$out/$pass-video-start.txt"
    kill -INT "$rec" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$rec" 2>/dev/null || break; sleep 1; done
    rec=""
    cp .build/launch-ready/runs.jsonl "$out/$pass-runs.jsonl" 2>/dev/null
    cp .build/launch-ready/report.tgz "$out/$pass-launch-ready.tgz" 2>/dev/null
    ls -la "$out/$pass.mov" 2>&1 | sed 's/^/SV video /'
  done
  tar -czf "$out.tgz" -C "$out" . && mv "$out.tgz" "$out/report.tgz"
  return "$rc"
}

main "$@"; exit $?

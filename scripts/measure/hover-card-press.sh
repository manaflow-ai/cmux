#!/usr/bin/env bash
# Fleet entry for the sidebar workspace card's Show/Hide details press bench (Lawrence 2026-11-18, msg 38370
# follow-up: "trace the late frames"): builds a tagged DEBUG app at each arm's commit (app-at-commit.sh), then runs
# scripts/cmux-next/hover-card-press-bench.py on each, ROUNDS times in alternating order (A B C, then C B A), and
# prints one HCP-SUMMARY line per arm and round: late presses of Show details and Hide details, the no-press control's
# late frames, the press's main-thread work at the start of the next frame.
#
#   cmux-ci run --class exclusive --measurement --label measure --urgent --pool perf-lead --target-worker aws-m4pro-7 \
#     --pin-strict --script scripts/measure/hover-card-press.sh --arg=--vdisplay=120 --ref <a feat-cmux-next sha with this script> \
#     --arg=--arm=base@<sha> --arg=--arm=room@<sha> [--arg=--rounds=2] [--arg=--cycles=20] [--arg=--trace=room]
#
# --trace=ARM: after the rounds, one more launch of that arm presses for 20 s while Instruments' Animation Hitches
# records the app for 12 s (a hitch's kind: the app's commit, or the render server). It runs only when the Mac has
# room: under 60% of kern.maxproc processes and memory pressure normal (a long attached recording took a Mac down,
# 2026-11-18). The hitch rows print as HCP-HITCH lines.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
out="$(mktemp -d)"
vdisplay_pid=""
# shellcheck disable=SC2329 # run by the trap below
cleanup() {
  if [[ -n "$vdisplay_pid" ]]; then kill "$vdisplay_pid" 2>/dev/null || true; wait "$vdisplay_pid" 2>/dev/null || true; fi  # the helper this script started
  measure_remove_scratch "$out"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

arms=() rounds=2 cycles=20 trace="" vdisplay_hz=""
for arg in "$@"; do
  case "$arg" in
    --arm=*) arms+=("${arg#--arm=}") ;;
    --rounds=*) rounds="${arg#--rounds=}" ;;
    --cycles=*) cycles="${arg#--cycles=}" ;;
    --trace=*) trace="${arg#--trace=}" ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    *) echo "hover-card-press: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ ${#arms[@]} -gt 0 ]] || { echo "hover-card-press: pass --arm=NAME@SHA at least once" >&2; exit 2; }

names=() apps=()
for arm in ${arms[@]+"${arms[@]}"}; do
  name="${arm%%@*}" sha="${arm#*@}"
  app="$(measure_app_at_commit "$sha" "hcp-$name" "$out/at-$name")" || { echo "HCP-FAIL $name build at $sha"; exit 1; }
  names+=("$name") apps+=("$app")
  echo "HCP-BUILT $name $sha $app"
done

# --vdisplay=HZ: the app opens on a virtual main display at HZ (scripts/ci/frame-pacing/vdisplay.m), as held-new-tab.sh.
if [[ -n "$vdisplay_hz" ]]; then
  vd="$out/vdisplay"
  mkdir -p "$vd/VDisplay.app/Contents/MacOS"
  if xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
      scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay" 2> "$vd/clang.err"; then
    cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
    codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
    "$vd/VDisplay.app/Contents/MacOS/VDisplay" "$vdisplay_hz" 3600 main 1920x1200 > "$vd/out" 2> "$vd/err" &
    vdisplay_pid=$!
    for _ in $(seq 20); do
      grep -q '^ready\|^error' "$vd/out" 2>/dev/null && break
      kill -0 "$vdisplay_pid" 2>/dev/null || break
      sleep 1  # bounded wait for the helper's own ready line
    done
    echo "HCP-DISPLAY $(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo 'the virtual display never reported')"
    # Until a new process sees the virtual display as its main display (what the app opens on), 15 s.
    # Only when the helper's ready line says it made the display main (main=ID).
    vd_id="$(sed -n 's/^ready \([0-9]*\) [0-9.]* main=\1 .*/\1/p' "$vd/out" 2>/dev/null | head -1 || true)"
    if [[ -n "$vd_id" ]]; then
      vd_main="" vd_deadline=$((SECONDS + 15))
      while (( SECONDS < vd_deadline )); do
        vd_main="$("$vd/VDisplay.app/Contents/MacOS/VDisplay" probe 2>/dev/null | awk '$1 == "main" {print $2}' || true)"
        [[ "$vd_main" == "$vd_id" ]] && break
        sleep 0.2
      done
      [[ "$vd_main" == "$vd_id" ]] || echo "warning: a new process still sees display ${vd_main:-?} as main, not the virtual display $vd_id, after 15 s" >&2
    fi
  else
    echo "HCP-DISPLAY the virtual display helper did not compile: $(head -c 300 "$vd/clang.err")"
  fi
fi

echo "HCP-MOTION reduceMotion=$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo unset)"

bench() { # NAME APP DIR [bench args...]
  local name="$1" app="$2" dir="$3"
  shift 3
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh \
    python3 -I "$PWD/scripts/cmux-next/hover-card-press-bench.py" --app "$app" --tag "hcp-$name" --out "$dir" "$@" \
    >"$dir.log" 2>&1
}

order=("${!names[@]}")
for ((round = 1; round <= rounds; round++)); do
  for i in "${order[@]}"; do
    dir="$out/${names[$i]}-r$round"
    if bench "${names[$i]}" "${apps[$i]}" "$dir" --cycles "$cycles"; then
      echo "HCP-SUMMARY ${names[$i]} r$round $(tr -d '\n ' < "$dir/summary.json")"
      [[ "$round" == 1 ]] && grep -m1 '^CARD' "$dir.log" | cut -c1-400 | sed 's/^/HCP-/' 
    else
      echo "HCP-FAIL ${names[$i]} r$round"; tail -n 20 "$dir.log"
    fi
  done
  reversed=()
  for ((k = ${#order[@]} - 1; k >= 0; k--)); do reversed+=("${order[$k]}"); done
  order=(${reversed[@]+"${reversed[@]}"})
done

[[ -n "$trace" ]] || exit 0
index=""
for i in "${!names[@]}"; do [[ "${names[$i]}" == "$trace" ]] && index="$i"; done
[[ -n "$index" ]] || { echo "HCP-TRACE no arm named $trace"; exit 0; }
procs="$(ps -A | wc -l | tr -d ' ')" maxproc="$(sysctl -n kern.maxproc)"
pressure="$(memory_pressure 2>/dev/null | sed -n 's/.*System-wide memory free percentage: *//p')"
echo "HCP-TRACE room: processes $procs of $maxproc, memory free ${pressure:-?}"
if (( procs * 100 >= maxproc * 60 )) || [[ -n "$pressure" && "${pressure%\%}" -lt 20 ]]; then
  echo "HCP-TRACE skipped: the Mac has no room for a recording"
  exit 0
fi
dir="$out/trace"
bench "$trace" "${apps[$index]}" "$dir" --cycles 0 --hold-seconds 20 &
runner=$!
pid=""
for _ in $(seq 1 240); do # the app's start (a measurement script, not runtime code)
  pid="$(sed -n 's/^PID //p' "$dir.log" 2>/dev/null | head -n 1)"
  [[ -n "$pid" ]] && break
  sleep 0.5
done
if [[ -n "$pid" ]]; then
  xcrun xctrace record --template 'Animation Hitches' --attach "$pid" --time-limit 12s --output "$out/hitches.trace" \
    --no-prompt >"$out/xctrace.log" 2>&1 || echo "HCP-TRACE record failed: $(tail -n 3 "$out/xctrace.log" | tr '\n' ' ')"
fi
wait "$runner" || true
if [[ -d "$out/hitches.trace" ]]; then
  xcrun xctrace export --input "$out/hitches.trace" --toc >"$out/toc.xml" 2>/dev/null || true
  for schema in $(grep -oE 'schema="[a-z0-9-]*hitch[a-z0-9-]*"' "$out/toc.xml" | sort -u | cut -d'"' -f2); do
    xcrun xctrace export --input "$out/hitches.trace" \
      --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" >"$out/$schema.xml" 2>/dev/null || continue
    python3 -I - "$out/$schema.xml" "$schema" <<'EOF'
import sys, xml.etree.ElementTree as ET
path, schema = sys.argv[1], sys.argv[2]
root = ET.parse(path).getroot()
ids = {}
for el in root.iter():
    if el.get("id") is not None and el.get("fmt") is not None:
        ids[el.get("id")] = el.get("fmt")
cols = [c.findtext("mnemonic") for c in root.iter("col")]
print(f"HCP-HITCH-TABLE {schema} columns={cols}")
for n, r in enumerate(root.iter("row")):
    if n >= 60:
        break
    cells = [c.get("fmt") or ids.get(c.get("ref") or "", "") for c in r]
    print("HCP-HITCH", schema, " | ".join(cells))
EOF
  done
fi

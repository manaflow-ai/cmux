#!/usr/bin/env bash
# Fleet entry for the sidebar workspace card's Show/Hide details press bench (Lawrence 2026-11-18, msg 38370
# follow-up: "trace the late frames"): builds a tagged DEBUG app at each arm's commit (app-at-commit.sh), then runs
# scripts/cmux-next/hover-card-press-bench.py on each, ROUNDS times in alternating order (A B C, then C B A), and
# prints one HCP-SUMMARY line per arm and round: late presses of Show details and Hide details, the no-press control's
# late frames, the press's main-thread work at the start of the next frame.
#
#   cmux-ci run --class exclusive --measurement --label measure --urgent --pool perf-lead --target-worker aws-m4pro-7 \
#     --pin-strict --script scripts/measure/hover-card-press.sh --ref <a feat-cmux-next sha with this script> \
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
trap 'measure_remove_scratch "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

arms=() rounds=2 cycles=20 trace=""
for arg in "$@"; do
  case "$arg" in
    --arm=*) arms+=("${arg#--arm=}") ;;
    --rounds=*) rounds="${arg#--rounds=}" ;;
    --cycles=*) cycles="${arg#--cycles=}" ;;
    --trace=*) trace="${arg#--trace=}" ;;
    *) echo "hover-card-press: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ ${#arms[@]} -gt 0 ]] || { echo "hover-card-press: pass --arm=NAME@SHA at least once" >&2; exit 2; }

names=() apps=()
for arm in "${arms[@]}"; do
  name="${arm%%@*}" sha="${arm#*@}"
  app="$(measure_app_at_commit "$sha" "hcp-$name" "$out/at-$name")" || { echo "HCP-FAIL $name build at $sha"; exit 1; }
  names+=("$name") apps+=("$app")
  echo "HCP-BUILT $name $sha $app"
done

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
      echo "HCP-SUMMARY ${names[$i]} r$round $(cat "$dir/summary.json" | tr -d '\n ')"
    else
      echo "HCP-FAIL ${names[$i]} r$round"; tail -n 20 "$dir.log"
    fi
  done
  reversed=()
  for ((k = ${#order[@]} - 1; k >= 0; k--)); do reversed+=("${order[$k]}"); done
  order=("${reversed[@]}")
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

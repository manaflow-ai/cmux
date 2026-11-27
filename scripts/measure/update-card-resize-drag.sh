#!/usr/bin/env bash
# Fleet entry for the Updated card resize-drag proof (Leo 2026-11-27: "this thing is just too weird there's a glass back that shouldnt be there"): builds a tagged DEBUG app
# at each arm's commit (app-at-commit.sh), then drags the sidebar edge wide, narrow, wide over each with
# scripts/cmux-next/update-card-resize-drag.py, recorded, printing UCD-STEP lines; videos and steps land in
# artifacts/update-card-drag/ (pass --artifact artifacts/update-card-drag to cmux-ci run).
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/update-card-resize-drag.sh \
#     --ref <sha with this script> --artifact artifacts/update-card-drag --arg=--arm=base@<sha> --arg=--arm=head@<sha>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
out="$(mktemp -d)"
trap 'measure_remove_scratch "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

arms=()
for arg in "$@"; do
  case "$arg" in
    --arm=*) arms+=("${arg#--arm=}") ;;
    *) echo "update-card-resize-drag: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ ${#arms[@]} -gt 0 ]] || { echo "update-card-resize-drag: pass --arm=NAME@SHA at least once" >&2; exit 2; }

art="$PWD/artifacts/update-card-drag"
mkdir -p "$art"
xcrun swiftc -O scripts/cmux-next/pointer-probe.swift -o "$out/pointer-probe" 2> "$out/probe.err" \
  || { echo "UCD-FAIL pointer-probe did not compile: $(head -c 300 "$out/probe.err")"; exit 1; }

status=0
for arm in "${arms[@]}"; do
  name="${arm%%@*}" sha="${arm#*@}"
  app="$(measure_app_at_commit "$sha" "ucd-$name" "$out/at-$name")" || { echo "UCD-FAIL $name build at $sha"; status=1; continue; }
  echo "UCD-BUILT $name $sha $app"
  if ! GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh \
      python3 -I "$PWD/scripts/cmux-next/update-card-resize-drag.py" --app "$app" --tag "ucd-$name" --arm "$name" \
      --out "$art/$name" --probe "$out/pointer-probe" > "$art/$name.log" 2>&1; then
    echo "UCD-FAIL $name run"; status=1
  fi
  grep '^UCD-' "$art/$name.log" || tail -n 30 "$art/$name.log"
done
exit "$status"

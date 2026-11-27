#!/usr/bin/env bash
# Fleet entry for the hidden-sidebar title bar reveal proof (cmux#60461, Leo 2026-11-27): builds a tagged DEBUG app
# at each arm's commit (app-at-commit.sh), then walks a fixed pointer path over each with
# scripts/cmux-next/titlebar-hover-reveal.py, recorded, printing TRH-STEP lines; videos and steps land in
# artifacts/titlebar-hover/ (pass --artifact artifacts/titlebar-hover to cmux-ci run).
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/titlebar-hover-reveal.sh \
#     --ref <sha with this script> --artifact artifacts/titlebar-hover --arg=--arm=base@<sha> --arg=--arm=head@<sha>
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
    *) echo "titlebar-hover-reveal: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ ${#arms[@]} -gt 0 ]] || { echo "titlebar-hover-reveal: pass --arm=NAME@SHA at least once" >&2; exit 2; }

art="$PWD/artifacts/titlebar-hover"
mkdir -p "$art"
xcrun swiftc -O scripts/cmux-next/pointer-probe.swift -o "$out/pointer-probe" 2> "$out/probe.err" \
  || { echo "TRH-FAIL pointer-probe did not compile: $(head -c 300 "$out/probe.err")"; exit 1; }

status=0
for arm in "${arms[@]}"; do
  name="${arm%%@*}" sha="${arm#*@}"
  app="$(measure_app_at_commit "$sha" "trh-$name" "$out/at-$name")" || { echo "TRH-FAIL $name build at $sha"; status=1; continue; }
  echo "TRH-BUILT $name $sha $app"
  if ! GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh \
      python3 -I "$PWD/scripts/cmux-next/titlebar-hover-reveal.py" --app "$app" --tag "trh-$name" --arm "$name" \
      --out "$art/$name" --probe "$out/pointer-probe" > "$art/$name.log" 2>&1; then
    echo "TRH-FAIL $name run"; status=1
  fi
  grep '^TRH-' "$art/$name.log" || tail -n 30 "$art/$name.log"
done
exit "$status"

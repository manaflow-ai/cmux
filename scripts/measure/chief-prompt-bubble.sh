#!/usr/bin/env bash
# Fleet entry for the Chief prompt bubble proof (u4256): builds a tagged cmux-next app at this checkout,
# then runs scripts/cmux-next/chief-prompt-bubble-live.py against it (a Chief subagent's 140 KB first
# prompt, sent to the app's own acpmux with the test agent, must draw as the chat's first bubble, marked
# from the Chief, live and on reopen; a tell draws as a second one). Window snapshots and report.json
# come back as artifacts. Launches an app, so it runs alone and needs a logged-in console:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/chief-prompt-bubble.sh \
#     --ref <sha> --artifact artifacts/chief-prompt-bubble.tar.gz
# A step returns one artifact, so the snapshots, report.json and logs come back as one archive.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers and ghostty-next for cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="chiefbubble"
out="$(pwd)/artifacts/chief-prompt-bubble"
mkdir -p "$out"
# --config=<debug|release|bench> picks reload.sh's build configuration (bench: Release optimization with the
# debug.* control commands kept); every other argument goes to the bench.
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "chief-prompt-bubble: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
status=0
python3 scripts/cmux-next/chief-prompt-bubble-live.py --tag "$tag" --app "$app" --out "$out" --json "$out/report.json" "$@" || status=$?
tar -czf artifacts/chief-prompt-bubble.tar.gz -C artifacts chief-prompt-bubble
exit "$status"

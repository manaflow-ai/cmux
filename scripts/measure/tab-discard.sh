#!/usr/bin/env bash
# Fleet entry for the hidden tab discard bench (process-sharing row 4): builds a tagged cmux-next app at this
# checkout, then runs scripts/cmux-next/bench_tab_discard.py at 1, 10 and 20 hidden Chromium tabs plus an audio, a
# form and a pinned tab, under the default `browser.hibernation` (unset) and forced critical memory pressure:
# renderer processes and footprint per hidden tab before and after, idle wakeups, which tabs were discarded, and
# the time a discarded tab takes to come back at its URL when shown.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/tab-discard.sh --ref <sha> [--arg=--expect-discard]
# Before/after: run it at the base with the harness commit cherry-picked, and at the head, with the same arguments.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="tabdiscard"
out="$(mktemp -d)"
# Remove the scratch folder on every exit (a failed build, a TERM), not only at the end: a leaked one holds a build.
trap 'rm -rf -- "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "tab-discard: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "tab-discard: ref $(git rev-parse HEAD)"
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_tab_discard.py --app "$app" --out "$PWD/tab-discard.json" "$@"

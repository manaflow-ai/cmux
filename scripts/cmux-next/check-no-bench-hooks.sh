#!/usr/bin/env bash
# check-no-bench-hooks.sh [--expect] <app bundle>
# A bench build (scripts/reload.sh --config bench: Release optimization, -DDEBUG -DCMUX_BENCH_HOOKS)
# keeps the debug.* control commands in an optimized app for the fleet benches. It must never ship:
# its main executable carries the marker CMUX_BENCH_HOOKS_BUILD (Sources/CmuxNextApp/BenchHooksMarker.swift,
# compiled only under CMUX_BENCH_HOOKS). Without --expect the check fails when the marker is there (the
# release and nightly pipelines run it on the app they ship); with --expect it fails when the marker is
# missing (reload.sh --config bench proves its flags reached the app).
set -euo pipefail
expect=0
if [[ "${1:-}" == --expect ]]; then expect=1; shift; fi
[[ $# -eq 1 && -d "$1" ]] || { echo "usage: $0 [--expect] <app bundle>" >&2; exit 2; }
app="$1"
exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
exe="$app/Contents/MacOS/$exe_name"
[[ -n "$exe_name" && -f "$exe" ]] || { echo "error: no main executable in $app" >&2; exit 2; }
marker="CMUX_BENCH_HOOKS""_BUILD"
if LC_ALL=C grep -aq "$marker" "$exe"; then
  if (( expect )); then echo "bench hooks: present in $exe_name (bench build)"; exit 0; fi
  echo "error: $app is a bench build (CMUX_BENCH_HOOKS: debug.* control commands in an optimized app); it must not ship" >&2
  exit 1
fi
if (( expect )); then
  echo "error: $app has no bench hooks; the --config bench flags did not reach CmuxNextApp" >&2
  exit 1
fi
echo "bench hooks: none in $exe_name"

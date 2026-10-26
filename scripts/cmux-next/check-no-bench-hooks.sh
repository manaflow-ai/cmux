#!/usr/bin/env bash
# check-no-bench-hooks.sh [--expect | --expect-sanitizer asan|tsan|ubsan] <app bundle>
# Two lab builds must never ship; the release and nightly pipelines and build-sign-upload.sh run this
# without a flag on the app they ship, and it fails when the app is either one:
# - A bench build (scripts/reload.sh --config bench: Release optimization, -DCMUX_BENCH_HOOKS) keeps the
#   debug.* control commands in an optimized app for the fleet benches. Its main executable carries the
#   marker CMUX_BENCH_HOOKS_BUILD (Sources/CmuxNextApp/BenchHooksMarker.swift, compiled only under
#   CMUX_BENCH_HOOKS).
# - A sanitizer build (scripts/reload.sh --config asan|tsan|ubsan: Release with the sanitizer) links
#   libclang_rt.<kind>_osx_dynamic.dylib and embeds it in Contents/Frameworks.
# --expect requires the bench marker (reload.sh --config bench proves its flags reached the app);
# --expect-sanitizer KIND requires that sanitizer's runtime, linked and embedded, and no bench marker.
set -euo pipefail
expect=""
case "${1:-}" in
  --expect) expect=bench; shift ;;
  --expect-sanitizer)
    expect="${2:-}"; shift 2 || true
    case "$expect" in asan | tsan | ubsan) ;; *) echo "error: --expect-sanitizer takes asan, tsan or ubsan" >&2; exit 2 ;; esac
    ;;
esac
[[ $# -eq 1 && -d "$1" ]] || { echo "usage: $0 [--expect | --expect-sanitizer asan|tsan|ubsan] <app bundle>" >&2; exit 2; }
app="$1"
plist="$app/Contents/Info.plist"
if [[ -x /usr/libexec/PlistBuddy ]]; then
  exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
else
  exe_name="$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleExecutable", ""))' "$plist" 2>/dev/null || true)"
fi
exe="$app/Contents/MacOS/$exe_name"
[[ -n "$exe_name" && -f "$exe" ]] || { echo "error: no main executable in $app" >&2; exit 2; }

marker="CMUX_BENCH_HOOKS""_BUILD"
bench=0
LC_ALL=C grep -aq "$marker" "$exe" && bench=1
# The sanitizer the main executable loads (its LC_LOAD_DYLIB path names the runtime) and the runtimes in the bundle.
linked="$(LC_ALL=C grep -aoE 'libclang_rt\.(asan|tsan|ubsan)_osx_dynamic\.dylib' "$exe" | sed -E 's/^libclang_rt\.([a-z]+)_.*/\1/' | sort -u | tr '\n' ' ' || true)"
embedded="$(find "$app" -name 'libclang_rt.*_osx_dynamic.dylib' -print 2>/dev/null | sed -E 's#.*/libclang_rt\.([a-z]+)_osx_dynamic\.dylib$#\1#' | sort -u | tr '\n' ' ' || true)"
linked="${linked% }" embedded="${embedded% }"

case "$expect" in
  bench)
    if (( ! bench )); then
      echo "error: $app has no bench hooks; the --config bench flags did not reach CmuxNextApp" >&2
      exit 1
    fi
    if [[ -n "$linked$embedded" ]]; then
      echo "error: $app is a bench build with a sanitizer runtime (${linked:-$embedded})" >&2
      exit 1
    fi
    echo "bench hooks: present in $exe_name (bench build)"
    ;;
  asan | tsan | ubsan)
    if (( bench )); then
      echo "error: $app is a $expect build with bench hooks; the two configs never combine" >&2
      exit 1
    fi
    if [[ " $linked " != *" $expect "* ]]; then
      echo "error: $exe_name does not load the $expect runtime (loads: ${linked:-none}); the --config $expect flags did not reach the link" >&2
      exit 1
    fi
    if [[ " $embedded " != *" $expect "* ]]; then
      echo "error: $app does not embed libclang_rt.${expect}_osx_dynamic.dylib; it would not launch on a Mac without Xcode" >&2
      exit 1
    fi
    echo "sanitizer: $expect runtime linked and embedded in $exe_name (sanitizer build)"
    ;;
  *)
    if (( bench )); then
      echo "error: $app is a bench build (CMUX_BENCH_HOOKS: debug.* control commands in an optimized app); it must not ship" >&2
      exit 1
    fi
    if [[ -n "$linked$embedded" ]]; then
      echo "error: $app is a sanitizer build (linked: ${linked:-none}; embedded: ${embedded:-none}); it must not ship" >&2
      exit 1
    fi
    echo "bench hooks: none in $exe_name; no sanitizer runtime"
    ;;
esac

#!/usr/bin/env bash
# check-no-bench-hooks.sh [--expect | --expect-sanitizer asan|tsan|ubsan] <app bundle>
# Two lab builds must never ship; the release and nightly pipelines and build-sign-upload.sh run this
# without a flag on the app they ship, and it fails when the app is either one:
# - A bench build (scripts/reload.sh --config bench: Release optimization, -DDEBUG -DCMUX_BENCH_HOOKS) keeps
#   the debug.* control commands in an optimized app for the fleet benches. Its main executable carries the
#   marker CMUX_BENCH_HOOKS_BUILD (Sources/CmuxNextApp/BenchHooksMarker.swift, compiled only under
#   CMUX_BENCH_HOOKS).
# - A sanitizer build (scripts/reload.sh --config asan|tsan|ubsan: Release with the sanitizer) links
#   libclang_rt.<kind>_osx_dynamic.dylib and embeds it in Contents/Frameworks.
# --expect requires the bench marker (reload.sh --config bench proves its flags reached the app);
# --expect-sanitizer KIND requires that sanitizer's runtime, linked and embedded, and no bench marker.
# An app that is not a bench one must also not name a benchOnly feature (schemas/features/features.d/*.json
# with "benchOnly": true): gen-features.py compiles their handles and registry entries only under
# DEBUG || CMUX_BENCH_HOOKS, so a tagged debug build (CMUXBuildConfiguration debug, scripts/reload.sh) is
# the one app that may name them. No app but a bench one may contain the flags test public key
# (schemas/features/bench-test-signing-key.json).
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
plist_value() {
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true
  else
    python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2], ""))' "$plist" "$1" 2>/dev/null || true
  fi
}
exe_name="$(plist_value CFBundleExecutable)"
exe="$app/Contents/MacOS/$exe_name"
[[ -n "$exe_name" && -f "$exe" ]] || { echo "error: no main executable in $app" >&2; exit 2; }

marker="CMUX_BENCH_HOOKS""_BUILD"
bench=0
LC_ALL=C grep -aq "$marker" "$exe" && bench=1
# The sanitizer the main executable loads (its LC_LOAD_DYLIB path names the runtime) and the runtimes in the bundle.
linked="$(LC_ALL=C grep -aoE 'libclang_rt\.(asan|tsan|ubsan)_osx_dynamic\.dylib' "$exe" | sed -E 's/^libclang_rt\.([a-z]+)_.*/\1/' | sort -u | tr '\n' ' ' || true)"
embedded="$(find "$app" -name 'libclang_rt.*_osx_dynamic.dylib' -print 2>/dev/null | sed -E 's#.*/libclang_rt\.([a-z]+)_osx_dynamic\.dylib$#\1#' | sort -u | tr '\n' ' ' || true)"
linked="${linked% }" embedded="${embedded% }"

# Not a bench build: no flags test key, and outside a debug build no benchOnly feature name.
check_no_bench_artifacts() {
  # The perf lab's flags test key (FeatureRemoteSignatureCheck.benchTestPublicKey) is compiled only under
  # CMUX_BENCH_HOOKS in CmuxNextFeatures; a per-target flag mismatch must not ship an app that trusts it.
  local repo test_key config features_dir file name
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  test_key="$(sed -n 's/^[[:space:]]*"publicKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$repo/schemas/features/bench-test-signing-key.json")"
  [[ -n "$test_key" ]] || { echo "error: no publicKey in schemas/features/bench-test-signing-key.json" >&2; exit 2; }
  if LC_ALL=C grep -aqF "$test_key" "$exe"; then
    echo "error: $app trusts the bench flags test key (schemas/features/bench-test-signing-key.json); it must not ship" >&2
    exit 1
  fi
  config="$(plist_value CMUXBuildConfiguration)"
  [[ "$config" == debug ]] && return 0
  features_dir="$repo/schemas/features/features.d"
  local shipped_bench=()
  for file in "$features_dir"/*.json; do
    [[ -f "$file" ]] || continue
    LC_ALL=C grep -Eq '"benchOnly"[[:space:]]*:[[:space:]]*true' "$file" || continue
    name="$(basename "$file" .json)"
    if LC_ALL=C grep -aq "$name" "$exe"; then shipped_bench+=("$name"); fi
  done
  if (( ${#shipped_bench[@]} )); then
    echo "error: $app names bench-only features (${shipped_bench[*]}); they must be compiled out of a shipped app" >&2
    exit 1
  fi
}

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
    check_no_bench_artifacts
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
    check_no_bench_artifacts
    if [[ "$(plist_value CMUXBuildConfiguration)" == debug ]]; then
      echo "bench hooks: none in $exe_name; no sanitizer runtime (a debug build declares the bench-only features)"
      exit 0
    fi
    echo "bench hooks: none in $exe_name; no sanitizer runtime"
    ;;
esac

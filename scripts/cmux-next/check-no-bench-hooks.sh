#!/usr/bin/env bash
# check-no-bench-hooks.sh [--expect] [--invariant-report --channel nightly|nightly-next|dev] <app bundle>
# A bench build (scripts/reload.sh --config bench: Release optimization, -DDEBUG -DCMUX_BENCH_HOOKS)
# keeps the debug.* control commands in an optimized app for the fleet benches. It must never ship:
# its main executable carries the marker CMUX_BENCH_HOOKS_BUILD (Sources/CmuxNextApp/BenchHooksMarker.swift,
# compiled only under CMUX_BENCH_HOOKS). Without --expect the check fails when the marker is there (the
# release and nightly pipelines run it on the app they ship); with --expect it fails when the marker is
# missing (reload.sh --config bench proves its flags reached the app). A shipped app must also not name a
# benchOnly feature (schemas/features/features.d/*.json with "benchOnly": true): gen-features.py compiles
# their handles and registry entries only under DEBUG || CMUX_BENCH_HOOKS, so a tagged debug build
# (CMUXBuildConfiguration debug, scripts/reload.sh) is the one app that may name them. No app but a bench
# one may contain the flags test public key (schemas/features/bench-test-signing-key.json).
#
# The nightly-assert variant (scripts/reload.sh --invariant-report: an -O build with -DINVARIANT_REPORT,
# p10-stability-202, Chrome's DCHECK canary) reports debug checks; its main executable carries
# CMUX_INVARIANT_REPORT_BUILD (Invariant.reportBuildMarker in CmuxSafeConcurrency). Without --invariant-report
# the check fails when that marker is there, so the release, RC and main nightly pipelines refuse it.
# --invariant-report needs --channel, the channel the app ships on, which decides (not the bundle id: a
# pipeline's product is com.cmuxterm.app until nightly.yml's prepare_variant renames it): nightly (the sampled
# Nightly slice), nightly-next or dev (a reload.sh tagged build) pass, rc and release fail. The bundle id must
# then be the build product's (com.cmuxterm.app), the channel's own after the rename (com.cmuxterm.app.nightly,
# com.cmuxterm.app.nightly.cmux-next), or for dev not a shipped one; com.cmuxterm.app.rc always fails. A
# pipeline that ships the variant runs this check before prepare_variant and again on the renamed bundle.
set -euo pipefail
usage="usage: $0 [--expect] [--invariant-report --channel nightly|nightly-next|dev] <app bundle>"
expect=0
invariant_report=0
channel=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --expect) expect=1; shift ;;
    --invariant-report) invariant_report=1; shift ;;
    --channel) channel="$2"; shift 2 ;;
    *) break ;;
  esac
done
[[ $# -eq 1 && -d "$1" ]] || { echo "$usage" >&2; exit 2; }
case "$channel" in
  "" | nightly | nightly-next | dev | rc | release) ;;
  *) echo "error: unknown --channel $channel" >&2; echo "$usage" >&2; exit 2 ;;
esac
if (( invariant_report )) && [[ -z "$channel" ]]; then
  echo "error: --invariant-report needs --channel (the channel the app ships on; the bundle id before nightly.yml's prepare_variant does not say)" >&2
  exit 2
fi
if (( ! invariant_report )) && [[ -n "$channel" ]]; then
  echo "error: --channel goes with --invariant-report" >&2
  exit 2
fi
app="$1"
exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
exe="$app/Contents/MacOS/$exe_name"
[[ -n "$exe_name" && -f "$exe" ]] || { echo "error: no main executable in $app" >&2; exit 2; }
invariant_marker="CMUX_INVARIANT_REPORT""_BUILD"
if (( invariant_report )); then
  case "$channel" in
    rc | release)
      echo "error: the nightly-assert variant (INVARIANT_REPORT) never ships on $channel; only the sampled Nightly slice ships it" >&2
      exit 1
      ;;
  esac
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  case "$channel:$bundle_id" in
    nightly:com.cmuxterm.app | nightly:com.cmuxterm.app.nightly) ;;
    nightly-next:com.cmuxterm.app | nightly-next:com.cmuxterm.app.nightly.cmux-next) ;;
    dev:com.cmuxterm.app.debug | dev:com.cmuxterm.app.debug.*) ;;
    dev:com.cmuxterm.app | dev:com.cmuxterm.app.*) bundle_id_wrong=1 ;;
    dev:?*) ;;
    *) bundle_id_wrong=1 ;;
  esac
  if [[ -n "${bundle_id_wrong:-}" ]]; then
    echo "error: $app ($bundle_id) is not a $channel bundle; the nightly-assert variant (INVARIANT_REPORT) never ships on another channel" >&2
    exit 1
  fi
  if ! LC_ALL=C grep -aq "$invariant_marker" "$exe"; then
    echo "error: $app has no $invariant_marker; the -DINVARIANT_REPORT flag did not reach CmuxSafeConcurrency" >&2
    exit 1
  fi
  echo "invariant report: present in $exe_name (nightly-assert build)"
elif LC_ALL=C grep -aq "$invariant_marker" "$exe"; then
  echo "error: $app is a nightly-assert build (INVARIANT_REPORT: debug checks and assert() report); only the sampled Nightly slice ships it, never Release or RC" >&2
  exit 1
fi
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
# The perf lab's flags test key (FeatureRemoteSignatureCheck.benchTestPublicKey) is compiled only under
# CMUX_BENCH_HOOKS in CmuxNextFeatures; a per-target flag mismatch must not ship an app that trusts it.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_key="$(sed -n 's/^[[:space:]]*"publicKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$repo/schemas/features/bench-test-signing-key.json")"
[[ -n "$test_key" ]] || { echo "error: no publicKey in schemas/features/bench-test-signing-key.json" >&2; exit 2; }
if LC_ALL=C grep -aqF "$test_key" "$exe"; then
  echo "error: $app trusts the bench flags test key (schemas/features/bench-test-signing-key.json); it must not ship" >&2
  exit 1
fi
config="$(/usr/libexec/PlistBuddy -c 'Print :CMUXBuildConfiguration' "$app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$config" == debug ]]; then
  echo "bench hooks: none in $exe_name (a debug build declares the bench-only features)"
  exit 0
fi
features_dir="$repo/schemas/features/features.d"
shipped_bench=()
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
echo "bench hooks: none in $exe_name"

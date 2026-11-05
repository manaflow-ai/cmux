#!/usr/bin/env bash
# Builder step of the perf lab: builds the bench app of ANOTHER commit (--build-sha) with this checkout's
# harness, zips it and returns the zip as the step's artifact, content-addressed by its sha256.
#   cmux-ci run --class exclusive --script scripts/measure/perf-lab-build.sh --ref <tip> \
#     --arg=--build-sha=<40-hex sha> [--arg=--config=bench-checks] --artifact artifacts/perf-lab-build/app.zip
#
# Measure entries are blob-allowlisted, so the script always runs at the tip ref; a bisect midpoint two
# days old builds with today's script (p12-perf-process.md 3.2), as Pinpoint's build quest builds any
# revision with the current recipe and reuses the isolate it already has for that revision and target
# (catapult dashboard/dashboard/pinpoint/models/quest/find_isolate.py).
#
# - Configs are only bench and bench-checks (task 147, reload.sh --config): never a Debug app.
# - The commit builds in a persistent checkout of its own at $CI_SHARED_CACHE_DIR/perf-lab-build/src,
#   with its own submodules and its own reload.sh, and one DerivedData per config beside it, so the next
#   build on this builder is incremental (task 234 orders builds for that).
# - scripts/perf-lab/builds.py keeps one record per (sha, config) next to the zips (zips/<digest>.zip).
#   An ok record whose zip is still there is reused (cached: true); one whose zip was evicted is built
#   again and its record takes the new digest. A failure the commit causes is recorded once and never
#   built again: xcodebuild's BUILD FAILED with a compile or link error, a reload.sh with no such
#   --config, or an app whose defines are not the config's (`builds.py outcome`). Anything else (fetch,
#   submodule, GhosttyKit, disk, network, signing, a signal, BUILD INTERRUPTED) records nothing.
# - The last line is `perf-lab-build: {"sha", "config", "digest", "seconds", "status", "cached", ...}`,
#   also in artifacts/perf-lab-build/receipt.json. digest is the zip's sha256, the key the worker uploads
#   the --artifact under, so a lab host downloads the app by it (scripts/measure/perf-lab.sh, task 008).
# - It refuses to run on a perf-lab host (worker label perf-lab): those measure, they never build.
# Exit: 0 built or reused; 1 the commit did not build (now or before); 2 refused (usage, label);
#       75 the build did not finish for a reason that is not the commit's (fetch, disk, signal, cache busy).
set -euo pipefail
PERF_LAB_BUILD_VERSION=1  # names the ledger and is in the receipt; bump when a change alters what gets built
build_sha="" config=bench
for arg in "$@"; do
  case "$arg" in
    --build-sha=*) build_sha="${arg#--build-sha=}" ;;
    --config=*) config="${arg#--config=}" ;;
    *) echo "perf-lab-build: unknown argument $arg" >&2; exit 2 ;;
  esac
done
case "$config" in
  bench | bench-checks) ;;
  *) echo "perf-lab-build: --config takes bench or bench-checks (got '$config'); a lab app is never Debug" >&2; exit 2 ;;
esac
if [[ ! "$build_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "perf-lab-build: --build-sha takes a full 40-hex commit id (got '$build_sha')" >&2
  exit 2
fi
# The worker passes its configured labels (CMUX_CI_LABELS) to the step's environment.
if [[ ",${CMUX_CI_LABELS:-}," == *",perf-lab,"* ]]; then
  echo "perf-lab-build: refused: this worker has the perf-lab label; lab hosts measure, builders build" >&2
  exit 2
fi
tip="$(git rev-parse --show-toplevel)"
builds=(python3 -I "$tip/scripts/perf-lab/builds.py")
# PERF_LAB_BUILD_ROOT is the tests' seam (scripts/perf-lab/tests/test_builds.py); the fleet uses the shared cache.
root="${PERF_LAB_BUILD_ROOT:-${CI_SHARED_CACHE_DIR:+$CI_SHARED_CACHE_DIR/perf-lab-build}}"
if [[ -z "$root" ]]; then
  echo "perf-lab-build: no CI_SHARED_CACHE_DIR: run this as a fleet step" >&2
  exit 2
fi
mkdir -p "$root"
if [[ -z "${PERF_LAB_BUILD_LOCKED:-}" ]]; then
  # One build per builder cache at a time: the source checkout and DerivedData are shared by every build.
  exec "${builds[@]}" run-locked "$root/lock" -- env PERF_LAB_BUILD_LOCKED=1 bash "$0" "$@"
fi
out="$tip/artifacts/perf-lab-build"
rm -rf "$out"
mkdir -p "$out"
ledger="$root/v$PERF_LAB_BUILD_VERSION"
zips="$ledger/zips"
src="$root/src"
tag="perf-lab-build"
mkdir -p "$zips"

infra() { echo "perf-lab-build: $*; nothing recorded" >&2; exit 75; }

publish() {  # $1: cached (true|false). Prints and keeps the receipt; returns the record's exit code.
  local receipt_args=(receipt --ledger "$ledger" --sha "$build_sha" --config "$config")
  [[ "$1" == true ]] && receipt_args+=(--cached)
  "${builds[@]}" "${receipt_args[@]}" > "$out/receipt.json"
  python3 -I - "$out/receipt.json" "$PERF_LAB_BUILD_VERSION" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1]))
receipt["build_version"] = int(sys.argv[2])
json.dump(receipt, open(sys.argv[1], "w"), sort_keys=True)
PY
  echo "perf-lab-build: $(cat "$out/receipt.json")"
  [[ "$("${builds[@]}" status --ledger "$ledger" --sha "$build_sha" --config "$config")" == ok ]]
}

record_failed() {  # $1: seconds, $2: reason
  if [[ "$("${builds[@]}" status --ledger "$ledger" --sha "$build_sha" --config "$config")" == ok ]]; then
    infra "$build_sha ($config) built before, so this failure is the builder's: $2"
  fi
  "${builds[@]}" record --ledger "$ledger" --sha "$build_sha" --config "$config" --status failed \
    --seconds "$1" --reason "$2" --job "${CMUX_CI_STEP_KEY:-}" > /dev/null
  publish false || exit 1
}

case "$("${builds[@]}" status --ledger "$ledger" --sha "$build_sha" --config "$config")" in
  failed)
    echo "perf-lab-build: $build_sha ($config) failed to build before; a failed build is never retried" >&2
    publish true || exit 1
    ;;
  ok)
    digest="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' \
      "$ledger/records/$build_sha-$config.json")"
    if [[ -f "$zips/$digest.zip" && "$("${builds[@]}" digest "$zips/$digest.zip")" == "$digest" ]]; then
      cp "$zips/$digest.zip" "$out/app.zip"
      touch "$zips/$digest.zip"
      echo "perf-lab-build: $build_sha ($config) from the builder cache"
      publish true
      exit 0
    fi
    echo "perf-lab-build: the cached zip of $build_sha ($config) is gone or damaged; building again" >&2
    ;;
esac

on_signal() {
  echo "perf-lab-build: signal $1; nothing recorded for $build_sha ($config)" >&2
  exit 75
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap 'on_signal HUP' HUP

# The commit's own tree, submodules and GhosttyKit. A failure here is the fleet's, not the commit's.
[[ -d "$src/.git" ]] || git init -q "$src" || infra "cannot create $src"
origin="$(git -C "$tip" remote get-url origin 2>/dev/null || true)"
if ! { [[ -n "$origin" ]] && git -C "$src" fetch -q --no-tags "$origin" "$build_sha"; }; then
  # The step's own checkout, when its origin cannot serve the commit (it has it when --ref descends from it).
  git -C "$src" fetch -q --no-tags "$tip" "$build_sha" || infra "cannot fetch $build_sha"
fi
cd "$src"
git -c advice.detachedHead=false checkout -q --force --detach "$build_sha" || infra "cannot check out $build_sha"
git clean -q -ffd
rm -rf GhosttyKit.xcframework  # ignored, so clean keeps it; it must be the one of this commit's ghostty
if [[ -f .gitmodules ]]; then
  git submodule sync -q
  for sub in ghostty ghostty-next; do
    if git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' | grep -qx "$sub"; then
      git submodule update -q --init --force --depth 1 -- "$sub" || git submodule update -q --init --force -- "$sub" \
        || infra "cannot check out the $sub submodule of $build_sha"
    fi
  done
fi
if [[ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" && -n "${CI_SHARED_CACHE_DIR:-}" ]]; then
  export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
fi
./scripts/download-prebuilt-ghosttykit.sh || infra "no prebuilt GhosttyKit for $build_sha"

if ! "${builds[@]}" supports --reload scripts/reload.sh --config "$config"; then
  record_failed 0 "reload.sh at $build_sha has no --config $config"
fi

start=$SECONDS
set +e
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config "$config" \
  --derived-data "$root/derived-$config" --no-global-cli-links > "$out/reload.log" 2>&1
rc=$?
set -e
seconds=$((SECONDS - start))
tail -n 40 "$out/reload.log"
# reload.sh writes its body (xcodebuild, the bench configuration line) to its own log, `==> log: PATH`.
build_log="$(sed -n 's/^==> log: //p' "$out/reload.log" | tail -n 1)"
if [[ -n "$build_log" && -f "$build_log" ]]; then
  cp "$build_log" "$out/build.log"
fi
verdict="$("${builds[@]}" outcome --config "$config" --rc "$rc" --log "$out/reload.log" --log "$out/build.log")" \
  || infra "cannot read how reload.sh ended ($rc)"
kind="$(sed -n 1p <<< "$verdict")"
reason="$(sed -n 2p <<< "$verdict")"
case "$kind" in
  ok) ;;
  commit) record_failed "$seconds" "$reason" ;;
  *) infra "${reason:-reload.sh ended with $rc}" ;;
esac
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  infra "reload.sh succeeded but printed no app path that exists ('$app')"
fi

name="$(basename "$app")"
if command -v ditto > /dev/null; then
  ditto -c -k --sequesterRsrc --keepParent "$app" "$out/app.zip"
else
  (cd "$(dirname "$app")" && zip -q -r -y "$out/app.zip" "$name")
fi
digest="$("${builds[@]}" digest "$out/app.zip")"
cp "$out/app.zip" "$zips/$digest.zip.tmp"
mv "$zips/$digest.zip.tmp" "$zips/$digest.zip"
defines=() names=()
read -r -a names <<< "$(sed -n 3p <<< "$verdict")" || true
for define in ${names[@]+"${names[@]}"}; do defines+=(--define "$define"); done
"${builds[@]}" record --ledger "$ledger" --sha "$build_sha" --config "$config" --status ok --seconds "$seconds" \
  --digest "$digest" --app "$name" --job "${CMUX_CI_STEP_KEY:-}" ${defines[@]+"${defines[@]}"} > /dev/null
# Keep the 20 newest zips; an evicted zip's commit is rebuilt on demand and its record takes the new digest.
# shellcheck disable=SC2012 # the names are 64-hex digests
ls -1t "$zips"/*.zip 2>/dev/null | tail -n +21 | while read -r old; do rm -f "$old"; done
publish false

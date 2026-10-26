#!/usr/bin/env bash
# Runs SwiftPM on the Linux tier of Packages/macOS/CmuxNext (and, with --shared,
# on the Shared/iOS packages) without writing to the checkout (p15-oracle-229,
# p15-oracle-004).
#
# The checkout's Package.resolved pins the macOS graph (Sparkle, sentry-cocoa).
# The Linux mode of the manifest (CMUX_SWIFTPM_TARGET_LINUX=1) has a different
# graph, so its pins live in Package.linux.resolved. SwiftPM always writes the
# resolved file next to the root manifest, so every run uses a scratch copy:
#
#   <scratch>/src    rsync --link-dest copy of the files git sees in the
#                    worktree (tracked and unignored, edits included, no
#                    submodules): package tests read schemas/, docs/, web/
#                    and cmux-tui/ through #filePath. cmux-next-ios/ (half
#                    the worktree) is left out: no package test reads it.
#                    The ignored Linux inputs
#                    (.build-linux: FFI headers and libraries, compiled
#                    strings) are copied too. Package.resolved files are
#                    private copies: SwiftPM rewrites them in place, which
#                    would write through a hard link.
#   <scratch>/build  SwiftPM --scratch-path of the tier, outside src so builds
#                    stay incremental (build-<sanitizer> for sanitized runs,
#                    build-shared/<package> for the shared packages).
#
# Every tier command gets --only-use-versions-from-resolved-file, so a
# manifest change that needs new pins fails instead of resolving silently.
# --update-resolved is the one way to change Package.linux.resolved.
#
# Usage:
#   swift-tier.sh [--scratch DIR] [--] [swift-args...]  (default swift-args: build)
#   swift-tier.sh --update-resolved
#   swift-tier.sh --print-paths
#   swift-tier.sh --all | --only T1,T2 [runner options]   the tier runner
#   swift-tier.sh --shared [--only P1,P2] [runner options] (swift-shared.sh runs this)
# Options:
#   --scratch DIR       scratch root (default $CMUX_SWIFT_TIER_SCRATCH, else
#                       /tmp/cmux-swift-tier/<hash of the checkout path>).
#                       Hard links need DIR on the checkout's mount (a bind
#                       mount of the same disk is another mount); elsewhere
#                       the first run copies about 530 MB and later runs
#                       copy only changed files.
#   --update-resolved   resolve without the lock and write the result to
#                       Package.linux.resolved (seeded from it, or from the
#                       macOS Package.resolved the first time, so shared pins
#                       keep the macOS versions).
#   --print-paths       print the source copy, package path and scratch path.
# Runner options (any of them selects the runner):
#   --receipt FILE              receipt JSON (default <out>/receipt.json)
#   --errors-queue FILE         compiler-error queue, JSON lines (default
#                               <out>/errors-queue.jsonl)
#   --measure-incremental T     after the run, edit one file of target T and
#                               time `swift build --target T` (budget 30 s)
#   --sanitize thread|address   build and test with the sanitizer
#   --jobs N                    swift build -j (default 240)
#   --workers N                 swift test --num-workers (default 200)
#   --packages-at-once N        shared packages built at once (default 6)
#   --build-timeout S, --test-timeout S   per step (default 3600, 1800)
# Runner flow (tier): resolve, dump the Linux-mode manifest, then
#   `swift build --build-tests -j 240`. When that fails, every planned target
#   builds alone in dependency order, so each compiler error lands in the queue
#   under its own target, and a target whose dependency failed is `blocked`.
#   The red targets leave a pruned scratch linux-tier.json and the test product
#   links again, so the green test targets still run:
#   `swift test --parallel --num-workers 200` per tier test target.
#   errors_queue.py writes the receipt (sha, toolchain, targets built/failed,
#   tests executed/passed/failed, wall times) and the queue: one JSON line per
#   file cluster of <= 400 lines in one target (Jarred's method for Bun's
#   port). Exit 1 on any red no `[ linux ]` line in
#   tests/oracle/Expectations.d/swift-tier.txt (swift-shared.txt) expects.
#   Logs and xunit files go to $CMUX_LINUX_OUT (default $TMPDIR/oracle).
#   The runner is for agents on the VM; no CI job runs it.
# Environment:
#   SWIFT               swift executable (default: swift on PATH; install it
#                       with scripts/cmux-next/linux/setup-swift.sh).
#
# Examples:
#   swift-tier.sh build --target CmuxNextCompat -j 240
#   swift-tier.sh test --filter CmuxNextCompatTests --parallel
#   swift-tier.sh package dump-package
#   swift-tier.sh --all --receipt /tmp/oracle/linux-tier.json
#   swift-tier.sh --only CmuxNextTerminalGeometry --measure-incremental CmuxNextTerminalGeometry
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
package_rel="Packages/macOS/CmuxNext"
checkout_resolved="$repo_root/$package_rel/Package.resolved"
linux_resolved="$repo_root/$package_rel/Package.linux.resolved"
queue_py=("${PYTHON:-python3}" -I -B "$here/errors_queue.py") # -B: no __pycache__ in the checkout

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
die() { echo "error: $*" >&2; exit 2; }
need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }

scratch_root="${CMUX_SWIFT_TIER_SCRATCH:-}"
mode=run
runner=""
only=""
receipt=""
errors_queue=""
measure=""
sanitize=""
jobs=240
workers=200
packages_at_once=6
build_timeout=3600
test_timeout=1800
while (($#)); do
  case "$1" in
    --scratch) need_value "$@"; scratch_root="$2"; shift 2 ;;
    --scratch=*) scratch_root="${1#--scratch=}"; shift ;;
    --update-resolved) mode=update; shift ;;
    --print-paths) mode=paths; shift ;;
    --all) runner="${runner:-tier}"; shift ;;
    --shared) runner=shared; shift ;;
    --only) need_value "$@"; runner="${runner:-tier}"; only="$2"; shift 2 ;;
    --receipt) need_value "$@"; runner="${runner:-tier}"; receipt="$2"; shift 2 ;;
    --errors-queue) need_value "$@"; runner="${runner:-tier}"; errors_queue="$2"; shift 2 ;;
    --measure-incremental) need_value "$@"; runner="${runner:-tier}"; measure="$2"; shift 2 ;;
    --sanitize)
      need_value "$@"; runner="${runner:-tier}"; sanitize="$2"; shift 2
      case "$sanitize" in thread|address) ;; *) die "--sanitize takes thread or address, not $sanitize" ;; esac ;;
    --jobs) need_value "$@"; runner="${runner:-tier}"; jobs="$2"; shift 2 ;;
    --workers) need_value "$@"; runner="${runner:-tier}"; workers="$2"; shift 2 ;;
    --packages-at-once) need_value "$@"; runner="${runner:-tier}"; packages_at_once="$2"; shift 2 ;;
    --build-timeout) need_value "$@"; runner="${runner:-tier}"; build_timeout="$2"; shift 2 ;;
    --test-timeout) need_value "$@"; runner="${runner:-tier}"; test_timeout="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [[ "$mode" != run && $# -gt 0 ]]; then
  die "--update-resolved and --print-paths take no swift arguments"
fi
if [[ -n "$runner" ]]; then
  [[ "$mode" == run ]] || die "runner options do not combine with --update-resolved or --print-paths"
  (($# == 0)) || die "runner options take no swift arguments: $*"
  [[ "$runner" == tier || -z "$measure" ]] || die "--measure-incremental is a tier option"
  for n in "$jobs" "$workers" "$packages_at_once" "$build_timeout" "$test_timeout"; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "want a positive number, not $n"
  done
  mode="$runner"
fi
swift_args=("$@")
((${#swift_args[@]})) || swift_args=(build)

if [[ -z "$scratch_root" ]]; then
  checkout_key="$(printf '%s' "$repo_root" | sha256sum | cut -c1-12)"
  scratch_root="/tmp/cmux-swift-tier/$checkout_key"
fi
case "$scratch_root" in
  ""|"/") die "the scratch root must name a directory" ;;
  "$repo_root"|"$repo_root"/*) die "the scratch root must be outside the checkout" ;;
esac
src="$scratch_root/src"
package_path="$src/$package_rel"
san_suffix="${sanitize:+-$sanitize}"
build="$scratch_root/build$san_suffix"

if [[ "$mode" == paths ]]; then
  printf 'src=%s\npackage-path=%s\nscratch-path=%s\n' "$src" "$package_path" "$build"
  exit 0
fi

[[ "$(uname -s)" == Linux ]] || { echo "error: Linux only; on a Mac use the fleet (cmux-ci)" >&2; exit 1; }
swift_bin="${SWIFT:-swift}"
command -v "$swift_bin" >/dev/null 2>&1 || {
  echo "error: $swift_bin not found; run scripts/cmux-next/linux/setup-swift.sh" >&2
  exit 1
}
for tool in rsync flock git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done
if [[ "$mode" != update && "$mode" != shared && ! -f "$linux_resolved" ]]; then
  echo "error: $package_rel/Package.linux.resolved is missing; run $0 --update-resolved" >&2
  exit 1
fi

mkdir -p "$src" "$build"
# One run per scratch root: two runs would rsync over each other's sources.
exec 9>"$scratch_root/lock"
if ! flock -n 9; then
  echo "swift-tier: another run holds $scratch_root/lock; waiting for it" >&2
  flock 9
fi

resolved_digest() { sha256sum "$checkout_resolved" 2>/dev/null || echo missing; }
checkout_resolved_before="$(resolved_digest)"
export CMUX_SWIFTPM_TARGET_LINUX=1

copy_excludes=(cmux-next-ios)
# --link-dest only where link(2) works: across mounts rsync copies regular
# files but fails on symlinks.
link_dest() {
  rm -f "$scratch_root/link-probe"
  if ln "$repo_root/$package_rel/Package.swift" "$scratch_root/link-probe" 2>/dev/null; then
    rm -f "$scratch_root/link-probe"
    printf -- '--link-dest=%s\n' "$1"
  fi
}

# The worktree as git sees it, minus submodules, deleted files and copy_excludes.
sync_src() {
  local list="$scratch_root/files" link_flags=() ex
  mapfile -t link_flags < <(link_dest "$repo_root/")
  {
    git -C "$repo_root" ls-files -s | awk '$1 == "160000" { print $4 }'
    git -C "$repo_root" ls-files --deleted
  } | LC_ALL=C sort -u >"$scratch_root/skip"
  ex="$(printf '%s/\n' "${copy_excludes[@]}")"
  git -C "$repo_root" ls-files -co --exclude-standard | LC_ALL=C sort -u \
    | LC_ALL=C comm -23 - "$scratch_root/skip" \
    | awk -v ex="$ex" 'BEGIN { n = split(ex, dirs, "\n") } { for (i = 1; i <= n; i++) if (dirs[i] != "" && index($0, dirs[i]) == 1) next; print }' \
      >"$list"
  rsync -a "${link_flags[@]}" --files-from="$list" "$repo_root/" "$src/"
  # Files that left the worktree since the last run leave the copy too.
  (cd "$src" && find . \( -name .build-linux -o -name .build -o -name .swiftpm \) -prune -o \( -type f -o -type l \) -print) \
    | sed 's|^\./||' | LC_ALL=C sort | LC_ALL=C comm -13 "$list" - \
    | while IFS= read -r stale; do rm -f -- "$src/$stale"; done
  local gen
  for gen in .build-linux "$package_rel/.build-linux"; do
    if [[ -d "$repo_root/$gen" ]]; then
      mkdir -p "$src/$gen"
      mapfile -t link_flags < <(link_dest "$repo_root/$gen/")
      rsync -a --delete "${link_flags[@]}" "$repo_root/$gen/" "$src/$gen/"
    fi
  done
  local resolved
  while IFS= read -r -d '' resolved; do
    cp -p "$resolved" "$resolved.cmux-tmp"
    mv -f "$resolved.cmux-tmp" "$resolved"
  done < <(find "$src" -name Package.resolved -links +1 -print0)
}

# SwiftPM checks a forced resolved file against its workspace state, so a pin
# missing from the file passes on a scratch that already checked it out. Drop
# the state when the pins change; a warm scratch then fails like a cold one.
pins_marker="$build/cmux-linux-resolved.sha256"
pins_digest() { sha256sum <"$1" | cut -d' ' -f1; }
stage_linux_resolved() {
  rm -f "$package_path/Package.resolved"
  cp "$linux_resolved" "$package_path/Package.resolved"
  digest="$(pins_digest "$linux_resolved")"
  if [[ "$(cat "$pins_marker" 2>/dev/null)" != "$digest" ]]; then
    rm -f "$pins_marker" "$build/workspace-state.json"
  fi
}
checkout_unchanged() { [[ "$(resolved_digest)" == "$checkout_resolved_before" ]]; }

t_sync="$EPOCHREALTIME"
sync_src

if [[ "$mode" == update ]]; then
  rm -f "$package_path/Package.resolved"
  if [[ -f "$linux_resolved" ]]; then
    cp "$linux_resolved" "$package_path/Package.resolved"
  elif [[ -f "$checkout_resolved" ]]; then
    cp "$checkout_resolved" "$package_path/Package.resolved"
  fi
  "$swift_bin" package --package-path "$package_path" --scratch-path "$build" resolve
  cp "$package_path/Package.resolved" "$linux_resolved.tmp"
  mv "$linux_resolved.tmp" "$linux_resolved"
  pins_digest "$linux_resolved" >"$pins_marker"
  echo "wrote $package_rel/Package.linux.resolved"
  checkout_unchanged || { echo "error: $package_rel/Package.resolved changed during the run" >&2; exit 1; }
  exit 0
fi

if [[ "$mode" == run ]]; then
  stage_linux_resolved
  status=0
  # swift package takes these options before its subcommand; build, test and
  # run take them anywhere.
  "$swift_bin" "${swift_args[0]}" --package-path "$package_path" --scratch-path "$build" \
    --only-use-versions-from-resolved-file "${swift_args[@]:1}" || status=$?
  ((status)) || echo "$digest" >"$pins_marker"
  checkout_unchanged || { echo "error: $package_rel/Package.resolved changed during the run" >&2; exit 1; }
  exit "$status"
fi

# ------------------------------------------------------------------ runner

suite="swift-$mode"
sha="$(git -C "$repo_root" rev-parse HEAD)"
dirty=0
[[ -z "$(git -C "$repo_root" status --porcelain -- Packages vendor)" ]] || dirty=1
toolchain="$("$swift_bin" --version 2>/dev/null | head -1)"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="${CMUX_LINUX_OUT:-${TMPDIR:-/tmp}/oracle}/$suite/${sha:0:12}$( ((dirty)) && echo -dirty)$san_suffix-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out/logs" "$out/xunit"
receipt="${receipt:-$out/receipt.json}"
errors_queue="${errors_queue:-$out/errors-queue.jsonl}"
ledger="$out/ledger.tsv"
: >"$ledger"
resolved_file=""

since() { awk -v a="$1" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.3f", b - a }'; }
# record CASE KIND STATUS EXIT SECONDS [LOG] [XUNIT]: one ledger line for errors_queue.py.
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$1" "$2" "$3" "$4" "$5" "${6:-}" "${7:-}" >>"$ledger"; }
phase() { record "$1" phase pass 0 "$(since "$2")"; }
status_of() { case "$1" in 0) echo pass ;; 124) echo timeout ;; *) echo fail ;; esac; }
# logged LOG LIMIT CMD...: output to LOG only; returns the command's exit status.
logged() {
  local log="$1" limit="$2" rc=0
  shift 2
  timeout --kill-after=30 "$limit" "$@" >"$log" 2>&1 || rc=$?
  return "$rc"
}
swift_flags=(-j "$jobs")
[[ -n "$sanitize" ]] && swift_flags+=(--sanitize "$sanitize")
phase sync "$t_sync"

finish() {
  local unchanged=1 rc=0
  checkout_unchanged || unchanged=0
  "${queue_py[@]}" receipt --ledger "$ledger" --receipt "$receipt" --errors-queue "$errors_queue" \
    --repo "$repo_root" --strip "$src" --strip "$scratch_root" \
    --meta "suite=$suite" --meta "runner=$suite.sh" --meta "sha=$sha" --meta "dirty=$dirty" \
    --meta "toolchain=$toolchain" --meta "sanitize=$sanitize" --meta "started_at=$started" \
    --meta "jobs=$jobs" --meta "workers=$workers" --meta "resolved_file=$resolved_file" \
    --meta "checkout_resolved_unchanged=$unchanged" || rc=$?
  echo "logs: $out"
  exit "$rc"
}

# ---------------------------------------------------------- shared packages

run_package() {
  local pkg_rel="$1" name pkg_build log rc t
  name="$(basename "$pkg_rel")"
  pkg_build="$scratch_root/build-shared/$name$san_suffix"
  log="$out/logs/$name.build.log"
  t="$EPOCHREALTIME"
  rc=0
  logged "$log" "$build_timeout" "$swift_bin" build --package-path "$src/$pkg_rel" --scratch-path "$pkg_build" \
    --build-tests "${swift_flags[@]}" || rc=$?
  record "$name" package "$(status_of "$rc")" "$rc" "$(since "$t")" "$log"
  [[ "$rc" == 0 && -d "$src/$pkg_rel/Tests" ]] || return 0
  t="$EPOCHREALTIME"
  rc=0
  log="$out/logs/$name.test.log"
  logged "$log" "$test_timeout" "$swift_bin" test --package-path "$src/$pkg_rel" --scratch-path "$pkg_build" \
    --skip-build "${swift_flags[@]}" --parallel --num-workers "$workers" --xunit-output "$out/xunit/$name.xml" || rc=$?
  record "$name" test "$(status_of "$rc")" "$rc" "$(since "$t")" "$log" "$out/xunit/$name.xml"
}

if [[ "$mode" == shared ]]; then
  resolved_file="each package's own Package.resolved, in the scratch copy"
  mapfile -t packages < <("${queue_py[@]}" shared-packages --repo "$repo_root")
  if [[ -n "$only" ]]; then
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | awk -v only=",$only," '{ n = $0; sub(".*/", "", n) } index(only, "," n ",")')
  fi
  ((${#packages[@]})) || { echo "swift-shared: no package matches" >&2; finish; }
  echo "swift-shared: ${#packages[@]} packages, $packages_at_once at a time -> $out"
  t0="$EPOCHREALTIME"
  running=0
  for pkg in "${packages[@]}"; do
    if ((running >= packages_at_once)); then
      wait -n || true
      running=$((running - 1))
    fi
    run_package "$pkg" &
    running=$((running + 1))
  done
  wait || true
  phase build-and-test "$t0"
  finish
fi

# --------------------------------------------------------------- tier setup

tier_json="$package_path/linux-tier.json"
resolved_file="$package_rel/Package.linux.resolved"
pkg_flags=(--package-path "$package_path" --scratch-path "$build" --only-use-versions-from-resolved-file)
stage_linux_resolved

t0="$EPOCHREALTIME"
rc=0
logged "$out/logs/resolve.log" "$build_timeout" "$swift_bin" package "${pkg_flags[@]}" resolve || rc=$?
record resolve setup "$(status_of "$rc")" "$rc" "$(since "$t0")" "$out/logs/resolve.log"
resolve_ok="$rc"
((rc)) || echo "$digest" >"$pins_marker"
phase resolve "$t0"

rc=0
"$swift_bin" package "${pkg_flags[@]}" dump-package >"$out/dump.json" 2>"$out/logs/dump.log" || rc=$?
if ((rc)); then
  record dump-package setup fail "$rc" 0 "$out/logs/dump.log"
  finish
fi

tier_args=()
[[ -f "$tier_json" ]] && tier_args=(--tier "$tier_json")
mapfile -t plan_rows < <("${queue_py[@]}" plan --dump "$out/dump.json" "${tier_args[@]}" --suite "$suite" --sanitize "$sanitize")
all_rows=("${plan_rows[@]}")
if [[ -n "$only" ]]; then
  mapfile -t plan_rows < <(printf '%s\n' "${plan_rows[@]}" | awk -F'\t' -v only=",$only," 'index(only, "," $2 ",")')
fi
((${#plan_rows[@]})) || { echo "swift-tier: the plan is empty" >&2; finish; }
echo "swift-tier: ${#plan_rows[@]} targets$([[ -f "$tier_json" ]] || echo ' (no linux-tier.json: every manifest target)') -> $out"

declare -A state=() # target -> pass | fail | timeout | blocked | skip
test_targets=()
for row in "${plan_rows[@]}"; do
  IFS=$'\t' read -r kind name _ _ _ <<<"$row"
  if [[ "$kind" == missing ]]; then
    echo "error: tier target $name is not a target of the Linux-mode manifest" >"$out/logs/$name.missing.log"
    record "$name" missing fail 1 0 "$out/logs/$name.missing.log"
  fi
  [[ "$kind" == test ]] && test_targets+=("$name")
done
ledger_kind() { [[ "$1" == test ]] && echo build-test || echo build; }

if ((resolve_ok)); then
  for row in "${plan_rows[@]}"; do
    IFS=$'\t' read -r kind name _ _ _ <<<"$row"
    [[ "$kind" == missing ]] || record "$name" "$(ledger_kind "$kind")" blocked 0 0
  done
  finish
fi

# --------------------------------------------------------------- tier build

t0="$EPOCHREALTIME"
rc=1 # a subset builds target by target
if [[ -z "$only" ]]; then
  rc=0
  logged "$out/logs/build-all.log" "$build_timeout" "$swift_bin" build "${pkg_flags[@]}" --build-tests "${swift_flags[@]}" || rc=$?
  phase build-all "$t0"
fi

if ((rc == 0)); then
  for row in "${plan_rows[@]}"; do
    IFS=$'\t' read -r kind name _ _ _ <<<"$row"
    [[ "$kind" == missing ]] && continue
    state[$name]=pass
    record "$name" "$(ledger_kind "$kind")" pass 0 0
  done
else
  # One target at a time in dependency order: every error lands under its own target.
  t0="$EPOCHREALTIME"
  for row in "${plan_rows[@]}"; do
    IFS=$'\t' read -r kind name deps skip _ <<<"$row"
    [[ "$kind" == missing ]] && continue
    if [[ "$skip" == 1 ]]; then
      state[$name]=skip
      record "$name" "$(ledger_kind "$kind")" skip 0 0
      continue
    fi
    blocked=""
    if [[ "$deps" != - ]]; then
      IFS=, read -r -a dep_list <<<"$deps"
      for dep in "${dep_list[@]}"; do
        case "${state[$dep]:-pass}" in pass) ;; *) blocked="$dep" ;; esac
      done
    fi
    if [[ -n "$blocked" ]]; then
      state[$name]=blocked
      record "$name" "$(ledger_kind "$kind")" blocked 0 0
      continue
    fi
    t="$EPOCHREALTIME"
    rc=0
    logged "$out/logs/$name.build.log" "$build_timeout" "$swift_bin" build "${pkg_flags[@]}" --target "$name" "${swift_flags[@]}" || rc=$?
    state[$name]="$(status_of "$rc")"
    record "$name" "$(ledger_kind "$kind")" "${state[$name]}" "$rc" "$(since "$t")" "$out/logs/$name.build.log"
    echo "  ${state[$name]} $name"
  done
  phase build-targets "$t0"

  # The test product links every test target: drop the red ones (and, with
  # --only, the unselected ones) from the scratch tier file and link again.
  runnable=()
  for name in "${test_targets[@]}"; do [[ "${state[$name]:-}" == pass ]] && runnable+=("$name"); done
  if ((${#runnable[@]})); then
    drop=()
    for row in "${all_rows[@]}"; do
      IFS=$'\t' read -r _ name _ _ _ <<<"$row"
      [[ "${state[$name]:-}" == pass ]] || drop+=("$name")
    done
    if [[ -f "$tier_json" ]] && ((${#drop[@]})); then
      "${queue_py[@]}" prune-tier --tier "$tier_json" --out "$tier_json.pruned" "${drop[@]}"
      rm -f "$tier_json" # a hard link to the checkout's file: replace it, never write through it
      mv "$tier_json.pruned" "$tier_json"
      # SwiftPM caches the evaluated manifest by its text, not by the files it
      # reads: a private Package.swift with the drop list is a new manifest.
      manifest="$package_path/Package.swift"
      cp -p "$manifest" "$manifest.cmux-tmp"
      mv -f "$manifest.cmux-tmp" "$manifest"
      printf '\n// swift-tier.sh dropped: %s\n' "${drop[*]}" >>"$manifest"
    fi
    t0="$EPOCHREALTIME"
    rc=0
    logged "$out/logs/test-product.log" "$build_timeout" "$swift_bin" build "${pkg_flags[@]}" --build-tests "${swift_flags[@]}" || rc=$?
    record test-product setup "$(status_of "$rc")" "$rc" "$(since "$t0")" "$out/logs/test-product.log"
    phase test-product "$t0"
    if ((rc)); then
      for name in "${runnable[@]}"; do state[$name]=blocked; done
    fi
  fi
fi

# ---------------------------------------------------------------- tier test

t0="$EPOCHREALTIME"
for name in "${test_targets[@]}"; do
  [[ "${state[$name]:-}" == pass ]] || continue
  t="$EPOCHREALTIME"
  rc=0
  logged "$out/logs/$name.test.log" "$test_timeout" "$swift_bin" test "${pkg_flags[@]}" --skip-build "${swift_flags[@]}" \
    --parallel --num-workers "$workers" --filter "^$name\\." --xunit-output "$out/xunit/$name.xml" || rc=$?
  record "$name" test "$(status_of "$rc")" "$rc" "$(since "$t")" "$out/logs/$name.test.log" "$out/xunit/$name.xml"
  echo "  test $(status_of "$rc") $name"
done
phase test "$t0"

# --------------------------------------------------------- incremental build

if [[ -n "$measure" ]]; then
  target_dir=""
  for row in "${plan_rows[@]}"; do
    IFS=$'\t' read -r _ name _ _ target_path <<<"$row"
    [[ "$name" == "$measure" ]] && target_dir="$target_path"
  done
  file=""
  if [[ -n "$target_dir" && -d "$package_path/$target_dir" ]]; then
    file="$(find "$package_path/$target_dir" -name '*.swift' -type f | LC_ALL=C sort | head -1)"
  fi
  if [[ "${state[$measure]:-}" != pass || -z "$file" ]]; then
    echo "error: $measure did not build (or has no Swift file); nothing to measure" >"$out/logs/$measure.incremental.log"
    record "$measure" incremental fail 1 0 "$out/logs/$measure.incremental.log"
  else
    # A one-line edit on a private copy: appending to the hard link would edit the checkout.
    cp -p "$file" "$file.cmux-tmp"
    mv -f "$file.cmux-tmp" "$file"
    printf '\n' >>"$file"
    t="$EPOCHREALTIME"
    rc=0
    logged "$out/logs/$measure.incremental.log" "$build_timeout" "$swift_bin" build "${pkg_flags[@]}" --target "$measure" "${swift_flags[@]}" || rc=$?
    record "$measure" incremental "$(status_of "$rc")" "$rc" "$(since "$t")" "$out/logs/$measure.incremental.log"
  fi
fi

finish

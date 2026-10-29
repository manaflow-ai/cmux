#!/usr/bin/env bash
# Runs SwiftPM on the Linux tier of Packages/macOS/CmuxNext (and, with --shared,
# on the Shared/iOS packages) without writing to the checkout.
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
# Before each SwiftPM build of the tier (not --update-resolved or --shared),
# compile-xcstrings.py writes the string tables the Linux mode takes from every
# target with a catalog (LinuxStringTables) into the source
# copy, for the targets the Linux-mode dump-package names. Without them SwiftPM
# stops on the missing folder before it compiles any Swift. The copy's tables
# and links are kept between runs, so the script rewrites only changed tables;
# the checkout's own (from a manual run) are not copied.
#
# Every tier command gets --only-use-versions-from-resolved-file, so a
# manifest change that needs new pins fails instead of resolving silently.
# A package pinned in both files must have the same revision in both, so the
# Linux tier compiles against the dependency APIs of the macOS build; a run
# fails when Package.resolved bumped a shared pin.
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
#                       Package.linux.resolved. The seed is the Linux pins
#                       with every macOS Package.resolved pin laid over them,
#                       so shared pins take the macOS revisions.
#   --print-paths       print the source copy, package path and scratch path.
# Runner options (any of them selects the runner):
#   --receipt FILE              receipt JSON (default <out>/receipt.json)
#   --errors-queue FILE         compiler-error queue, JSON lines (default
#                               <out>/errors-queue.jsonl)
#   --measure-incremental T     after the run, edit one file of target T and
#                               time `swift build --target T`; a failed build,
#                               a T that is not a planned target, or more than
#                               30 s fails the run
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
#   tests/oracle/Expectations.d/swift-tier.txt (swift-shared.txt) expects:
#   a failed build or test, a target blocked by an expected failure or a
#   Skip, a test target that executed no test, an --only name that matches
#   nothing, a failed setup step (resolve, plan, test-product link).
#   A target or package a Skip line names is neither built alone nor tested.
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

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/../../.." && pwd -P)"
package_rel="Packages/macOS/CmuxNext"
checkout_resolved="$repo_root/$package_rel/Package.resolved"
linux_resolved="$repo_root/$package_rel/Package.linux.resolved"
queue_py=("${PYTHON:-python3}" -I -B "$here/errors_queue.py") # -B: no __pycache__ in the checkout

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
die() { echo "error: $*" >&2; exit 2; }
need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }

# pins seed LINUX MACOS OUT: the Linux pins with the macOS pins laid over them
#   (macOS wins per identity), without originHash so SwiftPM checks every pin
#   against the manifest. Either input may be missing.
# pins check LINUX MACOS: fail naming each identity pinned in both files at
#   different revisions.
pins() {
  python3 -I - "$@" <<'PY'
import json, os, sys

def load(path):
    if not os.path.isfile(path):
        return {}, {}
    with open(path) as f:
        data = json.load(f)
    return data, {pin["identity"]: pin for pin in data.get("pins", [])}

def revision(pin):
    return pin.get("state", {}).get("revision")

command, linux_path, mac_path = sys.argv[1:4]
linux, linux_pins = load(linux_path)
mac, mac_pins = load(mac_path)
if command == "seed":
    seed = dict(linux or mac)
    seed.pop("originHash", None)
    merged = {**linux_pins, **mac_pins}
    seed["pins"] = [merged[identity] for identity in sorted(merged)]
    seed.setdefault("version", 3)
    with open(sys.argv[4], "w") as f:
        json.dump(seed, f, indent=2)
        f.write("\n")
else:
    drift = sorted(identity for identity in linux_pins.keys() & mac_pins.keys()
                   if revision(linux_pins[identity]) != revision(mac_pins[identity]))
    for identity in drift:
        print(f"error: shared pin {identity} differs from Package.resolved "
              f"({revision(linux_pins[identity])} in Package.linux.resolved, "
              f"{revision(mac_pins[identity])} in Package.resolved); "
              "run swift-tier.sh --update-resolved", file=sys.stderr)
    sys.exit(1 if drift else 0)
PY
}

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
# Canonical paths, so a relative path, `..` or a symlink cannot name a
# directory inside the checkout.
scratch_root="$(realpath -m -- "$scratch_root")"
case "$scratch_root" in
  "/") die "the scratch root must name a directory" ;;
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
for tool in rsync flock git python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done
if [[ "$mode" != update && "$mode" != shared && ! -f "$linux_resolved" ]]; then
  echo "error: $package_rel/Package.linux.resolved is missing; run $0 --update-resolved" >&2
  exit 1
fi
if [[ "$mode" == run || "$mode" == tier ]]; then
  pins check "$linux_resolved" "$checkout_resolved" || exit 1
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
  (cd "$src" && find . \( -name .build-linux -o -name .build -o -name .swiftpm -o -name LinuxStringTables \) -prune -o \( -type f -o -type l \) -print) \
    | sed 's|^\./||' | LC_ALL=C sort | LC_ALL=C comm -13 "$list" - \
    | while IFS= read -r stale; do rm -f -- "$src/$stale"; done
  local gen
  for gen in .build-linux "$package_rel/.build-linux"; do
    if [[ -d "$repo_root/$gen" ]]; then
      mkdir -p "$src/$gen"
      mapfile -t link_flags < <(link_dest "$repo_root/$gen/")
      # lproj/ is the copy's own compile-xcstrings.py output: kept, never copied.
      rsync -a --delete --exclude=/lproj/ "${link_flags[@]}" "$repo_root/$gen/" "$src/$gen/"
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
# The marker follows the pins, not the result: a run that fails to compile
# keeps the state, so the next run does not clone every dependency again.
pins_marker="$build/cmux-linux-resolved.sha256"
pins_digest() { sha256sum <"$1" | cut -d' ' -f1; }
stage_linux_resolved() {
  local digest
  rm -f "$package_path/Package.resolved"
  cp "$linux_resolved" "$package_path/Package.resolved"
  digest="$(pins_digest "$linux_resolved")"
  if [[ "$(cat "$pins_marker" 2>/dev/null)" != "$digest" ]]; then
    rm -f "$build/workspace-state.json"
    printf '%s\n' "$digest" >"$pins_marker"
  fi
}
checkout_unchanged() { [[ "$(resolved_digest)" == "$checkout_resolved_before" ]]; }
# compile_string_tables DUMP LOG: the Linux mode's string tables into the copy.
compile_string_tables() {
  python3 -I "$repo_root/scripts/cmux-next/linux/compile-xcstrings.py" \
    --package "$package_path" --manifest "$1" >"$2" 2>&1
}

# SwiftPM caches the evaluated manifest by its text, not by the files it reads
# (the Linux mode reads linux-tier.json): note NOTE in a private copy of the
# scratch Package.swift, so a changed tier file is a new manifest. The next
# sync puts the checkout's text back.
manifest_note() {
  local manifest="$package_path/Package.swift"
  cp -p "$manifest" "$manifest.cmux-tmp" # a hard link to the checkout: never write through it
  mv -f "$manifest.cmux-tmp" "$manifest"
  printf '\n// swift-tier.sh: %s\n' "$1" >>"$manifest"
}

t_sync="$EPOCHREALTIME"
sync_src
if [[ -f "$package_path/linux-tier.json" ]]; then
  manifest_note "linux-tier.json $(pins_digest "$package_path/linux-tier.json")"
fi

if [[ "$mode" == update ]]; then
  rm -f "$package_path/Package.resolved"
  if [[ -f "$linux_resolved" || -f "$checkout_resolved" ]]; then
    pins seed "$linux_resolved" "$checkout_resolved" "$package_path/Package.resolved"
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
  manifest_dump="$build/cmux-linux-manifest.json"
  "$swift_bin" package --package-path "$package_path" --scratch-path "$build" \
    dump-package >"$manifest_dump"
  compile_string_tables "$manifest_dump" "$build/cmux-linux-string-tables.log" \
    || { echo "error: compile-xcstrings.py failed (log: $build/cmux-linux-string-tables.log)" >&2; exit 1; }
  status=0
  # swift package takes these options before its subcommand; build, test and
  # run take them anywhere.
  "$swift_bin" "${swift_args[0]}" --package-path "$package_path" --scratch-path "$build" \
    --only-use-versions-from-resolved-file "${swift_args[@]:1}" || status=$?
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
# record CASE KIND STATUS EXIT SECONDS [LOG] [XUNIT] [DETAIL]: one ledger line
# for errors_queue.py. DETAIL of a blocked step names the step that blocked it.
record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$1" "$2" "$3" "$4" "$5" "${6:-}" "${7:-}" "${8:-}" >>"$ledger"
}
phase() { record "$1" phase pass 0 "$(since "$2")"; }
status_of() { case "$1" in 0) echo pass ;; 124) echo timeout ;; *) echo fail ;; esac; }
# setup_fail STEP MESSAGE: a failed setup step with MESSAGE as its log.
setup_fail() {
  printf 'error: %s\n' "$2" >>"$out/logs/$1.log"
  record "$1" setup fail 1 0 "$out/logs/$1.log"
}
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

# select_only FIELD WHAT ROW...: only_rows gets the rows whose FIELD-th tab
# field (its last path component) --only names; each --only name that no row
# has is a `missing` red, so a typo never gives a green run of nothing.
only_rows=()
select_only() {
  local field="$1" what="$2" row name
  local -a cols wanted
  local -A named=()
  shift 2
  only_rows=()
  for row in "$@"; do
    IFS=$'\t' read -r -a cols <<<"$row"
    name="${cols[field]##*/}"
    named[$name]=1
    [[ ",$only," == *",$name,"* ]] && only_rows+=("$row")
  done
  IFS=, read -r -a wanted <<<"$only"
  for name in "${wanted[@]}"; do
    [[ -z "$name" || -n "${named[$name]:-}" ]] && continue
    echo "error: --only $name names no $what" >"$out/logs/$name.missing.log"
    record "$name" missing fail 1 0 "$out/logs/$name.missing.log"
  done
}

# ---------------------------------------------------------- shared packages

# run_package "SKIP<TAB>PATH": build with tests, then test, one package.
run_package() {
  local skip pkg_rel name pkg_build log rc t
  IFS=$'\t' read -r skip pkg_rel <<<"$1"
  name="$(basename "$pkg_rel")"
  if [[ "$skip" == 1 ]]; then
    record "$name" package skip 0 0
    return 0
  fi
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
  rc=0
  "${queue_py[@]}" shared-packages --repo "$repo_root" --suite "$suite" --sanitize "$sanitize" \
    >"$out/packages.tsv" 2>"$out/logs/plan.log" || rc=$?
  ((rc == 0)) || { setup_fail plan "errors_queue.py shared-packages exited $rc"; finish; }
  mapfile -t packages <"$out/packages.tsv"
  ((${#packages[@]})) || { setup_fail plan "no shared package found under Packages/Shared or Packages/iOS"; finish; }
  if [[ -n "$only" ]]; then
    select_only 1 "shared package" "${packages[@]}"
    packages=("${only_rows[@]}")
    ((${#packages[@]})) || finish
  fi
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
phase resolve "$t0"

rc=0
"$swift_bin" package "${pkg_flags[@]}" dump-package >"$out/dump.json" 2>"$out/logs/dump.log" || rc=$?
if ((rc)); then
  record dump-package setup fail "$rc" 0 "$out/logs/dump.log"
  finish
fi
t0="$EPOCHREALTIME"
rc=0
compile_string_tables "$out/dump.json" "$out/logs/string-tables.log" || rc=$?
record string-tables setup "$(status_of "$rc")" "$rc" "$(since "$t0")" "$out/logs/string-tables.log"
((rc == 0)) || finish

tier_args=()
[[ -f "$tier_json" ]] && tier_args=(--tier "$tier_json")
rc=0
"${queue_py[@]}" plan --dump "$out/dump.json" "${tier_args[@]}" --suite "$suite" --sanitize "$sanitize" \
  >"$out/plan.tsv" 2>"$out/logs/plan.log" || rc=$?
((rc == 0)) || { setup_fail plan "errors_queue.py plan exited $rc"; finish; }
mapfile -t plan_rows <"$out/plan.tsv"
((${#plan_rows[@]})) || { setup_fail plan "the plan is empty: the Linux-mode manifest has no tier target"; finish; }
all_rows=("${plan_rows[@]}")
if [[ -n "$only" ]]; then
  select_only 1 "tier target" "${plan_rows[@]}"
  plan_rows=("${only_rows[@]}")
  ((${#plan_rows[@]})) || finish
fi
echo "swift-tier: ${#plan_rows[@]} targets$([[ -f "$tier_json" ]] || echo ' (no linux-tier.json: every manifest target)') -> $out"

declare -A state=()   # target -> pass | fail | timeout | blocked | skip
declare -A deps_of=() # target -> comma-separated local dependencies, or -
for row in "${all_rows[@]}"; do
  IFS=$'\t' read -r _ name deps _ _ <<<"$row"
  deps_of[$name]="$deps"
done
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
    [[ "$kind" == missing ]] || record "$name" "$(ledger_kind "$kind")" blocked 0 0 "" "" resolve
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
    IFS=$'\t' read -r kind name _ skip _ <<<"$row"
    [[ "$kind" == missing ]] && continue
    if [[ "$skip" == 1 ]]; then
      state[$name]=skip
    else
      state[$name]=pass
    fi
    record "$name" "$(ledger_kind "$kind")" "${state[$name]}" 0 0
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
      record "$name" "$(ledger_kind "$kind")" blocked 0 0 "" "" "$blocked"
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

  # The test product links every test target: keep the runnable test targets,
  # the green selected targets and every target they depend on (an unselected
  # dependency of --only builds implicitly), drop the rest from the scratch
  # tier file and link again.
  runnable=()
  for name in "${test_targets[@]}"; do [[ "${state[$name]:-}" == pass ]] && runnable+=("$name"); done
  if ((${#runnable[@]})); then
    declare -A keep=()
    keep_with_deps() {
      local name="$1" dep
      local -a dep_list
      [[ -z "${keep[$name]:-}" ]] || return 0
      keep[$name]=1
      [[ "${deps_of[$name]:--}" != - ]] || return 0
      IFS=, read -r -a dep_list <<<"${deps_of[$name]}"
      for dep in "${dep_list[@]}"; do keep_with_deps "$dep"; done
    }
    for row in "${plan_rows[@]}"; do
      IFS=$'\t' read -r _ name _ _ _ <<<"$row"
      [[ "${state[$name]:-}" == pass ]] && keep_with_deps "$name"
    done
    drop=()
    for row in "${all_rows[@]}"; do
      IFS=$'\t' read -r _ name _ _ _ <<<"$row"
      [[ -n "${keep[$name]:-}" ]] || drop+=("$name")
    done
    if [[ -f "$tier_json" ]] && ((${#drop[@]})); then
      "${queue_py[@]}" prune-tier --tier "$tier_json" --out "$tier_json.pruned" "${drop[@]}"
      rm -f "$tier_json" # a hard link to the checkout's file: replace it, never write through it
      mv "$tier_json.pruned" "$tier_json"
      manifest_note "dropped ${drop[*]}"
    fi
    t0="$EPOCHREALTIME"
    rc=0
    logged "$out/logs/test-product.log" "$build_timeout" "$swift_bin" build "${pkg_flags[@]}" --build-tests "${swift_flags[@]}" || rc=$?
    record test-product setup "$(status_of "$rc")" "$rc" "$(since "$t0")" "$out/logs/test-product.log"
    phase test-product "$t0"
    if ((rc)); then
      for name in "${runnable[@]}"; do
        state[$name]=blocked
        record "$name" build-test blocked 0 0 "" "" test-product
      done
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
  log="$out/logs/$measure.incremental.log"
  planned=0
  target_dir=""
  for row in "${plan_rows[@]}"; do
    IFS=$'\t' read -r kind name _ _ target_path <<<"$row"
    if [[ "$name" == "$measure" && "$kind" != missing ]]; then
      planned=1
      target_dir="$target_path"
    fi
  done
  file=""
  if [[ -n "$target_dir" && -d "$package_path/$target_dir" ]]; then
    file="$(find "$package_path/$target_dir" -name '*.swift' -type f | LC_ALL=C sort | head -1)"
  fi
  if ((planned == 0)); then
    echo "error: --measure-incremental $measure is not a target of this run's plan" >"$log"
    record "$measure" incremental fail 1 0 "$log"
  elif [[ "${state[$measure]:-}" != pass ]]; then
    # The target's own build result is the red (or its expected failure).
    record "$measure" incremental blocked 0 0 "" "" "$measure"
  elif [[ -z "$file" ]]; then
    echo "error: --measure-incremental $measure has no Swift file under $target_dir" >"$log"
    record "$measure" incremental fail 1 0 "$log"
  else
    # A one-line edit on a private copy: appending to the hard link would edit the checkout.
    cp -p "$file" "$file.cmux-tmp"
    mv -f "$file.cmux-tmp" "$file"
    printf '\n' >>"$file"
    t="$EPOCHREALTIME"
    rc=0
    logged "$log" "$build_timeout" "$swift_bin" build "${pkg_flags[@]}" --target "$measure" "${swift_flags[@]}" || rc=$?
    record "$measure" incremental "$(status_of "$rc")" "$rc" "$(since "$t")" "$log"
  fi
fi

finish

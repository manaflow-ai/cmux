#!/usr/bin/env bash
# Dev loop ceiling, Swift inject (goal dev-loop-ceiling): a function-body edit patched into a running
# process with no relaunch, split into stages, and each stage's floor measured on the same Mac.
#
#   scripts/measure/dev-loop/swift_inject.sh OUT [N]   (N measured edits, default 5; writes OUT/swift_inject.json)
#
# The loop is live-code-shell.sh's: the Debug view shell (Prototypes/ViewShell) runs headless with a
# live folder, Badge.swift's body is edited, Prototypes/ViewShell/inject.sh compiles and links the
# patch and drops it in the folder, the shell loads and interposes it and draws the badge to pixels
# (generation-N.png, judged by its width). An FSEvents watcher (swift_inject/probe.swift `watch`)
# runs inject.sh on each save, as a person's watcher would. inject.sh runs unchanged: its xcrun, python3,
# codesign and mv are timestamped by a shim on PATH (swift_inject/stamp.c), so each of its steps is
# a boundary. Stages: fs_event, compile, link, sign, pickup (the patch renamed into the folder to the
# shell hearing it), load (dlopen + interpose), paint (one frame), unattributed (everything else).
# Floors: one experiment each, same run (the notes in the json say which).
set -euo pipefail
out="${1:?usage: swift_inject.sh OUT [N]}"
n="${2:-5}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
package="$root/Prototypes/ViewShell"
badge="$package/Sources/ViewShell/Badge.swift"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
json="$out/swift_inject.json"
rm -f "$json"
work="$(mktemp -d "${TMPDIR:-/tmp}/dlc-swift-inject.XXXXXX")"
live="$work/live"
render="$out/render"
phase="setup"
shell="" watcher="" backed_up=""
mkdir -p "$work/bin" "$work/shim" "$work/floors" "$work/fw" "$live" "$render"
: >"$work/writes.txt"
: >"$work/stamps.log"

assemble() { # ERROR (empty: measured)
  python3 "$here/swift_inject/assemble.py" --out "$json" --work "$work" --n "$n" --root "$root" \
    --shell-log "$out/shell.log" --watch-log "$out/watch.log" --error "$1"
}
cleanup() {
  local code=$?
  [[ -n "$watcher" ]] && kill "$watcher" 2>/dev/null || true
  [[ -n "$shell" ]] && kill "$shell" 2>/dev/null || true
  if [[ -n "$backed_up" ]] && ! cmp -s "$work/Badge.swift.orig" "$badge"; then cp "$work/Badge.swift.orig" "$badge"; fi
  if [[ ! -f "$json" ]]; then
    assemble "the script stopped in $phase (exit $code); see the step log" || true
  fi
  cp "$work/stamps.log" "$out/stamps.log" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
die() { echo "swift_inject: $1" >&2; assemble "$1" || true; exit 1; }
now() { python3 -c 'import time; print(f"{time.time():.6f}")'; }
wait_for() { # FILE PATTERN SECONDS
  local i
  for ((i = 0; i < $3 * 20; i++)); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.05; done
  echo "timed out waiting for '$2' in $1" >&2; tail -30 "$1" >&2 || true
  return 1
}
[[ "$(uname)" == Darwin ]] || die "needs macOS (Xcode, the view shell, FSEvents)"
[[ -f "$badge" ]] || die "no $badge"
git -C "$root" diff --quiet -- "$badge" || die "Badge.swift has uncommitted edits; this measurement edits and restores it"

phase="building the tools"
target="$(uname -m)-apple-macos14.0"
xcrun clang -O2 "$here/swift_inject/stamp.c" -o "$work/bin/stamp"
for tool in xcrun python3 codesign mv; do ln -s "$work/bin/stamp" "$work/shim/$tool"; done
xcrun swiftc -O -swift-version 5 "$here/swift_inject/probe.swift" -o "$work/bin/probe" 2>&1 | tail -5
[[ -x "$work/bin/probe" ]] || die "probe.swift did not build"

phase="building the view shell (Debug)"
swift build --package-path "$package" --product cmux-view-shell 2>&1 | tail -3
bin="$(swift build --package-path "$package" --show-bin-path)/cmux-view-shell"
[[ -x "$bin" ]] || die "no cmux-view-shell after the build"

phase="starting the shell"
"$bin" --headless --live "$live" --live-render "$render" >"$out/shell.log" 2>&1 &
shell=$!
wait_for "$out/shell.log" "redrawn generation=0" 60 || die "the shell never drew generation 0"
cp "$badge" "$work/Badge.swift.orig"
backed_up=1

phase="starting the watcher"
# Only inject.sh sees the shim (and DLC_STAMP_LOG); the watcher and the shell run the real tools.
PATH="$work/shim:$PATH" DLC_STAMP_LOG="$work/stamps.log" TMPDIR="$work" \
  "$work/bin/probe" watch "$badge" -- "$package/inject.sh" --live "$live" "$badge" >"$out/watch.log" 2>&1 &
watcher=$!
wait_for "$out/watch.log" "^watching" 30 || die "the watcher did not start"
# The stream's own setup events pass: until watch.log has had no new "event at=" line for 0.5 s (10 s at most).
seen=-1; quiet=0
for ((i = 0; i < 100 && quiet < 5; i++)); do
  now_seen="$(grep -c "^event at=" "$out/watch.log" || true)"
  if [[ "$now_seen" == "$seen" ]]; then quiet=$((quiet + 1)); else quiet=0; seen="$now_seen"; fi
  sleep 0.1
done
(( quiet >= 5 )) || die "the watcher's stream was still reporting setup events 10 s after it started (watch.log in OUT)"

for ((k = 1; k <= n; k++)); do
  phase="round $k"
  # Each round widens the badge (padding 8 -> 8+4k), so its pixels show the edit.
  python3 - "$badge" "$((8 + 4 * k))" "$work/writes.txt" <<'PY'
import sys, time
path, pad, log = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
import re
new = re.sub(r"\.padding\(\.horizontal, \d+\)", f".padding(.horizontal, {pad})", text, count=1)
if new == text:
    sys.exit("swift_inject: no .padding(.horizontal, N) in Badge.swift to edit")
t = time.time()
with open(path, "w") as f:  # in place, one write: one save, as an editor's
    f.write(new)
open(log, "a").write(f"{t:.6f}\n")
PY
  for ((i = 0; i < 200; i++)); do (( $(grep -c "^fs_event" "$out/watch.log" || true) >= k )) && break; sleep 0.05; done
  (( $(grep -c "^fs_event" "$out/watch.log" || true) >= k )) || die "round $k: the watcher heard no save of Badge.swift in 10 s (watch.log in OUT)"
  wait_for "$out/shell.log" "redrawn generation=$k " 120 || die "round $k never redrew (watch.log and shell.log in OUT)"
  sleep 0.3  # the watcher's line for this round, and a quiet machine before the next edit
done
phase="stopping the loop"
kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; watcher=""
kill "$shell" 2>/dev/null || true; wait "$shell" 2>/dev/null || true; shell=""
cp "$work/Badge.swift.orig" "$badge"

# Floors. Each writes a JSON list of ms to $work/floors/STAGE.json.
phase="the compile floor"
sources=("$package"/Sources/ViewShell/*.swift)
flags=(-module-name ViewShell -target "$target" -Onone -g -enable-testing -DDEBUG -DSWIFT_PACKAGE -swift-version 6)
# The frontend jobs inject.sh's own driver command plans (-###), and of them the one whose primary is
# Badge.swift: the smallest unit swiftc recompiles, one primary file, the module's other files read.
(cd "$work/fw" && xcrun swiftc -c "${sources[@]}" "${flags[@]}" -### >"$work/compile-plan.txt" 2>&1) || die "swiftc -### failed"
(cd "$work/fw" && xcrun swiftc -c "${sources[@]}" "${flags[@]}" >/dev/null 2>&1) || die "the floor's module compile failed"
phase="the link floor"
(cd "$work/fw" && xcrun swiftc -emit-library Badge.o -o floor-patch.dylib -target "$target" -module-name ViewShellPatch \
  -Xlinker -undefined -Xlinker dynamic_lookup -### >"$work/link-plan.txt" 2>&1) || die "swiftc -emit-library -### failed"
python3 "$here/swift_inject/floors.py" --work "$work" --badge "$badge" --n "$n" --stamp "$work/bin/stamp" || die "the compile, link or sign floor failed"
phase="the fs_event floor"
mkdir -p "$work/fsprobe"
"$work/bin/probe" fsevents-floor "$work/fsprobe" "$n" >"$work/floors/fs_event.json" || die "the fs_event floor failed"
phase="the pickup floor"
"$work/bin/probe" pickup-floor "$work/pickup/live" "$n" >"$work/floors/pickup.json" || die "the pickup floor failed"
phase="the load floor"
printf 'int dlc_trivial(void) { return 1; }\n' >"$work/trivial.c"
xcrun clang -dynamiclib "$work/trivial.c" -o "$work/trivial.dylib"
/usr/bin/codesign --force --sign - "$work/trivial.dylib" 2>/dev/null
mkdir -p "$work/dl"
"$work/bin/probe" dlopen-floor "$work/trivial.dylib" "$work/dl" "$n" >"$work/floors/load.json" || die "the load floor failed"
phase="the paint floor"
"$work/bin/probe" paint-floor "$n" >"$work/floors/paint.json" || die "the paint floor failed"

phase="writing the json"
assemble ""

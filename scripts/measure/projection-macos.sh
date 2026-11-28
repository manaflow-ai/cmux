#!/usr/bin/env bash
# projectionfs on a Mac: what one agent checkout costs fseventsd (every path a checkout writes is a
# name fseventsd journals and keeps until reboot), as a plain git worktree, an APFS clone of one
# (wt today), a recycled checkout moved to the commit, and a projected checkout (cmux-projection
# git-mount: the commit served over NFSv3 from localhost, mounted with the Mac's own mount_nfs, no
# kernel or app extension, no prompt). Run on a fleet Mac:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/projection-macos.sh --ref SHA
#     [--arg JOBS [--arg BUILD_SHA]]
#   JOBS       checkouts made at once in the duress arms (default 10)
#   BUILD_SHA  the commit whose cmux-projection is measured (default the step's own), fetched from
#              origin: the script runs only at a reviewed commit, the code under test need not
#
# Per arm a line `PROJMAC {json}`: checkout_ms (to a usable checkout), events and paths (FSEvents
# under the scratch root, unique paths), status_ms and status_clean (the first `git status`),
# grep_ms (a `git grep` that reads every file), disk_kb. The projected arm adds write_events (an
# edit, a new file and a commit) and mount_events (FSEvents seen under the mount point itself).
# `PROJMAC-SUMMARY {json}` closes the run with fseventsd's RSS before and after. Everything this
# script makes is under one scratch root that it removes on exit, mounts unmounted first.
set -euo pipefail

jobs="${1:-10}"
build_sha="${2:-}"
[[ "$jobs" =~ ^[1-9][0-9]?$ ]] || { echo "projection-macos: JOBS must be 1-99" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || { echo "projection-macos: macOS only" >&2; exit 2; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$repo/scripts/measure/projection-macos"
rev="$(git -C "$repo" rev-parse HEAD)"
if [ -n "${CMUX_CI_XCODE_APP:-}" ]; then
  export DEVELOPER_DIR="$CMUX_CI_XCODE_APP/Contents/Developer"
fi
umask 022

root="$(mktemp -d "${TMPDIR:-/tmp}/projmac.XXXXXX")"
root="$(cd "$root" && pwd -P)"
arms="$root/arms"
mkdir -p "$arms" "$root/bin" "$root/keep" "$root/log"
mounts=()
servers=()
cleanup() {
  set +e
  for at in "${mounts[@]+"${mounts[@]}"}"; do
    /sbin/umount "$at" 2>/dev/null || /sbin/umount -f "$at" 2>/dev/null
  done
  for pid in "${servers[@]+"${servers[@]}"}"; do
    kill "$pid" 2>/dev/null
  done
  for pid in "${servers[@]+"${servers[@]}"}"; do
    wait "$pid" 2>/dev/null
  done
  git -C "$root/mirror.git" worktree prune 2>/dev/null
  rm -rf "$root"
}
trap cleanup EXIT

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
fseventsd_kb() { ps -o rss= -p "$(pgrep -x fseventsd | head -1)" 2>/dev/null | tr -d ' ' || echo 0; }
json() { python3 -c 'import json, sys; print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:])))' "$@"; }

# Builds: the counter (swiftc) and cmux-projection (cargo, this step's own target dir).
swiftc -O -o "$root/bin/fsevents-count" "$here/fsevents-count.swift"
target="$repo/.build/cmux-tui-rust-target"
src="$repo"
if [ -n "$build_sha" ]; then
  [[ "$build_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "projection-macos: BUILD_SHA must be a full SHA" >&2; exit 2; }
  source "$repo/scripts/measure/fetch-commit.sh"
  measure_fetch_commit "$repo" "$build_sha" || exit 1
  src="$root/src"
  mkdir -p "$src"
  git -C "$repo" archive "$build_sha" cmux-tui | tar -x -C "$src"
fi
(cd "$src/cmux-tui" && CARGO_TARGET_DIR="$target" cargo build --release --locked \
  -p cmux-projection --bin cmux-projection >"$root/log/cargo.log" 2>&1) || {
  tail -40 "$root/log/cargo.log" >&2; exit 1; }
projection="$target/release/cmux-projection"
counter="$root/bin/fsevents-count"

# A bare repo that borrows this checkout's objects (alternates: no copy), so the arms register
# their worktrees there, never in the step's own repo.
git clone -q --bare --shared "$repo" "$root/mirror.git"
mirror="$root/mirror.git"

watch_start() { # PATH NAME: a counter on PATH, its pid in watch_pid
  local out="$root/log/$2.watch"
  "$counter" "$1" >"$out" &
  watch_pid=$!
  local waited=0
  until grep -q ready "$out" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || { echo "projection-macos: counter on $1 never started" >&2; exit 1; }
  done
}
watch_stop() { # PID NAME: prints the counter's JSON
  sleep 2  # sleep-ok: file events arrive with the watcher's delivery latency; the counter has no caught-up signal
  kill -INT "$1"
  wait "$1" || true
  tail -1 "$root/log/$2.watch"
}
field() { python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get(sys.argv[2], 0))' "$1" "$2"; }
status_of() { # DIR: status_ms and status_clean of the first git status
  local start end porcelain
  start=$(now_ms)
  porcelain="$(git -C "$1" status --porcelain 2>&1 | head -20)"
  end=$(now_ms)
  status_ms=$((end - start))
  if [ -z "$porcelain" ]; then status_clean=true; else status_clean=false; echo "$porcelain" >"$root/log/status-$(basename "$1")"; fi
}
grep_of() { # DIR: grep_ms of a search that matches nothing (it reads every file)
  local start end
  start=$(now_ms)
  git -C "$1" grep -q -e 'zq-no-such-text-qz' >/dev/null 2>&1 || true
  end=$(now_ms)
  grep_ms=$((end - start))
}
report() { # ARM CHECKOUT_MS WATCH_JSON DIR DISK_DIR [k=v...]
  local arm="$1" ms="$2" watch="$3" dir="$4" disk="$5"
  shift 5
  status_of "$dir"
  grep_of "$dir"
  echo "PROJMAC $(json arm="$arm" checkout_ms="$ms" events="$(field "$watch" events)" \
    paths="$(field "$watch" paths)" kinds="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]).get("kinds", {})))' "$watch")" \
    status_ms="$status_ms" status_clean="$status_clean" grep_ms="$grep_ms" \
    disk_kb="$(du -sk "$disk" | cut -f1)" files="$(git -C "$mirror" ls-tree -r --name-only "$rev" | wc -l | tr -d ' ')" "$@")"
}

mount_one() { # NAME: starts a projected checkout at $arms/NAME, its server pid in servers
  local at="$arms/$1"
  "$projection" git-mount --git-dir "$mirror" --commit "$rev" --at "$at" --keep "$root/keep/$1" \
    --name "$1" --fresh --ready-file "$root/log/$1.ready" 2>"$root/log/$1.server" &
  servers+=($!)
  mounts+=("$at")
}
wait_ready() { # NAME
  local waited=0
  until [ -s "$root/log/$1.ready" ]; do
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -ge 2400 ]; then
      echo "projection-macos: $1 never got ready" >&2; cat "$root/log/$1.server" >&2; exit 1
    fi
  done
}

before_kb=$(fseventsd_kb)

# 1. A plain git worktree (what git writes for one checkout).
watch_start "$arms" worktree
start=$(now_ms)
git -C "$mirror" worktree add -q --detach "$arms/worktree" "$rev"
ms=$(( $(now_ms) - start ))
report worktree "$ms" "$(watch_stop "$watch_pid" worktree)" "$arms/worktree" "$arms/worktree"

# 2. wt today: an APFS clone of a sibling checkout, per file (clonefile), then registered.
watch_start "$arms" clone
start=$(now_ms)
git -C "$mirror" worktree add -q --no-checkout --detach "$arms/clone" "$rev"
(cd "$arms/worktree" && find . -path ./.git -prune -o -type d -print | (cd "$arms/clone" && xargs mkdir -p))
(cd "$arms/worktree" && find . -path ./.git -prune -o \( -type f -o -type l \) -print0 \
  | xargs -0 -n 500 sh -c 'for f; do cp -c -P "$f" "$0/$f"; done' "$arms/clone")
git -C "$arms/clone" reset -q
ms=$(( $(now_ms) - start ))
report clone "$ms" "$(watch_stop "$watch_pid" clone)" "$arms/clone" "$arms/clone"

# 3. A recycled checkout moved to the commit from one RECYCLE_BACK commits older (spares reused in
#    place: only the paths that differ are written).
back="${RECYCLE_BACK:-30}"
if git -C "$mirror" rev-parse -q --verify "$rev~$back^{commit}" >/dev/null; then
  git -C "$arms/worktree" checkout -q --detach "$rev~$back"
  diff_paths=$(git -C "$mirror" diff --name-only "$rev~$back" "$rev" | wc -l | tr -d ' ')
  watch_start "$arms" recycle
  start=$(now_ms)
  git -C "$arms/worktree" checkout -q --detach "$rev"
  ms=$(( $(now_ms) - start ))
  report recycle "$ms" "$(watch_stop "$watch_pid" recycle)" "$arms/worktree" "$arms/worktree" \
    back="$back" diff_paths="$diff_paths"
else
  echo "PROJMAC $(json arm=recycle skipped="no commit $back back (shallow checkout)")"
fi

# 4. Projected: served, mounted, registered as a worktree with an index of the served stat data.
watch_start "$root" projected
start=$(now_ms)
mount_one projected
wait_ready projected
ms=$(( $(now_ms) - start ))
watch=$(watch_stop "$watch_pid" projected)
report projected "$ms" "$watch" "$arms/projected" "$root/keep/projected" \
  server="$(tr -d '\n' <"$root/log/projected.ready")"

#    Writes in the mount: an edit, a new file, a commit. Counted under the whole scratch root (the
#    server's upper folder takes them) and under the mount point alone (whether xnu journals the NFS
#    vnode's own events too).
watch_start "$root" writes
whole=$watch_pid
watch_start "$arms/projected" mount-writes
mount_watch=$watch_pid
start=$(now_ms)
echo "// projmac" >>"$arms/projected/README.md"
echo "new" >"$arms/projected/projmac-new.txt"
git -C "$arms/projected" add -A
git -C "$arms/projected" -c user.name=projmac -c user.email=projmac@invalid commit -q -m projmac
committed=$(git -C "$arms/projected" log -1 --format=%s)
porcelain_after=$(git -C "$arms/projected" status --porcelain | wc -l | tr -d ' ')
ms=$(( $(now_ms) - start ))
writes=$(watch_stop "$whole" writes)
mount_writes=$(watch_stop "$mount_watch" mount-writes)
echo "PROJMAC $(json arm=projected-writes ms="$ms" write_events="$(field "$writes" events)" \
  write_paths="$(field "$writes" paths)" mount_events="$(field "$mount_writes" events)" \
  committed="$committed" dirty_after="$porcelain_after")"

#    Unmount: the server ends by itself.
start=$(now_ms)
"$projection" git-unmount --at "$arms/projected"
wait "${servers[0]}" || true
echo "PROJMAC $(json arm=projected-unmount ms="$(( $(now_ms) - start ))" \
  still_mounted="$(mount | grep -c " on $arms/projected " || true)")"

# 5. Duress: JOBS checkouts at once, each arm.
watch_start "$root" duress-projected
start=$(now_ms)
for n in $(seq 1 "$jobs"); do mount_one "p$n"; done
for n in $(seq 1 "$jobs"); do wait_ready "p$n"; done
ms=$(( $(now_ms) - start ))
watch=$(watch_stop "$watch_pid" duress-projected)
clean=0
for n in $(seq 1 "$jobs"); do
  [ -z "$(git -C "$arms/p$n" status --porcelain)" ] && clean=$((clean + 1))
done
echo "PROJMAC $(json arm=duress-projected jobs="$jobs" all_ready_ms="$ms" \
  events="$(field "$watch" events)" paths="$(field "$watch" paths)" clean="$clean")"

watch_start "$arms" duress-worktree
start=$(now_ms)
pids=()
for n in $(seq 1 "$jobs"); do
  git -C "$mirror" worktree add -q --detach "$arms/w$n" "$rev" &
  pids+=($!)
done
for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid"; done
ms=$(( $(now_ms) - start ))
watch=$(watch_stop "$watch_pid" duress-worktree)
echo "PROJMAC $(json arm=duress-worktree jobs="$jobs" all_ready_ms="$ms" \
  events="$(field "$watch" events)" paths="$(field "$watch" paths)")"

echo "PROJMAC-SUMMARY $(json rev="$rev" build_sha="${build_sha:-$rev}" fseventsd_kb_before="$before_kb" \
  fseventsd_kb_after="$(fseventsd_kb)" macos="$(sw_vers -productVersion)" \
  host_model="$(sysctl -n hw.model)")"

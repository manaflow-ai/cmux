#!/usr/bin/env bash
# acpmux-zthreads.sh: what rustc's parallel front end (-Zthreads=N) does to acpmux's incremental release
# rebuild on a real merge, measured the way the machine channel's thin leg builds (LTO off, 16 codegen units,
# incremental). For each N it builds acpmux at BASE, then at HEAD reusing that incremental state, and prints
# HEAD's wall time, the peak RSS of the biggest child (rustc) and the rlib's sha256.
#
# usage: scripts/measure/acpmux-zthreads.sh BASE_SHA HEAD_SHA [N ...]   (default N: 1 4 8)
# CI:    cmux-ci test --setup rust --timeout 170 -- scripts/measure/acpmux-zthreads.sh BASE HEAD 1 4 8
# Needs more memory than rustc's plain peak (about 15 GiB at -j6) times the thread factor.
set -uo pipefail
base=$1 head=$2
shift 2
[[ $# -gt 0 ]] || set -- 1 4 8
root=$(git rev-parse --show-toplevel)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/acpmux-zthreads.XXXXXX")
out=${FAST_CHECKS_OUT:-$work/out}
mkdir -p "$out"
jobs=${J:-16}

echo "host: nproc=$(nproc) mem=$(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo) $(rustc -V) -j$jobs"
git -C "$root" fetch -q origin "$base" "$head" 2>/dev/null || git -C "$root" fetch -q --depth=400 origin "$base" "$head"
git -C "$root" worktree add -q --detach "$work/wt" "$base" || exit 1
cd "$work/wt" || exit 1

export RUSTC_WRAPPER='' CARGO_TARGET_DIR="$work/target" RUSTC_BOOTSTRAP=1
export CARGO_PROFILE_RELEASE_LTO=off CARGO_PROFILE_RELEASE_INCREMENTAL=true

# build REV LABEL N: one acpmux lib build; prints "LABEL wall_s maxrss_gib rc"
build() {
  git checkout -q --detach "$1" && git submodule update -q --init ghostty-next 2>/dev/null
  (cd cmux-tui && python3 -I -c '
import resource, subprocess, sys, time
s = time.time()
rc = subprocess.call(sys.argv[2:], stdout=open(sys.argv[1], "w"), stderr=subprocess.STDOUT)
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1048576
print(f"{time.time() - s:.0f} {rss:.1f} {rc}")' "$out/$2.log" \
    cargo rustc -j "$jobs" -p acpmux --lib --release --locked \
      --config 'profile.release.package.acpmux.codegen-units=16' \
      --config 'profile.release.package.cmux-tui-core.codegen-units=16' -- "-Zthreads=$3")
}

printf '%-8s %8s %8s %8s %8s  %s\n' threads base_s head_s rss_gib rc rlib_sha256 | tee "$out/summary.txt"
for n in "$@"; do
  read -r bw _ brc < <(build "$base" "base-t$n" "$n")
  read -r hw hrss hrc < <(build "$head" "head-t$n" "$n")
  rlib=$(ls -t "$CARGO_TARGET_DIR"/release/deps/libacpmux-*.rlib 2>/dev/null | head -1)
  sha=$( [[ -n $rlib ]] && sha256sum "$rlib" | cut -c1-16 || echo none)
  printf '%-8s %8s %8s %8s %8s  %s\n' "$n" "$bw" "$hw" "$hrss" "$brc/$hrc" "$sha" | tee -a "$out/summary.txt"
done
git -C "$root" worktree remove --force "$work/wt"

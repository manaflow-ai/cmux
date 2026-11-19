#!/usr/bin/env bash
# Scratch bisect harness for the webui.update_one perf rows (cmux#24569); not for merge.
# Rebuilds older webviews trees from this checkout by applying chain.txt's patches (tip -> each SHA,
# webviews + release-notes/next + schemas), then runs the cron's web-ui-scale command
# (bun bench/update-one.bench.ts --changes 20 --turns 1000, as web-ui-suite.ts --only update-one does)
# on every tree interleaved (A B C .. A B C ..), each run pinned to 4 cores like the cron's 4 vCPU host.
#   bash perf-bisect-scratch/run.sh ROUNDS TAG [TAG...]     (TAG "tip" is this checkout)
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
here="$root/perf-bisect-scratch"
rounds=$1; shift
out="${FAST_CHECKS_OUT:-/tmp/pbu-out}"
mkdir -p "$out"
work="${RUNNER_TEMP:-/tmp}/pbu-trees"
mkdir -p "$work"

shell_line=
# PBU_BUILD_ONLY=1: only rebuild the trees (a local check of the chain), no browser, install or bench.
[ -n "${PBU_BUILD_ONLY:-}" ] || shell_line=$(bash "$root/scripts/ci/ensure-system-chrome.sh" --optional 2>&1 | tee "$out/chrome.txt" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | tail -n 1)
export "${shell_line:-CMUX_CHROME_HEADLESS_SHELL=}"
echo "headless shell: ${CMUX_CHROME_HEADLESS_SHELL:-none}" | tee -a "$out/summary.txt"
nproc | sed 's/^/nproc /' | tee -a "$out/summary.txt"

tree_of() { if [ "$1" = tip ]; then echo "$root"; else echo "$work/$1"; fi; }

build() { # build TAG: its parent first, then copy the parent's three dirs and apply the patch
  local tag=$1 parent patch dir pdir
  [ "$tag" = tip ] && return 0
  [ -d "$work/$tag/webviews" ] && return 0
  read -r _ parent patch < <(grep "^$tag " "$here/chain.txt")
  [ -n "${patch:-}" ] || { echo "no chain entry for $tag"; return 1; }
  build "$parent" || return 1
  pdir=$(tree_of "$parent"); dir="$work/$tag"
  mkdir -p "$dir/release-notes"
  for top in "$root"/* "$root"/.github; do
    name=$(basename "$top")
    case "$name" in webviews|release-notes|schemas|perf-bisect-scratch) ;; *) ln -s "$top" "$dir/$name" ;; esac
  done
  # From the tip only its tracked files (the job's setup has already installed it); a derived parent is clean.
  if [ "$parent" = tip ]; then
    (cd "$root" && git ls-files -z webviews schemas release-notes/next | tar --null -T - -cf -) | (cd "$dir" && tar -xf -)
  else
    (cd "$pdir" && tar -cf - webviews schemas release-notes/next) | (cd "$dir" && tar -xf -)
  fi
  (cd "$dir" && gzip -dc "$here/patches/$patch" | git apply --binary --whitespace=nowarn -) || { echo "apply failed: $tag"; return 1; }
  echo "built $tag from $parent"
}

# Every tree before any install: a tree is copied from its parent's, which must not carry an install's
# generated files yet.
for tag in "$@"; do build "$tag" || exit 1; done
[ -n "${PBU_BUILD_ONLY:-}" ] && exit 0
for tag in "$@"; do
  dir=$(tree_of "$tag")
  (cd "$dir/webviews" && bun install --frozen-lockfile > "$out/install-$tag.txt" 2>&1) || { echo "install failed: $tag"; tail -n 20 "$out/install-$tag.txt"; exit 1; }
  echo "installed $tag"
done

[ -n "${PBU_BUILD_ONLY:-}" ] && exit 0
cores=$(nproc)
pin="0-3"; [ "$cores" -lt 4 ] && pin="0-$((cores - 1))"
for round in $(seq 1 "$rounds"); do
  for tag in "$@"; do
    dir=$(tree_of "$tag")
    log="$out/$tag-r$round.log"
    start=$(date +%s)
    (cd "$dir/webviews" && timeout 900 taskset -c "$pin" bun bench/update-one.bench.ts --changes 20 --turns 1000 > "$log" 2>&1)
    echo "$tag r$round exit=$? $(( $(date +%s) - start ))s rows=$(grep -c '^PERF_ROW' "$log")" | tee -a "$out/summary.txt"
  done
done
python3 "$here/summ.py" "$out" "$@" | tee -a "$out/summary.txt"

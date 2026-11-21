#!/usr/bin/env bash
# The pre-push architecture ratchet's time on small pushes, this checkout's scripts against before=REF's. For each
# commit C (one push of C over C^1), arch-ratchet.py runs once to warm the facts cache, then RUNS times; it prints the
# median wall time per commit for both script sets, interleaved (before, after, before, after) so load drifts hit
# both. Read only: it judges commits, writes nothing in the checkout (the facts cache is in the git directory).
#   scripts/measure/arch-ratchet-hook-time.sh before=REF [runs=5] [COMMIT ...]
#   cmux-ci test -- bash -c 'scripts/measure/arch-ratchet-hook-time.sh before=origin/feat-cmux-next'
# COMMITs default to the last four non-merge feat-cmux-next commits that change Swift, and the last one that changes
# none (a docs push: the cost of a push the Swift rows have nothing to read for).
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
before="" runs=5 commits=()
for arg in "$@"; do
  case "$arg" in
    before=*) before=${arg#before=} ;;
    runs=*) runs=${arg#runs=} ;;
    *) commits+=("$arg") ;;
  esac
done
[ -n "$before" ] || { echo "usage: $0 before=REF [runs=N] [COMMIT ...]" >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/arch-ratchet-hook-time-XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$repo" archive "$before" scripts/cmux-next | tar -x -C "$work"
if [ ${#commits[@]} -eq 0 ]; then
  mapfile -t commits < <(git -C "$repo" log --no-merges --format=%H -n 4 origin/feat-cmux-next -- '*.swift')
  commits+=("$(git -C "$repo" log --no-merges --format=%H -n 1 origin/feat-cmux-next -- docs)")
fi
median() {  # SCRIPTDIR BASE HEAD -> the median of RUNS warm runs, seconds
  local dir=$1 base=$2 head=$3 times=() i s e
  python3 -I "$dir/arch-ratchet.py" --repo "$repo" --base "$base" --head "$head" >/dev/null 2>&1 || true
  for ((i = 0; i < runs; i++)); do
    s=$(date +%s%N)
    python3 -I "$dir/arch-ratchet.py" --repo "$repo" --base "$base" --head "$head" >/dev/null 2>&1 || true
    e=$(date +%s%N)
    times+=($(((e - s) / 1000000)))
  done
  printf '%s\n' "${times[@]}" | sort -n | sed -n "$(((runs + 1) / 2))p"
}
printf '%-12s %10s %10s\n' commit before_ms after_ms
for c in "${commits[@]}"; do
  base=$(git -C "$repo" rev-parse "$c^1") head=$(git -C "$repo" rev-parse "$c")
  b1=$(median "$work/scripts/cmux-next" "$base" "$head"); a1=$(median "$repo/scripts/cmux-next" "$base" "$head")
  b2=$(median "$work/scripts/cmux-next" "$base" "$head"); a2=$(median "$repo/scripts/cmux-next" "$base" "$head")
  printf '%-12s %10s %10s\n' "${c:0:11}" "$(((b1 < b2) ? b1 : b2))" "$(((a1 < a2) ? a1 : a2))"
done
echo "load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime)"

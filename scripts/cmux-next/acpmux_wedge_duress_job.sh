set -o pipefail
REF="$1"; TAG="$2"; shift 2  # the rest: harness args (e.g. --cpus 4 --cpu-x 12)
cat /proc/sys/kernel/yama/ptrace_scope; sudo -n true && echo sudo-ok
W=$(mktemp -d)/src
git fetch -q --depth=1 origin "$REF" && git worktree add -q --detach "$W" FETCH_HEAD || exit 3
echo "measuring $TAG at $(git -C "$W" rev-parse HEAD)"
T=$(cd cmux-tui && cargo metadata --format-version 1 --no-deps | python3 -c "import json,sys;print(json.load(sys.stdin)['target_directory'])")
(cd "$W/cmux-tui" && CARGO_TARGET_DIR="$T" cargo build -p acpmux --bin acpmux 2>&1 | tail -2) || exit 3
cp "$T/debug/acpmux" "$FAST_CHECKS_OUT/acpmux-$TAG" 2>/dev/null; B="$T/debug/acpmux"
ACPMUX_WEDGE_HERE=1 python3 -I scripts/cmux-next/acpmux_wedge_duress.py --acpmux "$B" --out "$FAST_CHECKS_OUT/$TAG" --secs 180 --reads 24 "$@"
rc=$?; rm -f "$FAST_CHECKS_OUT/acpmux-$TAG"; cat "$FAST_CHECKS_OUT/$TAG/summary.md"; exit $rc

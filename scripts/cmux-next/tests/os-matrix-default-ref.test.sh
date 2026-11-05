#!/usr/bin/env bash
# os-matrix.sh with no --ref resolves the feat-cmux-next tip without a write to the shared clone.
# Two os-matrix runs (or another agent's fetch) share one clone: a `git fetch origin feat-cmux-next`
# there failed on the other fetch's ref lock (exit 75, a lost launch-smoke cycle), and FETCH_HEAD
# read after it could name the other run's commit. No network: origin is a local bare repo and
# cmux-ci is a stub that records its arguments.
# OS_MATRIX=<path> runs the test against another copy of the script (for the red run on the base).
set -euo pipefail
trap 'rc=$?; printf "%s: line %d exited %d\n" "$0" "$LINENO" "$rc" >&2' ERR
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OS_MATRIX=${OS_MATRIX:-$ROOT/scripts/cmux-next/os-matrix.sh}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# git_q, and no background git maintenance in the scratch repositories.
source "$ROOT/scripts/cmux-next/tests/lib/git-fixture.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf 'output:\n%s\n' "$2" >&2; exit 1; }
BUILD=0123456789abcdef01234567

git_q init "$TMP/src"
mkdir -p "$TMP/src/scripts/fuzz/macos-matrix"
cp "$ROOT/scripts/fuzz/macos-matrix/images.json" "$TMP/src/scripts/fuzz/macos-matrix/"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m base
git_q -C "$TMP/src" branch -M feat-cmux-next
git_q clone --bare "$TMP/src" "$TMP/origin.git"
git_q clone -b feat-cmux-next "$TMP/origin.git" "$TMP/work"

# The stub: `run` records its arguments and gives a verdict; `artifact` writes an empty results tarball.
cat >"$TMP/cmux-ci" <<EOF
#!/usr/bin/env bash
case "\$1" in
  run) printf '%s\n' "\$@" >"$TMP/ci-args"; echo "cmux-ci: step $BUILD"; echo "MATRIX VERDICT PASS" ;;
  artifact) mkdir -p "$TMP/empty"; tar -czf "\$3" -C "$TMP/empty" . ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$TMP/cmux-ci"

run_matrix() {  # run_matrix OUT_NAME: os-matrix.sh with no --ref, from the shared clone
  rm -f "$TMP/ci-args"
  (cd "$TMP/work" && CMUX_CI="$TMP/cmux-ci" bash "$OS_MATRIX" --build "$BUILD" --os 14 --out "$TMP/$1" 2>&1)
}
ref_sent() { awk 'prev == "--ref" {print; exit} {prev = $0}' "$TMP/ci-args"; }

# 1. origin moved, and another fetch holds the clone's remote-tracking ref lock.
echo tip >"$TMP/src/tip"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m tip
git_q -C "$TMP/src" push "$TMP/origin.git" feat-cmux-next
tip=$(git -C "$TMP/origin.git" rev-parse refs/heads/feat-cmux-next)
tracking_before=$(git -C "$TMP/work" rev-parse refs/remotes/origin/feat-cmux-next)
git -C "$TMP/work" cat-file -e "$tip^{commit}" 2>/dev/null && fail "fixture: the tip is already in the clone"
lock="$TMP/work/.git/refs/remotes/origin/feat-cmux-next.lock"
: >"$lock"
rc=0; out=$(run_matrix held) || rc=$?
[[ $rc == 0 ]] || fail "a held ref lock in the shared clone ended os-matrix.sh with exit $rc" "$out"
[[ $(ref_sent) == "$tip" ]] || fail "vm.sh ref $(ref_sent), want the origin tip $tip" "$out"
git -C "$TMP/work" cat-file -e "$tip^{commit}" || fail "the missing tip commit was not fetched" "$out"
[[ -e "$lock" ]] || fail "the other fetch's lock was removed"
[[ ! -e "$TMP/work/.git/FETCH_HEAD" ]] || fail "FETCH_HEAD was written in the shared clone" "$(cat "$TMP/work/.git/FETCH_HEAD")"
[[ $(git -C "$TMP/work" rev-parse refs/remotes/origin/feat-cmux-next) == "$tracking_before" ]] \
  || fail "the shared clone's remote-tracking ref moved"
rm -f "$lock"
echo "ok   held ref lock: --ref $tip, no ref or FETCH_HEAD written"

# 2. The tip commit is already present, and FETCH_HEAD names another run's commit: neither is read
#    nor written, and the run sends origin's tip.
base=$(git -C "$TMP/work" rev-parse HEAD)
printf '%s\t\tbranch '"'"'other'"'"' of elsewhere\n' "$base" >"$TMP/work/.git/FETCH_HEAD"
before=$(cat "$TMP/work/.git/FETCH_HEAD")
rc=0; out=$(run_matrix present) || rc=$?
[[ $rc == 0 ]] || fail "exit $rc with the tip commit present" "$out"
[[ $(ref_sent) == "$tip" ]] || fail "vm.sh ref $(ref_sent), want the origin tip $tip (FETCH_HEAD named $base)" "$out"
[[ $(cat "$TMP/work/.git/FETCH_HEAD") == "$before" ]] || fail "FETCH_HEAD was rewritten" "$out"
echo "ok   present tip: --ref $tip, another run's FETCH_HEAD left as it was"

# 3. origin unreachable: no verdict (75), not a wrong ref.
git -C "$TMP/work" remote set-url origin "$TMP/missing.git"
rc=0; out=$(run_matrix unreachable) || rc=$?
[[ $rc == 75 ]] || fail "exit $rc with origin unreachable, want 75" "$out"
[[ ! -e "$TMP/ci-args" ]] || fail "a step was submitted with origin unreachable" "$out"
echo "ok   unreachable origin: exit 75, no step"
echo "PASS os-matrix-default-ref"

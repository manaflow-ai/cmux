#!/usr/bin/env bash
# The nightly train's per-car guard command (NIGHTLY_NEXT_TRAIN_CAR_GUARD's default,
# scripts/ci/nightly_next_train_drive.py): `nightly-next-car-guard.sh --car-json FILE`.
#
# FILE is one train car ({"id", "commits": [oldest .. newest], ...}). The car's range is
# commits[0]^..commits[-1]. The train runs up to eight cars at once from one checkout, so each
# car gets its own detached worktree at its head, and scripts/ci/car_guards.py judges it there.
#
# Exit 0 keeps the car, 1 quarantines it, 2 (or anything else) is a guard error the train
# reports as a warning while the car rides on to the candidate build.
#
# CAR_GUARD_KINDS (default guard,python): the kinds run here, on the train's own runner. The
# repo guards and focused python tests take seconds and need no toolchain. Focused cargo,
# webviews and Swift tests need Rust, bun or a Mac: .github/workflows/cmux-next-car-guards.yml
# runs every kind for a car (workflow_call). The focused python tests run on a python3 with
# CI's pinned test modules (scripts/ci/car-guard-python.sh). CAR_GUARD_RECEIPTS: a directory for each car's
# verdict JSON (default: none kept).
set -euo pipefail

if [[ $# -ne 2 || "$1" != --car-json ]]; then
  echo "usage: nightly-next-car-guard.sh --car-json FILE" >&2
  exit 2
fi
car_json="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"

read -r car base head < <(python3 -I - "$car_json" <<'PY'
import json, re, sys
car = json.load(open(sys.argv[1]))
commits = car.get("commits") or []
if not commits or not all(re.fullmatch(r"[0-9a-f]{7,40}", c) for c in commits):
    sys.exit("car has no commits")
car_id = re.sub(r"[^A-Za-z0-9._-]", "-", str(car.get("id") or commits[-1][:8]))
print(car_id, commits[0] + "^", commits[-1])
PY
) || exit 2

work="$(mktemp -d)"
cleanup() {
  git -C "$repo" worktree remove --force "$work/tree" > /dev/null 2>&1 || rm -rf "$work"
  rm -rf "$work"
}
trap cleanup EXIT
git -C "$repo" worktree add --quiet --detach "$work/tree" "$head" > /dev/null 2>&1 || {
  echo "car $car: cannot check out $head" >&2
  exit 2
}

receipt="$work/verdict.json"
python="$(bash "$here/car-guard-python.sh")" || exit 2
set +e
"$python" -I "$here/car_guards.py" run --where linux --root "$work/tree" --base "$base" --head "$head" \
  --car "$car" --kinds "${CAR_GUARD_KINDS:-guard,python}" --receipt "$receipt" > /dev/null
code=$?
set -e
if [[ -n "${CAR_GUARD_RECEIPTS:-}" && -f "$receipt" ]]; then
  mkdir -p "$CAR_GUARD_RECEIPTS"
  cp "$receipt" "$CAR_GUARD_RECEIPTS/$car.json"
fi
case "$code" in
  0 | 1) exit "$code" ;;
  *) exit 2 ;;
esac

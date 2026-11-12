#!/bin/bash
# Before/after for the Cloud late-attach harness: the same request against
# cmux-server built at BASE (required: a commit) and at HEAD, each attach time
# several times. Needs a network namespace: unprivileged, or through sudo -n.
# Usage: scripts/cloud-attach-compare.sh BASE
#   BASE 6646d219f2bbf184de8dfb2371678bb2c2c6e973 is the commit before the 2 s
#   connect bound (cmux#41487). A shallow checkout needs the full SHA to fetch.
set -euo pipefail
cd "$(dirname "$0")/.."
# No default: HEAD~1 was a commit after the fix once more commits landed, so a
# bare run compared the fix against itself.
base=${1:?usage: $0 BASE (a commit before the change)}
runs=${RUNS:-3}
file=crates/cmux-server/src/cloud_http_transport.rs
# A shallow checkout (CI) may not hold BASE yet.
if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  git fetch -q --no-tags --depth=1 origin "$base" ||
    { echo "attach-compare: BASE $base is not here and could not be fetched (a shallow checkout needs the full SHA)" >&2; exit 2; }
fi
# The same connect code on both sides measures nothing: refuse instead.
if git show "$base:cmux-tui/$file" | cmp -s - "$file"; then
  echo "attach-compare: BASE's $file is HEAD's; name a commit before the change" >&2
  exit 2
fi
# A user namespace where allowed, else root's (a CI runner's passwordless sudo).
if unshare -rn true 2>/dev/null; then ns=(unshare -rn)
elif sudo -n unshare -n true 2>/dev/null; then ns=(sudo -n unshare -n)
else echo "attach-compare: no network namespace here"; exit 2; fi
# BASE is built in its own worktree with its own target dir, so the two builds
# share no source file and no cache. Swapping BASE's file into this tree kept
# HEAD's newer mtime on disk, and Cargo could reuse the HEAD binary as BASE's.
# BASE's target dir sits beside HEAD's and is kept between runs (a cold
# cmux-server build alone outran a one-hour CI step); it is never HEAD's.
head_target=${CARGO_TARGET_DIR:-$PWD/target}
base_target=${ATTACH_BASE_TARGET_DIR:-$head_target-attach-base}
scratch=$(mktemp -d)
basetree="$scratch/base"
cleanup() {
  # Only the worktree and scratch directory this run made.
  if [ -d "$basetree" ]; then git worktree remove --force "$basetree" || true; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
git worktree add -q --detach "$basetree" "$base"
build() {
  echo "attach-compare: building $1 into $2" >&2
  local started=$SECONDS
  (cd "$1" && CARGO_TARGET_DIR="$2" cargo test -p cmux-server --lib --no-run --message-format=json 2>/dev/null) |
  python3 -c 'import json,sys
for l in sys.stdin:
    m=json.loads(l)
    if m.get("reason")=="compiler-artifact" and m.get("executable") and m["target"]["name"]=="cmux_server": print(m["executable"])' | tail -1
  echo "attach-compare: built $1 in $((SECONDS - started))s" >&2
}
measure() {
  for attach in 1 4 8 12; do
    for _ in $(seq "$runs"); do
      echo "attach-compare: $1 attach ${attach}s $("${ns[@]}" scripts/cloud-attach-harness.sh "$2" "$attach")"
    done
  done
}
[ "$base_target" != "$head_target" ] || { echo "attach-compare: BASE's target dir is HEAD's" >&2; exit 2; }
after=$(build . "$head_target")
before=$(build "$basetree/cmux-tui" "$base_target")
[ -x "$after" ] && [ -x "$before" ] || { echo "attach-compare: a build made no test binary" >&2; exit 1; }
# The sources differ (checked above), so equal binaries mean one build was
# reused for the other: the run would compare HEAD against itself.
if cmp -s "$before" "$after"; then
  echo "attach-compare: BASE and HEAD built byte-identical binaries from different sources; refusing" >&2
  exit 3
fi
measure before "$before"
measure after "$after"

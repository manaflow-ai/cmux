#!/bin/bash
# Before/after for the Cloud late-attach harness: the same request against
# cmux-server built at BASE (required: a commit) and at HEAD, each attach time
# several times. Needs a network namespace: unprivileged, or through sudo -n.
# Usage: scripts/cloud-attach-compare.sh BASE
#   BASE 6646d219f2b is the commit before the 2 s connect bound (cmux#41487).
set -euo pipefail
cd "$(dirname "$0")/.."
# No default: HEAD~1 was a commit after the fix once more commits landed, so a
# bare run compared the fix against itself.
base=${1:?usage: $0 BASE (a commit before the change)}
runs=${RUNS:-3}
file=crates/cmux-server/src/cloud_http_transport.rs
# A shallow checkout (CI) may not hold BASE yet.
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q --no-tags --depth=1 origin "$base"
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
scratch=$(mktemp -d)
basetree="$scratch/base"
cleanup() {
  # Only the worktree and scratch directory this run made.
  if [ -d "$basetree" ]; then git worktree remove --force "$basetree" || true; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
git worktree add -q --detach "$basetree" "$base"
build() { (cd "$1" && CARGO_TARGET_DIR="$2" cargo test -p cmux-server --lib --no-run --message-format=json 2>/dev/null) |
  python3 -c 'import json,sys
for l in sys.stdin:
    m=json.loads(l)
    if m.get("reason")=="compiler-artifact" and m.get("executable") and m["target"]["name"]=="cmux_server": print(m["executable"])' | tail -1; }
measure() {
  for attach in 1 4 8 12; do
    for _ in $(seq "$runs"); do
      echo "attach-compare: $1 attach ${attach}s $("${ns[@]}" scripts/cloud-attach-harness.sh "$2" "$attach")"
    done
  done
}
after=$(build . "${CARGO_TARGET_DIR:-$PWD/target}")
before=$(build "$basetree/cmux-tui" "$scratch/target")
[ -x "$after" ] && [ -x "$before" ] || { echo "attach-compare: a build made no test binary" >&2; exit 1; }
# The sources differ (checked above), so equal binaries mean one build was
# reused for the other: the run would compare HEAD against itself.
if cmp -s "$before" "$after"; then
  echo "attach-compare: BASE and HEAD built byte-identical binaries from different sources; refusing" >&2
  exit 3
fi
measure before "$before"
measure after "$after"

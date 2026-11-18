#!/bin/bash
# Before/after for the Cloud late-attach harness: the same request against
# the connect code at BASE (required: a commit, or a path to that commit's
# cloud_http_transport.rs) and at HEAD, each attach time several times.
# Needs a network namespace: unprivileged, or through sudo -n.
# Usage: scripts/cloud-attach-compare.sh BASE
#   BASE 6646d219f2b is the commit before the 2 s connect bound (cmux#41487).
set -euo pipefail
cd "$(dirname "$0")/.."
# No default: HEAD~1 was a commit after the fix once more commits landed, so a
# bare run compared the fix against itself.
base=${1:?usage: $0 BASE (a commit, or a path to its cloud_http_transport.rs)}
runs=${RUNS:-3}
file=crates/cmux-server/src/cloud_http_transport.rs
if [ -f "$base" ]; then cp "$base" "$file.base"; else git show "$base:cmux-tui/$file" > "$file.base"; fi
# The same connect code on both sides measures nothing: refuse instead.
if cmp -s "$file.base" "$file"; then
  rm -f "$file.base"
  echo "attach-compare: BASE's $file is HEAD's; name a commit before the change" >&2
  exit 2
fi
# A user namespace where allowed, else root's (a CI runner's passwordless sudo).
if unshare -rn true 2>/dev/null; then ns=(unshare -rn)
elif sudo -n unshare -n true 2>/dev/null; then ns=(sudo -n unshare -n)
else rm -f "$file.base"; echo "attach-compare: no network namespace here"; exit 2; fi
build() { cargo test -p cmux-server --lib --no-run --message-format=json 2>/dev/null |
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
after=$(build); cp "$after" /tmp/attach-after
cp "$file" "$file.head" && mv "$file.base" "$file"
before=$(build); cp "$before" /tmp/attach-before; mv "$file.head" "$file"
measure before /tmp/attach-before
measure after /tmp/attach-after

#!/bin/bash
# Before/after for the Cloud late-attach harness: the same request against
# the connect code at BASE (default HEAD~1) and at HEAD, each attach time
# several times. Needs unprivileged user and network namespaces.
set -euo pipefail
cd "$(dirname "$0")/.."
base=${1:-HEAD~1}
runs=${RUNS:-3}
file=crates/cmux-server/src/cloud_http_transport.rs
unshare -rn true || { echo "attach-compare: no user namespaces here"; exit 2; }
build() { cargo test -p cmux-server --lib --no-run --message-format=json 2>/dev/null |
  python3 -c 'import json,sys
for l in sys.stdin:
    m=json.loads(l)
    if m.get("reason")=="compiler-artifact" and m.get("executable") and m["target"]["name"]=="cmux_server": print(m["executable"])' | tail -1; }
measure() {
  for attach in 1 4 8 12; do
    for _ in $(seq "$runs"); do
      echo "attach-compare: $1 attach ${attach}s $(unshare -rn scripts/cloud-attach-harness.sh "$2" "$attach")"
    done
  done
}
after=$(build); cp "$after" /tmp/attach-after
git show "$base:cmux-tui/$file" > "$file.base" && cp "$file" "$file.head" && mv "$file.base" "$file"
before=$(build); cp "$before" /tmp/attach-before; mv "$file.head" "$file"
measure before /tmp/attach-before
measure after /tmp/attach-after

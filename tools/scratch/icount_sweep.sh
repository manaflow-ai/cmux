#!/usr/bin/env bash
# Bisect sweep: acpmux-icount mcp_connect at several feat-cmux-next commits, one job.
# Draft-only helper for the mcp_connect +30.8% over baseline after #56137; not for merge.
set -u
cd "$(git rev-parse --show-toplevel)"
command -v valgrind >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq valgrind; } >/dev/null 2>&1
export CARGO_NET_RETRY=10 CARGO_HTTP_TIMEOUT=120 CARGO_INCREMENTAL=0
here=$(git rev-parse HEAD)
summary=""
for c in "$@"; do
  git cat-file -e "$c^{commit}" 2>/dev/null || git fetch -q --no-tags --depth=1 origin "$c" 2>/dev/null || git fetch -q --no-tags --shallow-since=2026-11-20 origin feat-cmux-next
  if ! git checkout -q "$c" -- cmux-tui 2>/dev/null; then summary+="$c fetch-failed"$'\n'; continue; fi
  ( cd cmux-tui
    channel="$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' rust-toolchain.toml)"
    rustup toolchain install "$channel" --profile minimal >/dev/null 2>&1
    cargo bench --profile gate -p acpmux --bench icount --locked -- check 2>&1 ) > "/tmp/icount-$c.log"
  line=$(grep -E '^mcp_connect' "/tmp/icount-$c.log" | tail -1)
  summary+="$c ${line:-no-result: $(tail -2 /tmp/icount-$c.log | tr '\n' ' ')}"$'\n'
  echo "SWEEP $c ${line:-no result}"
done
git checkout -q "$here" -- cmux-tui
echo "=== SWEEP SUMMARY ==="; printf '%s' "$summary"

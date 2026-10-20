#!/usr/bin/env bash
# linux-gate.sh BINDIR: the mux2 correctness gate on Linux (smaller corpus).
set -u
B=$1; W=$(mktemp -d); export MUX2_SOCKET=$W/sock TMPDIR=$W
perl "$(dirname "$0")/gen-corpus.pl" "$W/c" >/dev/null
for f in cursor unicode; do truncate -s 8M "$W/c/$f.txt"; done
for f in plain sgr; do truncate -s 64M "$W/c/$f.txt"; done
"$B/mux2" stats >/dev/null
n=0
for f in cursor unicode sgr plain; do for m in --no-viewer "" --attach-midway --slow-viewer --resize-midway; do
  "$B/mux2-verify" "$W/c/$f.txt" $m >"$W/v.json" 2>&1 && n=$((n+1)) || { echo "FAIL $f $m"; cat "$W/v.json"; }
done; done
echo "verify passed: $n/20"
Q=$(dirname "$0")
id=$("$B/mux2" new --size 120x40 -- /usr/bin/perl "$Q/query-rtt.pl" 1000); "$B/mux2" wait "$id" >/dev/null; "$B/mux2" screen "$id" | grep -E 'query_rtt|BAD'
id=$("$B/mux2" new -- /usr/bin/perl "$Q/query-edge.pl"); "$B/mux2" wait "$id" >/dev/null; "$B/mux2" screen "$id" | grep QUERY-EDGE
"$B/mux2" stop; rm -rf "$W"

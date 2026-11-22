#!/usr/bin/env bash
# Runs a measurement matrix detached-safe: vm-matrix.sh MATRIX_FILE OUT_DIR ADDR
# Matrix lines: SIZE | SERVE_ARGS | NAME | CLIENT_ARGS   ('#' comments allowed).
# Restarts Xvfb + serve only when SIZE or SERVE_ARGS change. Writes OUT_DIR/DONE at the end.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
matrix=$1; out=$2; addr=$3
mkdir -p "$out"; rm -f "$out/DONE"
prev=""
while IFS='|' read -r size sargs name cargs; do
  size=$(echo "$size" | xargs); [ -z "$size" ] && continue; [[ "$size" == \#* ]] && continue
  sargs=$(echo "$sargs" | xargs); name=$(echo "$name" | xargs); cargs=$(echo "$cargs" | xargs)
  if [ "$size|$sargs" != "$prev" ]; then
    "$here/vm-bench.sh" up "$size" $sargs >>"$out/log.txt" 2>&1; prev="$size|$sargs"
  fi
  echo "== $(date -u +%H:%M:%SZ) $name [$size $sargs] $cargs" >>"$out/log.txt"
  OUT="$out" "$here/vm-bench.sh" run "$name" --addr "$addr" $cargs >>"$out/log.txt" 2>&1 || echo "FAILED $name" >>"$out/log.txt"
done <"$matrix"
date -u +%FT%TZ >"$out/DONE"

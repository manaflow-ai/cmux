#!/usr/bin/env bash
# Model-check LayoutRows.tla (plans/cmux-next/rows.md) with TLC.
#   main:    LayoutRows.cfg (one client, three ops), LayoutRows_2clients.cfg (two clients,
#            two ops) and LayoutRows_sticky3.cfg (three columns, outer two sticky);
#            every invariant and R6_OwnPlaceComplete; must pass.
#   mutants: LayoutRows_<bug>.cfg, one deliberate defect each; each must fail.
# Usage: run-rows-tlc.sh [main|mutants|all] (default all). Needs Java 11+.
# TLC_WORKERS overrides 2; the main run needs about 4 GB of heap.
set -euo pipefail

TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
CACHE_DIR="${CMUX_TLA_CACHE:-$HOME/.cache/cmux-tla}"
JAR="$CACHE_DIR/tla2tools-$TLA_VERSION.jar"
WORKERS="${TLC_WORKERS:-2}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! java -version >/dev/null 2>&1; then
  echo "error: java not found; install a JDK (11+) or put one on PATH. TLC was not run." >&2
  exit 2
fi
mkdir -p "$CACHE_DIR"
if [ ! -f "$JAR" ] || ! echo "$TLA_SHA256  $JAR" | shasum -a 256 -c - >/dev/null 2>&1; then
  tmp="$JAR.tmp.$$"
  curl -fsSL -o "$tmp" "https://github.com/tlaplus/tlaplus/releases/download/v$TLA_VERSION/tla2tools.jar"
  if ! echo "$TLA_SHA256  $tmp" | shasum -a 256 -c - >/dev/null; then
    rm -f "$tmp"; echo "error: tla2tools.jar sha256 mismatch" >&2; exit 3
  fi
  mv "$tmp" "$JAR"
fi

run() { # $1 = config file; returns TLC's exit code
  local meta; meta="$(mktemp -d "${TMPDIR:-/tmp}/tlc-rows.XXXXXX")"
  echo "== TLC $1 =="
  set +e
  (cd "$HERE" && java -XX:+UseParallelGC -Xmx4g -cp "$JAR" tlc2.TLC \
      -workers "$WORKERS" -deadlock -metadir "$meta" -config "$1" LayoutRows.tla)
  local rc=$?
  set -e
  rm -rf "$meta"
  return $rc
}

mode="${1:-all}"
status=0
if [ "$mode" = main ] || [ "$mode" = all ]; then
  run LayoutRows.cfg || { echo "FAIL: LayoutRows.cfg violated a property"; status=1; }
  run LayoutRows_2clients.cfg || { echo "FAIL: LayoutRows_2clients.cfg violated a property"; status=1; }
  run LayoutRows_sticky3.cfg || { echo "FAIL: LayoutRows_sticky3.cfg violated a property"; status=1; }
fi
if [ "$mode" = mutants ] || [ "$mode" = all ]; then
  for bug in keepEmptyRow sticky3_noStickyNormalize ownPlaceRowOnly noDedup noFocusRepair \
             focusColumnFirst respawnDropsTab; do
    if run "LayoutRows_$bug.cfg"; then echo "FAIL: mutant $bug passed (expected a counterexample)"; status=1
    else echo "OK: mutant $bug produced a counterexample"; fi
  done
fi
exit $status

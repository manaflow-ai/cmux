#!/usr/bin/env bash
# Model-check TabLayout.tla with TLC.
#   fixed: safety invariants at the full bound (4 tabs); must pass.
#   live:  liveness (EventuallyConverged) plus invariants at 3 tabs; must pass.
#   buggy: BUGGY_DETACH = TRUE; must produce a counterexample.
#   respawn: RESPAWN = TRUE (own-pane split of the only tab creates a fresh tab), 2 tabs + 1 spawn; must pass.
# Usage: run-tlc.sh [fixed|live|respawn|buggy|all] (default all). Needs Java 11+.
# The fixed run takes minutes and about 1-2 GB of heap; TLC_WORKERS overrides 2.
set -euo pipefail

TLA_VERSION=1.7.4   # v1.8.0 is a rolling prerelease whose jar changes; pin stable
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

run() { # $1 = fixed|buggy; returns TLC's exit code
  local meta; meta="$(mktemp -d "${TMPDIR:-/tmp}/tlc-$1.XXXXXX")"
  echo "== TLC $1 =="
  set +e
  (cd "$HERE" && java -XX:+UseParallelGC -Xmx2g -cp "$JAR" tlc2.TLC \
      -workers "$WORKERS" -deadlock -metadir "$meta" \
      -config "TabLayout_$1.cfg" TabLayout.tla)
  local rc=$?
  set -e
  rm -rf "$meta"
  return $rc
}

mode="${1:-all}"
status=0
if [ "$mode" = fixed ] || [ "$mode" = all ]; then
  run fixed || { echo "FAIL: fixed model violated a property"; status=1; }
fi
if [ "$mode" = live ] || [ "$mode" = all ]; then
  run live || { echo "FAIL: liveness model violated a property"; status=1; }
fi
if [ "$mode" = respawn ] || [ "$mode" = all ]; then
  run respawn || { echo "FAIL: respawn model violated a property"; status=1; }
fi
if [ "$mode" = buggy ] || [ "$mode" = all ]; then
  if run buggy; then echo "FAIL: buggy model passed (expected a counterexample)"; status=1
  else echo "OK: buggy model produced the expected counterexample"; fi
fi
exit $status

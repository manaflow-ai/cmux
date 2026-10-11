#!/usr/bin/env bash
# Model-check closefocus.tla (plans/cmux-next/close-focus.md) with a pinned,
# sha256-checked tla2tools.jar (the same pin as run-tlc.sh).
#   default: strip, strip-recent and list configs must pass;
#   --mutants: each broken variant (history, noanchor, center, noreveal, nudge) must
#   fail on the config that exposes it.
# Needs Java 11+. TLC_WORKERS overrides 2.
set -euo pipefail
TLA_VERSION=1.7.4
TLA_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
CACHE_DIR="${CMUX_TLA_CACHE:-$HOME/.cache/cmux-tla}"
JAR="$CACHE_DIR/tla2tools-$TLA_VERSION.jar"
WORKERS="${TLC_WORKERS:-2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
java -version >/dev/null 2>&1 || { echo "error: java not found; TLC was not run." >&2; exit 2; }
mkdir -p "$CACHE_DIR"
if [ ! -f "$JAR" ] || ! echo "$TLA_SHA256  $JAR" | shasum -a 256 -c - >/dev/null 2>&1; then
  tmp="$JAR.tmp.$$"
  curl -fsSL -o "$tmp" "https://github.com/tlaplus/tlaplus/releases/download/v$TLA_VERSION/tla2tools.jar"
  echo "$TLA_SHA256  $tmp" | shasum -a 256 -c - >/dev/null || { rm -f "$tmp"; echo "error: tla2tools.jar sha256 mismatch" >&2; exit 3; }
  mv "$tmp" "$JAR"
fi

tlc() { # $1 = cfg file; prints TLC's tail; returns its exit code
  local meta; meta="$(mktemp -d "${TMPDIR:-/tmp}/tlc-closefocus.XXXXXX")"
  set +e
  (cd "$HERE" && java -XX:+UseParallelGC -Xmx2g -cp "$JAR" tlc2.TLC -workers "$WORKERS" -deadlock \
      -metadir "$meta" -config "$1" closefocus.tla) > "$meta/out.txt" 2>&1
  local rc=$?
  set -e
  grep -E "states generated|distinct states|depth of the complete|is violated|Error:|No error" "$meta/out.txt" | head -8
  rm -rf "$meta"
  return $rc
}

status=0
if [ "${1:-}" = "--mutants" ]; then
  for pair in history:strip noanchor:list noanchor:strip center:strip noreveal:strip nudge:list nudge:strip; do
    mutant="${pair%%:*}"; cfg="${pair##*:}"
    tmp="$HERE/.closefocus-$mutant-$cfg.cfg"
    sed "s/MUTANT = \"none\"/MUTANT = \"$mutant\"/" "$HERE/closefocus-$cfg.cfg" > "$tmp"
    echo "== mutant $mutant on $cfg (must fail) =="
    if tlc "$(basename "$tmp")"; then echo "MUTANT NOT CAUGHT: $mutant"; status=1; else echo "caught"; fi
    rm -f "$tmp"
  done
  exit $status
fi
for cfg in strip strip-recent list; do
  echo "== TLC closefocus-$cfg =="
  tlc "closefocus-$cfg.cfg" || status=1
done
exit $status

#!/usr/bin/env bash
# A/B on one runner: head (the working tree) and base (files in .ab-gcsc/base, the base commit's copies of
# every changed file; .ab-gcsc/base/DELETE lists files the head added) alternately, same bench command.
# usage: ab.sh ROUNDS MODE [extra env...]
set -u
rounds=$1; mode=$2
root=$(git rev-parse --show-toplevel); cd "$root"
ab=webviews/.ab-gcsc; out=${FAST_CHECKS_OUT:-/tmp/ab}; mkdir -p "$out" "$ab/head"
{ hostname; nproc; grep -m1 "model name" /proc/cpuinfo; } > "$out/runner.txt" 2>&1
files=$(cd "$ab/base" && find . -type f ! -name ADDED | sed 's|^\./||')
added=$(cat "$ab/base/ADDED" 2>/dev/null || true)
for f in $files $added; do mkdir -p "$ab/head/$(dirname "$f")"; cp "$f" "$ab/head/$f"; done
use_head() { for f in $files $added; do cp "$ab/head/$f" "$f"; done; }
use_base() { for f in $files; do cp "$ab/base/$f" "$f"; done; for f in $added; do rm -f "$f"; done; }
run() { (cd webviews && env FIXTURE=flat ROWS=100000 MODE=$mode PAGES=24 ENGINES=chromium "${@:2}" bun bench/transcript-scroll-up.bench.ts > "$out/$1.txt" 2>&1); }
for i in $(seq 1 "$rounds"); do
  use_head; run "$mode-head-$i" "${@:3}"
  use_base; run "$mode-base-$i" "${@:3}"
done
use_head
echo "files: $files added: $added" >> "$out/runner.txt"

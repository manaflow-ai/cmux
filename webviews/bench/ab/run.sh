#!/usr/bin/env bash
set -u
cd "$(git rev-parse --show-toplevel)"
bash scripts/ci/ensure-system-chrome.sh >/dev/null 2>&1
P=webviews/bench/ab/revert-change.patch
for i in 1 2 3; do
  echo "AB run=$i side=change $(bash scripts/measure/replay-under-load.sh --cores 8 --out /tmp/h$i.json 2>&1 | tail -1)"
  git apply "$P" || { echo "patch failed"; exit 1; }
  echo "AB run=$i side=base $(bash scripts/measure/replay-under-load.sh --cores 8 --out /tmp/r$i.json 2>&1 | tail -1)"
  git apply -R "$P"
done
exit 0

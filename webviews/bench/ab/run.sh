#!/usr/bin/env bash
# Throwaway A/B driver (never lands): head vs head with #56665 reverted, alternating, then a --profile run on head.
set -u
cd "$(git rev-parse --show-toplevel)"
bash scripts/ci/ensure-system-chrome.sh >/dev/null 2>&1
P=webviews/bench/ab/revert-56665.patch
for i in 1 2 3; do
  echo "AB run=$i side=head $(bash scripts/measure/replay-under-load.sh --cores 8 --out /tmp/h$i.json 2>&1 | tail -1)"
  git apply "$P" || { echo "patch failed"; exit 1; }
  echo "AB run=$i side=revert56665 $(bash scripts/measure/replay-under-load.sh --cores 8 --out /tmp/r$i.json 2>&1 | tail -1)"
  git apply -R "$P"
done
echo "PROFILE head"
bash scripts/measure/replay-under-load.sh --cores 8 --seconds 30 --profile --out /tmp/p.json 2>&1 | tail -120
exit 0

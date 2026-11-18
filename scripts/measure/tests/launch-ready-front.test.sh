#!/usr/bin/env bash
# launch-ready.sh front=home: every launch's probe shows Home before its quit (mode home), with keys on a keys=1
# measured launch, so each next launch is a relaunch whose last front was Home. Without front=home no probe gets it.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/launch-ready.sh"
# shellcheck source=../launch-ready.sh
source "$script"

fail() { echo "launch-ready front: $*" >&2; exit 1; }

LR_STATE=kept LR_KEYS=0 LR_FRONT=home
for label in prime full1 run1; do
  [[ "$(probe_mode "$label")" == home ]] || fail "front=home $label: want home, got '$(probe_mode "$label")'"
done
LR_KEYS=1
[[ "$(probe_mode run1)" == keys,home ]] || fail "front=home keys=1 run1: want keys,home, got '$(probe_mode run1)'"
[[ "$(probe_mode prime)" == home ]] || fail "front=home keys=1 prime: want home, got '$(probe_mode prime)'"
LR_FRONT='' LR_KEYS=0
[[ -z "$(probe_mode run1)" ]] || fail "no front=home: want nothing, got '$(probe_mode run1)'"
echo 'launch-ready front: front=home shows Home before every quit'

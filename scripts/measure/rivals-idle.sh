#!/usr/bin/env bash
# rivals-idle: the idle footprint of rival desktop apps (default Claude and ChatGPT), signed out, beside cmux NEXT's
# daily idle step (hq tools/fleet-reconcilers/idle_footprint_remote.py, goal ram-baseline). rivals.sh's own method
# (scripts/perf-bench/rivals.py) with a 60 s soak, the cmux leg's measure=60, read as soak-memory-end in
# artifacts/rivals/results.json (total phys_footprint over every process of the app, median over rounds).
# Leo, 2026-11-28: "Ok well we can't be letting important rfds like that take breaks unless I put in fleet wide pauses,
# esp when this is stuff that materially improves the app". rivals.sh is a listed measure script, so the fleet runs it
# exclusive only (its class waited 400-990 min p90); an unlisted reviewed script runs in the class it asks for
# (hq build-fleet/cmd/controller/measure_reviewed.go), so this one runs light:
#   cmux-ci run --class light --display --script scripts/measure/rivals-idle.sh --ref SHA \
#     --artifact artifacts/rivals/results.json [--arg=apps=claude,chatgpt] [--arg=rounds=3] [--arg=soak=60] ...
# maxload=64: a light host is shared, so rivals.py does not wait for an idle Mac (the reading is the app's own
# footprint, not a timing). Only the idle knobs pass; signed-in profiles and quarantined launches stay on rivals.sh.
set -euo pipefail
args=(apps=claude,chatgpt rounds=3 warm=1 after=20 soak=60 sample=10 maxload=64)
for arg in "$@"; do
  case "$arg" in
    apps=* | rounds=* | warm=* | after=* | soak=* | sample=* | maxload=* | settlecut=*) args+=("$arg") ;;
    *) echo "rivals-idle.sh: unknown argument $arg (signedin and quarantined stay on rivals.sh)" >&2; exit 2 ;;
  esac
done
exec bash "$(dirname "$0")/rivals.sh" "${args[@]}"

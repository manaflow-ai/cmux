#!/usr/bin/env bash
# A/B of one app env switch on one build, one Mac, one step: split-spring.sh with the switch (arm "a",
# --ab-env=NAME=VALUE) and then without it (arm "b"), every other arg the same. Writes
# artifacts/split-spring/report.json = {"ab_env": ..., "a": report, "b": report}. A build-phase run builds once.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
ab="" args=()
for arg in "$@"; do
  case "$arg" in
    --ab-env=*) ab="${arg#--ab-env=}" ;;
    *) args+=("$arg") ;;
  esac
done
[[ -n "$ab" ]] || { echo "split-spring-ab: --ab-env=NAME=VALUE is required" >&2; exit 2; }
[[ "${CMUX_MEASURE_PHASE:-}" == build ]] && exec bash scripts/measure/split-spring.sh "${args[@]}"
out=artifacts/split-spring
mkdir -p "$out"
rc_a=0 rc_b=0
bash scripts/measure/split-spring.sh "${args[@]}" "--app-env=$ab" || rc_a=$?
mv "$out/report.json" "$out/report-a.json" 2>/dev/null || echo '{}' > "$out/report-a.json"
bash scripts/measure/split-spring.sh "${args[@]}" || rc_b=$?
mv "$out/report.json" "$out/report-b.json" 2>/dev/null || echo '{}' > "$out/report-b.json"
python3 - "$ab" "$out" "$rc_a" "$rc_b" <<'PY'
import json, sys
ab, out, rc_a, rc_b = sys.argv[1:5]
def load(p):
    try:
        return json.load(open(p))
    except Exception as e:
        return {"error": str(e)}
json.dump({"ab_env": ab, "rc": {"a": int(rc_a), "b": int(rc_b)},
           "a": load(f"{out}/report-a.json"), "b": load(f"{out}/report-b.json")}, open(f"{out}/report.json", "w"))
PY
exit $(( rc_a || rc_b ))

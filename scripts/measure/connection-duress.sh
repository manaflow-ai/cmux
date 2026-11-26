#!/usr/bin/env bash
# Connection duress, offline (cmux-duress): runs each connection scenario across several seeds and prints ONE
# aggregate JSON line. A scenario's [[check]] entries are its goals; a check that fails on any seed fails it.
#   scripts/measure/connection-duress.sh [seeds=N] [names=a,b,c] [dir=PATH]
#   seeds=N     1 to 20 seeds per scenario (default 3); seed k runs as `seed=k` appended to the spec
#   names=LIST  scenarios to run (default: steady-rtt-echo, handoff-reset-5g, pause-resume-3s, resume-after-1s)
#   dir=PATH    the scenarios folder (default: cmux-tui/crates/cmux-duress/scenarios)
# Output: {"schema":"connection-duress.v1","commit","seeds","pass","scenarios":{NAME:{verdict,seeds_failed,
#   checks:[{metric,stat,min,max,values,pass}],metrics:{NAME:{unit,p50_median,p95_median,max_max}}}}}
# Exit 0: every scenario passes on every seed. 1: a check failed or a run produced no verdict. 2: usage. 3: build failed.
# Not in scope: live connection faults (cmux-fault on a device); this only replays the offline schedule.
set -uo pipefail

main() {
  local root seeds=3 names="steady-rtt-echo,handoff-reset-5g,pause-resume-3s,resume-after-1s" dir="" arg bin target
  for arg in "$@"; do
    case "$arg" in
      seeds=*) seeds="${arg#seeds=}" ;;
      names=*) names="${arg#names=}" ;;
      dir=*) dir="${arg#dir=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$seeds" =~ ^([1-9]|1[0-9]|20)$ ]] || { echo "seeds= must be 1 to 20" >&2; exit 2; }
  root="$(cd "$(dirname "$0")/../.." && pwd)" || exit 3
  [[ -n "$dir" ]] || dir="$root/cmux-tui/crates/cmux-duress/scenarios"
  cd "$root/cmux-tui" || exit 3
  cargo build -q -p cmux-duress >&2 || { echo "cmux-duress build failed" >&2; exit 3; }
  target="$(cargo metadata --format-version 1 --no-deps 2>/dev/null \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')" || exit 3
  bin="$target/debug/cmux-duress"
  [[ -x "$bin" ]] || { echo "no binary at $bin" >&2; exit 3; }
  python3 -I - "$bin" "$dir" "$seeds" "$names" "$(git -C "$root" rev-parse --short HEAD 2>/dev/null)" <<'PY'
import json, os, statistics, subprocess, sys, tomllib

bin_path, scen_dir, seeds, names, commit = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4].split(","), sys.argv[5]
report = {"schema": "connection-duress.v1", "commit": commit, "seeds": seeds, "scenarios": {}}
all_pass = True

def run_once(name, spec):
    proc = subprocess.run([bin_path, "scenario", "run", name, "--spec", spec, "--dir", scen_dir],
                          capture_output=True, text=True)
    lines = [line for line in proc.stdout.splitlines() if line.startswith("{")]
    if not lines:
        return {"verdict": "error", "error": (proc.stderr.strip().splitlines() or ["no output"])[-1]}
    return json.loads(lines[-1])

for name in names:
    path = os.path.join(scen_dir, name + ".toml")
    try:
        base_spec = tomllib.load(open(path, "rb"))["spec"]
    except (OSError, KeyError, tomllib.TOMLDecodeError) as error:
        report["scenarios"][name] = {"verdict": "error", "error": str(error)}
        all_pass = False
        continue
    runs = [run_once(name, f"{base_spec},seed={seed}") for seed in range(1, seeds + 1)]
    verdicts = [run.get("verdict", "error") for run in runs]
    failed = sum(1 for verdict in verdicts if verdict != "pass")
    checks, metrics = {}, {}
    for run in runs:
        for check in run.get("checks", []):
            key = (check["metric"], check["stat"], check.get("min"), check.get("max"))
            entry = checks.setdefault(key, {"metric": key[0], "stat": key[1], "min": key[2], "max": key[3],
                                            "values": [], "pass": True})
            entry["values"].append(check.get("value"))
            entry["pass"] = entry["pass"] and bool(check.get("pass"))
        for metric, body in run.get("metrics", {}).items():
            metrics.setdefault(metric, {"unit": body.get("unit"), "p50": [], "p95": [], "max": []})
            for stat in ("p50", "p95", "max"):
                if body.get(stat) is not None:
                    metrics[metric][stat].append(body[stat])
    summary = {
        "verdict": "pass" if failed == 0 else "fail",
        "seeds_failed": failed,
        "checks": list(checks.values()),
        "metrics": {
            metric: {
                "unit": body["unit"],
                "p50_median": round(statistics.median(body["p50"]), 3) if body["p50"] else None,
                "p95_median": round(statistics.median(body["p95"]), 3) if body["p95"] else None,
                "max_max": round(max(body["max"]), 3) if body["max"] else None,
            }
            for metric, body in metrics.items()
        },
    }
    if any(verdict == "error" for verdict in verdicts):
        summary["verdict"] = "error"
        summary["errors"] = [run.get("error") for run in runs if run.get("verdict") == "error"]
    report["scenarios"][name] = summary
    all_pass = all_pass and summary["verdict"] == "pass"

report["pass"] = all_pass
print(json.dumps(report, sort_keys=True))
sys.exit(0 if all_pass else 1)
PY
}

main "$@"

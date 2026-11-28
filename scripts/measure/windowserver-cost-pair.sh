#!/usr/bin/env bash
# One exclusive display-worker job, two exact app revisions, one unchanged WindowServer probe.
# cmux-ci run --class exclusive --measurement --label measure \
#   --script scripts/measure/windowserver-cost-pair.sh --ref HARNESS_SHA \
#   --artifact artifacts/windowserver-cost-pair \
#   --arg=--baseline-ref=FULLSHA --arg=--fixed-ref=FULLSHA
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
baseline="" fixed="" out="$PWD/artifacts/windowserver-cost-pair"
probe_args=()
for arg in "$@"; do
  case "$arg" in
    --baseline-ref=*) baseline="${arg#--baseline-ref=}" ;;
    --fixed-ref=*) fixed="${arg#--fixed-ref=}" ;;
    --out=*) out="${arg#--out=}" ;;
    --scenarios=*|--rounds=*|--idle-s=*|--tabs=*|--samples=*) probe_args+=("$arg") ;;
    *) echo "windowserver-cost-pair: unknown argument $arg" >&2; exit 2 ;;
  esac
done
if [[ ! "$baseline" =~ ^[0-9a-fA-F]{40}$ || ! "$fixed" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "windowserver-cost-pair: --baseline-ref and --fixed-ref must be full pushed commit SHAs" >&2
  exit 2
fi
mkdir -p "$out"
out="$(cd "$out" && pwd)"
. scripts/measure/app-at-commit.sh
scratch="$(mktemp -d)"
trap 'measure_remove_scratch "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
status=0
for arm in baseline fixed; do
  sha="$baseline"
  [[ "$arm" != fixed ]] || sha="$fixed"
  mkdir -p "$out/$arm"
  build_status=0
  app="$(measure_app_at_commit "$sha" "ws887-$arm" "$scratch/$arm-tree" \
    --config bench --no-global-cli-links --build-only --keep-app "$scratch/$arm.app" \
    2> "$out/$arm/build.log")" || build_status=$?
  python3 - "$out/$arm/build-receipt.json" "$sha" "$app" "$build_status" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "declared_source_sha": sys.argv[2], "app": sys.argv[3], "build_exit_code": int(sys.argv[4]),
    "config": "bench", "build_log": "build.log",
}, indent=2) + "\n")
PY
  if [[ "$build_status" != 0 ]]; then
    echo "WINDOWSERVER-PAIR-FAIL $arm build at $sha; see $out/$arm/build.log" >&2
    status=1
    continue
  fi
  echo "WINDOWSERVER-PAIR-BUILT $arm $sha $app"
  if ! scripts/measure/windowserver-cost.sh --app="$app" --app-source-sha="$sha" --out="$out/$arm" \
      ${probe_args[@]+"${probe_args[@]}"} > "$out/$arm/probe.log" 2>&1; then
    echo "WINDOWSERVER-PAIR-FAIL $arm probe transport; see $out/$arm/probe.log" >&2
    status=1
  fi
done
# Single-arm transport deliberately exits zero for partial reports. The paired job must
# reject either failed arm and confirm identical probe fingerprints before claiming a pair.
python3 - "$out" "$status" <<'PY' || status=1
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
if int(sys.argv[2]):
    raise SystemExit("WINDOWSERVER-PAIR-FAIL a build or probe transport failed")
reports = []
for arm in ("baseline", "fixed"):
    report = json.loads((root / arm / "report.json").read_text())
    if report.get("verdict") != "passed" or report.get("failures") or report.get("harness_exit_code"):
        raise SystemExit("WINDOWSERVER-PAIR-FAIL " + arm + " validation; see report.json")
    provenance = report.get("provenance") or {}
    build = json.loads((root / arm / "build-receipt.json").read_text())
    if build["build_exit_code"] or provenance.get("declared_app_source_sha") != build["declared_source_sha"]:
        raise SystemExit("WINDOWSERVER-PAIR-FAIL " + arm + " source receipt mismatch")
    if not provenance.get("executable_sha256") or provenance.get("binary_provenance_error"):
        raise SystemExit("WINDOWSERVER-PAIR-FAIL " + arm + " binary provenance unavailable")
    reports.append(report)
if not reports[0]["provenance"].get("harness_sha256") or reports[0]["provenance"]["harness_sha256"] != reports[1]["provenance"].get("harness_sha256"):
    raise SystemExit("WINDOWSERVER-PAIR-FAIL probe fingerprints differ")
print("WINDOWSERVER-PAIR-PASS both arms valid with identical probe fingerprints")
PY
exit "$status"

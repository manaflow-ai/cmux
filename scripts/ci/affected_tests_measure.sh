#!/usr/bin/env bash
# The Linux half of affected_tests.py's measurement: at one merged commit, the full suite and
# the affected selection, one after the other on the same runner, each from a cold cmux-tui
# target dir. Run it as a fast check (setup rust) from this PR's head:
#   cmux-ci test --setup rust --timeout 10800 -- bash scripts/ci/affected_tests_measure.sh SHA [PYTHON_TEST]...
# SHA is the merged commit; its first parent is the base. PYTHON_TEST are the linux-guard tests
# the plan selects (affected_tests.py's python units), none for a plan with no Python unit.
# Writes $FAST_CHECKS_OUT/measure.json: seconds and the failed tests of each run.
set -uo pipefail
sha="${1:?SHA}"
shift
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: SHA must be 40 hex" >&2; exit 2; }
out="${FAST_CHECKS_OUT:-$PWD/.build/measure}"
mkdir -p "$out"
work="$(mktemp -d)"
# This script and the lane runner (with --path) come from this PR's head: the checkout below
# replaces the tree.
cp scripts/ci/run_python_test_lane.py "$work/run_python_test_lane.py"
git fetch --quiet --no-tags --depth=2 origin "$sha" || { echo "error: cannot fetch $sha" >&2; exit 3; }
git checkout --quiet --force "$sha"
cp "$work/run_python_test_lane.py" scripts/ci/run_python_test_lane.py
bash scripts/ci/init-submodule.sh ghostty >/dev/null
base="$(git rev-parse "$sha^")"
if ! command -v cargo-nextest >/dev/null; then
  curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C "$HOME/.cargo/bin"
fi
scope="$(python3 scripts/ci/cargo_affected.py --root . --base "$base")"
echo "affected scope: ${scope:-<none>}"
export CARGO_TARGET_DIR="$work/target"
results="$work/results.jsonl"

rust() { # LABEL SCOPE...
  local label="$1" start rc
  shift
  rm -rf "$CARGO_TARGET_DIR"
  start=$(date +%s)
  (cd cmux-tui && cargo nextest run "$@" --locked --profile ci --no-tests=pass) >"$out/$label.log" 2>&1
  rc=$?
  python3 - "$label" "$rc" "$(( $(date +%s) - start ))" "$CARGO_TARGET_DIR/nextest/ci/junit.xml" "$*" >>"$results" <<'PY'
import json, os, sys
import xml.etree.ElementTree as ET
label, rc, secs, junit, scope = sys.argv[1:]
failed, total = [], 0
if os.path.exists(junit):
    for case in ET.parse(junit).iter("testcase"):
        total += 1
        if case.find("failure") is not None or case.find("error") is not None:
            failed.append(f"{case.get('classname')}::{case.get('name')}")
print(json.dumps({"label": label, "rc": int(rc), "seconds": int(secs), "tests": total, "failed": sorted(failed), "scope": scope}))
PY
}

python_lane() { # LABEL [--path P]...
  local label="$1" start rc
  shift
  start=$(date +%s)
  python3 scripts/ci/run_python_test_lane.py --lane linux-guard --jobs 8 "$@" >"$out/$label.log" 2>&1
  rc=$?
  python3 - "$label" "$rc" "$(( $(date +%s) - start ))" "$out/$label.log" >>"$results" <<'PY'
import json, re, sys
label, rc, secs, log = sys.argv[1:]
text = open(log, encoding="utf-8", errors="replace").read()
failed = sorted(set(re.findall(r"^(?:FAIL|FAILED|TIMEOUT)\S*:?\s+(tests?/\S+\.py|\S+/test_\S+\.py)", text, re.M)))
print(json.dumps({"label": label, "rc": int(rc), "seconds": int(secs), "failed": failed}))
PY
}

rust rust-full --workspace
if [[ -n "$scope" ]]; then
  # shellcheck disable=SC2086 # the scope is cargo_affected.py's argument list
  rust rust-affected $scope
else
  echo '{"label": "rust-affected", "rc": 0, "seconds": 0, "tests": 0, "failed": [], "scope": ""}' >>"$results"
fi
python_lane python-full
if [[ $# -gt 0 ]]; then
  args=()
  for p in "$@"; do args+=(--path "$p"); done
  python_lane python-affected "${args[@]}"
else
  echo '{"label": "python-affected", "rc": 0, "seconds": 0, "failed": []}' >>"$results"
fi
python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1])]; json.dump({"sha": sys.argv[2], "base": sys.argv[3], "runs": rows}, open(sys.argv[4], "w"), indent=2); print(json.dumps(rows, indent=1))' \
  "$results" "$sha" "$base" "$out/measure.json"
rm -rf "$work"

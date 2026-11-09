#!/usr/bin/env bash
# The Linux half of affected_tests.py's measurement: at one merged commit, the full suite and
# the affected selection, one after the other on the same runner, each from a cold cmux-tui
# target dir. Run it as a fast check (setup rust) from this PR's head:
#   cmux-ci test --setup rust --timeout 10800 -- bash scripts/ci/affected_tests_measure.sh [--python-only] SHA [PYTHON_TEST]...
# SHA is the merged commit; its first parent is the base. PYTHON_TEST are the linux-guard tests
# the plan selects (affected_tests.py's python units), none for a plan with no Python unit.
# Writes $FAST_CHECKS_OUT/measure.json: seconds and the failed tests of each run.
set -uo pipefail
python_only=0
if [[ "${1:-}" == --python-only ]]; then python_only=1; shift; fi
sha="${1:?SHA}"
shift
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: SHA must be 40 hex" >&2; exit 2; }
out="${FAST_CHECKS_OUT:-$PWD/.build/measure}"
mkdir -p "$out"
work="$(mktemp -d)"
# This script and the lane runner (with --path) come from this PR's head: the checkout below
# replaces the tree.
cp scripts/ci/run_python_test_lane.py "$work/run_python_test_lane.py"
depth=()  # --depth only in a checkout that is already shallow, so a full clone stays full
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=2)
git fetch --quiet --no-tags ${depth[@]+"${depth[@]}"} origin "$sha" || { echo "error: cannot fetch $sha" >&2; exit 3; }
git checkout --quiet --force "$sha"
cp "$work/run_python_test_lane.py" scripts/ci/run_python_test_lane.py
bash scripts/ci/init-submodule.sh ghostty >/dev/null
base="$(git rev-parse "$sha^")"
# Some linux-guard tests need fish; the lane runner refuses to start without it.
command -v fish >/dev/null || sudo apt-get install -y -qq fish >/dev/null 2>&1 || echo "measure: fish not installed"
if [[ "$python_only" == 0 ]] && ! command -v cargo-nextest >/dev/null; then
  curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C "$HOME/.cargo/bin"
fi
scope=""
[[ "$python_only" == 1 ]] || scope="$(python3 scripts/ci/cargo_affected.py --root . --base "$base")"
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
  python3 - "$label" "$rc" "$(( $(date +%s) - start ))" "$out/$label.log" "$*" >>"$results" <<'PY'
import json, re, sys
label, rc, secs, log, scope = sys.argv[1:]
# nextest's per-test lines: "  PASS [ 0.1s] ( 1/9) crate::binary test_name"
line = re.compile(r"^\s+(\S+) \[.*?\]\s+\(\s*\d+/\d+\)\s+(\S+)\s+(\S+)")
ran, failed = set(), set()
for text in open(log, encoding="utf-8", errors="replace"):
    m = line.match(text)
    if m:
        ran.add(f"{m.group(2)} {m.group(3)}")
        if m.group(1) not in ("PASS", "LEAK", "FLAKY"):
            failed.add(f"{m.group(2)} {m.group(3)}")
print(json.dumps({"label": label, "rc": int(rc), "seconds": int(secs), "tests": len(ran), "failed": sorted(failed), "scope": scope}))
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

if [[ "$python_only" == 1 ]]; then
  :
elif rust rust-full --workspace; [[ -n "$scope" ]]; then
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

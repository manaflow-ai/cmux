#!/usr/bin/env bash
# The acpmux lib's default test run beside 16 busy loops: the detector for the class "a timing
# judged on a busy host" (a wall-clock bound in the default run that goes red when the host is
# loaded). It must pass. A check you run by hand on CI, not a gate; nothing wires it into a
# workflow:
#   cmux-ci test --setup rust -- 'bash scripts/ci/acpmux-lib-under-load.sh'
# It starts LOAD_LOOPS (default 16) busy loops it owns, records their PIDs and kills only
# those on exit, runs `cargo nextest run -p acpmux --lib --profile ci` (no fail-fast, no
# retries, JUnit at cmux-tui/target/nextest/ci/junit.xml), prints nextest's summary and one
# `UNDER-LOAD-RED <binary> <test>` line per failing test from the JUnit file, and exits with
# nextest's code. Arguments go to nextest (a filter: `-- 'bash ... -E "test(/outbox/)"'`).
# A red here is a test whose bound depends on how busy the host is: move its
# wall-clock bound to nextest's timing-alone group or an #[ignore] timing test and give the
# default test a count or byte bound (cmux#41508). Runs only on CI (CI or CMUX_CI_STEP_KEY set),
# never on a developer machine.
set -euo pipefail
if [[ -z "${CI:-}" && -z "${CMUX_CI_STEP_KEY:-}" ]]; then
  echo "acpmux-lib-under-load.sh loads every CPU and runs only on CI:" >&2
  echo "  cmux-ci test --setup rust -- 'bash scripts/ci/acpmux-lib-under-load.sh'" >&2
  exit 2
fi
root="$(git rev-parse --show-toplevel)"
cd "$root/cmux-tui"
loops="${LOAD_LOOPS:-16}"
[[ "$loops" =~ ^[0-9]+$ ]] || { echo "LOAD_LOOPS must be a number, got $loops" >&2; exit 2; }
# The fast-checks Rust setup has cargo but not nextest (as scripts/ci/affected_tests_measure.sh).
if ! command -v cargo-nextest >/dev/null; then
  mkdir -p "${CARGO_HOME:-$HOME/.cargo}/bin"
  curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C "${CARGO_HOME:-$HOME/.cargo}/bin"
fi

# Build first, unloaded, so the load lands on the tests and not on the compiler.
cargo nextest run -p acpmux --lib --profile ci --no-run "$@"

pids=()
stop_load() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap stop_load EXIT
for _ in $(seq 1 "$loops"); do
  ( while :; do :; done ) &
  pids+=("$!")
done
echo "UNDER-LOAD loops=$loops pids=${pids[*]} cpus=$(nproc)"

# nextest's store is target/nextest under the workspace root, whatever CARGO_TARGET_DIR says.
junit="$PWD/target/nextest/ci/junit.xml"
rm -f "$junit"
set +e
cargo nextest run -p acpmux --lib --profile ci --no-fail-fast "$@"
code=$?
set -e
stop_load
trap - EXIT

if [[ -f "$junit" ]]; then
  python3 - "$junit" <<'PY'
import sys
import xml.etree.ElementTree as ET

reds = []
for case in ET.parse(sys.argv[1]).getroot().iter("testcase"):
    if case.find("failure") is not None or case.find("error") is not None:
        reds.append((case.get("classname", ""), case.get("name", "")))
for binary, name in sorted(reds):
    print(f"UNDER-LOAD-RED {binary} {name}")
print(f"UNDER-LOAD reds={len(reds)}")
PY
else
  echo "UNDER-LOAD no JUnit file at $junit"
fi
echo "UNDER-LOAD nextest exit=$code"
exit "$code"

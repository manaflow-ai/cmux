#!/usr/bin/env bash
# The prepush gate suite's four check-pool shards, timed with the base fixture made fresh for every test (the old
# setUp, `old`) and made once a process then copied (tests/test_cmux_next_prepush_gate.py's _BASE_FIXTURES, `new`),
# on one host, shard by shard, old then new: the same harness for the before and after of #64044.
#   Run: cmux-ci test -- bash scripts/measure/prepush-gate-fixture.sh
run() { # $1 old|new, $2 shard
python3 - "$1" "$2" <<'PY'
import importlib.util, sys, time
from pathlib import Path
mode, shard = sys.argv[1], sys.argv[2]
sys.path.insert(0, "tests")
spec = importlib.util.spec_from_file_location("gate", Path("tests/test_cmux_next_prepush_gate.py").resolve())
gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
if mode == "old":  # the parent commit's setUp: every test makes its base fresh
    setup = gate.PrePushGateTests.setUp
    def fresh(self):
        gate._BASE_FIXTURES.clear()
        setup(self)
    gate.PrePushGateTests.setUp = fresh
import unittest_shard
sys.argv = ["gate", "--shard", shard]
start = time.time()
try:
    unittest_shard.main(module=gate)
finally:
    print(f"RESULT {mode} shard {shard} {time.time()-start:.0f}s", file=sys.stderr)
PY
}
for s in 1/4 2/4 3/4 4/4; do
  run old $s 2>&1 | grep -E "^RESULT|^(OK|FAILED)|^Ran " 
  run new $s 2>&1 | grep -E "^RESULT|^(OK|FAILED)|^Ran "
done

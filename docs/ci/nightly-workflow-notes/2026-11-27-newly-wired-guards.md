# Newly wired guard merge verification

PR #58134 adds executable guard steps relative to base
`f0a5ca40dc975fe710fc8b15dd415f101050dcdd`. A previously failing test becomes this PR's own red when the PR first wires it.
Registry validation alone does not execute these tests. Run the exact workflow
steps below on the proposed merge head; retain the head SHA, terminal exit and
results file with the PR's verification evidence. Every named step must pass.
Check that every named step appears in the results; `--keep-going` reaches later guards
after a failure. The deadline produces an incomplete, failing receipt.

```bash
python3 scripts/ci/run_ci_guards.py --all --keep-going --no-stamp --deadline 900 \
  --results /tmp/58134-newly-wired-guards.json \
  --step 'Validate apt package handling on runner images' \
  --step 'Validate iroh Apple suite coverage' \
  --step 'Validate commands on owned Mac runners' \
  --step 'Validate the Linux batch workflow' \
  --step 'Validate relay journey build caching' \
  --step 'Validate dispatch workflow registration' \
  --step 'Validate API workerd green markers' \
  --step 'Validate the hot verify workspace mirror seed' \
  --step 'Validate job routing on router failure' \
  --step 'Validate app compile deferral on pull requests' \
  --step 'Validate cmux-tui tree requests for pull requests' \
  --step 'Validate fleet fallback reporting' \
  --step 'Validate registered base coalesce record dir' \
  --step 'Validate registered cancel superseded pr runs' \
  --step 'Validate registered ci affected set replay' \
  --step 'Validate registered ci app input digest' \
  --step 'Validate registered ci branch history fetch' \
  --step 'Validate registered ci cmux tui mac warm target' \
  --step 'Validate registered ci fixit handoff' \
  --step 'Validate registered ci fleet fast tier result' \
  --step 'Validate registered ci ghosttykit digest routing' \
  --step 'Validate registered ci guards skip when checkout failed' \
  --step 'Validate registered ci hourly full tier' \
  --step 'Validate registered ci land tier status post' \
  --step 'Validate registered ci light jobs pool mirror checkout' \
  --step 'Validate registered ci pool tokens' \
  --step 'Validate registered ci reset needs repo' \
  --step 'Validate registered ci router checkout mirror' \
  --step 'Validate registered ci tui tree checkout retry' \
  --step 'Validate registered cmux next media defer keeps clips' \
  --step 'Validate registered cmux next media tour timeout' \
  --step 'Validate registered cmux next pr autofix drift scope' \
  --step 'Validate registered cmux next pr autofix repair on red' \
  --step 'Validate registered cmux scheme compile fleet' \
  --step 'Validate registered cmux tui branch on request' \
  --step 'Validate registered cmux tui dispatch points channel' \
  --step 'Validate registered cmux tui tree key verb' \
  --step 'Validate registered fast checks concurrency' \
  --step 'Validate registered ios mobile core linux only' \
  --step 'Validate registered mac tiers' \
  --step 'Validate registered nightly component fallbacks' \
  --step 'Validate registered nightly git token env' \
  --step 'Validate registered nightly next web bundles gate' \
  --step 'Validate registered nightly release downloads' \
  --step 'Validate registered nightly warm checkout bounded' \
  --step 'Validate registered receipt input key' \
  --step 'Validate registered screen sharing helper release' \
  --step 'Validate registered swift linux reach' \
  --step 'Validate acpmux full-ci own-path routing' \
  --step 'Validate Rust workspace coverage on the landing head' \
  --step 'Validate workflow self-edit sweep routing' \
  --step 'Validate TUI simulations run after merge' \
  --step 'Validate machine-channel Cargo seed freshness' \
  --step 'Validate web green-marker input keys' \
  --step 'Validate kit benchmarks after a lint failure' \
  --step 'Validate iOS live lease ownership' \
  --step 'Validate opaque App Store screenshots' \
  --step 'Validate ephemeral daily signing' \
  --step 'Validate the nightly feed watcher' \
  --step 'Validate nightly notarization channels' \
  --step 'Validate release reads during publication'

python3 scripts/ci/guards_new_reds.py --tip /tmp/58134-newly-wired-guards.json
python3 - <<'CHECK'
import json
import subprocess
from pathlib import Path
import yaml
base = "f0a5ca40dc975fe710fc8b15dd415f101050dcdd"
workflow = ".github/workflows/ci-guards.yml"
def steps(doc):
    return {(job, step["name"]) for job, data in doc["jobs"].items()
            for step in data.get("steps", []) if "run" in step}
before = yaml.safe_load(subprocess.check_output(["git", "show", base + ":" + workflow]))
after = yaml.safe_load(Path(workflow).read_text())
expected = {name for job, name in steps(after) - steps(before)}
results = json.loads(Path("/tmp/58134-newly-wired-guards.json").read_text())
assert expected, "No newly wired guards selected"
assert all(results.get(name) is True for name in expected), sorted(
    name for name in expected if results.get(name) is not True)
print(f"All {len(expected)} newly wired guards have passing results")
CHECK
```

The workflow's individual steps and registry lane entries keep this verification
in CI after merge. The wiring detector is
`tests/test_ci_workflow_guards_are_wired.py`: autogenerated manual reasons are
not exemptions. The router detector is
`tests/test_ci_path_route_skips_on_failure.py`: only the exact documented
`remote-web-wasm` condition may run after its router fails. Its mutation tests
reject broader exceptions and operand-valued fallback mistakes.

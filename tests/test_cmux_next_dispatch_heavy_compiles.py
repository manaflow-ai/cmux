#!/usr/bin/env python3
"""A working-branch dispatch of cmux-next.yml skips the scheme and Release compiles unless full=true.

On 2026-11-15 about 14 lanes dispatched cmux-next.yml on their own branches. A dispatch runs every
tier, so each one put a 5-unit `cmux app scheme compile (Debug)` (and a Release compile) on
glaeda-side-std-xcode-27.2: 24 jobs queued there, the oldest 81 minutes. path_route now writes
scheme=false and native=false for such a dispatch unless it passes `full=true`; pushes, pull
requests, the DEV daily, base tier, tip suites and same-tree runs keep their routing.

The override's bash condition is run here for each kind of run (docs/ci/cmux-next-workflow-notes.md#note-365).
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/cmux-next.yml").read_text()

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


inputs = re.search(r"^  workflow_dispatch:\n    inputs:\n(.*?)(?=^\S)", WORKFLOW, re.MULTILINE | re.DOTALL)
inputs_text = inputs.group(1) if inputs else ""
full_input = re.search(r"^      full:\n((?:        .*\n)+)", inputs_text, re.MULTILINE)
check(bool(full_input), "workflow_dispatch must have a `full` input")
check(bool(full_input) and "default: false" in full_input.group(1) and "type: boolean" in full_input.group(1),
      "`full` must be a boolean that defaults to false, so a plain dispatch skips the heavy compiles")

route = re.search(r"- name: Classify pull request paths\n        id: route\n(.*?)(?=\n      - name: )", WORKFLOW, re.DOTALL)
route_text = route.group(1) if route else ""
# The step's commands live in scripts/ci/cmux-next-steps/ (moved out to keep cmux-next.yml under its size budget,
# tests/test_ci_workflow_file_size.py); its env: stays in the workflow. Read both.
step_script = re.search(r"run: bash -e (scripts/ci/cmux-next-steps/[A-Za-z0-9_.-]+\.sh)\n", route_text + "\n")
if step_script:
    route_text += "\n" + (ROOT / step_script.group(1)).read_text()
check("FULL_DISPATCH: ${{ inputs.full || false }}" in route_text, "the route step must read inputs.full")
block = re.search(r"\n( +)if \[\[ \"\$EVENT_NAME\" == workflow_dispatch && -z \"\$SAME_TREE_SHA\" && \"\$FULL_DISPATCH\" != true(.*?)\n\1fi\n",
                  route_text, re.DOTALL)
check(bool(block), "the route step must override scheme and native for a working-branch dispatch")


def routed(event, ref, same_tree="", full="false"):
    """The outputs the override writes for one run."""
    if not block:
        return ""
    script = "set -euo pipefail\n" + re.sub(r"(?m)^" + block.group(1), "", "if [[ \"$EVENT_NAME\" == workflow_dispatch && -z \"$SAME_TREE_SHA\" && \"$FULL_DISPATCH\" != true" + block.group(2) + "\nfi\n")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out"
        summary = Path(tmp) / "summary"
        out.write_text("")
        env = dict(os.environ, EVENT_NAME=event, GITHUB_REF=ref, SAME_TREE_SHA=same_tree, FULL_DISPATCH=full,
                   GITHUB_OUTPUT=str(out), GITHUB_STEP_SUMMARY=str(summary))
        result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
        check(result.returncode == 0, f"override failed for {event} {ref}: {result.stderr.strip()}")
        return out.read_text()


skipped = "scheme=false\nnative=false\n"
check(routed("workflow_dispatch", "refs/heads/lane/some-work") == skipped,
      "a plain working-branch dispatch must skip the scheme and Release compiles")
check(routed("workflow_dispatch", "refs/heads/lane/some-work", full="true") == "",
      "a dispatch with full=true must keep the scheme and Release compiles")
check(routed("workflow_dispatch", "refs/heads/feat-cmux-next") == "",
      "a feat-cmux-next dispatch must keep its routing")
check(routed("workflow_dispatch", "refs/heads/next-batch/42") == "",
      "a next-batch dispatch must keep its routing")
check(routed("workflow_dispatch", "refs/heads/lane/some-work", same_tree="a" * 40) == "",
      "a same-tree run must keep its routing")
check(routed("push", "refs/heads/feat-cmux-next") == "", "a push must keep its routing")
check(routed("pull_request", "refs/pull/1/merge") == "", "a pull request must keep its routing")

# The override sits after the router wrote its outputs (GitHub keeps the last value of an output).
router_at = route_text.find("python3 scripts/ci/cmux_next_route.py")
check(router_at != -1 and block is not None and route_text.find(block.group(0)) > router_at,
      "the override must come after cmux_next_route.py writes the outputs")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print("ok: a working-branch dispatch skips the scheme and Release compiles unless full=true")

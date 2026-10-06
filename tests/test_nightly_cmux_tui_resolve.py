#!/usr/bin/env python3
"""The nightly bundles the newest PUBLISHED cmux-tui tree and never waits for the tip's.

Regression: nightly-next run 37464320457 failed in resolve-nightly-cmux-tui-client
("cmux-tui for this checkout's tree 23f87460a409 is not published after 45 min").
cmux-tui-artifacts.yml lets a running build finish and a newer push replaces only
the pending run, so under steady pushes the tip's own tree may never publish.
The resolver walks back a bounded window of commits (pin-cmux-tui.sh
resolve-newest-published, behavior-tested by
scripts/cmux-next/tests/pin-cmux-tui-resolve-newest.test.sh, which this guard
also runs) and records the tree and commit it used.
"""

import subprocess
import sys
from pathlib import Path

import re

ROOT = Path(__file__).resolve().parents[1]
failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


text = (ROOT / ".github/workflows/nightly.yml").read_text()
# The job block: from its key to the next job key (two-space indent), no YAML module needed.
match = re.search(r"^  resolve-nightly-cmux-tui-client:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)", text, re.MULTILINE | re.DOTALL)
job = match.group(1) if match else ""
check(bool(job), "nightly.yml must keep the resolve-nightly-cmux-tui-client job")
resolve = job[job.find("id: resolve"):] if "id: resolve" in job else ""
check("pin-cmux-tui.sh resolve-newest-published" in resolve,
      "the resolve step must use pin-cmux-tui.sh resolve-newest-published")
check("resolve-commit" not in resolve and "CMUX_TUI_TREE_WAIT_SECONDS" not in resolve,
      "the resolve step must not wait for the tip's tree (resolve-commit / CMUX_TUI_TREE_WAIT_SECONDS)")
check("CMUX_TUI_TREE_SEARCH_COMMITS:" in resolve,
      "the resolve step must bound the search with CMUX_TUI_TREE_SEARCH_COMMITS")
check("GITHUB_STEP_SUMMARY" in resolve or "GITHUB_STEP_SUMMARY" in (ROOT / "scripts/cmux-next/pin-cmux-tui.sh").read_text(),
      "the resolver must record the tree and commit in the step summary")
outputs = re.search(r"^    outputs:\n((?:^      .*\n)+)", job, re.MULTILINE)
for name in ("commit", "key", "source_commit"):
    check(bool(outputs) and re.search(rf"^      {name}:", outputs.group(1), re.MULTILINE) is not None,
          f"resolve-nightly-cmux-tui-client must output {name}")
timeout = re.search(r"^    timeout-minutes: (\d+)", job, re.MULTILINE)
check(bool(timeout) and int(timeout.group(1)) <= 20, "a resolver that never waits needs no 55-minute timeout")
depth = re.search(r"fetch-depth: (\d+)", job)
check(bool(depth) and (int(depth.group(1)) == 0 or int(depth.group(1)) > 50),
      "the checkout must hold the search window (fetch-depth > 50)")

test = ROOT / "scripts/cmux-next/tests/pin-cmux-tui-resolve-newest.test.sh"
result = subprocess.run(["bash", str(test)], capture_output=True, text=True)
check(result.returncode == 0, f"{test.name} failed:\n{result.stdout}{result.stderr}")

if failures:
    print("FAIL: nightly cmux-tui resolve\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly cmux-tui resolve")

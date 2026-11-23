#!/usr/bin/env python3
"""Runs cmux-duress.yml's "Replay every scenario" script against a stand-in cmux-duress.

`cmux-duress scenario list` prints a table: a `name  headless  summary` header row, then one row per scenario
(cmux-tui/crates/cmux-duress/src/scenario.rs, list_table). The step once read the header's `name` as a
scenario, ran `scenario run name`, and turned feat-cmux-next red ("scenario name exited 2").
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-duress.yml"

FAKE_BIN = """#!/usr/bin/env bash
case "$1 $2" in
  "scenario list")
    printf '%s\\n' 'name           headless   summary' \\
      'flaky-wifi     yes        drops every 3 s' \\
      'phone-sleeps   sim-only   suspends the app'
    ;;
  "scenario run")
    [[ "$3" == flaky-wifi || "$3" == phone-sleeps ]] || { echo "no scenario $3" >&2; exit 2; }
    echo "replaying $3"
    printf '{"ok": true, "name": "%s"}\\n' "$3"
    ;;
  *) echo "usage: cmux-duress scenario list|run"; exit 2 ;;
esac
"""


def replay_script() -> str:
    """The step's `run: |` block, dedented (plain text: the runner's python3 has no PyYAML)."""
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "- name: Replay every scenario")
    run = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
    body = []
    for line in lines[run + 1 :]:
        if line.strip() and len(line) - len(line.lstrip()) <= len(lines[run]) - len(lines[run].lstrip()):
            break
        body.append(line)
    indent = min(len(line) - len(line.lstrip()) for line in body if line.strip())
    return "\n".join(line[indent:] for line in body) + "\n"


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        bin_path = work / "target/release/cmux-duress"
        bin_path.parent.mkdir(parents=True)
        bin_path.write_text(FAKE_BIN)
        bin_path.chmod(0o755)
        runner_temp = work / "runner"
        runner_temp.mkdir()
        env = {
            **os.environ,
            "RUNNER_TEMP": str(runner_temp),
            "GITHUB_OUTPUT": str(work / "output"),
            "GITHUB_STEP_SUMMARY": str(work / "summary"),
        }
        done = subprocess.run(
            ["bash", "-c", replay_script()], cwd=work, env=env, capture_output=True, text=True, check=False
        )
        out = runner_temp / "duress-scenarios"
        broken = (out / "broken.txt").read_text()
        rows = [json.loads(line) for line in (out / "scenarios.jsonl").read_text().splitlines()]
        failures = []
        if done.returncode != 0:
            failures.append(f"step exited {done.returncode}: {done.stdout}{done.stderr}")
        if broken:
            failures.append(f"broken.txt is not empty: {broken!r}")
        if [row["scenario"] for row in rows] != ["flaky-wifi", "phone-sleeps"]:
            failures.append(f"replayed {[row['scenario'] for row in rows]}, want the two table rows")
        if "scenario name" in done.stdout:
            failures.append("the header row's `name` was replayed as a scenario")
    for failure in failures:
        print(f"FAIL: {failure}")
    if not failures:
        print("PASS: the replay step skips the list header and replays each scenario row")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

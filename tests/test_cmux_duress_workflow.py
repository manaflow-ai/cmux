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
      'phone-sleeps   sim-only   suspends the app' \\
      'slow-scroll    yes        regressed'
    ;;
  "scenario run")
    [[ "$3" == flaky-wifi || "$3" == phone-sleeps || "$3" == slow-scroll ]] || { echo "no scenario $3" >&2; exit 2; }
    echo "replaying $3"
    if [[ "$3" == slow-scroll ]]; then printf '{"verdict": "fail", "metrics": {"x": 9}}\\n'; exit 1; fi
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


def deltas_script() -> str:
    """The "Scenario deltas" step's Python (its `python3 - <<'PY'` heredoc), dedented."""
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "- name: Scenario deltas against the previous run")
    begin = next(i for i in range(start, len(lines)) if lines[i].strip() == "python3 - <<'PY'")
    end = next(i for i in range(begin + 1, len(lines)) if lines[i].strip() == "PY")
    body = lines[begin + 1 : end]
    indent = min(len(line) - len(line.lstrip()) for line in body if line.strip())
    return "\n".join(line[indent:] for line in body) + "\n"


def check_deltas() -> list[str]:
    """A known-failing scenario is reported, not red; an unknown failure is red; a fixed one is named."""
    failures = []

    def run(rows: list[dict]) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            work = pathlib.Path(tmp)
            out, prev = work / "out", work / "prev"
            out.mkdir()
            prev.mkdir()
            (out / "broken.txt").write_text("")
            (out / "scenarios.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
            (prev / "scenarios.jsonl").write_text(json.dumps({"scenario": "lag", "result": {"verdict": "fail", "wall_ms": 10}}) + "\n")
            (prev / "run-id").write_text("41")
            env = {**os.environ, "OUT": str(out), "PREV": str(prev), "GITHUB_STEP_SUMMARY": str(work / "summary")}
            done = subprocess.run([sys.executable, "-c", deltas_script()], env=env, capture_output=True, text=True, check=False)
            done.stdout += (work / "summary").read_text() if (work / "summary").is_file() else ""
            return done

    known = {"scenario": "lag", "result": {"verdict": "fail", "known_failing": "#1 open", "wall_ms": 12}}
    done = run([known, {"scenario": "ok", "result": {"verdict": "pass"}}])
    if done.returncode != 0:
        failures.append(f"a known-failing scenario turned the step red: {done.stdout}{done.stderr}")
    if "Known failing" not in done.stdout or "+20.0%" not in done.stdout:
        failures.append(f"the summary lacks the known failure or its delta against run 41: {done.stdout}")
    done = run([{"scenario": "lag", "result": {"verdict": "fail", "wall_ms": 12}}])
    if done.returncode != 1 or "its line says it failed" not in done.stdout:
        failures.append(f"an unknown failure did not turn the step red: {done.returncode} {done.stdout}")
    done = run([{"scenario": "lag", "result": {"verdict": "pass", "known_failing": "#1 open"}}])
    if done.returncode != 0 or "Passes now" not in done.stdout or "::warning::scenario lag passes now" not in done.stdout:
        failures.append(f"a known-failing scenario that passes was not named: {done.stdout}")
    return failures


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
        if broken != "slow-scroll: exited 1\n":
            failures.append(f"broken.txt should name only slow-scroll's exit: {broken!r}")
        if [row["scenario"] for row in rows] != ["flaky-wifi", "phone-sleeps", "slow-scroll"]:
            failures.append(f"replayed {[row['scenario'] for row in rows]}, want the three table rows")
        # A failing scenario's numbers are kept: the next run compares with them.
        if rows and rows[-1]["result"].get("metrics") != {"x": 9}:
            failures.append(f"the failing scenario's line was not kept: {rows[-1]!r}")
        if "scenario name" in done.stdout:
            failures.append("the header row's `name` was replayed as a scenario")
    failures += check_deltas()
    for failure in failures:
        print(f"FAIL: {failure}")
    if not failures:
        print("PASS: the replay step skips the list header, replays each scenario row and keeps a failing one's line; the deltas step reds only an unknown failure")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

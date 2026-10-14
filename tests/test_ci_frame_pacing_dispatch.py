#!/usr/bin/env python3
"""The nightly agent pane frame pacing bench runs feat-cmux-next's copy of its workflow.

The bench builds and measures cmux-next. main's reload-build.yml builds main:
its client check expects the classic ghostty, the published cmux-next client
carries ghostty-next, and the bench failed at that check every night from
2026-10-08 (cx-v9hdp). A schedule fires only on the default branch, so main's
copy must start feat-cmux-next's, whose reload-build.yml knows that tree.

Each test runs the workflow's steps that call `gh workflow run` with a stub
`gh` on PATH and reads what they asked for.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_seed_derived_data import evaluate, github_context  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-frame-pacing.yml"
REPO = "manaflow-ai/cmux"


def resolve(value: object, context: dict) -> str:
    text = str(value)
    if text.startswith("${{") and text.endswith("}}"):
        return str(evaluate(text[3:-2], context) or "")
    return text


def gh_calls(event_name: str, inputs: dict[str, str]) -> list[list[str]]:
    """The `gh` argument lists the workflow's dispatching steps make for this event."""
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    context = github_context(event_name)
    context["github"]["repository"] = REPO
    context["github"]["token"] = "token"
    context["inputs"] = inputs
    calls: list[list[str]] = []
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = Path(tmp) / "bin"
        bin_dir.mkdir()
        log = Path(tmp) / "gh.log"
        stub = bin_dir / "gh"
        stub.write_text('#!/usr/bin/env bash\nprintf "%s\\0" "$@" >> "$GH_LOG"\nprintf "\\n" >> "$GH_LOG"\n')
        stub.chmod(0o755)
        for job in document["jobs"].values():
            for step in job.get("steps", []):
                script = step.get("run", "")
                if "gh workflow run" not in script:
                    continue
                env = {
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "GH_LOG": str(log),
                    "GITHUB_REPOSITORY": REPO,
                }
                env.update({key: resolve(value, context) for key, value in (step.get("env") or {}).items()})
                subprocess.run(["bash", "-euo", "pipefail", "-c", script], env=env, check=True)
        if log.exists():
            for line in log.read_text().split("\n"):
                if line:
                    calls.append(line.rstrip("\0").split("\0"))
    return calls


def test_the_nightly_run_starts_the_bench_on_feat_cmux_next() -> None:
    assert gh_calls("schedule", {}) == [
        [
            "workflow", "run", "cmux-next-frame-pacing.yml", "--repo", REPO, "--ref", "feat-cmux-next",
            "-f", "ref=feat-cmux-next", "-f", "flings=3",
        ]
    ]


def test_a_dispatch_passes_its_ref_and_flings_on() -> None:
    assert gh_calls("workflow_dispatch", {"ref": "my-branch", "flings": "5"}) == [
        [
            "workflow", "run", "cmux-next-frame-pacing.yml", "--repo", REPO, "--ref", "feat-cmux-next",
            "-f", "ref=my-branch", "-f", "flings=5",
        ]
    ]


def test_main_never_builds_cmux_next_with_its_own_reload_build() -> None:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    callers = [name for name, job in document["jobs"].items() if "reload-build.yml" in str(job.get("uses", ""))]
    assert callers == [], f"jobs {callers} build cmux-next with main's reload-build.yml"


if __name__ == "__main__":
    failures = 0
    for name, test in list(globals().items()):
        if name.startswith("test_") and callable(test):
            try:
                test()
                print(f"ok {name}")
            except AssertionError as error:
                failures += 1
                print(f"FAIL {name}: {error}")
    sys.exit(1 if failures else 0)

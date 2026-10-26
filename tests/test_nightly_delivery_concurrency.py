"""Nightly and Dev delivery must never cancel started work."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def delivery_workflows() -> list[Path]:
    paths = sorted(WORKFLOWS.glob("nightly*.yml"))
    paths += sorted(WORKFLOWS.glob("cmux-next-dev-daily*.yml"))
    return sorted(set(paths))


def test_delivery_workflows_never_cancel_in_progress_work() -> None:
    for path in delivery_workflows():
        text = path.read_text(encoding="utf-8")
        assert not re.search(r"(?m)^\s*cancel-in-progress:\s*true\s*$", text), path


def test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups() -> None:
    tick = (WORKFLOWS / "nightly-next-tick.yml").read_text(encoding="utf-8")
    assert re.search(r'(?m)^\s+- cron: "7,37 \* \* \* \*"$', tick)
    assert "cancel-in-progress: false" in tick
    # One shared job-level group: one tick runs, the newest waits. The tick
    # dispatches no build itself, so replacing a pending tick cancels no work.
    # No polling coalescer: it spent the GITHUB_TOKEN quota (2026-10-25).
    assert "|| 'nightly-next-tick' }}" in tick
    assert "listWorkflowRuns" not in tick and "needs: coalesce" not in tick
    dev = (WORKFLOWS / "cmux-next-dev-daily-dispatch.yml").read_text(encoding="utf-8")
    assert 'cron: "2-59/5 * * * *"' in dev or 'cron: "7,22,37,52 * * * *"' in dev
    assert "cancel-in-progress: false" in dev


if __name__ == "__main__":
    test_delivery_workflows_never_cancel_in_progress_work()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()

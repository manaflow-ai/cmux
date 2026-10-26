"""Nightly and Dev delivery must never cancel started work."""

from pathlib import Path
import re

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# The delivery workflows (nightly, dev and promote builds): none may cancel a
# run in progress. A glob picks up a new nightly-* workflow on its own; the
# required names make a rename or deletion fail here instead of quietly
# dropping out of the glob.
DELIVERY_GLOBS = ("nightly*.yml", "cmux-next-dev-daily*.yml")
REQUIRED_DELIVERY_WORKFLOWS = ("nightly.yml", "cmux-next-dev-daily.yml")

# Workflows whose listed jobs take no concurrency group at all, top-level or
# job-level, not even a non-cancelling one: GitHub keeps one pending run per
# group and cancels the older pending one, so any group evicts waiting work.
NO_CONCURRENCY_GROUP: dict[str, tuple[str, ...]] = {
    # #25398: main's groups cancelled publish and tip after sign and verify had
    # passed (runs 40370485774, 40371402817, 40373347803, 40378401600). The
    # newest write wins instead through an R2 lease plus commit record
    # (publish) and a feed compare-and-swap (tip).
    "cmux-next-dev-daily.yml": ("publish", "tip"),
}


def delivery_workflows() -> list[Path]:
    paths = {path for pattern in DELIVERY_GLOBS for path in WORKFLOWS.glob(pattern)}
    return sorted(paths)


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def test_required_delivery_workflows_exist() -> None:
    found = {path.name for path in delivery_workflows()}
    for name in (*REQUIRED_DELIVERY_WORKFLOWS, *NO_CONCURRENCY_GROUP):
        assert name in found, f"{name} is missing: a rename would silently drop its delivery guard"


def test_delivery_workflows_never_cancel_in_progress_work() -> None:
    for path in delivery_workflows():
        text = path.read_text(encoding="utf-8")
        assert not re.search(r"(?m)^\s*cancel-in-progress:\s*true\s*$", text), path


def test_newest_wins_jobs_take_no_concurrency_group() -> None:
    for name, jobs in NO_CONCURRENCY_GROUP.items():
        document = load(WORKFLOWS / name)
        assert "concurrency" not in document, (
            f"{name} has a top-level concurrency group: it would replace a pending run of {', '.join(jobs)}")
        for job in jobs:
            assert job in document["jobs"], f"{name} has no {job} job: update NO_CONCURRENCY_GROUP"
            assert "concurrency" not in document["jobs"][job], (
                f"{name} {job} has a concurrency group: GitHub would cancel its pending run; "
                "newest-wins belongs to the job's own lease or compare-and-swap")


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
    test_required_delivery_workflows_exist()
    test_delivery_workflows_never_cancel_in_progress_work()
    test_newest_wins_jobs_take_no_concurrency_group()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()
    print("PASS: nightly and DEV delivery never cancel or replace waiting builds")

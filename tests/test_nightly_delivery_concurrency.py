"""Nightly and Dev delivery must never cancel started work."""

from pathlib import Path
import re
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# The delivery workflows (nightly, dev and promote builds): none may cancel a
# run in progress. scripts/ci/delivery_workflows.py declares them once; the
# queue janitor reads the same list to never cancel one of their runs.
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
from delivery_workflows import (  # noqa: E402
    DELIVERY_GLOBS, DELIVERY_RUN_NAME_PREFIXES, REQUIRED_DELIVERY_WORKFLOWS, is_delivery_run, is_delivery_workflow)

# Workflows whose listed jobs take no concurrency group at all, top-level or
# job-level, not even a non-cancelling one: GitHub keeps one pending run per
# group and cancels the older pending one, so any group evicts waiting work.
NO_CONCURRENCY_GROUP: dict[str, tuple[str, ...]] = {
    # #25398: main's groups cancelled publish and tip after sign and verify had
    # passed (runs 40370485774, 40371402817, 40373347803, 40378401600). The
    # newest write wins instead through an R2 lease plus commit record
    # (publish) and a feed compare-and-swap (tip).
    # sign, runner, verify and the rcodesign signer build too (#26001 renamed it from rcodesign-dmg):
    # a pending handoff waiting for any of them would be evicted by a newer one (2026-10-26: nothing
    # published from 00:13Z for over six hours).
    "cmux-next-dev-daily.yml": ("sign", "runner", "verify", "publish", "tip-dmg-build", "rcodesign",
                                "tip-dmg", "tip", "tip-deltas"),
    # Classic main and rc push runs build in parallel (#25959), so their
    # continuations publish in any order. Sharing release-publish-<tag> let an
    # older run's delta job replace a newer publish that was still pending.
    # One R2 lease serializes the two writers instead.
    "auto-resume-nightly-notarization.yml": ("publish", "republish-deltas"),
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


def test_the_declared_list_matches_every_delivery_workflow_path() -> None:
    for path in delivery_workflows():
        assert is_delivery_workflow(f".github/workflows/{path.name}"), path
    for name in ("ci.yml", "ci-queue-janitor.yml", "cmux-next.yml"):
        assert not is_delivery_workflow(f".github/workflows/{name}"), name


def test_dev_source_runs_are_named_as_the_declared_list_expects() -> None:
    # The dispatcher names the DEV source build of cmux-next.yml; a renamed title would drop its protection.
    dispatch = (WORKFLOWS / "cmux-next-dev-daily-dispatch.yml").read_text(encoding="utf-8")
    assert "const workflow = 'cmux-next.yml';" in dispatch
    (prefix,) = DELIVERY_RUN_NAME_PREFIXES["cmux-next.yml"]
    assert f"const devTitle = `{prefix}${{sha}}`;" in dispatch, prefix
    assert is_delivery_run(".github/workflows/cmux-next.yml", f"{prefix}{'a' * 40}")
    assert not is_delivery_run(".github/workflows/cmux-next.yml", "cmux-next · " + "a" * 40)
    # The API's name can be the generic workflow name while display_title carries the DEV title.
    assert is_delivery_run(".github/workflows/cmux-next.yml", "cmux-next", f"{prefix}{'a' * 40}")


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


def test_nightly_push_runs_never_share_a_build_group() -> None:
    # A shared workflow-level group held a newer tip pending behind a running
    # build and let the next push replace it (2026-10-27). Each push run of
    # nightly.yml takes a group keyed by its own run id, chosen before any
    # other alternative, so no two pushes (two SHAs) ever share one.
    group = load(WORKFLOWS / "nightly.yml")["concurrency"]["group"]
    suffix = group.split("}}-${{", 1)[1].strip()
    assert suffix.startswith("github.event_name == 'push' && format('push-{0}', github.run_id) ||"), group
    assert load(WORKFLOWS / "nightly.yml")["concurrency"]["cancel-in-progress"] is False


def test_classic_publishers_write_only_while_they_hold_the_lease() -> None:
    # One writer at a time, newest first (scripts/ci/classic_publish_lease.py):
    # every write comes after the job took the lease, renews it right before
    # writing (failing the job if it was lost), and the lease is released
    # whatever happens.
    document = load(WORKFLOWS / "auto-resume-nightly-notarization.yml")
    keys = set()
    writes = ("live_appcast_build.py \"https://", "publish-release-assets.py", "upload-r2-object.py",
              "update-release-tag.py", "gh release edit")
    for name in NO_CONCURRENCY_GROUP["auto-resume-nightly-notarization.yml"]:
        job = document["jobs"][name]
        keys.add((job["env"]["LEASE_KEY"], job["env"]["CLAIM_KEY"]))
        assert job["env"]["LEASE_OWNER"] == "${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}", name
        # A successor finds the holder's job by name in the jobs API, which
        # names a job by its id only without `name:` or a matrix.
        assert "name" not in job and "strategy" not in job, name
        assert "actions" in job["permissions"], name
        steps = job["steps"]
        names = [step.get("name", "") for step in steps]
        take = names.index("Take the channel publication lease")
        release = names.index("Release the channel publication lease")
        assert "classic_publish_lease.py acquire" in steps[take]["run"], name
        assert steps[release].get("if") == "always()", name
        assert "classic_publish_lease.py release" in steps[release]["run"], name
        for index, step in enumerate(steps):
            body = str(step.get("run", ""))
            found = [marker for marker in writes if marker in body]
            if not found:
                continue
            assert take < index < release, (name, step.get("name"))
            if any(marker != writes[0] for marker in found):
                check = body.find("classic_publish_lease.py check")
                assert 0 <= check < min(body.find(marker) for marker in found if marker != writes[0]), (
                    name, step.get("name"))
                assert "R2_BUCKET" in step.get("env", {}), (name, step.get("name"))
    assert len(keys) == 1, keys

if __name__ == "__main__":
    test_required_delivery_workflows_exist()
    test_the_declared_list_matches_every_delivery_workflow_path()
    test_dev_source_runs_are_named_as_the_declared_list_expects()
    test_delivery_workflows_never_cancel_in_progress_work()
    test_newest_wins_jobs_take_no_concurrency_group()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()
    test_nightly_push_runs_never_share_a_build_group()
    test_classic_publishers_write_only_while_they_hold_the_lease()
    print("PASS: nightly and DEV delivery never cancel or replace waiting builds")

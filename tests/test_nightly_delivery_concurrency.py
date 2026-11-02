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


def test_dev_daily_jobs_take_no_concurrency_group() -> None:
    """The DEV publisher's build and signing jobs take no group at all, not even a non-cancelling one:
    GitHub keeps one pending run per group and cancels the older pending one, so a group evicts waiting
    DEV work.

    publish alone keeps its non-cancelling group in this branch's copy: it updates the rolling release
    with no lease, so the group serializes it (main's copy, which runs, uses an R2 lease instead). The
    dispatcher's own top-level group is allowed: it builds and signs nothing."""
    import yaml

    document = yaml.safe_load((WORKFLOWS / "cmux-next-dev-daily.yml").read_text(encoding="utf-8"))
    assert "concurrency" not in document, "cmux-next-dev-daily.yml has a workflow-level group"
    grouped = sorted(name for name, job in document["jobs"].items() if "concurrency" in job and name != "publish")
    assert not grouped, f"cmux-next-dev-daily.yml jobs with a concurrency group: {grouped}"
    publish = document["jobs"]["publish"].get("concurrency")
    assert publish is None or (isinstance(publish, dict) and publish.get("cancel-in-progress") is False), publish


# Shared nightly.yml job groups that may replace a pending job. None builds or signs: each is a
# promotion request (builds nothing; the newest request wins) or a feed writer whose replaced
# pending job is an older run's publish, which its order check would refuse after the newer one.
SHARED_NIGHTLY_GROUPS = {
    "promote-nightly-next": "nightly-next-promote",
    "await-release-surface-ack": "nightly-next-promote-ack",
    "publish-nightly": "release-publish-",
    "republish-nightly-deltas": "release-",
    "publish-release-notes": "release-publish-",
    "publish-nightly-identity-legacy": "nightly-next-legacy-identity-publish",
    # The release's mutable names only; the uploads (publish-nightly-next-github) have no group.
    "publish-nightly-next-github-names": "nightly-next-github-names",
}


# A group scoped to its run with nothing conditional: a fixed prefix and github.run_id, so no branch of
# an expression can fall back to a shared name (the old warm slot named github.run_id only in its fallback).
RUN_SCOPED = re.compile(
    r"\$\{\{ format\('[\w.-]*\{0\}', github\.run_id\) \}\}|[\w.-]*\$\{\{ github\.run_id \}\}")


def test_a_conditional_group_is_not_run_scoped() -> None:
    old_warm_slot = ("${{ github.ref == 'refs/heads/nightly-next' && 'nightly-next-build-app-warm' || "
                     "format('nightly-build-app-{0}', github.run_id) }}")
    assert not RUN_SCOPED.fullmatch(old_warm_slot)
    assert not RUN_SCOPED.fullmatch("nightly-${{ github.run_id }}-${{ github.ref_name }}")
    assert RUN_SCOPED.fullmatch("${{ format('nightly-build-app-{0}', github.run_id) }}")
    assert RUN_SCOPED.fullmatch("nightly-next-legacy-identity-${{ github.run_id }}")


def test_nightly_builds_and_signers_never_share_an_evicting_group() -> None:
    """A newer nightly tip builds and signs alongside an older one, never replacing it (2026-10-26).

    GitHub keeps one pending job per concurrency group and cancels the older pending one. A shared
    build slot (nightly-next-build-app-warm) and signing slot (nightly-next-legacy-identity) did
    that to waiting nightlies, and a holder stuck on a dead runner label held every newer tip.
    """
    import yaml

    document = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))
    top = document["concurrency"]["group"]
    # The nightly-next branch is the expression's first operand, so no other branch can win first.
    assert re.match(r"nightly-build-\$\{\{[^}]*\}\}-\$\{\{ github\.ref == 'refs/heads/nightly-next' && "
                    r"format\('run-\{0\}', github\.run_id\) \|\|", top), top
    for name, job in document["jobs"].items():
        concurrency = job.get("concurrency")
        if concurrency is None:
            continue
        group = concurrency if isinstance(concurrency, str) else str(concurrency.get("group", ""))
        if isinstance(concurrency, dict):
            assert concurrency.get("cancel-in-progress") is not True, name
        if RUN_SCOPED.fullmatch(group):
            continue
        allowed = SHARED_NIGHTLY_GROUPS.get(name)
        assert allowed and group.startswith(allowed), (
            f"nightly.yml {name} shares concurrency group {group!r}: a newer run would replace its pending "
            "job; scope it to github.run_id, or add it to SHARED_NIGHTLY_GROUPS if it builds nothing")


# Jobs that publish a build. GitHub keeps one pending job per group and replaces it with the next
# one queued, so a publish shares its group with no other kind of job: a queued delta or notes job
# would cancel a waiting publish (2026-10-27 nightly path audit). Publishes stay serialized against
# each other in their own group.
PUBLISH_JOBS = {"publish-nightly"}
# Writers that still need the publish lock because their writes have no compare-and-swap. Each entry
# is a known eviction risk to remove once its writes are made safe without the lock.
KEEPS_PUBLISH_LOCK = {
    "publish-release-notes": "notes/index.json and the other notes objects are written unconditionally",
}


def test_a_publish_never_shares_a_group_with_a_non_publish_job() -> None:
    import yaml

    jobs = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))["jobs"]

    def group_of(job: dict) -> str:
        concurrency = job.get("concurrency")
        if concurrency is None:
            return ""
        return concurrency if isinstance(concurrency, str) else str(concurrency.get("group", ""))

    def family(group: str) -> str:
        return group.split("${{", 1)[0]

    for name in PUBLISH_JOBS:
        assert name in jobs, f"nightly.yml has no {name} job: update PUBLISH_JOBS"
        assert group_of(jobs[name]), f"{name} must keep its publication group"
        assert jobs[name]["concurrency"]["cancel-in-progress"] is False, name
    publish_families = {family(group_of(jobs[name])) for name in PUBLISH_JOBS}
    # The nightly-next delta republish leaves the publish group (its feed write is a compare-and-swap);
    # the classic and RC tracks keep the publish lock, since they replace feeds without one.
    deltas = group_of(jobs["republish-nightly-deltas"])
    assert deltas == ("release-${{ needs.decide.outputs.track == 'nightly-next' && 'deltas' || 'publish' }}-"
                      "${{ needs.decide.outputs.release_tag }}"), deltas
    for name, job in jobs.items():
        if name in PUBLISH_JOBS or name in KEEPS_PUBLISH_LOCK or name == "republish-nightly-deltas" or not group_of(job):
            continue
        assert family(group_of(job)) not in publish_families, (
            f"nightly.yml {name} shares a publish job's concurrency group {group_of(job)!r}: "
            "a newly queued job would cancel a waiting publish")


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
    cmux_next = (WORKFLOWS / "cmux-next.yml").read_text(encoding="utf-8")
    assert "group: ${{ format('cmux-next-release-compile-{0}', github.run_id) }}" in cmux_next
    assert "needs.push-head-preflight.outputs.current == 'true'" in cmux_next


if __name__ == "__main__":
    test_delivery_workflows_never_cancel_in_progress_work()
    test_a_conditional_group_is_not_run_scoped()
    test_nightly_builds_and_signers_never_share_an_evicting_group()
    test_a_publish_never_shares_a_group_with_a_non_publish_job()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()
    print("PASS: nightly and DEV delivery never cancel or replace waiting builds")

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


# Shared nightly.yml job groups that may replace a pending job. None builds or signs, and none is a
# nightly-next feed writer: a replaced pending writer is a dropped publish (run 41436891188's publish,
# which carried a fix, was cancelled for a newer run's), so those take an R2 lease instead
# (NEXT_FEED_WRITERS below). publish-nightly keeps release-publish- only on the classic and RC tracks.
SHARED_NIGHTLY_GROUPS = {
    "promote-nightly-next": "nightly-next-promote",
    "await-release-surface-ack": "nightly-next-promote-ack",
    "publish-nightly": "release-publish-",
    "republish-nightly-deltas": "release-",
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
    # The nightly-next branch is the expression's first operand, so no other branch can win first. A
    # nightly-next push shares one group, so a waiting push run is replaced by a newer one and only the
    # newest head builds and signs (Leo, 2026-11-05: "why do multiple merges even build the f***ing
    # nightlies anyway?"); every other nightly-next run stays run-scoped.
    assert re.match(r"nightly-build-\$\{\{[^}]*\}\}-\$\{\{ github\.ref == 'refs/heads/nightly-next' && "
                    r"\(github\.event_name == 'push' && 'push' \|\| format\('run-\{0\}', github\.run_id\)\) \|\|",
                    top), top
    assert document["concurrency"]["cancel-in-progress"] is False
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
# Writers that still need the publish lock because their writes have no compare-and-swap. The lock
# is publish-nightly's R2 lease now, not its group (test_next_feed_writers_take_the_r2_lease), so no
# entry here shares a group with a publish.
KEEPS_PUBLISH_LOCK: dict[str, str] = {}


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


# The nightly-next feed writers and the R2 lease key each takes (scripts/ci/nightly-steps/publish-lease.sh).
# publish-release-notes shares publish-nightly's key: only that lock orders the notes writes.
NEXT_FEED_WRITERS = {
    "publish-nightly": ("nightly-next/locks/publish-nightly-next.json", "Recheck the recovered build against both feeds"),
    "publish-release-notes": ("nightly-next/locks/publish-nightly-next.json", "Recheck the NEXT publication head"),
}
# Steps that read a feed to decide, or write the release, R2 or a feed: each runs inside the lease.
FEED_STEP_WORDS = ("feed", "Publish", "Upload", "Recheck", "Prune", "Move channel", "Record")


def _nightly_jobs() -> dict:
    import yaml

    return yaml.safe_load((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))["jobs"]


def test_next_feed_writers_share_no_group_on_nightly_next() -> None:
    """GitHub keeps one pending job per group and cancels the older one, so on nightly-next no
    feed writer's group can name anything shared: each is absent or scoped to its own run."""
    jobs = _nightly_jobs()
    for name in NEXT_FEED_WRITERS:
        concurrency = jobs[name].get("concurrency")
        if concurrency is None:
            # Only nightly-next jobs may drop the group: classic and RC keep theirs.
            assert "needs.decide.outputs.track == 'nightly-next'" in str(jobs[name]["if"]), name
            continue
        assert concurrency.get("cancel-in-progress") is False, name
        group = concurrency["group"]
        on_next = group.replace("needs.decide.outputs.track == 'nightly-next' && format('-run-{0}', github.run_id) || ''",
                                "RUN")
        assert on_next != group and on_next.endswith("${{ RUN }}"), (
            f"{name} group {group!r} is not scoped to its run on nightly-next")
    # Classic and RC keep their shared release-publish group (the expression is empty off nightly-next).
    assert jobs["publish-nightly"]["concurrency"]["group"].startswith("release-publish-${{ needs.decide.outputs.release_tag }}")


def test_next_feed_writers_take_the_r2_lease() -> None:
    jobs = _nightly_jobs()
    for name, (key, first_read) in NEXT_FEED_WRITERS.items():
        steps = jobs[name]["steps"]
        names = [str(step.get("name", "")) for step in steps]
        lock = next(i for i, step in enumerate(steps) if "publish-lease.sh lock" in str(step.get("run", "")))
        unlock = next(i for i, step in enumerate(steps) if "publish-lease.sh unlock" in str(step.get("run", "")))
        assert steps[lock]["env"]["LEASE_KEY"] == key, name
        assert steps[lock]["env"]["LEASE_OWNER"] == "${{ github.run_id }}-${{ github.run_attempt }}", name
        assert steps[lock]["env"]["AWS_ACCESS_KEY_ID"] == "${{ secrets.NIGHTLY_NEXT_R2_ACCESS_KEY_ID }}", name
        assert steps[lock].get("id") == "lease", name
        assert lock < names.index(first_read), f"{name} reads the feed before it holds the lease"
        for i, step_name in enumerate(names[:lock]):
            uses = str(steps[i].get("uses", ""))
            assert not any(word in step_name for word in FEED_STEP_WORDS) or "checkout" in uses or "token" in step_name, (
                f"{name}: {step_name!r} runs before the lease")
        # The release is the job's last step and runs whatever happened once the lock step ran:
        # a lease PUT can land while its response is lost, and unlock checks the owner. On an owned
        # Mac only the always() wipe of the job's credentials and files follows it
        # (tests/test_nightly_owned_minis_only.py), since unlock runs from the files it removes.
        last = steps[-1]
        wipe_last = last.get("id") == "wipe-credentials" and str(last.get("if", "")) == "always()"
        assert unlock == len(steps) - (2 if wipe_last else 1), name
        assert steps[unlock]["if"] == "always() && steps.lease.outcome != 'skipped'", name
        assert steps[unlock]["env"] == steps[lock]["env"], name
        # A short TTL kept alive by a heartbeat: a dead holder blocks the feed at most one TTL,
        # inside the 30-minute freshness bound, while a live one renews several times per TTL.
        env = steps[lock]["env"]
        ttl, wait = int(env["LEASE_TTL"]), int(env["LEASE_WAIT"])
        renew, max_hold = int(env["LEASE_RENEW"]), int(env["LEASE_MAX_HOLD"])
        # With one-mini mode off: the smaller limit, the one the lease must match (one-mini mode adds
        # room for glaeda's capacity wait before the job starts, tests/test_nightly_mini_gate_timeouts.py).
        timeout = min(int(n) for n in re.findall(r"\b\d+\b", str(jobs[name]["timeout-minutes"]))) * 60
        assert ttl <= 15 * 60, f"{name}: a dead holder's lease ({ttl}s) blocks the feed past 15 minutes"
        assert renew * 10 <= ttl, f"{name}: renewing every {renew}s leaves under ten tries per {ttl}s TTL"
        assert max_hold <= 3 * 60 * 60 and max_hold >= timeout - wait, (
            f"{name}: the heartbeat's max hold ({max_hold}s) does not match the job's timeout ({timeout}s)")
        assert timeout - wait >= 70 * 60, f"{name}: after the wait the job has under 70 minutes for its work"
    # Sharers of one key pass one TTL.
    by_key: dict[str, set[int]] = {}
    for name, (key, _) in NEXT_FEED_WRITERS.items():
        step = next(s for s in jobs[name]["steps"] if "publish-lease.sh lock" in str(s.get("run", "")))
        by_key.setdefault(key, set()).add(int(step["env"]["LEASE_TTL"]))
    assert all(len(ttls) == 1 for ttls in by_key.values()), by_key
    # publish-nightly takes it only on nightly-next; classic and RC keep their group.
    lock = next(s for s in jobs["publish-nightly"]["steps"] if "publish-lease.sh lock" in str(s.get("run", "")))
    assert lock["if"] == "needs.decide.outputs.track == 'nightly-next'", lock.get("if")
    # The notes job's sparse tooling checkout carries the lease's scripts.
    notes_checkout = next(s for s in jobs["publish-release-notes"]["steps"] if s.get("with", {}).get("path") == ".publish-tooling")
    for path in ("scripts/ci/nightly-steps/publish-lease.sh", "scripts/ci/r2_cas.py", "scripts/ci/upload-r2-object.py",
                 "scripts/ci/nightly-next-guard.py"):
        assert path in notes_checkout["with"]["sparse-checkout"], path


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
    test_next_feed_writers_share_no_group_on_nightly_next()
    test_next_feed_writers_take_the_r2_lease()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()
    print("PASS: nightly and DEV delivery never cancel or replace waiting builds")

"""Nightly and Dev delivery must never cancel started work."""

from pathlib import Path
import re
<<<<<<< HEAD
=======
import subprocess
import sys

import yaml
>>>>>>> origin/main


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

<<<<<<< HEAD

def delivery_workflows() -> list[Path]:
    paths = sorted(WORKFLOWS.glob("nightly*.yml"))
    paths += sorted(WORKFLOWS.glob("cmux-next-dev-daily*.yml"))
    return sorted(set(paths))
=======
# The delivery workflows (nightly, dev and promote builds): none may cancel a
# run in progress. scripts/ci/delivery_workflows.py declares them once; the
# queue janitor reads the same list to never cancel one of their runs.
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
from delivery_workflows import (  # noqa: E402
    DELIVERY_GLOBS, DELIVERY_RUN_NAME_PREFIXES, REQUIRED_DELIVERY_WORKFLOWS, is_delivery_run, is_delivery_workflow)
from delivery_concurrency import can_be_shared, findings, matching, stale_allowances  # noqa: E402

# Shared groups in delivery workflows that may replace a waiting run, and why. Each is a run that
# builds and publishes nothing itself, or whose waiting runs are interchangeable (it reads the tip or
# the feed when it starts), or whose replaced request the job itself recovers. Anything else is keyed
# per run, SHA or build (scripts/ci/delivery_concurrency.py; the same check runs in
# manaflow-ai/cmuxterm-hq and teamleaderleo/glaeda).
ALLOWED_SHARED: dict[tuple[str, str], str] = {
    ("cmux-next-dev-daily-dispatch.yml", ""): (
        "the dispatcher snapshots the branch tip when it starts and builds nothing itself; the run that "
        "waits does the work of any it replaced"),
    ("nightly-next-canary.yml", ""): (
        "the scheduled 'feed' tick canaries the feed's newest build when it starts; a dispatch for one "
        "build and a pull request run have their own groups"),
    ("nightly-next-feed-watch.yml", ""): "a schedule-only watch that reads the feed when it starts",
    ("nightly-next-launch-smoke.yml", ""): (
        "a schedule or dispatch run has a group of its own run id; only a pull request's runs share one, "
        "per pull request, and such a run delivers nothing (it never rolls back or files)"),
    ("nightly-next-tick.yml", "unstick"): (
        "the stuck-run rescue and cancelled-tip re-run read every run's state when they start, so the "
        "newest waiting one does the work of any it replaced; a sha request skips the job"),
    ("nightly-next-tick.yml", "request"): (
        "the tick dispatches no build itself (test_delivery_coalescers_have_fixed_backstops...); a sha "
        "request has its own group"),
    ("nightly-next-train.yml", "drive"): (
        "only plain drives share it: each plans from the durable verdict to the branch tip when it starts; "
        "a fix-forward or a given tip has a group per run"),
    ("nightly.yml", ""): (
        "every push run, 15-minute main tick and promotion request is keyed by its run id (decide caps main "
        "app builds in flight); the shared lanes are the scheduled "
        "cache seed and manual fast/full dispatches, which build the branch tip when they start "
        "(test_nightly_push_runs_never_share_a_build_group)"),
    ("nightly.yml", "decide"): (
        "only main's app ticks (15-minute and 08:05 backstop) share it, so they decide one at a time and "
        "each sees the build the previous one started (the 3-in-flight cap); each decides main HEAD when "
        "it starts, so the newest waiting tick does the work of one it replaced; nothing running is "
        "cancelled, and every other run's decide is keyed by its run id"),
    ("nightly.yml", "promote-nightly-next"): (
        "a promotion request builds nothing; decideNewest() also decides the newest request GitHub "
        "evicted from this queue"),
    ("nightly.yml", "await-release-surface-ack"): "retired (if: false); it never runs",
    ("nightly.yml", "publish-nightly"): (
        "KNOWN GAP, follow-up: runs only for branch builds that are not main or rc (should_publish != "
        "'true'); published channels go through auto-resume-nightly-notarization.yml under one R2 lease. "
        "Moving this job under that lease changes nightly.yml, which is sequenced separately"),
}

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
    # supersede cancels older publish runs itself, keeping the oldest waiting one, so it must not take a
    # group either: one would replace its own pending run and could cancel this run's.
    "cmux-next-dev-daily.yml": ("sign", "runner", "verify", "publish", "tip-dmg-build", "rcodesign",
                                "tip-dmg", "tip", "tip-deltas", "supersede"),
    # Classic main and rc push runs build in parallel (#25959), so their
    # continuations publish in any order. Sharing release-publish-<tag> let an
    # older run's delta job replace a newer publish that was still pending.
    # One R2 lease serializes the two writers instead.
    "auto-resume-nightly-notarization.yml": ("publish", "republish-deltas"),
}


def delivery_workflows() -> list[Path]:
    return matching(WORKFLOWS, DELIVERY_GLOBS)


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
>>>>>>> origin/main


def test_delivery_workflows_never_cancel_in_progress_work() -> None:
    for path in delivery_workflows():
        text = path.read_text(encoding="utf-8")
        assert not re.search(r"(?m)^\s*cancel-in-progress:\s*true\s*$", text), path


<<<<<<< HEAD
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
}


# The nightly-next push slot with the one job on (docs/ci/nightly-workflow-notes.md#note-19): the
# workflow-level push group moved to the one job, with the same rule. A newer loop run replaces only a pending
# one, and main's tick promotes nothing while one is pending (run_holds_group), so none is ever replaced; other
# runs' nightly-next-one stays run-scoped. tests/test_nightly_next_push_slot_at_build.py evaluates it.
PUSH_SLOT_JOBS = {
    # One slot per signer Mac (docs/ci/nightly-workflow-notes.md#note-33).
    "nightly-next-one": "${{ github.ref == 'refs/heads/nightly-next' && (github.event_name == 'push' || "
                        "inputs.nightly_next_loop_retry != '') && (vars.NIGHTLY_NEXT_SLOTS == '2' && vars.CI_NIGHTLY_MINI == '' && format('nightly-next-one-push-{0}', "
                        "needs.pick-nightly-next-signer.outputs.attempt == github.run_attempt && "
                        "needs.pick-nightly-next-signer.outputs.host || 'cmux15') || 'nightly-next-one-push') || "
                        "format('nightly-next-one-{0}', github.run_id) }}",
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
    # nightlies anyway?"); the loop's own retry (nightly_next_loop_retry) joins it, and every other
    # nightly-next run stays run-scoped, among them the tail a loop run dispatches after its GitHub release
    # (nightly_next_post_publish), so nothing replaces that tail and it never holds the push group.
    assert re.match(r"nightly-build-\$\{\{[^}]*\}\}-\$\{\{ github\.ref == 'refs/heads/nightly-next' && "
                    r"\(\(github\.event_name == 'push' \|\| github\.event_name == 'workflow_dispatch' && "
                    r"inputs\.nightly_next_loop_retry != ''\) && \(vars\.NIGHTLY_NEXT_ONE_JOB != 'on' [^)]*\) && 'push' \|\| "
                    r"format\('run-\{0\}', github\.run_id\)\) \|\|",
                    top), top
    assert "nightly_next_post_publish" not in top, top
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
        if name in PUSH_SLOT_JOBS and group == PUSH_SLOT_JOBS[name]:
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
    # It reads the track from published-build: it also runs in the dispatched post-publish run, where decide skips.
    assert deltas == ("release-${{ needs.published-build.outputs.track == 'nightly-next' && 'deltas' || 'publish' }}-"
                      "${{ needs.published-build.outputs.release_tag }}"), deltas
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
            assert re.search(r"needs\.(?:decide|published-build)\.outputs\.track == 'nightly-next'", str(jobs[name]["if"])), name
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
    # nightly-next-one shares the step; there it also skips once the run left the push slot (LEFT_SLOT).
    assert lock["if"] in ("needs.decide.outputs.track == 'nightly-next'",
                          "needs.decide.outputs.track == 'nightly-next' && !env.LEFT_SLOT"), lock.get("if")
    # The notes job's sparse tooling checkout carries the lease's scripts.
    notes_checkout = next(s for s in jobs["publish-release-notes"]["steps"] if s.get("with", {}).get("path") == ".publish-tooling")
    for path in ("scripts/ci/nightly-steps/publish-lease.sh", "scripts/ci/r2_cas.py", "scripts/ci/upload-r2-object.py",
                 "scripts/ci/nightly-next-guard.py"):
        assert path in notes_checkout["with"]["sparse-checkout"], path
=======
def test_delivery_groups_are_keyed_per_run_or_payload() -> None:
    # A fixed group drops queued delivery runs: GitHub keeps one pending run per group.
    workflows = delivery_workflows()
    problems = [problem for path in workflows for problem in findings(path, ALLOWED_SHARED)]
    problems += stale_allowances(workflows, ALLOWED_SHARED)
    assert not problems, "\n".join(problems)


def test_the_shared_group_check_tells_keyed_groups_from_fixed_ones() -> None:
    assert can_be_shared("nightly-next-linux")
    assert can_be_shared("x-${{ inputs.channel }}-${{ inputs.variant }}")
    assert can_be_shared("${{ inputs.sha != '' && format('t-{0}', github.run_id) || 't' }}")
    assert can_be_shared("c-${{ github.event.pull_request.number || 'feed' }}")
    assert can_be_shared("d-${{ matrix.os }}")
    assert can_be_shared("${{ format('nightly-{0}', inputs.build || 'feed') }}")
    assert can_be_shared("${{ github.event_name == 'pull_request' && github.sha }}")
    assert not can_be_shared("${{ github.event_name == 'push' && github.sha || github.run_id }}")
    # Results, not references: a comparison, a literal and an unused format argument are constants.
    assert can_be_shared("d-${{ github.sha != '' }}")
    assert can_be_shared("d-${{ 'github.run_id' }}")
    assert can_be_shared("${{ format('nightly-{0}', inputs.channel, github.run_id) }}")
    assert can_be_shared("${{ format('feed', github.sha) }}")
    assert not can_be_shared("${{ (github.event_name == 'push' && github.sha) || github.run_id }}")
    assert not can_be_shared("${{ true && github.sha }}")
    # An optional input may be empty; a required one is set.
    assert can_be_shared("r-${{ inputs.source_run_id }}")
    assert not can_be_shared("r-${{ inputs.source_run_id }}", frozenset({"source_run_id"}))
    # Per trigger: an input is empty on a schedule; workflow_run's id only exists for workflow_run.
    both = frozenset({"schedule", "workflow_dispatch"})
    assert can_be_shared("release-${{ inputs.build }}", frozenset({"build"}), both)
    assert not can_be_shared("release-${{ inputs.build }}", frozenset({"build"}), frozenset({"workflow_dispatch"}))
    assert not can_be_shared("s-${{ github.event.workflow_run.id || inputs.source_run_id }}",
                             frozenset({"source_run_id"}), frozenset({"workflow_run", "workflow_dispatch"}))
    assert not can_be_shared("x-${{ github.event_name == 'push' && github.sha || github.run_id }}",
                             frozenset(), frozenset({"push", "schedule"}))
    # An empty format() result falls through; a boolean control is not an identity.
    assert can_be_shared("${{ format('{0}', inputs.build) && github.run_id || 'feed' }}")
    assert can_be_shared("release-${{ inputs.dry_run }}", frozenset({"dry_run"}), frozenset({"workflow_dispatch"}))
    assert can_be_shared("c-${{ github.event.pull_request.number }}")
    assert not can_be_shared("x-${{ github.run_id }}")
    assert not can_be_shared("x-${{ github.sha }}")
    assert not can_be_shared("s-${{ github.event.workflow_run.id || inputs.source_run_id }}")
    assert not can_be_shared("v-${{ needs.decide.outputs.build }}")
    assert not can_be_shared("p-${{ (github.ref_name == 'main') && 'a' || 'b' }}-${{ format('p-{0}', github.run_id) }}")
    assert can_be_shared("p-${{ github.event_name == 'push' && format('p-{0}', github.run_id) || 'full' }}")


def test_the_check_reads_every_concurrency_form_in_a_workflow(tmp_path: Path | None = None) -> None:
    import tempfile

    sample = """on: push
concurrency: one-group
jobs:
  a:
    runs-on: x
    concurrency:
      group: job-${{ github.run_id }}
      cancel-in-progress: true
  b:
    runs-on: x
    strategy:
      matrix:
        concurrency: [1, 2]
    concurrency:
      group: fixed
      cancel-in-progress: false
"""
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "nightly-sample.yml"
        path.write_text(sample, encoding="utf-8")
        found = findings(path, {})
    assert any("top-level: group 'one-group'" in p for p in found), found
    assert any("job a: cancel-in-progress is 'true'" in p for p in found), found
    assert any("job b: group 'fixed'" in p for p in found), found
    assert not any("job a: group" in p for p in found), found
    assert len(found) == 3, found
    deep = "jobs:\n    a:\n        runs-on: x\n        concurrency:\n            group: fixed\n"
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "nightly-deep.yaml"
        path.write_text(deep, encoding="utf-8")
        assert matching(Path(folder), ("nightly*.yml",)) == [path]
        assert any("job a: group 'fixed'" in p for p in findings(path, {}))
        commented = Path(folder) / "nightly-commented.yml"
        commented.write_text("jobs:\n  publish: # upload\n    runs-on: x\n    concurrency:\n      group: fixed\n",
                             encoding="utf-8")
        assert any("job publish: group 'fixed'" in p for p in findings(commented, {}))
        quoted = Path(folder) / "nightly-quoted.yml"
        quoted.write_text("on:\n  workflow_dispatch:\n    inputs:\n      build:\n        required: true\n"
                          "jobs:\n  'publish':\n    runs-on: x\n    concurrency:\n      group: fixed\n"
                          "  keyed:\n    runs-on: x\n    concurrency:\n      group: k-${{ inputs.build }}\n",
                          encoding="utf-8")
        found = findings(quoted, {})
        assert any("job publish: group 'fixed'" in p for p in found) and len(found) == 1, found


def test_the_check_reads_triggers_and_inputs_per_event() -> None:
    import tempfile

    def check(text: str) -> list[str]:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "nightly-sample.yml"
            path.write_text(text, encoding="utf-8")
            return findings(path, {})

    job = "jobs:\n  a:\n    runs-on: x\n    concurrency:\n      group: {group}\n"
    # Required for workflow_call, optional for workflow_dispatch: a dispatch can leave it empty.
    mixed = ("on:\n  workflow_call:\n    inputs:\n      build:\n        required: true\n"
             "  workflow_dispatch:\n    inputs:\n      build:\n        required: false\n")
    assert check(mixed + job.format(group="release-${{ inputs.build }}"))
    assert not check(mixed.replace("required: false", "required: true") + job.format(group="release-${{ inputs.build }}"))
    # A boolean input is a control, not an identity, whatever its name.
    boolean = "on:\n  workflow_dispatch:\n    inputs:\n      force_build:\n        type: boolean\n"
    assert check(boolean + job.format(group="release-${{ inputs.force_build || github.run_id }}"))
    # An indentless trigger list is read; workflow_run's id is empty on push.
    assert check("on:\n- push\n- workflow_dispatch\n" + job.format(group="r-${{ github.event.workflow_run.id }}"))
    # Unread triggers (a flow map) are an unknown event: an event_name guard can go either way.
    assert check("on: {schedule: [{cron: '1 * * * *'}], workflow_dispatch: {}}\n"
                 + job.format(group="${{ github.event_name == 'schedule' && 'scheduled' || github.run_id }}"))
    assert check("on: {workflow_run: {workflows: [x]}, push: {}}\n"
                 + job.format(group="${{ github.event.workflow_run.id && 'fixed' || github.run_id }}"))
    # The usual PR-or-push SHA is keyed on both events.
    assert not check("on:\n  pull_request:\n  push:\n"
                     + job.format(group="c-${{ github.event.pull_request.head.sha || github.sha }}"))


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
>>>>>>> origin/main


def test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups() -> None:
    tick = (WORKFLOWS / "nightly-next-tick.yml").read_text(encoding="utf-8")
<<<<<<< HEAD
    assert re.search(r'(?m)^\s+- cron: "7,37 \* \* \* \*"$', tick)
=======
    assert re.search(r'(?m)^\s+- cron: "4-59/5 \* \* \* \*"$', tick)
>>>>>>> origin/main
    assert "cancel-in-progress: false" in tick
    # One shared job-level group: one tick runs, the newest waits. The tick
    # dispatches no build itself, so replacing a pending tick cancels no work.
    # No polling coalescer: it spent the GITHUB_TOKEN quota (2026-10-25).
    assert "|| 'nightly-next-tick' }}" in tick
    assert "listWorkflowRuns" not in tick and "needs: coalesce" not in tick
    dev = (WORKFLOWS / "cmux-next-dev-daily-dispatch.yml").read_text(encoding="utf-8")
    assert 'cron: "2-59/5 * * * *"' in dev or 'cron: "7,22,37,52 * * * *"' in dev
    assert "cancel-in-progress: false" in dev
<<<<<<< HEAD
    cmux_next = (WORKFLOWS / "cmux-next.yml").read_text(encoding="utf-8")
    assert "format('cmux-next-release-compile-{0}', github.run_id) }}" in cmux_next
    assert "needs.push-head-preflight.outputs.current == 'true'" in cmux_next


# A job that tolerates a need (continue-on-error) can still end `cancelled` when it hits its
# timeout-minutes. A job whose `if` names no status function gets an implicit success(), which asks
# that every ancestor (not only its own needs) succeeded, so GitHub skips it and the started run loses
# its build with no cancel-in-progress anywhere. On 2026-11-12 pick-nightly-build-runner timed out at
# 13 minutes while a signing job held its mini, and build-nightly-app was skipped in nightly-next runs
# 43129045111 and 43138638076. Same class: cmuxterm-hq docs/handbook/skipped-by-a-job-it-does-not-need.md.
STATUS_FUNCTION = re.compile(r"\b(always|cancelled|failure|success)\(\)")


def jobs_a_tolerated_ancestor_skips(jobs: dict) -> list[str]:
    def needs(name: str) -> list[str]:
        value = jobs[name].get("needs") or []
        return [value] if isinstance(value, str) else list(value)

    ancestors: dict[str, set[str]] = {}

    def of(name: str) -> set[str]:
        if name not in ancestors:
            ancestors[name] = set()
            for need in needs(name):
                ancestors[name] |= {need} | of(need)
        return ancestors[name]

    tolerated = {name for name, job in jobs.items() if job.get("continue-on-error") is True}
    return [f"{name} (ancestor {sorted(of(name) & tolerated)})" for name, job in jobs.items()
            if of(name) & tolerated and not STATUS_FUNCTION.search(str(job.get("if", "")))]


def test_the_tolerated_ancestor_check_catches_the_2026_11_12_shape() -> None:
    jobs = {
        "pick": {"continue-on-error": True},
        "build": {"needs": ["pick"], "if": "needs.decide.outputs.should_build == 'true'"},
        "prepare": {"needs": "build", "if": "inputs.x == ''"},
        "safe": {"needs": ["build"], "if": "${{ !cancelled() && needs.build.result == 'success' }}"},
    }
    assert sorted(jobs_a_tolerated_ancestor_skips(jobs)) == ["build (ancestor ['pick'])", "prepare (ancestor ['pick'])"]


def test_a_tolerated_need_never_skips_its_dependents() -> None:
    import yaml

    found = []
    for path in delivery_workflows():
        jobs = (yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("jobs") or {}
        found += [f"{path.name}: {entry}" for entry in jobs_a_tolerated_ancestor_skips(jobs)]
    assert not found, ("a timed-out continue-on-error ancestor skips these jobs; give their `if` "
                       f"!cancelled() and the needs' results: {found}")

if __name__ == "__main__":
    test_delivery_workflows_never_cancel_in_progress_work()
    test_a_conditional_group_is_not_run_scoped()
    test_nightly_builds_and_signers_never_share_an_evicting_group()
    test_a_publish_never_shares_a_group_with_a_non_publish_job()
    test_next_feed_writers_share_no_group_on_nightly_next()
    test_next_feed_writers_take_the_r2_lease()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()
    test_the_tolerated_ancestor_check_catches_the_2026_11_12_shape()
    test_a_tolerated_need_never_skips_its_dependents()
=======


def test_the_tick_is_the_only_promoter_and_the_rolling_rule_gates_its_events() -> None:
    """A burst of landings starts one build: the tick runs at landing, but promotes only under the rolling rule.

    On 2026-10-28 every finished cmux-next or cmux-tui artifacts run on feat-cmux-next promoted, through
    this tick's workflow_run trigger and their own request jobs, and six Release builds ran at once. A
    30-minute cron alone then kept the feed 45-50 minutes behind each landing. Now the landing events and
    the backstop cron run scripts/ci/nightly_next_rolling.py first, and its "wait" skips the request; only
    a dispatch for one commit skips the rule."""
    tick = yaml.safe_load((WORKFLOWS / "nightly-next-tick.yml").read_text(encoding="utf-8"))
    triggers = tick.get("on", tick.get(True))
    assert set(triggers) == {"workflow_run", "schedule", "workflow_dispatch"}
    assert triggers["schedule"] == [{"cron": "4-59/5 * * * *"}]
    assert triggers["workflow_run"]["types"] == ["completed"]
    assert set(triggers["workflow_run"]["workflows"]) == {"cmux-next", "cmux-tui artifacts", "Nightly macOS build"}
    job = tick["jobs"]["request"]
    assert "github.event.workflow_run.event == 'push'" in job["if"]
    assert "head_repository.full_name == github.repository" in job["if"]
    steps = [step.get("name") for step in job["steps"]]
    by_name = {step.get("name"): step for step in job["steps"]}
    rolling = by_name["Apply the rolling rule"]
    request = by_name["Request nightly-next promotion on main"]
    assert steps.index("Apply the rolling rule") < steps.index("Request nightly-next promotion on main")
    assert "inputs.sha == ''" in rolling["if"], "a dispatch for one commit skips the rule"
    assert rolling.get("continue-on-error") is True, "a failed rule never holds the promotion"
    assert "nightly_next_rolling.py" in rolling["run"]
    # One build per signer Mac (design manaflow-ai/cmuxterm-hq#17011): the cap is a variable, 1 when unset.
    assert rolling["env"]["NIGHTLY_NEXT_SLOTS"] == "${{ vars.NIGHTLY_NEXT_SLOTS || '1' }}"
    assert '--slots "$NIGHTLY_NEXT_SLOTS"' in rolling["run"]
    assert "steps.rolling.outputs.go != 'false'" in request["if"]
    assert request["env"]["NIGHTLY_NEXT_PROMOTE"] == "1", "request-nightly-next.sh promotes only when the tick asks"
    for name, step in by_name.items():
        if step is not request:
            assert "NIGHTLY_NEXT_PROMOTE" not in (step.get("env") or {}), name


def test_the_tick_marks_every_revisions_promotion_request(tmp_path: Path) -> None:
    """Main's promote job admits only "tick:" requests from github-actions[bot] (promote-nightly-next.mjs
    decideRequest); the tick's gh shim adds the prefix to whatever form each revision's script dispatches."""
    tick = yaml.safe_load((WORKFLOWS / "nightly-next-tick.yml").read_text(encoding="utf-8"))
    run = next(s for s in tick["jobs"]["request"]["steps"] if s.get("name") == "Request nightly-next promotion on main")["run"]
    shim = re.search(r"cat > \"\$GH_TICK_CACHE/bin/gh\" <<'SH'\n(.*?)\nSH\n", run, re.S).group(1)
    (tmp_path / "gh").write_text(shim, encoding="utf-8")
    real = tmp_path / "real-gh"
    real.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$LOG"\n', encoding="utf-8")
    real.chmod(0o755)
    env = {"PATH": "/usr/bin:/bin", "GH_REAL": str(real), "GH_TICK_CACHE": str(tmp_path), "LOG": str(tmp_path / "log")}
    sha = "a" * 40
    head = ["workflow", "run", "nightly.yml", "--repo", "o/r", "--ref", "main"]
    forms = [  # (as a revision passes it, as main must receive it)
        (["-f", f"promote_nightly_next_sha={sha}"], ["-f", f"promote_nightly_next_sha=tick:{sha}"]),
        (["-f", f"promote_nightly_next_sha=tick:{sha}"], ["-f", f"promote_nightly_next_sha=tick:{sha}"]),
        (["--raw-field", f"promote_nightly_next_sha={sha}"], ["--raw-field", f"promote_nightly_next_sha=tick:{sha}"]),
        ([f"-fpromote_nightly_next_sha={sha}"], [f"-fpromote_nightly_next_sha=tick:{sha}"]),
        ([f"-Fpromote_nightly_next_sha={sha}"], [f"-Fpromote_nightly_next_sha=tick:{sha}"]),
        ([f"--field=promote_nightly_next_sha={sha}"], [f"--field=promote_nightly_next_sha=tick:{sha}"]),
    ]
    for sent, _ in forms:
        subprocess.run(["bash", str(tmp_path / "gh"), *head, *sent], env=env, check=True)
    other = ["workflow", "run", "cmux-tui-artifacts.yml", "--repo", "o/r", "--ref", "feat-cmux-next"]
    subprocess.run(["bash", str(tmp_path / "gh"), *other], env=env, check=True)
    assert (tmp_path / "log").read_text(encoding="utf-8").splitlines() == [
        *(" ".join([*head, *got]) for _, got in forms), " ".join(other)]


def test_a_landing_request_never_enters_the_promote_queue() -> None:
    """GitHub keeps one waiting job in nightly-next-promote and cancels it when another request arrives, so a
    landing's request must be skipped at the job, not after it queued: there it would evict the tick's request."""
    job = load(WORKFLOWS / "nightly.yml")["jobs"]["promote-nightly-next"]
    assert job["concurrency"]["group"] == "nightly-next-promote"
    assert job["if"].endswith(
        "&& (contains(inputs.promote_nightly_next_sha, 'tick:') || github.triggering_actor != 'github-actions[bot]')"
    ), job["if"]


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
    test_delivery_groups_are_keyed_per_run_or_payload()
    test_the_shared_group_check_tells_keyed_groups_from_fixed_ones()
    test_the_check_reads_every_concurrency_form_in_a_workflow()
    test_the_check_reads_triggers_and_inputs_per_event()
    test_newest_wins_jobs_take_no_concurrency_group()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()
    test_nightly_push_runs_never_share_a_build_group()
    test_classic_publishers_write_only_while_they_hold_the_lease()
    test_the_tick_is_the_only_promoter_and_the_rolling_rule_gates_its_events()
    test_a_landing_request_never_enters_the_promote_queue()
    import tempfile
    with tempfile.TemporaryDirectory() as scratch:
        test_the_tick_marks_every_revisions_promotion_request(Path(scratch))
>>>>>>> origin/main
    print("PASS: nightly and DEV delivery never cancel or replace waiting builds")

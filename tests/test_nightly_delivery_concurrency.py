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
    ("nightly-next-tick.yml", "request"): (
        "the tick dispatches no build itself (test_delivery_coalescers_have_fixed_backstops...); a sha "
        "request has its own group"),
    ("nightly-next-train.yml", "drive"): (
        "only plain drives share it: each plans from the durable verdict to the branch tip when it starts; "
        "a fix-forward or a given tip has a group per run"),
    ("nightly.yml", ""): (
        "every push run and promotion request is keyed by its run id; the shared lanes are the scheduled "
        "cache seed and manual fast/full dispatches, which build the branch tip when they start "
        "(test_nightly_push_runs_never_share_a_build_group)"),
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
    "cmux-next-dev-daily.yml": ("sign", "runner", "verify", "publish", "tip-dmg-build", "rcodesign",
                                "tip-dmg", "tip", "tip-deltas"),
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


def test_delivery_workflows_never_cancel_in_progress_work() -> None:
    for path in delivery_workflows():
        text = path.read_text(encoding="utf-8")
        assert not re.search(r"(?m)^\s*cancel-in-progress:\s*true\s*$", text), path


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
    test_delivery_groups_are_keyed_per_run_or_payload()
    test_the_shared_group_check_tells_keyed_groups_from_fixed_ones()
    test_the_check_reads_every_concurrency_form_in_a_workflow()
    test_the_check_reads_triggers_and_inputs_per_event()
    test_newest_wins_jobs_take_no_concurrency_group()
    test_delivery_coalescers_have_fixed_backstops_and_non_cancelling_groups()
    test_nightly_push_runs_never_share_a_build_group()
    test_classic_publishers_write_only_while_they_hold_the_lease()
    print("PASS: nightly and DEV delivery never cancel or replace waiting builds")

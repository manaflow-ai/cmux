#!/usr/bin/env python3
"""Every guard that reads a workflow must be run by a workflow.

A test under tests/ that opens a file from .github/workflows/ exists to hold
some CI invariant still. If nothing in .github/workflows/ ever executes that
test, the invariant is unenforced and the file is decoration: it keeps passing
locally while main drifts away from what it asserts, and it reports nothing
when the drift breaks a release.

That is not hypothetical here. tests/test_tui_publish_dispatch_budget.py
arrived with the dispatch-budget fix it was written to hold, was never named by
any workflow, and cmux-tui v0.13.0 failed to publish on that exact regression
anyway. tests/test_ci_universal_release_settings.sh kept asserting that
scripts/setup.sh builds GhosttyKit universal for however long it has been since
that build moved to scripts/ensure-ghosttykit.sh -- an assertion about a file
that had stopped doing the job, which nothing was in a position to notice.

So the rule is structural rather than a list of known guards: discover the
guards from what they read, discover the wiring from what the workflows run,
and require the second to cover the first.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"

# A guard is identified by what it reads, not by where it lives, so a test that
# is moved or renamed keeps its obligation. Both spellings occur in-tree: a
# literal "…/.github/workflows/x.yml" and a pathlib join of the segments.
READS_A_WORKFLOW = re.compile(r"\.github[/\"'\s,)]+.{0,4}workflows")

# Paths a workflow executes directly: `python3 tests/x.py`, `./tests/x.sh`,
# `bash tests/x.sh`. Matching the path alone (rather than the whole command)
# keeps this indifferent to which interpreter a step chooses.
INVOKED_PATH = re.compile(r"(?:\./)?(tests(?:_v2)?/[A-Za-z0-9_.-]+\.(?:py|sh))")

# Guards that are knowingly unwired. Each entry needs a reason and an exit:
# an allowlist that can be appended to without argument is the failure mode
# this test exists to prevent.
UNWIRED: set[str] = {
    # lane = "manual" in tests/test-execution.d/other.toml. Checks that every job of
    # each workflow in its GATED set carries the draft-head condition and that its trigger lists ready_for_review (the
    # draft tier, scripts/ci/head_tier.py); it reads the workflows as data. Run it by hand when a workflow is added to
    # or removed from GATED. Exit: as below.
    "tests/test_head_tier.py",
    # lane = "manual" in tests/test-execution.d/other.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). Proves cmux Files (dev) never reaches a shipped build; it needs macOS ditto and codesign, and reads
    # the workflows only as data. Run it by hand on a fleet Mac when the embed phase, FilesHost or the pin changes.
    # Exit: as below.
    "tests/test_files_host_dev_only.py",
    # lane = "manual" in tests/test-execution.d/other.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). Pins run_ci_guards.py --affected's per-diff guard step selection; it reads the workflows as data. Run
    # it by hand when scripts/ci/guard_step_inputs.py or run_ci_guards.py changes. Exit: as below.
    "tests/test_guard_step_inputs.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). The pre-push hook refuses a push that adds an unbounded job (prepush-gate.py JOB_BOUNDS_CHECK); it
    # reads the workflows as data. Run it by hand after changing scripts/ci/workflow_job_bounds.py or
    # .github/workflow-job-bounds.json.
    "tests/test_ci_workflow_job_bounds.py",
    # lane = "manual" in tests/test-execution.d/nightly.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). Checks the nightly health gate's verdicts; it reads nightly-next-health.yml only as data. Run it by
    # hand when nightly_next_health.py or that workflow changes. Exit: as below.
    "tests/test_nightly_next_health.py",
    # lane = "manual" in tests/test-execution.d/app.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It checks that the app FFI release's Linux control jobs take the nightly lane's reserved label first,
    # never the bulk route alone; it reads app-ffi-repin.yml and app-ffi-release.yml only as data. Run it by hand when
    # those workflows change. Exit: as below.
    "tests/test_app_ffi_release_linux_route.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It checks that a setup-bun step on a route that can reach an owned runner skips the Bun cache off the
    # Blacksmith layout; it reads every workflow's setup-bun steps only as data. Run it by hand when those workflows
    # change. Exit: as below.
    "tests/test_ci_setup_bun_cache_layout.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It checks that every pool job in rust-workspaces, cmux-next-guards and the cloud VM image bake/roll
    # removes a reused workspace left sparse or broken before checkout; it runs that step on fixture repos and reads the
    # workflows as data. Run it by hand when those workflows change. Exit: as below.
    "tests/test_ci_reused_sparse_checkout.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It checks that every reader of the Linux pools (fast gates' receipt and post, rescue, reconcile,
    # artifact runner sets) reads the ephemeral-only pools; it reads the workflows and runners.json only as data. Run it
    # by hand when those readers change. Exit: as below.
    "tests/test_ci_ephemeral_pool_readers.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). Policy tests of scripts/ci/shed_superseded_runs.py over fixture runs (#47662); it reads
    # ci-shed-superseded-runs.yml only as data. Run it by hand when the script or that workflow changes. Exit: as below.
    "tests/test_ci_shed_superseded_runs.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It checks that a feat-cmux-next push's Linux control jobs start on the JIT nightly label (#47764,
    # #47905); it reads the workflows as data. Run it by hand when those runs-on lines change. Exit: as below.
    "tests/test_cmux_next_push_roots_on_nightly_jit.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, lifted 2026-11-18). It runs
    # scripts/cmux-next/cargo-locks.py in a throwaway repository and reads rust-workspaces.yml only as data (that the
    # workflow calls the script). Run it by hand when the script or that workflow changes. Exit: as below.
    "tests/test_cargo_locks.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It pins scripts/cmux-next/check-single-host-fallbacks.py, which the pre-push gate runs strictly and
    # CI runs with --advisory; it reads the workflows only as that script's data. Exit: as below.
    "tests/test_ci_single_host_fallbacks.py",
    # lane = "manual" in tests/test-execution.d/other.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It pins scripts/install-axe-ci.sh's sha256 refusal and reads ios-e2e.yml only to check it calls that
    # script, not the Homebrew tap. Run it by hand when either changes. Exit: as below.
    "tests/test_install_axe_ci.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It evaluates every PR- and merge-queue-reachable runs-on, runner input and env against the reserved
    # cmux-gcp-nightly(-jit)-x64 labels. Run it by hand when a PR-triggered or reusable workflow's runner changes. Exit:
    # as below.
    "tests/test_ci_nightly_labels_reserved.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, lifted 2026-11-18). It checks pool reads against
    # .github/runners.json and that copy against main's; run it by hand when a pool read or the pools change. Exit: as
    # below.
    "tests/test_ci_runner_pools_copy.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). Both read every workflow only as data: a job whose need runs past a skipped ancestor has a status
    # function in its if (tree-owner-wait, runs 44818589673, 44834489171), and a fleet-reachable job sources
    # ensure-gh-attestation.sh before `gh attestation` (#48350). Run them by hand when a job's needs/if or a gh
    # attestation step changes. Exit: as below.
    "tests/test_ci_needs_skip_propagation.py",
    "tests/test_ci_gh_attestation_has_gh.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, lifted 2026-11-18). It reads workflows and
    # scripts only as data: which callers read reload.sh's App path after --build-only without --keep-app. Run it after
    # adding such a caller. Exit: as below.
    "tests/test_reload_build_only_app_path_readers.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, lifted 2026-11-18). It reads workflows only as
    # data: which files exist and which call a reusable declared workflow, for scripts/ci/hosted_light_rescue.py's
    # scope. Exit: as below.
    "tests/test_ci_hosted_light_rescue.py",
    # lane = "manual" in tests/test-execution.d/ci.toml (kept manual under the 2026-10-23 no-new-CI rule, lifted
    # 2026-11-18). It runs scripts/ci/swiftpm_prefetch_binary_artifacts.py against a fake cache and reads the owned-Mac
    # workflows only as data (each SwiftPM step seeds first, #43932). Run it by hand when the seed or such a step
    # changes. Exit: as below.
    "tests/test_ci_swiftpm_prefetch_shared_cache.py",
    # Kept manual under the 2026-10-23 no-new-CI rule (lifted 2026-11-18): #44697 added it with no step. It reads
    # test-ios.yml only as data (a bot's re-run on a cmux-next lane takes the picker's Blacksmith route); run it by hand
    # when that route changes. Exit: as below.
    "tests/test_ci_ios_bot_rerun_route.py",
    # lane = "manual": kept manual under the 2026-10-23 no-new-CI rule (lifted 2026-11-18). It reads the fast-check
    # workflows only as data (each routed job's needs and if, and its declared inputs in
    # scripts/ci/fast-check-inputs.json); run it by hand when fast_check_route.py, that map or a routed workflow
    # changes. Exit: as below.
    "tests/test_ci_fast_check_route.py",
    # lane = "manual": kept manual under the 2026-10-23 no-new-CI rule (lifted 2026-11-18). Both read the
    # workflows only as data (the receipt jobs' verifier calls; each pull-request job's same-tree reuse or
    # denial in scripts/ci/same_tree_reuse.json); run them by hand when ci_receipt.py, same_tree_reuse.py,
    # its map or a covered workflow changes. Exit: as below.
    "tests/test_ci_receipt.py",
    "tests/test_same_tree_reuse.py",
    # Both are lane = "manual" in tests/test-execution.toml, kept manual under the 2026-10-23 no-new-CI rule
    # (lifted 2026-11-18). Each reads a workflow only as data (a fixture nightly.yml; cmux-next.yml for stamp
    # readers). Exit: wire it here when its toml entry moves to a CI lane.
    "tests/test_cmux_next_guardrails.py",
    "tests/test_settings_stamp_not_committed.py",
    # lane = "manual" for the same rule. It runs tree-preflight's inspect step with fakes and asserts
    # wall-clock bounds of its fallback owner election; run it by hand when that step changes.
    "tests/test_cmux_tui_election_budget.py",
    # lane = "manual" for the same rule. It writes a fixture .github/workflows/nightly.yml into a throwaway
    # repository and pushes it through the real pre-push hook (the workflow YAML layer of prepush-gate.py); it
    # reads no real workflow. Run it by hand when that layer changes. Exit: as above.
    "tests/test_cmux_next_prepush_workflow_yaml.py",
    # lane = "manual" for the same rule. They check the cmux-next swift test job's shard plan and its
    # main-thread-heavy split; run them by hand after changing scripts/cmux-next/swift-test-shards.py,
    # main-thread-heavy-suites.py or that job.
    "tests/test_ci_swift_test_main_thread_isolation.py",
    "tests/test_ci_swift_test_shards.py",
    # lane = "manual" for the same rule. It reads nightly-next-launch-smoke.yml and nightly.yml to assert
    # the post-publish smoke never gates a publish; run it by hand when the smoke or its workflow changes.
    "tests/test_nightly_next_launch_smoke.py",
    # lane = "manual" for the same rule. It checks the one-mini routing (vars.CI_NIGHTLY_MINI) of nightly.yml
    # and the tag permission probe; run it by hand after changing either. Exit: as above.
    "tests/test_nightly_one_mini.py",
    # lane = "manual" for the same rule. It checks that generate-nightly-deltas checks out only scripts/ of the
    # build ref and that the reel's apt install retries; run it by hand after changing either.
    "tests/test_nightly_deltas_sparse_checkout.py",
    # lane = "manual" for the same rule. It runs the warm nightly-next builder's checkout step from nightly.yml in
    # a temp workspace that a sparse checkout was left in, and needs the whole tree after it; run it by hand after
    # changing that step or a sparse checkout in a job that shares the builder's workspace.
    "tests/test_nightly_warm_checkout_sparse.py",
    # lane = "manual" for the same rule. It runs the warm nightly-next builder's checkout step from nightly.yml on
    # an empty slot beside a temp git mirror and checks the slot borrows the mirror (glaeda's borrow record and the
    # alternates line) before its fetch; run it by hand after changing that step or glaeda's borrow record.
    "tests/test_nightly_warm_checkout_borrows_mirror.py",
    # lane = "manual" for the same rule. It reads nightly.yml only to keep the pinned Sparkle key of
    # nightly_next_artifact_check.py equal to NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY; run it by hand when that
    # helper or the workflows that call it change.
    "tests/test_nightly_next_artifact_check.py",
    # lane = "manual" for the same rule. It checks that the nightly-next tail jobs run in the dispatched
    # post-publish run, off the push group; run it by hand after changing those jobs or their dispatch.
    "tests/test_nightly_next_tail_off_push_group.py",
    # lane = "manual" for the same rule. It checks that a nightly-next loop run holds the push slot only in
    # nightly-next-one, that the next notes start from the live feed, and the tick wake; run it by hand after
    # changing nightly.yml's concurrency, nightly-next-one or wake-nightly-next-tick.
    "tests/test_nightly_next_push_slot_at_build.py",
    # lane = "manual" for the same rule. It checks the single nightly-next loop: one push group held through the
    # GitHub release, the rest of the tail dispatched, and the retry at the newest head; run it by hand after
    # changing decide, retry-nightly-next or dispatch-published-in.
    "tests/test_nightly_next_single_loop.py",
    # lane = "manual" for the same rule. It checks the nightly-next build and sign stages (the push run builds,
    # dispatch-nightly-next-sign hands the unsigned app to a sign run in its own group); run it by hand after
    # changing decide, the sign-stage dispatch, retry-nightly-next or resume-unsigned-nightly.py.
    "tests/test_nightly_next_pipeline.py",
    # lane = "manual" for the same rule (tests/test-execution.d/nightly.toml). It checks the one-job nightly-next
    # path of nightly.yml (gate, concurrency, shared steps, the kept Zig cache and the single Zig install); run it
    # by hand after changing nightly-next-one or a step it shares with the split jobs.
    "tests/test_nightly_next_one_job.py",
    # lane = "manual" for the same rule. It checks that every nightly upload-artifact step has one retry that keeps
    # the first try's condition; run it by hand after adding or changing an upload in nightly.yml.
    "tests/test_nightly_artifact_uploads_retry.py",
    # lane = "manual" for the same rule. It checks that the nightly deltas are built without the Sparkle key, off
    # the whole-Mac hold; run it by hand after changing build-nightly-deltas, generate-nightly-deltas or their scripts.
    "tests/test_nightly_deltas_keyless_prebuild.py",
    # lane = "manual" for the same rule. It checks that build-nightly-deltas waits for a quiet nightly-next loop
    # before the keyed job asks for the signer Mac; run it by hand after changing the yield script or the delta jobs.
    "tests/test_nightly_deltas_yield.py",
    # lane = "manual" for the same rule. It checks that the nightly-next delta republish ships the deltas R2 serves past
    # one failed upload and fails red when the live feed's newest item offers none; run it by hand after changing
    # nightly_next_delta_check.py or republish-deltas-upload-next-appcasts.sh.
    "tests/test_nightly_next_delta_check.py",
    # lane = "manual" for the same rule. It checks that nightly-next-one's Release compile has its own step bound;
    # run it by hand after changing that step or the job's timeout.
    "tests/test_nightly_next_build_step_bound.py",
    # lane = "manual" for the same rule. It runs decide's browser-import block from nightly.yml in node and
    # checks the outputs the build and publish jobs read; run it by hand after changing that block.
    "tests/test_nightly_next_notary_full_import.py",
    # lane = "manual" for the same rule (their tests/test-execution.toml entries say so: wiring them as
    # linux-guard reddened tooling-tests on every pull request). Run each by hand after changing what it reads:
    # .github/runners.json linux_sizes or a Blacksmith Linux runs-on (#30360);
    "tests/test_ci_blacksmith_linux_sizes.py",
    # a Linux runs-on or the RUNNER_POOLS.linux picker (#30878);
    "tests/test_ci_overflow_pick_reads_pool.py",
    # scripts/ci/cloud_probe_rescue.py, run by the main controller's workflow_run adapter, not a PR job
    # (#30796): python3 -m unittest tests.test_ci_cloud_probe_rescue from the repository root.
    "tests/test_ci_cloud_probe_rescue.py",
    # lane = "manual" for the same rule. It checks the weekly rollback drill (nightly-next-rollback-drill.yml) and
    # its call into nightly-next-rollback.yml; run it by hand after changing either or
    # scripts/ci/nightly_next_rollback_drill.py.
    "tests/test_nightly_next_rollback_drill.py",
    # lane = "manual" for the same rule. It reads every workflow as data: a job in a secrets-only environment says
    # `deployment: false`, so the PR logs no "temporarily deployed" event. Run it by hand after adding an
    # environment to a job.
    "tests/test_ci_secrets_only_environments_log_no_deployment.py",
    # lane = "manual" for the same rule. The first proves each derived job list red against its pre-fix reader
    # with fixture workflows; the second fails on a guard that reads a job field raw instead of through
    # tests/workflow_jobs.py. Run both by hand after changing a job-list guard or the resolver. Exit: as above.
    "tests/test_ci_job_list_fixture_mutations.py",
    "tests/test_ci_guards_read_through_workflow_jobs.py",
    # lane = "manual" for the same rule. It fails when a job on a self-hosted selector downloads an artifact into a
    # relative directory a persistent worker may still hold files in; run it by hand after adding a download-artifact step.
    "tests/test_ci_self_hosted_downloads_are_fresh.py",
    # lane = "manual" for the same rule. It fails when a publishing step of coderouter-release.yml or app-ffi-release.yml
    # loses its release-ref gate or a workflow_dispatch can reach it; run it by hand after editing either workflow.
    "tests/test_ci_release_publish_tag_gate.py",
    # lane = "manual" (tests/test-execution.d/ci.toml): it pins scripts/cmux-next/check-single-host-fallbacks.py,
    # which ci-guards.yml runs only with --advisory and the pre-push gate runs strictly. Run it by hand after
    # changing the checker or .github/single-host-fallbacks.json.
    "tests/test_ci_single_host_fallbacks.py",
    # Kept manual under the 2026-10-23 no-new-CI rule, since lifted. It needs cargo, which no guard step has, and reads
    # rust-workspaces.yml's lock check step; that job runs scripts/cmux-next/cargo-locks.py check --strict itself on
    # every Rust change. Run it by hand after changing cargo-locks.py or that step.
    "tests/test_cargo_locks.py",
    # lane = "manual" (tests/test-execution.d/other.toml; the 2026-10-23 no-new-CI rule, since lifted). It reads four
    # workflows only as text (each failing step asks cargo-locks.py explain) and lists cargo --locked wrappers. Run it
    # by hand after changing cargo-locks.py or a step that runs cargo with --locked.
    "tests/test_cargo_locks_explain.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, since lifted). It checks that the cmux-tui tree
    # build legs install Debian packages through scripts/ci/apt-ensure.sh (dpkg first, no sudo when all are there; run
    # 44363923089). It reads cmux-tui- artifacts.yml, cmux-tui-build-package.yml and cmux-tui-tree-request.yml as data.
    # Run it by hand after changing apt-ensure.sh or those install steps. Exit: as above.
    "tests/test_ci_apt_ensure.py",
    # lane = "manual" (tests/test-execution.d/ci.toml; kept manual under the 2026-10-23 no-new-CI rule, since lifted).
    # It names .github/workflows/ paths only as data in its fixture runs: scripts/ci/ci_receipt.py accepts a same-tree
    # cmux-ci test run as the fast gates only from fast-checks.yml (fe0f9593). Run it by hand after changing
    # ci_receipt.py. Exit: as above.
    "tests/test_ci_receipt.py",
    # lane = "manual" (tests/test-execution.d/ci.toml; kept manual under the 2026-10-23 no-new-CI rule, since lifted).
    # It runs the Mac build steps of cmux- tui-build-package.yml with a fake cargo and sysctl and checks their cargo
    # builds run at once at 40 GiB or more (#46073). Run it by hand after changing those steps,
    # cmux-tui-mac-cargo-builds.sh or cargo-groups.sh. Exit: as above.
    "tests/test_ci_cmux_tui_mac_legs_cargo_groups.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, since lifted). It checks that fast-checks.yml's
    # setup=kernel-free Mac job: its owned label, trust boundary and receipt (#46651). Run it by hand after changing
    # that job. Exit: as above.
    "tests/test_ci_fast_checks_kernel_free.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, since lifted). It checks that a NEXT nightly's
    # cmux-tui tree wait in nightly.yml follows the owning cmux-tui-artifacts run and ends on a stalled or failed
    # preflight (#46957). It runs that step's shell, which needs GNU date (Linux). Run it by hand on Linux after
    # changing the wait. Exit: as above.
    "tests/test_ci_nightly_tree_wait_follows_owner.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, since lifted). It checks that every checkout of
    # a job that can take the owned GCP build lane repairs a reused workspace (proof run 44398113924). It reads
    # cloud-vm-image-roll.yml and the cmux-tui workflows as data. Run it by hand after changing those checkouts. Exit:
    # as above.
    "tests/test_ci_owned_route_checkout_repair.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, since lifted). It checks that a required check
    # of feat-cmux-next, and every job it needs, keeps its measured runner size, never the overflow upsize (#45823). Run
    # it by hand after changing a required job's runs-on. Exit: as above.
    "tests/test_ci_required_checks_keep_their_size.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, since lifted). It checks that a superseded
    # lane-branch push of cmux-tui artifacts skips before it takes a Blacksmith runner (#45997). Run it by hand after
    # changing cmux-tui-artifacts.yml's gate. Exit: as above.
    "tests/test_cmux_tui_superseded_gate.py",
    # lane = "manual" (kept manual under the 2026-10-23 no-new-CI rule, since lifted). It checks that every git fetch
    # and curl in nightly.yml's nightly- next-one job has its own bound and the ones that fail it retry (nightly run
    # 44232805509). Run it by hand after changing a fetch or download there. Exit: as above.
    "tests/test_nightly_next_network_bounds.py",
}


def tracked_tests() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "tests", "tests_v2"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [p for p in out if Path(p).name.startswith("test_") and p.endswith((".py", ".sh"))]


def workflow_guards() -> set[str]:
    found = set()
    for path in tracked_tests():
        try:
            text = (ROOT / path).read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if READS_A_WORKFLOW.search(text):
            found.add(path)
    return found


def invoked_by_workflows() -> set[str]:
    sys.path.insert(0, str(ROOT / "scripts" / "ci"))
    import workload_entrypoints

    invoked = set()
    for workflow in sorted(WORKFLOW_DIR.glob("*.yml")):
        text = workflow.read_text(encoding="utf-8")
        invoked.update(INVOKED_PATH.findall(text))
        # A workload profile step runs everything its entrypoint names.
        for _, script in workload_entrypoints.entrypoints(text, ROOT):
            invoked.update(INVOKED_PATH.findall(script))
    return invoked


def test_every_workflow_guard_is_run_by_a_workflow() -> None:
    unwired = sorted(workflow_guards() - invoked_by_workflows() - UNWIRED)
    assert not unwired, (
        "these tests read .github/workflows/ but no workflow runs them, so the "
        "invariants they assert are not enforced:\n  "
        + "\n  ".join(unwired)
        + "\n\nAdd a step to .github/workflows/ci-guards.yml, or add an "
        "entry to UNWIRED in this file explaining why not."
    )


def test_allowlist_does_not_outlive_its_entries() -> None:
    # An entry that has been wired, deleted, or renamed must leave, or the
    # allowlist silently accumulates permission for files that no longer exist.
    guards = workflow_guards()
    invoked = invoked_by_workflows()
    for entry in sorted(UNWIRED):
        assert (ROOT / entry).exists(), f"{entry} is allowlisted but does not exist"
        assert entry in guards, f"{entry} is allowlisted but no longer reads a workflow"
        assert entry not in invoked, f"{entry} is wired now; drop it from UNWIRED"


if __name__ == "__main__":
    test_every_workflow_guard_is_run_by_a_workflow()
    test_allowlist_does_not_outlive_its_entries()
    print("all workflow guards are wired")

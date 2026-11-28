#!/usr/bin/env python3
"""One router per push: which pull request workflows a feat-cmux-next head can affect (RFD 0023).

    pr_router.py route     in pr-router.yml's one `route` job: writes start=<JSON list of workflow files>
                           and one `<job>_*` output per routed value to $GITHUB_OUTPUT
    pr_router.py check     the manifest, the callees and pr-router.yml agree (run it by hand after an edit)
    pr_router.py explain FILE...   which workflows these changed paths would start (offline)

Every feat-cmux-next pull request head used to start each pull request workflow on its own, and each began
with a routing job of its own (a checkout, a diff, a decision) that often skipped everything after it: 22
workflows, about 13 runner-minutes a head on routing alone on 11-20. Here one small job lists the changed
files once (a blobless two-commit checkout of the merge commit: every changed path, not GitHub's first 300)
and starts, as `workflow_call` jobs of pr-router.yml, only the workflows the change can reach. A workflow it
does not start costs no runner: its caller job is skipped by `if:` and reports one skipped check under the
workflow's name.

pr_router.json lists each routed workflow ("callee") with what used to start it:
  types      the pull_request activity types it listened to;
  paths / paths-ignore
             its former pull_request path filter, GitHub's semantics (later patterns win, `!` negates),
             applied to every changed path;
  skip_docs_only
             true for a workflow that carried the shared docs-only filter (scripts/ci/docs_only_paths.py):
             a change of only prose and images does not start it;
  affects    optional, narrower: globs (same syntax) of the inputs the workflow actually reads; when given, a
             change must also touch one of them;
  table_jobs for the step table's workflow (pr-pipeline.yml): the jobs of ci/steps.toml it runs. It starts
             when the change routes a step of one of them (scripts/ci/ci_steps.py, each step's `inputs`);
             a table that cannot be read starts it. A job of FULL_TIER_JOBS (the `mac` job) is routed only
             on a full-tier head: a draft or idle head runs no Mac, as cmux-next.yml's path_route held;
  labels     labels whose `labeled` event starts it whatever the paths;
  land_handoff_only
             true for a workflow that starts only on a land's own heads: the `labeled` event that adds
             ready-to-land or full-ci (the land handoff), or a synchronize of a ready-to-land PR whose head
             is GitHub's base merge (land's update-branch), and the merge train's tip. The label handoff
             itself skips it unless $CI_MC_HANDOFF_LABEL_SKIP is 0 (handoff_label_skip). Any other head,
             full tier or not, skips it;
  land_affected
             true to consider the callee's paths on the affected landing tier as well as the full tier;
  land_ask_only
             with land_affected: on the affected landing tier it starts only on the land handoff (the `labeled`
             event adding ready-to-land or full-ci, which land-judge pulses at the head it lands) and the merge
             train's tip, not on each push or base merge of a labelled PR. $CI_NIGHTLY_PR_BUILD_AT_LAND=0 starts
             it on every landing head again (land_ask_only_on);
  draft      true for a workflow that also runs on a draft head (scripts/ci/head_tier.py's cheap tier);
             any other callee starts on a draft only with full-ci, and runs when the PR is marked ready
             for review, so every callee must listen to `ready_for_review` (`check` says so).
A `full-ci` label makes the head full tier (as ready-to-land does) and beats fast-track; its callees still
start only when a changed file reaches them, or when the changed files are unknown. A lane VM's land handoff
adds full-ci to every PR, and starting every callee for it repeated the base's push run (cmux#58044). Into feat-cmux-next
`full-ci` applies only on its own `labeled` event (head_tier.full_ci_applies; CI_FULL_CI_ONE_SHOT=0 makes it sticky).

Whatever the router cannot read (no merge commit, a git error) starts every callee the event's type allows:
it routes more, never less. Stdlib only, plus workflow_paths_cover_inputs (the one GitHub paths-glob
implementation in this tree).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The merge train's combined tip (cmuxterm-hq tools/fleet-reconcilers/merge_train.py; standing PR #55855).
TRAIN_TIP = "lane/merge-train"
sys.path.insert(0, str(HERE))
try:  # a head whose step-table runner does not import still routes: its pipeline starts (table_steps)
    import ci_steps  # noqa: E402
except Exception:  # noqa: BLE001
    ci_steps = None
import docs_only_paths  # noqa: E402
import fast_track  # noqa: E402
import head_tier  # noqa: E402
import workflow_paths_cover_inputs as filters  # noqa: E402

ROOT = HERE.parents[1]
# The step table's jobs that run only on a full-tier head (head_tier.py): a cheap head (a draft, a ready head before
# `ready-to-land` or `full-ci`, a base merge into an idle pull request) routes them nowhere, so pr-pipeline.yml does not
# start on it at all. mac alone was here until 11-25, so linux, web-browser and ios ran on every cheap push: about 50k
# runner-minutes a day (Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period.").
FULL_TIER_JOBS = ("linux", "web-browser", "mac", "ios")
# The step table's jobs a pull request routes only with the `full-ci` label: the full tier (`ready-to-land`) skips them
# too, and base pushes run their suites (ci-web.yml from cmux-next-web.yml and the post-merge batch). NOW's pr_verdict
# at 2026-11-26 08:57Z: `pr router / pr pipeline / web-browser` ended 3 of the newest 20 PR verdicts. Leo,
# 2026-11-21: "help 100x ci speed ... while maintaining a partial semblance of checks. and we can infrequenrly have
# fuller checks." The repository variable CI_PR_BROWSER_FULL_CI_ONLY=0 turns this off (passed in by pr-router.yml).
FULL_CI_ONLY_JOBS = ("web-browser",)


def full_ci_only_jobs() -> tuple[str, ...]:
    """FULL_CI_ONLY_JOBS, or none when $CI_PR_BROWSER_FULL_CI_ONLY is 0."""
    return () if os.environ.get("CI_PR_BROWSER_FULL_CI_ONLY", "1").strip() == "0" else FULL_CI_ONLY_JOBS


# A land_handoff_only callee (the machine channel PR head build) skips the label handoff itself and builds only
# the merge train's tip and land's update-branch head. 13-17Z 2026-11-26: 72 of 112 PR head builds (1,769 of
# 3,002 runner-min) came from a ready-to-land or full-ci label being added, 66 of the 102 PRs built had not merged
# by 20Z, and a labeled head had fallen behind the base by its merge (0 of 18 merges squashed their own head's
# tree, #58765), so find never took those builds. yap-goblin's unlabel/relabel of ready-to-land rebuilt the same
# head up to 3 times. Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time, period."
# The repository variable CI_MC_HANDOFF_LABEL_SKIP=0 turns this off (passed in by pr-router.yml).


def handoff_label_skip() -> bool:
    """Whether a land_handoff_only callee skips the label handoff ($CI_MC_HANDOFF_LABEL_SKIP, on unless 0)."""
    return os.environ.get("CI_MC_HANDOFF_LABEL_SKIP", "1").strip() != "0"


# A land_ask_only callee (nightly-pr-build.yml, the two "nightly app compile" Mac stubs) runs on the affected
# landing tier only when land asks: the handoff label and the merge train's tip. 15-21Z 2026-11-27 they were the
# 2nd and 3rd largest jobs (arm64 17.9, x86_64 17.5 runner-min per merged PR); 80% of their 11,896 runner-min was on
# PRs that had not merged by 21Z, 56% on base-merge heads of labelled PRs, 25% on pushes after the label, and 31%
# repeated an input key already compiled. Leo, 2026-11-27: "whatever we need to cut, we cut. whatever we can
# reuse, we reuse." The repository variable CI_NIGHTLY_PR_BUILD_AT_LAND=0 turns this off (passed in by pr-router.yml).


def land_ask_only_on() -> bool:
    """Whether a land_ask_only callee waits for land's ask ($CI_NIGHTLY_PR_BUILD_AT_LAND, on unless 0)."""
    return os.environ.get("CI_NIGHTLY_PR_BUILD_AT_LAND", "1").strip() != "0"


def full_ci_kept(event: dict) -> bool:
    """Whether the PR asks for FULL_CI_ONLY_JOBS: `full-ci` in the payload's own label list, the label as it stands
    when GitHub sends the event. land-judge's lane-VM pulse (label_lane_pulse: full-ci added and taken off 2 s later)
    is the land handoff, as ready-to-land is (head_tier.labels_of keeps it for the tier), not a request for the
    browser suites: its `labeled` payload no longer lists full-ci, so it routes the land tier without them. After
    #58223 (2026-11-26 12:28Z) the pulse was most of what web-browser still ran: 5 of 8 sampled runs 15-17Z, about
    4-6k runner-min a day. A full-ci someone keeps on the PR is in the list and still routes them; a pulse GitHub
    sends before the take-off lands routes them too (more, never less). Leo, 2026-11-21: "de facto, im asking for
    99% fewer minutes of ci time, period."
    """
    pr = event.get("pull_request") or {}
    return FULL_CI in {str(label.get("name") or "") for label in pr.get("labels") or []}


MANIFEST = HERE / "pr_router.json"
ENTRY = ROOT / ".github" / "workflows" / "pr-router.yml"
FULL_CI = "full-ci"


def load_manifest(path: Path = MANIFEST) -> dict:
    return json.loads(path.read_text())["callees"]


def changed_files(cwd: str | None = None) -> list[str] | None:
    """Every path the merge commit changes against its first parent (the base tip), both sides of a rename;
    None when there is no merge commit or git fails."""
    try:
        parents = subprocess.run(["git", "rev-list", "--parents", "-n", "1", "HEAD"], cwd=cwd, check=True,
                                 capture_output=True, text=True).stdout.split()
        if len(parents) != 3:
            return None
        out = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", "HEAD^1", "HEAD"], cwd=cwd,
                             check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [p for p in out.split("\0") if p]


def matches_filter(config: dict, files: list[str]) -> bool:
    if config.get("skip_docs_only") and docs_only_paths.docs_only(files):
        return False
    if "paths" in config:
        return any(filters.admits("paths", config["paths"], f) for f in files)
    if "paths-ignore" in config:
        return any(filters.admits("paths-ignore", config["paths-ignore"], f) for f in files)
    return True


def affects(config: dict, files: list[str]) -> bool:
    globs = config.get("affects")
    if not globs:
        return True
    return any(filters.admits("paths", globs, f) for f in files)


def table_steps(config: dict, files: list[str], table: Path | None = None, full: bool = True,
                full_ci: bool = True, tier: str = "full") -> list[str] | None:
    """The steps of the callee's `table_jobs` this change routes; None when the table cannot be read. FULL: the head
    is in the full tier (else FULL_TIER_JOBS route nothing). FULL_CI: the PR carries `full-ci` (else
    full_ci_only_jobs() route nothing). TIER: the step table's tier ("pr" leaves its `tier = "push"` steps to the push run)."""
    # Any failure to read the table (a missing file, bad TOML, a wrong shape, a runner that does not import)
    # starts the pipeline, whose own run reports it: the router routes more, never less, and never fails on it.
    try:
        routed = ci_steps.route(ci_steps.load(table or ci_steps.TABLE), files, tier=tier)
    except Exception:  # noqa: BLE001
        return None
    held = () if full_ci else full_ci_only_jobs()
    steps = [step for job in config["table_jobs"] if (full or job not in FULL_TIER_JOBS) and job not in held
             for step in routed.get(job, [])]
    # A step whose inputs are `["**"]` replaced a job that ran on every change its workflow's shared docs-only
    # filter let through (scripts/ci/docs_only_paths.py): a docs-only change alone does not start the pipeline for it.
    # `**` next to named inputs (tooling-tests-5's, which route it under --pr-scope) is still that whole-tree route.
    if files and docs_only_paths.docs_only(files):
        table = ci_steps.load(table or ci_steps.TABLE).steps
        steps = [step for step in steps if "**" not in table[step].inputs]
    return steps


def table_jobs_routed(callees: dict, files: list[str] | None, table: Path | None = None,
                      full: bool = True, full_ci: bool = True, tier: str = "full") -> list[str]:
    """Which of the step table's jobs the change routes, for pr-pipeline.yml's job `if:`s: every `table_jobs` job
    when the change or the table is unknown (the router routes more, never less). FULL: the head is in the full
    tier; else no job of FULL_TIER_JOBS. FULL_CI: the PR carries `full-ci`; else no job of full_ci_only_jobs()."""
    held = () if full_ci else full_ci_only_jobs()
    jobs = [job for config in callees.values() for job in config.get("table_jobs", [])
            if (full or job not in FULL_TIER_JOBS) and job not in held]
    if files is None:
        return jobs
    try:
        routed = ci_steps.route(ci_steps.load(table or ci_steps.TABLE), files, tier=tier)
    except Exception:  # noqa: BLE001
        return jobs
    return [job for job in jobs if routed.get(job)]


def pipeline_tier(labels: set[str]) -> str:
    """"pr": a pull request's step table leaves the `tier = "push"` steps to the push tier. "full": the `full-ci`
    label, or vars.CI_PR_PIPELINE_TIER=full (the workflow sets CI_PR_PIPELINE_TIER), runs every routed step."""
    return "full" if FULL_CI in labels or os.environ.get("CI_PR_PIPELINE_TIER") == "full" else "pr"


def route(event: dict, callees: dict, files: list[str] | None,
          draft_switch: str = "1", decided: tuple[str, str] | None = None,
          land_update: bool = False, carried: set[str] | None = None) -> tuple[list[str], dict[str, str]]:
    """(the callee files to start, a reason per callee) for one pull_request event. DECIDED: head_tier's
    (tier, reason) when the caller read the head's facts (route mode); else the draft rule alone. LAND_UPDATE:
    the head is GitHub's base merge into a ready-to-land PR (land_update_head), for `land_handoff_only` callees.
    CARRIED: callees the red-head base merge rule keeps off (rerun_plan): they passed at the previous head."""
    tier, tier_reason = decided or head_tier.tier("pull_request", event, draft_switch)
    cheap = tier == "cheap"
    landing_affected = head_tier.land_affected((tier, tier_reason))
    pr = event.get("pull_request") or {}
    # Fast-track (scripts/ci/fast_track.py): a docs, plans, skills, copy or tests-only change gets the cheap tier.
    # full-ci asks for the full tier, so it beats fast-track.
    fast = False
    if (not cheap and tier != "none" and files is not None and fast_track.enabled()
            and not head_tier.full_ci_applies(event)):
        fast, fast_reason = fast_track.classify(files)
        cheap = fast
    action = str(event.get("action") or "")
    added = str((event.get("label") or {}).get("name") or "") if action == "labeled" else ""
    handoff = added in (head_tier.LAND_LABEL, FULL_CI)
    if handoff:
        # The land handoff (head_tier's land rule): the same head now runs the full tier, as when a draft is marked
        # ready, so every callee that skips a cheap head starts on it (each listens to ready_for_review). full-ci is
        # the same handoff from a lane VM, whose broker never sets ready-to-land (land-judge's land_tier asks it).
        action, added = "ready_for_review", ""
    head = pr.get("head") or {}
    train_tip = (head.get("ref") == TRAIN_TIP
                 and (head.get("repo") or {}).get("full_name") == ((pr.get("base") or {}).get("repo") or {}).get("full_name"))
    start, why = [], {}
    for name, config in sorted(callees.items()):
        if action not in config["types"]:
            why[name] = f"does not listen to '{action}'"
            continue
        if config.get("land_handoff_only") and train_tip and action in ("opened", "reopened", "synchronize"):
            # The merge train's combined tip is the tree its last member squashes to: the one head whose build a
            # merge can take when every member's own head is behind the base (cmux_machine_channel_pr_head.py).
            if files is None or (matches_filter(config, files) and affects(config, files)):
                start.append(name)
                why[name] = f"the merge train's tip ({TRAIN_TIP})"
            else:
                why[name] = "no changed file is one of its inputs"
            continue
        if config.get("land_handoff_only") and not handoff and not land_update:
            why[name] = (f"land handoff only: starts when {head_tier.LAND_LABEL} or {FULL_CI} is added, or on land's "
                         f"update-branch head")
            continue
        if config.get("land_handoff_only") and handoff and not land_update and handoff_label_skip():
            why[name] = (f"label handoff: the merge train's tip ({TRAIN_TIP}) and land's update-branch head build the "
                         f"tree a merge takes; $CI_MC_HANDOFF_LABEL_SKIP=0 builds here too")
            continue
        if (config.get("land_ask_only") and landing_affected and not handoff and not train_tip
                and land_ask_only_on()):
            why[name] = (f"{head_tier.LAND_AFFECTED_REASON}: starts when land asks ({head_tier.LAND_LABEL} or "
                         f"{FULL_CI} added at this head) or on the merge train's tip ({TRAIN_TIP}), not on each push; "
                         f"$CI_NIGHTLY_PR_BUILD_AT_LAND=0 starts it here too")
            continue
        if added and added in config.get("labels", []):
            start.append(name)
            why[name] = f"label '{added}' added"
            continue
        if tier == "none":
            why[name] = tier_reason
            continue
        if carried and name in carried:
            why[name] = (f"{head_tier.RERUN_REASON}: this base merge's previous head ran it green; only what was "
                         f"red there runs again ({FULL_CI} or the land runs it)")
            continue
        if (name == IOS_VERDICT_CALLEE and head_tier.land_affected((tier, tier_reason)) and ios_verdict_on()
                and ios_touched(files)):
            # A landing head on the affected tier starts no full-tier job, so without this nothing iOS compiles
            # before the merge and the base breaks for the iOS developer an hour later (IOS_VERDICT_CALLEE).
            start.append(name)
            why[name] = (f"{head_tier.LAND_AFFECTED_REASON}, iOS-affecting: the ios fast verdict alone (no table job) "
                         f"compiles the changed iOS targets before the merge")
            gates = nightly_gates(config, files) if nightly_gate_on() else []
            why[name] += f"; nightly gate: runs only {', '.join(gates)}" if gates else ""
            continue
        gates = nightly_gates(config, files) if landing_affected and nightly_gate_on() else []
        if gates:
            # A landing head on the affected tier starts no full-tier job, so a check the nightly also runs first ran
            # at the nightly, hours after the merge (NIGHTLY_GATE_JOBS). Only those steps run (main's `only`).
            start.append(name)
            why[name] = (f"{head_tier.LAND_AFFECTED_REASON}, nightly gate: runs only "
                         f"{', '.join(gates)} (steps the nightly also runs, ci/steps.toml `nightly`)")
            continue
        if cheap and fast and not config.get("draft"):
            why[name] = "fast-track: runs after the merge (post-merge batch and push runs)"
            continue
        if cheap and not config.get("draft") and not (landing_affected and config.get("land_affected")):
            why[name] = ("draft: starts when marked ready for review (or with full-ci)" if pr.get("draft") is not False
                         else tier_reason)
            continue
        # A callee whose every table job is full-tier-only starts on no cheap head (a fast-track head is full tier).
        if tier != "full" and config.get("table_jobs") and set(config["table_jobs"]) <= set(FULL_TIER_JOBS):
            # The tier's own reason says what gives this head the full tier (a draft marked ready, full-ci, or the
            # land label when CI_LAND_FULL_PER_PR is on): a fixed "ready-to-land or marked ready" here sent a ready
            # pull request looking for a run its own marking could not start.
            why[name] = f"cheap tier: its jobs ({', '.join(config['table_jobs'])}) run only on the full tier: {tier_reason}"
            continue
        if files is None:
            start.append(name)
            why[name] = "changed files unknown: starts"
            continue
        if not matches_filter(config, files):
            why[name] = "its path filter admits no changed file"
            continue
        if not affects(config, files):
            why[name] = "no changed file is one of its inputs"
            continue
        if "table_jobs" in config:
            full_ci = head_tier.full_ci_applies(event) and full_ci_kept(event)
            steps = table_steps(config, files, full=tier == "full" or full_ci, full_ci=full_ci,
                                tier=pipeline_tier(head_tier.labels_of(event)))
            if steps == []:
                why[name] = "the change routes no step of " + ", ".join(config["table_jobs"])
                continue
            start.append(name)
            why[name] = "the step table could not be read: starts" if steps is None else "routes " + ", ".join(steps)
            continue
        start.append(name)
        why[name] = "a changed file reaches it"
    return start, why


# The compile preflight (cmux-next-compile-preflight.yml) has no tier rule and no `start` gate: pr-router.yml calls it on
# every head the route job runs for. Its job still took a runner on every head to learn, after a checkout and a merge
# onto the live base, that most changed no web bundle input: 1,237 such no-op runs in the 6 h to 2026-11-27 10Z, about
# 780 runner-min (scripts/measure/ci140-head-minutes). Leo, 2026-11-21: "whatever we need to cut, we cut. whatever we
# can reuse, we reuse." Its pr_router.json `paths-ignore` (GitHub's filter semantics, matches_filter) names paths no web
# bundle reads; a head whose every changed path it ignores passes `web: false` and the callee's job skips. The full-ci
# label, an unknown change and any other path keep it on; the callee's never-web-check holds the list to the bundles'
# routed inputs on every head that builds.
PREFLIGHT_CALLEE = "cmux-next-compile-preflight.yml"


def preflight_web(event: dict, callees: dict, files: list[str] | None) -> tuple[bool, str]:
    """(whether the compile preflight's web job runs at this head, why)."""
    config = callees.get(PREFLIGHT_CALLEE)
    if config is None or "paths-ignore" not in config:
        return True, "no paths-ignore in pr_router.json: runs"
    if FULL_CI in head_tier.labels_of(event):
        return True, f"{FULL_CI}: runs"
    if files is None:
        return True, "changed files unknown: runs"
    if not files:
        return True, "no changed file listed: runs"
    if matches_filter({"paths-ignore": config["paths-ignore"]}, files):
        return True, "a changed file may reach a web bundle: runs (its first step decides whether to build)"
    return False, "every changed file is one no web bundle reads (pr_router.json paths-ignore): skips"


# The callee whose ios fast verdict (pr-pipeline.yml ios-fast-runner, ios-fast) a landing head on the affected tier
# (head_tier.land_affected) still starts when it touches iOS: its table jobs are full-tier-only, so the hourly full
# tier rule started nothing there and `cmux/ios-fast` posted a carried success with no iOS build behind it. 11-23 to
# 11-27: about 16 iOS base-red repair commits on feat-cmux-next, culprits (#59377, #50367, #53746, #56982, #56007)
# merged with iOS skipped; one base red failed 27 PRs' `pr pipeline / ios` (#57448). Leo, 2026-11-27: "like idk if he
# just kept getting bottled on random stuff that we can juts fix fundamentally in terms of decisions and/or just
# setting up more capacity and stuff". vars.CI_IOS_FAST_VERDICT=0 turns the verdict, and this start, off.
IOS_VERDICT_CALLEE = "pr-pipeline.yml"


# The step table's steps that mirror a nightly step (ci/steps.toml `nightly`: the notices generation) run on a landing
# head of the affected tier when the change routes them, with every input kept (ci_steps.nightly_gate_steps). 11-26 to
# 11-27: 8 nightly failures in a row from 4 causes, each found only at the nightly (#59540's IJG-licensed jpeg-encoder;
# #51044's duplicate import and #46903's shelf red, now caught by the compile preflight and app-store-shelf-pr).
# Leo, 2026-11-27: "shouldn't a build check fail beforehand fast like fast-fail is useful ci all stuff".
# vars.CI_NIGHTLY_GATE_ON_LAND=0
# turns this start off.
NIGHTLY_GATE_JOBS = ("linux",)


def nightly_gate_on() -> bool:
    return os.environ.get("CI_NIGHTLY_GATE_ON_LAND", "").strip() != "0"


def nightly_gates(config: dict, files: list[str] | None, table: Path | None = None) -> list[str]:
    """The nightly-mirroring steps of CONFIG's table jobs FILES route. Unknown files route every such step; an
    unreadable table routes none here (the full tier and the post-merge batch still run it)."""
    jobs = [job for job in config.get("table_jobs", []) if job in NIGHTLY_GATE_JOBS]
    if not jobs:
        return []
    try:
        return ci_steps.nightly_gate_steps(ci_steps.load(table or ci_steps.TABLE), files, jobs)
    except Exception:  # noqa: BLE001
        return []


def ios_verdict_on() -> bool:
    return os.environ.get("CI_IOS_FAST_VERDICT", "").strip() != "0"


def ios_touched(files: list[str] | None) -> bool:
    """Whether FILES reach anything iOS builds (ios_fast_verdict.affects); unknown or unreadable routes more."""
    if files is None:
        return True
    try:
        import ios_fast_verdict
        return ios_fast_verdict.affects(files)
    except Exception:  # noqa: BLE001 - unreadable routes more, never less
        return True


def land_update_head(event: dict, callees: dict) -> bool:
    """Whether EVENT is a synchronize of a ready-to-land PR to a head GitHub made by merging the base
    (land's update-branch), read only when some callee is `land_handoff_only`. Unreadable is no."""
    labels = head_tier.labels_of(event)
    if (event.get("action") != "synchronize" or head_tier.LAND_LABEL not in labels
            or not any(c.get("land_handoff_only") for c in callees.values())):
        return False
    facts = head_tier.head_facts(event) or {}
    return bool(facts.get("base_merge_only") and facts.get("by_github") is True)


# A callee or table job that passed at the previous head in less than this reruns anyway (red-head base merge rule).
RERUN_SHORT_SECONDS = 60
GREEN_JOB = frozenset({"success", "skipped"})


def caller_names(text: str) -> dict[str, list[str]]:
    """All caller prefixes per callee; split invocations must not overwrite one another's receipts."""
    names, current, name = {}, None, ""
    for line in text.splitlines():
        if m := re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line):
            current, name = m.group(1), ""
        elif current and (m := re.match(r"^    name:\s*(.+?)\s*$", line)):
            name = m.group(1).strip("'\"")
        elif current and name and (m := re.match(r"^    uses: \./\.github/workflows/([^\s@]+)\s*$", line)):
            names.setdefault(m.group(1), []).append(name)
    return names


def _seconds(job: dict) -> float | None:
    import datetime as dt
    try:
        start = dt.datetime.fromisoformat(str(job["started_at"]).replace("Z", "+00:00"))
        end = dt.datetime.fromisoformat(str(job["completed_at"]).replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError):
        return None
    return (end - start).total_seconds()


def proved(jobs: list) -> bool:
    """Whether a callee's (or table job's) jobs at the previous head passed and took RERUN_SHORT_SECONDS or more:
    each completed `success` or `skipped`, at least one `success`. A red, cancelled, unfinished, short or absent
    one reruns."""
    if not jobs or not all(isinstance(j, dict) and j.get("status") == "completed"
                           and j.get("conclusion") in GREEN_JOB for j in jobs):
        return False
    if not any(j.get("conclusion") == "success" for j in jobs):
        return False
    took = [_seconds(j) for j in jobs if j.get("conclusion") == "success"]
    return all(t is not None for t in took) and sum(took) >= RERUN_SHORT_SECONDS


def rerun_plan(jobs: list | None, names: dict[str, list[str]], table: list[str]) -> tuple[set[str], set[str]]:
    """(callee files, table jobs) the red-head base merge rule keeps off: those whose every job passed at the
    previous head's router run (proved). JOBS: that run's jobs (the jobs API); None (unread) keeps nothing off."""
    if not isinstance(jobs, list):
        return set(), set()

    def under(prefix: str) -> list:
        return [j for j in jobs if isinstance(j, dict) and (str(j.get("name") or "") == prefix
                or str(j.get("name") or "").startswith(prefix + " / ")
                or str(j.get("name") or "").startswith(prefix + " ("))]

    carried = {callee for callee, prefixes in names.items()
               if proved([job for prefix in prefixes for job in under(prefix)])}
    pipeline = names.get("pr-pipeline.yml", [])
    rows = {job for job in table if pipeline
            and proved([row for prefix in pipeline for row in under(f"{prefix} / {job}")])}
    return carried, rows


def router_jobs_at(runs: list | None, repo: str, token: str) -> list | None:
    """The jobs of the newest pr-router.yml run among RUNS (a commit's Actions runs), or None when there is none or
    they cannot be read whole (at most three pages of 100)."""
    newest = head_tier.newest_runs(runs)
    run = next((r for path, r in newest.items() if path.split("@")[0].endswith("/pr-router.yml")), None)
    if not run or not re.fullmatch(r"\d+", str(run.get("id") or "")) or not token:
        return None
    import urllib.request
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    out: list = []
    try:
        import deadline_http
        for page in (1, 2, 3):
            req = urllib.request.Request(
                f"{head_tier.API}/repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100&page={page}",
                headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                         "X-GitHub-Api-Version": "2022-11-28"})
            status, body, _ = deadline_http.request(req, head_tier.VERDICT_SECONDS)
            data = json.loads(body) if status == 200 else None
            if not isinstance(data, dict) or not isinstance(data.get("jobs"), list):
                return None
            out += data["jobs"]
            if len(out) >= int(data.get("total_count") or 0):
                return out
    except Exception:  # fail open: an unread answer keeps everything on
        return None
    return None


def caller_jobs(text: str) -> dict[str, str]:
    """{callee file: caller job id} from pr-router.yml's `uses: ./.github/workflows/X` jobs."""
    jobs, current = {}, None
    for line in text.splitlines():
        if m := re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line):
            current = m.group(1)
        elif (m := re.match(r"^    uses: \./\.github/workflows/([^\s@]+)\s*$", line)) and current:
            jobs[m.group(1)] = current
    return jobs


def check(callees: dict, entry_text: str, workflows: Path) -> list[str]:
    """What disagrees: a callee with no caller job, a caller job of no callee, a callee that is not
    `workflow_call`-able or still starts on its own for feat-cmux-next pull requests."""
    problems = []
    jobs = caller_jobs(entry_text)
    for name in callees:
        if name not in jobs:
            problems.append(f"{name}: in pr_router.json but pr-router.yml has no job that calls it")
        if not callees[name].get("draft") and "ready_for_review" not in callees[name].get("types", []):
            problems.append(f"{name}: skips drafts but does not listen to ready_for_review, so a draft marked"
                            " ready would never run it")
    for name, config in callees.items():
        if "table_jobs" in config and ci_steps is None:
            problems.append(f"{name}: scripts/ci/ci_steps.py does not import, so its table_jobs cannot be read")
        elif "table_jobs" in config:
            try:
                unknown = sorted(set(config["table_jobs"]) - set(ci_steps.load(ci_steps.TABLE).jobs))
            except Exception as error:  # noqa: BLE001 - any broken table is one named problem
                problems.append(f"{name}: the step table does not load: {error}")
            else:
                if unknown:
                    problems.append(f"{name}: table_jobs {unknown} are not jobs of ci/steps.toml")
    for name in jobs:
        if name not in callees:
            problems.append(f"{name}: pr-router.yml calls it but pr_router.json does not route it")
    for name in callees:
        path = workflows / name
        if not path.is_file():
            problems.append(f"{name}: no such workflow")
            continue
        document = filters.load_yaml(path)
        events = filters.triggers(document)
        if "workflow_call" not in events:
            problems.append(f"{name}: has no workflow_call trigger")
        pr = events.get("pull_request")
        if "pull_request" in events:
            branches = (pr or {}).get("branches") if isinstance(pr, dict) else None
            if branches is None or "feat-cmux-next" in branches:
                problems.append(f"{name}: still starts on its own for feat-cmux-next pull requests")
    return problems


def land_status(event: dict, decided: tuple[str, str]) -> str:
    """The `cmux/land-tier` commit status for EVENT's head (pr-router.yml posts it): `pending` while the land rule holds
    it on the cheap tier (or idle), `success` once it runs the full tier, lands on the affected tier (the hourly
    full tier rule), or the land carry rule or the full-ci base merge carry rule carries its previous head's run
    (head_tier.carried, head_tier.full_carried), empty where the land rule does not apply."""
    if (os.environ.get("CI_LAND_TIER", "1").strip() in ("0", "")) or not head_tier.land_rule_applies(event):
        return ""
    return ("success" if decided[0] == "full" or head_tier.carried(decided) or head_tier.land_affected(decided)
            or head_tier.full_carried(decided) else "pending")


def ios_status(event: dict, files: list[str] | None, start: list[str], land: str) -> tuple[str, str]:
    """The `cmux/ios-fast` commit status for EVENT's head (pr-router.yml posts it; the ios fast verdict's own result
    replaces a `pending` one, pr-router.yml's ios-fast-status job): ("", "") where the land rule does not apply.
    `success` at once for a head that touches nothing iOS builds (scripts/ci/ios_fast_verdict.py affects, the ios-kit
    step's inputs, the Rust crates the FFI compiles among them), so a ruleset can require it; `pending` for an
    iOS-affecting head until its verdict runs (pr-pipeline.yml's ios-fast); a head the router starts no pipeline on
    carries `success` only where cmux/land-tier does (LAND, land_status), else waits for the land handoff."""
    if not head_tier.land_rule_applies(event):
        return "", ""
    if not ios_verdict_on():
        return "success", "iOS fast verdict is off (vars.CI_IOS_FAST_VERDICT=0): the ios job's kit tests still run"
    if not ios_touched(files):
        return "success", "Touches nothing iOS builds (cmux-next-ios, the packages it links, the FFI's Rust crates)"
    if "pr-pipeline.yml" in start:
        return "pending", "iOS fast verdict runs on this head: the changed iOS targets, the app and its UI tests compile"
    if land == "success":
        return "success", "Carried: no pipeline runs on this head (land tier carried from its previous head)"
    return "pending", "iOS-affecting: the fast verdict runs when ready-to-land or full-ci is added"


def ui_status(event: dict, files: list[str] | None) -> tuple[str, str]:
    """The `cmux/ui-proof` commit status for EVENT's head (pr-router.yml posts it; its ui-proof-status job replaces a
    `pending` one with the proof record's verdict, scripts/ci/ui_proof_verdict.py): ("", "") where the land rule does
    not apply. `success` at once for a head that changes nothing a desktop user sees, so a ruleset can require it;
    `pending` for a visual head until a look at that head is on the PR. Leo, 2026-11-27: "obviously for visuals
    we'll need to do better before getting them in but you know"."""
    if not head_tier.land_rule_applies(event):
        return "", ""
    if os.environ.get("CI_UI_PROOF", "").strip() == "0":
        return "success", "UI proof is off (vars.CI_UI_PROOF=0)"
    try:
        import ui_proof_verdict
        need = "app" if files is None else ui_proof_verdict.affects(files)
    except Exception:  # noqa: BLE001 - unreadable routes more, never less
        need = "app"
    if not need:
        return "success", "Touches nothing a user sees (docs, copy, tests, CI, iOS has cmux/ios-fast)"
    return "pending", f"Visual change ({need}): waiting for a look at this head (hot-verify.py look --record)"


def plan_for(decided: tuple[str, str], facts: dict | None, callees: dict) -> tuple[set[str], set[str]]:
    """rerun_plan for this head when the red-head base merge rule reached the router: the head only merges the base
    onto a previous head where some run was not green and the router's own run there was not green either (a green
    one gave the tier `none` already). ({}, {}) when it does not apply or anything is unread."""
    if (decided[0] == "none" or not facts or facts.get("previous_green") is not False
            or not isinstance(facts.get("previous_runs"), list)):
        return set(), set()
    jobs = router_jobs_at(facts["previous_runs"], os.environ.get("GITHUB_REPOSITORY", ""),
                          os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "")
    table = [job for config in callees.values() for job in config.get("table_jobs", [])]
    carried, rows = rerun_plan(jobs, caller_names(ENTRY.read_text()), table)
    return {c for c in carried if c in callees}, rows


def nightly_gate_table(callees: dict, files: list[str] | None, decided: tuple[str, str], start: list[str],
                       table: list[str]) -> tuple[list[str], list[str]]:
    """(the table jobs pr-pipeline.yml starts, the steps its jobs run only): on a landing head of the affected tier
    whose change routes a nightly-mirroring step (nightly_gates), that step's job joins TABLE and runs only those
    steps. Any other head: (TABLE, []), its jobs run their whole route."""
    if not head_tier.land_affected(decided) or not nightly_gate_on():
        return table, []
    only = [step for name, config in sorted(callees.items()) if name in start
            for step in nightly_gates(config, files)]
    jobs = [job for job in NIGHTLY_GATE_JOBS if only and job not in table]
    return (table + jobs, only) if jobs else (table, [])


def write_outputs(start: list[str], why: dict[str, str], files: list[str] | None,
                  table: list[str] | None = None, status: str = "", ios: tuple[str, str] = ("", ""),
                  ui: tuple[str, str] = ("", ""), only: list[str] | None = None,
                  preflight: tuple[bool, str] = (True, "")) -> None:
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        out.write(f"start={json.dumps(start, separators=(',', ':'))}\n")
        out.write(f"table={json.dumps(table or [], separators=(',', ':'))}\n")
        out.write(f"only={' '.join(only or [])}\n")
        out.write(f"land_status={status}\n")
        out.write(f"ios_status={ios[0]}\n")
        out.write(f"ios_status_description={ios[1]}\n")
        out.write(f"ui_status={ui[0]}\n")
        out.write(f"ui_status_description={ui[1]}\n")
        out.write(f"preflight_web={'true' if preflight[0] else 'false'}\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = ["### pr router", "",
             f"changed files: {len(files) if files is not None else 'unknown'}", "",
             f"compile preflight web job: {'runs' if preflight[0] else 'skips'} ({preflight[1]})", "",
             "| workflow | starts | why |", "|---|---|---|"]
    lines += [f"| `{name}` | {'yes' if name in start else 'no'} | {reason} |" for name, reason in sorted(why.items())]
    text = "\n".join(lines) + "\n"
    print(text)
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(text)


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else ""
    callees = load_manifest()
    if mode == "route":
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        files = changed_files()
        decided, facts = head_tier.decide_with_facts("pull_request", event)
        carried, rows = plan_for(decided, facts, callees)
        start, why = route(event, callees, files, decided=decided, land_update=land_update_head(event, callees),
                           carried=carried)
        labels = head_tier.labels_of(event)
        full = decided[0] == "full" or FULL_CI in labels
        table = [job for job in table_jobs_routed(callees, files, full=full,
                                                  full_ci=full_ci_kept(event),
                                                  tier=pipeline_tier(labels)) if job not in rows]
        table, only = nightly_gate_table(callees, files, decided, start, table)
        if rows:
            why["pr-pipeline.yml"] = why.get("pr-pipeline.yml", "") + (
                f" (table jobs that ran green at the previous head stay off: {', '.join(sorted(rows))})")
        status = land_status(event, decided)
        # A rerun of the red-head base merge rule leaves the land tier to come (pending); the full-ci base merge carry
        # rule's rerun is the land tier itself, on the label land pulsed, so it keeps success (else land pulses again).
        held = (carried or rows) and not head_tier.full_rerun(decided)
        status = "pending" if status and held else status
        write_outputs(start, why, files, table, status, ios_status(event, files, start, status),
                      ui_status(event, files), only, preflight_web(event, callees, files))
        return 0
    if mode == "check":
        problems = check(callees, ENTRY.read_text(), ENTRY.parent)
        for p in problems:
            print(p, file=sys.stderr)
        print(f"pr router: {len(callees)} callees, {len(problems)} problems")
        return 1 if problems else 0
    if mode == "explain":
        files = argv[2:]
        start, why = route({"action": "synchronize", "pull_request": {}}, callees, files)
        for name, reason in sorted(why.items()):
            print(f"{'START' if name in start else 'skip '} {name}: {reason}")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

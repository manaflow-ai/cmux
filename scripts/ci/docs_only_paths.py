#!/usr/bin/env python3
"""The one `paths:` block that keeps a docs-only pull request from starting CI it can't affect.

A pull request that changes only prose (CLAUDE.md, a plan, a design note) used to start about 28 workflows and 180-275
jobs on feat-cmux-next: guards, routers, size and tab-switch budgets, Rust planners and their gates, each of which
reads no Markdown. Leo, 2026-11-19: "I kept saying, skip CI, skip it ... when it's unnecessary ... We need to skip
more often."

DOCS_ONLY_PATHS is that block: every path, then Markdown and docs images taken out, then the prose that code, a build
or a test reads put back after the excludes (it is `paths:` with `!`, not `paths-ignore:`, so a file can be put back;
GitHub lets the last matching pattern win). A workflow in WORKFLOWS carries it as its `on.pull_request.paths`,
between the BEGIN and END marker comments; `--sync` rewrites every copy from this file and `--check` fails on drift.
Push, schedule and workflow_dispatch triggers are never filtered.

GitHub matches `paths:` against only a pull request's first 300 changed files, and filters label events too. FALLBACK
(.github/workflows/docs-only-fallback.yml, written by `--sync`) is the one unfiltered workflow that covers both: its
gate runs on every push of a pull request (and on a `full-ci`/`dev-build` label), and calls each workflow of
WORKFLOWS (each also has `workflow_call:`) that should have started and shows no run at the head, or whose run of this
event never started: completed `failure`/`startup_failure` with zero jobs (cmux#56364). It fails open.

tests/test_ci_docs_only_prs.py is the detector: a docs-only pull request starts only the workflows its ALLOWED table
names (the required checks, which must always start, and the cheap policy and merge-contract checks, each with its
reason); every file a Rust `include_str!`/`include_bytes!` compiles in is put back; every copy matches. The inputs of
the tests a filtered workflow runs are checked by tests/test_ci_workflow_paths_cover_inputs.py, as for any filter.

    python3 scripts/ci/docs_only_paths.py --sync            # rewrite every workflow's block from DOCS_ONLY_PATHS
    python3 scripts/ci/docs_only_paths.py --check           # exit 1 when a copy drifted
    python3 scripts/ci/docs_only_paths.py FILE...           # docs-only=true|false for a changed-file list
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_paths_cover_inputs as filters  # noqa: E402  (GitHub's paths glob, the one implementation)

ROOT = Path(__file__).resolve().parents[2]

# Docs images: under the prose trees only (an image elsewhere may be an asset or a test baseline).
_IMAGES = ("png", "jpg", "gif", "webp")

DOCS_ONLY_PATHS: tuple[str, ...] = (
    "**",
    "!**/*.md",
    *(f"!{tree}/**/*.{ext}" for tree in ("docs", "plans") for ext in _IMAGES),
    # Prose that agents, bots or the product read as instructions or data, never docs-only.
    "**/AGENTS.md",
    "**/CLAUDE.md",
    "**/SKILL.md",
    ".github/**",
    "**/skills/**",
    "**/references/**",
    "**/templates/**",
    "**/Resources/**",
    "**/fixtures/**",
    "**/testdata/**",
    "**/test/**",
    "**/tests/**",
    "CHANGELOG.md",
    "THIRD_PARTY_LICENSES.md",
    "release-notes/**",
    # Read by a check or a workflow (scripts/check-agent-hook-docs.py, workflow paths lists, generated-doc drift).
    "docs/agent-hooks.md",
    "docs/chief-setup-prompts.md",
    "docs/configuration.md",
    "docs/ci/node-product-cache-maintenance.md",
    # Generated (scripts/cmux-next/generated_outputs.py OUTPUTS): cmux-next-pr-autofix's drift check reads a hand edit.
    "plans/cmux-next/actions.md",
    "docs/mdm/managed-preferences.md",
    "cmux-tui/crates/cmux-app-host/generated/REFERENCE.md",
    # Read by a ci-guards group test (test_no_guard_group_test_reads_docs lists any new one).
    "docs/ci/health-report.md",  # tests/test_ci_health_report.py
    "docs/privacy.md",  # tests/test_outbound_hosts.py
    "docs/network-requirements.md",  # tests/test_network_allowlist.py
    "**/notices/**",  # third-party notice inputs (hand-written.md, REVIEW.md) that the bundle and release tests read
    "vendor/stack-auth-swift-sdk-prerelease/README.cmux.md",  # tests/test_supplychain_security.py
    "cmux-tui/README.md",  # the Testbox tour named its public fallback here
    # Compiled in by include_str! (the detector lists any new one).
    "docs/remote-agents-and-cloud.md",
    "docs/cmux-next/customize-recipes.md",
    "cmux-tui/crates/acpmux/README.md",
    "cmux-tui/crates/acpmux/docs/**",
    "cmux-tui/crates/cmux-browser-host/js/guide.md",
    "cmux-tui/crates/cmux-extension-sdk/README.md",
    "cmux-tui/vendor/terminput-crossterm/README.md",
    "mux/packages/brain/conformance/README.md",
    "Native/OptChat/chief-kernel/src/turn_checks.md",
)

# The workflows whose pull_request trigger carries DOCS_ONLY_PATHS. None is a required check: a required check that
# never starts stays "Expected" and blocks the merge (main: CLA Assistant, CLA policy guard, backend migrations
# applied; feat-cmux-next: cmux-tui-spec's clippy, React Doctor).
WORKFLOWS: tuple[str, ...] = (
    ".github/workflows/ci.yml",
    ".github/workflows/cmux-next-guards.yml",
    ".github/workflows/cmux-next-pr-autofix.yml",
    ".github/workflows/pr-checks.yml",
    ".github/workflows/rust-workspaces.yml",
    ".github/workflows/web-validation.yml",
)

BEGIN = "# docs-only paths: BEGIN (scripts/ci/docs_only_paths.py --sync writes this block; edit DOCS_ONLY_PATHS there)"
END = "# docs-only paths: END"


TRIGGER_PATHS = "scripts/ci/pr-trigger-paths.json"


def block_workflows(root: Path) -> list[str]:
    """WORKFLOWS that carry the block. A workflow whose trigger `paths:` scripts/ci/pr_trigger_paths.py derives from
    its own decider (TRIGGER_PATHS `derived`) starts on its inputs alone, already fewer paths than the block; it
    keeps those, and FALLBACK still calls it."""
    try:
        derived = set(json.loads((root / TRIGGER_PATHS).read_text(encoding="utf-8")).get("derived", {}))
    except FileNotFoundError:
        derived = set()
    return [name for name in WORKFLOWS if name not in derived]


def is_docs(path: str) -> bool:
    """Whether a change to `path` alone starts none of WORKFLOWS on a pull request."""
    return not filters.admits("paths", list(DOCS_ONLY_PATHS), path)


def docs_only(paths: list[str]) -> bool:
    """Whether every changed path is docs. An empty list is not docs-only (GitHub starts every workflow then)."""
    return bool(paths) and all(is_docs(p) for p in paths)


def block(indent: str) -> list[str]:
    """The block as it sits under `pull_request:`, `indent` being the `paths:` key's indentation."""
    lines = [f"{indent}{BEGIN}", f"{indent}paths:"]
    lines += [f'{indent}  - "{pattern}"' for pattern in DOCS_ONLY_PATHS]
    lines.append(f"{indent}{END}")
    return lines


def rewrite(text: str, name: str) -> str:
    """The workflow's text with its marked block rewritten, or ValueError when it has no single marked block."""
    lines = text.split("\n")
    starts = [i for i, line in enumerate(lines) if line.strip() == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.strip() == END]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        raise ValueError(f"{name}: needs exactly one docs-only paths block between its BEGIN and END markers")
    start, end = starts[0], ends[0]
    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
    return "\n".join(lines[:start] + block(indent) + lines[end + 1:])


# ------------------------------------------------------------------------------------------------ the fallback
# GitHub matches a pull request's `paths:` against only the first 300 changed files: a pull request whose first 300
# files are prose and whose 301st is code starts none of WORKFLOWS. Their `paths:` also filters label events, so
# adding `full-ci` or `dev-build` to a docs-only pull request started no CI. FALLBACK is one unfiltered workflow whose
# gate job (no runner unless one of those can have happened) lists the changed files and the runs at the head through
# the API and calls, as a reusable workflow in the same pull_request context, each of WORKFLOWS that should have
# started and did not. Whatever it cannot read, it calls (fails open to full CI).
#
# A run GitHub created and never started counts as missing too. On cmux#56364 (head 40124f05, 2026-11-26 02:41:09Z)
# ci.yml, cmux-next-guards.yml and pr-router.yml each ended `failure` with zero jobs and no logs at the moment they
# were created; ci-web.yml, which ci.yml starts, never ran, so the head had no webview verdict and nothing said so.
# The gate now runs on every push, reads the jobs of each run of this event that ended failure, and calls the
# callable ones of zero jobs; it names every zero-job run (callable or not, pr-router.yml is not) as an error
# annotation. Only a settled zero-job run is missing: a queued or running run, or one whose jobs it could not read,
# may still run its suites, so the gate waits for it (ZERO_JOB_WAIT_SECONDS) and then names it, never calls it.
FALLBACK = ".github/workflows/docs-only-fallback.yml"
PATHS_FILTER_LIMIT = 300  # GitHub evaluates path filters against this many changed files
FILES_API_LIMIT = 3000  # pulls/{n}/files lists at most this many
LABEL_OPT_INS = ("full-ci", "dev-build")  # ci.yml's labels that ask for CI on a pull request nothing else starts
DEFAULT_TYPES = ("opened", "synchronize", "reopened")
LABEL_ACTIONS = ("labeled", "unlabeled")
# Events the fallback does not listen for. `edited` re-runs only the description checks (pr-checks' PR size, the size
# budget's `size:` line) at a head its push already covered; listening would start a run for every title or HOLD-line
# edit of every pull request (tests/test_ci_pr_runs_cancel_superseded.py, pattern pr-edit-fans-out-ci).
UNCOVERED_TYPES = ("edited",)
PUSH_ACTIONS = DEFAULT_TYPES  # a push's run supersedes the pull request's older one; any other event runs on its own
# A run of a label event is created with the event; the gate's own run is created at the same moment.
SAME_EVENT_SLACK_SECONDS = 120
NEVER_STARTED = ("failure", "startup_failure")  # a run GitHub created and never started ends one of these, zero jobs
ZERO_JOB_WAIT_SECONDS = 120  # how long the gate waits for a run of this event that has no jobs yet to settle
ZERO_JOB_POLL_SECONDS = 20


def pull_request_config(root: Path, name: str) -> dict:
    """{"branches": [...] | None, "types": [...]} of a workflow's pull_request trigger (PyYAML; --sync only)."""
    config = filters.triggers(filters.load_yaml(root / name)).get("pull_request")
    config = config if isinstance(config, dict) else {}
    branches = config.get("branches")
    return {"branches": [str(b) for b in branches] if branches else None,
            "types": [str(t) for t in (config.get("types") or DEFAULT_TYPES)]}


def call_permissions(root: Path, name: str) -> dict[str, str]:
    """The highest level of each scope the workflow (or a job of it) asks for: what its caller job must grant."""
    import check_reusable_workflow_permissions as perms  # noqa: PLC0415

    path = root / name
    requests = perms.callee_requests(perms.parse_workflow(path), path.name)
    return {r.scope: perms.LEVEL_NAMES[r.level] for r in requests if perms.LEVEL_NAMES[r.level] != "none"}


def job_id(name: str) -> str:
    return Path(name).stem


# ci.yml's labels: the opt-ins plus the land handoff (scripts/ci/head_tier.py land rule). A docs-only pull request
# runs no CI tier, so the fallback does not start ci.yml on `ready-to-land`.
CI_LABELS = LABEL_OPT_INS + ("ready-to-land",)


def label_guard(labels_read: tuple[str, ...] = LABEL_OPT_INS) -> str:
    """A label guard: into feat-cmux-next, adding any label not in LABELS_READ, or removing any label, skips
    (test_ci_label_events_skip_full_ci; removing a coverage label asks for less than the head's run did, cmux#58222).
    The fallback's reads LABEL_OPT_INS, ci.yml's CI_LABELS."""
    labels = json.dumps(list(labels_read), separators=(",", ":"))
    return ("!(github.event_name == 'pull_request' && github.event.pull_request.base.ref == 'feat-cmux-next' && "
            f"(github.event.action == 'labeled' && !contains(fromJSON('{labels}'), github.event.label.name) || "
            "github.event.action == 'unlabeled'))")


def gate_condition() -> str:
    """Every push or review-ready event (a sibling run of it may never start, at any size), a CI label, and an unlabel
    of one over the 300-file limit; any other label event skips with no runner."""
    labels = json.dumps(list(LABEL_OPT_INS), separators=(",", ":"))
    over = f"github.event.pull_request.changed_files > {PATHS_FILTER_LIMIT}"
    return ("${{ ((github.event.action != 'labeled' && github.event.action != 'unlabeled') || "
            f"(contains(fromJSON('{labels}'), github.event.label.name) && (github.event.action == 'labeled' || "
            + over + "))) && " + label_guard() + " }}")


# Why a call grants a scope, written above it (workflow, scope): note.
CALL_GRANT_NOTES = {
    (".github/workflows/ci.yml", "statuses"): "ci.yml's changes job: head_tier.py's land carry rule reads cmux/land-tier.",
}


def render_fallback(root: Path) -> str:
    """FALLBACK's text, written by --sync from WORKFLOWS (their triggers and permissions)."""
    configs = {job_id(n) + ".yml": pull_request_config(root, n) for n in WORKFLOWS}
    types: list[str] = []
    for config in configs.values():
        types += [t for t in config["types"] if t not in types and t not in UNCOVERED_TYPES]
    order = [*DEFAULT_TYPES, *LABEL_ACTIONS, "ready_for_review", "edited", "closed"]
    types.sort(key=lambda t: order.index(t) if t in order else len(order))
    calls = json.dumps(configs, separators=(",", ":"), sort_keys=True)
    out = f"""# Written by scripts/ci/docs_only_paths.py --sync from its WORKFLOWS; edit that file, not this one.
name: docs-only fallback

# The workflows in scripts/ci/docs_only_paths.py WORKFLOWS carry the docs-only `paths:` block, and GitHub matches a
# pull request's `paths:` against only its first {PATHS_FILTER_LIMIT} changed files: a pull request of {PATHS_FILTER_LIMIT} prose files and one
# code file could start none of them. Their filter also filters label events, so `full-ci` or `dev-build` on a
# docs-only pull request started nothing. And GitHub can create a run that never starts: on cmux#56364 ci.yml ended
# `failure` with zero jobs, so ci-web.yml never ran. The gate (one small Linux job) runs on every push and on those
# labels; any other label event skips it with no runner. It lists the changed files and the head's runs through the
# API and calls, in this pull_request's own context, each workflow that should have started and shows no run or only a
# settled zero-job run of this event, and names every zero-job run; whatever it cannot read, it calls, except a run it
# cannot tell never started, which it names (tests/test_ci_docs_only_prs.py).
#
# A call passes no secrets: a called step that reads one gets an empty value, as on a fork's pull request. Signing, R2 cache writes
# and media publishing stay inside the protected environments of the workflows that own them.
on:
  pull_request:
    types: [{", ".join(types)}]

permissions: {{}}

# A push supersedes the pull request's older run (and its calls, which tested an older head). Any other event runs in a
# group of its own, so a label, review-ready or close event never cancels a push's calls in flight.
concurrency:
  group: docs-only-fallback-${{{{ github.event.pull_request.number }}}}${{{{ !contains(fromJSON('{json.dumps(list(PUSH_ACTIONS), separators=(",", ":"))}'), github.event.action) && format('-{{0}}-{{1}}', github.event.action, github.run_id) || '' }}}}${{{{ {label_guard()[2:-1]} && format('-label-{{0}}', github.run_id) || '' }}}}
  cancel-in-progress: true

jobs:
  gate:
    name: docs-only fallback gate
    # Into feat-cmux-next a label event for any other label skips with no runner
    # (tests/test_ci_label_events_skip_full_ci.py).
    if: {gate_condition()}
    runs-on: ${{{{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'ubuntu-24.04' || 'cmux-linux' }}}}
    timeout-minutes: 5
    permissions:
      actions: read
      contents: read
      pull-requests: read
    outputs:
      missing: ${{{{ steps.plan.outputs.missing }}}}
    steps:
      - name: Checkout the planner
        uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
          # The merge commit and its parents' trees: merge_files() and merge_commit_files() list the changed paths
          # with git, no API call.
          fetch-depth: 2
          filter: blob:none
          sparse-checkout: |
            scripts/ci/docs_only_paths.py
            scripts/ci/workflow_paths_cover_inputs.py
            scripts/ci/gh_expressions.py
            scripts/ci/deadline_http.py
            scripts/ci/check_reusable_workflow_permissions.py
            .gitmodules
          sparse-checkout-cone-mode: false
      - name: List the workflows that should have started and did not
        id: plan
        env:
          GH_TOKEN: ${{{{ github.token }}}}
          REPOSITORY: ${{{{ github.repository }}}}
          CALLS: '{calls}'
        run: python3 scripts/ci/docs_only_paths.py --fallback-plan
"""
    for name in WORKFLOWS:
        job = job_id(name)
        grant = call_permissions(root, name)
        lines = [line for scope, level in sorted(grant.items())
                 for line in ([f"      # {CALL_GRANT_NOTES[(name, scope)]}"] if (name, scope) in CALL_GRANT_NOTES else [])
                 + [f"      {scope}: {level}"]]
        permissions = "\n" + "\n".join(lines) if lines else " {}"
        out += f"""
  {job}:
    name: {job} (fallback)
    needs: gate
    if: ${{{{ contains(fromJSON(needs.gate.outputs.missing || '[]'), '{job}.yml') }}}}
    uses: ./{name}
    permissions:{permissions}
"""
    return out


def plan_fallback(event: dict, calls: dict, files: list[str] | None, runs: list[dict] | None,
                  since: float | None) -> list[str]:
    """The workflows (file names) FALLBACK calls for this pull_request event.

    `files` is every changed path, or None when the API could not list them all; `runs` is the head's pull_request
    runs ({"path", "created": epoch seconds, "status", "conclusion", "jobs": count or None when unread}), or None
    when unread; `since` is when this event's runs were created. A run of this event that never started (never_started)
    does not count as a run: the workflow is called when nothing else of its shows a start.
    """
    pr = event.get("pull_request") or {}
    action = str(event.get("action") or "")
    base = str((pr.get("base") or {}).get("ref") or "")
    label = str((event.get("label") or {}).get("name") or "")
    due = [name for name, config in sorted(calls.items())
           if action in config["types"]
           and (config["branches"] is None or filters.admits("paths", config["branches"], base))]
    asked = action == "labeled" and label in LABEL_OPT_INS
    if files is not None and docs_only(files):
        # Every filter skipped, as it should: only a label asking for CI runs what listens for it.
        return due if asked else []
    seen_all = files is not None and len(files) <= PATHS_FILTER_LIMIT
    if seen_all and runs is None:
        return []  # GitHub saw every file, and one is not docs: each due workflow started on its own.
    if runs is None:
        return due
    label_event = action in LABEL_ACTIONS
    this_event = [run for run in runs if since is None
                  or float(run.get("created") or 0) >= since - SAME_EVENT_SLACK_SECONDS]
    dead = {_name(run) for run in this_event if never_started(run)}
    started = {_name(run) for run in (this_event if label_event else runs) if not never_started(run)}
    if seen_all:
        # Each due workflow started on its own; call only one whose run of this event never started.
        return [name for name in due if name in dead and name not in started]
    return [name for name in due if name not in started]


def merge_files(head_sha: str, root: Path = Path(".")) -> list[str] | None:
    """The files the pull request's merge commit (the gate's checkout, fetch-depth 2) changes against its base parent,
    or None when the checkout is not that commit's merge of HEAD_SHA (a stale or missing merge ref) or git fails.

    No REST call: the gate's pulls/{n}/files and actions/runs reads answered 403 on every one of the 61 gates of
    2026-11-24T09Z..11-25T09Z that called a workflow (the repository's GITHUB_TOKEN budget was spent), and each then
    called every due workflow, so a `full-ci` label on a pull request of 17 to 26 files ran ci.yml twice for one head
    (1.6k runner-minutes that day). The merge's own change is a subset of the pull request's three-dot diff (a merge
    differs from its base parent only where the head side changed a file), so a code file here is a code file GitHub's
    `paths:` saw; an all-docs list proves nothing and the caller reads the API as before.
    """
    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=True,
                              timeout=60).stdout
    try:
        if git("rev-parse", "HEAD^2").strip() != head_sha:
            return None
        return [line for line in git("diff", "--no-renames", "--name-only", "HEAD^1", "HEAD").splitlines() if line]
    except (OSError, subprocess.SubprocessError):
        return None


def _name(run: dict) -> str:
    return Path(str(run.get("path") or "")).name


def never_started(run: dict) -> bool:
    """A run GitHub created and never started: completed, failure or startup_failure, and zero jobs read. A queued or
    running run, or one whose jobs were not read (jobs None), may still run its suites: not this."""
    return (run.get("status") == "completed" and run.get("conclusion") in NEVER_STARTED
            and run.get("jobs") == 0)


def unsettled(run: dict) -> bool:
    """A run of this event the gate cannot call yet: no job read and not settled, or a failed one whose jobs it could
    not read. It may still start; the gate waits for it, then names it."""
    if run.get("status") == "completed":
        return run.get("conclusion") in NEVER_STARTED and run.get("jobs") is None
    return not run.get("jobs")


def zero_job_report(runs: list[dict] | None, since: float | None, missing: list[str]) -> list[str]:
    """One line per run of this event that never started or may not have: the gate prints each as an error."""
    if runs is None:
        return []
    lines = []
    for run in runs:
        if since is not None and float(run.get("created") or 0) < since - SAME_EVENT_SLACK_SECONDS:
            continue
        name, ident = _name(run), run.get("id", "?")
        if never_started(run):
            fate = "called here" if name in missing else "not callable here: rerun it"
            lines.append(f"{name} run {ident} ended {run.get('conclusion')} with zero jobs, never started; {fate}")
        elif unsettled(run):
            lines.append(f"{name} run {ident} is {run.get('status')} with "
                         f"{'unread' if run.get('jobs') is None else 'zero'} jobs; not called (it may still start)")
    return lines


def _api(path: str) -> object:
    request = urllib.request.Request(f"https://api.github.com{path}", headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    import deadline_http  # noqa: PLC0415 - the gate's sparse checkout has it; --sync never calls this

    _status, body, _headers = deadline_http.request(request, 30, raise_errors=True)
    return json.loads(body)


def _epoch(stamp: str) -> float:
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def merge_commit_files(total: int) -> list[str] | None:
    """Every path the checked-out merge commit changes against its first parent (the base tip), both sides of a rename,
    from git alone: the gate checks out the pull request's merge commit with its parent (fetch-depth 2). It answers
    when the REST budget is spent. On 2026-11-25 19:14Z the files and runs reads both got 403, the gate failed open
    and called ci.yml on a 2-file pull request that ci.yml was already running (run 45682654194): about 300 runner-min
    for one label. ci.yml's fallback calls were 8,083 runner-min over 11-24 22Z..11-25 22Z. None when git cannot say,
    or lists fewer paths than the pull request's changed_files (TOTAL), which the caller treats as unread."""
    try:
        done = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", "HEAD^1", "HEAD"],
                              capture_output=True, text=True, timeout=60, check=True)
    except (OSError, subprocess.SubprocessError):
        return None
    names = [name for name in done.stdout.split("\0") if name]
    return names if names and len(set(names)) >= total else None


def read_runs(repo: str, sha: str, own: str, since: float) -> list[dict]:
    """The head's pull_request runs but the gate's own, with the job count of each run that ended failure (of any
    event) or of this event (created since SINCE) that has not started a job (queued): a completed failure with zero
    jobs never started, a queued one with zero has not yet. An in_progress run has a job running and a green one ran, so neither is read:
    a push reads a few jobs lists, not one per run. A job read that fails leaves jobs None (unread), which never calls."""
    found: list[dict] = []
    for page in range(1, 6):
        batch = _api(f"/repos/{repo}/actions/runs?head_sha={sha}&event=pull_request&per_page=100&page={page}")
        for run in batch["workflow_runs"]:
            if str(run["id"]) == own:
                continue
            entry = {"id": run["id"], "path": str(run["path"]).split("@")[0], "created": _epoch(run["created_at"]),
                     "status": run.get("status"), "conclusion": run.get("conclusion")}
            this_event = entry["created"] >= since - SAME_EVENT_SLACK_SECONDS
            if run.get("status") == "in_progress":
                entry["jobs"] = 1  # a job is running
            elif (this_event and run.get("status") != "completed") or (
                    run.get("status") == "completed" and run.get("conclusion") in NEVER_STARTED):
                # Any event's failed run is read: an earlier event's zero-job failure left unread would count as
                # started and keep this event's zero-job run of the same workflow from being called (a reopen).
                try:
                    entry["jobs"] = int(_api(f"/repos/{repo}/actions/runs/{run['id']}/jobs?per_page=1")["total_count"])
                except Exception as error:  # noqa: BLE001 - unread: named, never called
                    print(f"could not read run {run['id']}'s jobs ({error})", file=sys.stderr)
                    entry["jobs"] = None
            found.append(entry)
        if len(batch["workflow_runs"]) < 100:
            break
    return found


def fallback_main() -> int:
    """--fallback-plan, in the gate job: writes missing=<JSON list> to $GITHUB_OUTPUT. Any read that fails counts as
    unread, which calls more, never fewer."""
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    calls = json.loads(os.environ["CALLS"])
    repo = os.environ["REPOSITORY"]
    pr = event["pull_request"]
    files: list[str] | None = None
    runs: list[dict] | None = None
    since: float | None = None
    total = int(pr.get("changed_files") or 0)
    if 0 < total <= PATHS_FILTER_LIMIT:
        merged = merge_files(str((pr.get("head") or {}).get("sha") or ""))
        if merged and not docs_only(merged):
            # GitHub's filter saw every file and one is code: each due workflow started on its own (plan_fallback).
            missing = plan_fallback(event, calls, merged, [], None)
            print(f"changed files: {total} (from the merge commit, not docs-only); calling: {missing or 'none'}")
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
                out.write(f"missing={json.dumps(missing, separators=(',', ':'))}\n")
            return 0
    try:
        if 0 < total <= FILES_API_LIMIT:
            names: list[str] = []
            renamed_from: list[str] = []  # judged too: a rename out of code is not docs-only
            for page in range(1, FILES_API_LIMIT // 100 + 1):
                batch = _api(f"/repos/{repo}/pulls/{pr['number']}/files?per_page=100&page={page}")
                names += [str(item["filename"]) for item in batch]
                renamed_from += [str(item["previous_filename"]) for item in batch if item.get("previous_filename")]
                if len(batch) < 100:
                    break
            if len(set(names)) >= total:
                files = names + renamed_from
    except Exception as error:  # noqa: BLE001 - fail open
        print(f"could not list the changed files ({error}): reading them from the merge commit", file=sys.stderr)
    if files is None and 0 < total <= FILES_API_LIMIT:
        files = merge_commit_files(total)
        if files is None:
            print("could not read the merge commit's files either: calling every due workflow", file=sys.stderr)
    own = os.environ["GITHUB_RUN_ID"]
    deadline = time.monotonic() + ZERO_JOB_WAIT_SECONDS
    while True:
        try:
            since = _epoch(_api(f"/repos/{repo}/actions/runs/{own}")["created_at"])
            runs = read_runs(repo, pr["head"]["sha"], own, since)
        except Exception as error:  # noqa: BLE001 - fail open
            print(f"could not read the head's runs ({error}): calling every due workflow", file=sys.stderr)
            runs, since = None, None
        waiting = [] if runs is None else [run for run in runs if unsettled(run) and (
            since is None or float(run.get("created") or 0) >= since - SAME_EVENT_SLACK_SECONDS)]
        if not waiting or time.monotonic() >= deadline:
            break
        print(f"waiting for {len(waiting)} run(s) of this event with no jobs yet: "
              f"{', '.join(_name(run) for run in waiting)}", file=sys.stderr)
        time.sleep(ZERO_JOB_POLL_SECONDS)
    missing = plan_fallback(event, calls, files, runs, since)
    for line in zero_job_report(runs, since, missing):
        print(f"::error title=a run that never started::{line}")
    print(f"changed files: {total} ({'listed' if files is not None else 'not listed'}); calling: {missing or 'none'}")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        out.write(f"missing={json.dumps(missing, separators=(',', ':'))}\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--sync", action="store_true", help="rewrite each workflow's block and the fallback")
    mode.add_argument("--check", action="store_true", help="exit 1 when a workflow's block or the fallback drifted")
    mode.add_argument("--fallback-plan", action="store_true", help="the fallback gate (GitHub Actions only)")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("files", nargs="*", help="changed files: print docs-only=true|false")
    args = parser.parse_args(argv)
    if args.fallback_plan:
        return fallback_main()
    if not (args.sync or args.check):
        print(f"docs-only={'true' if docs_only(args.files) else 'false'}")
        return 0
    drifted = []
    fallback = args.root / FALLBACK
    rendered = render_fallback(args.root)
    if not fallback.is_file() or fallback.read_text() != rendered:
        if args.sync:
            fallback.write_text(rendered)
            print(f"rewrote {FALLBACK}")
        else:
            drifted.append(FALLBACK)
    for name in block_workflows(args.root):
        path = args.root / name
        text = path.read_text()
        try:
            new = rewrite(text, name)
        except ValueError as error:
            print(error, file=sys.stderr)
            drifted.append(name)
            continue
        if new != text:
            if args.sync:
                path.write_text(new)
                print(f"rewrote {name}")
            else:
                drifted.append(name)
    for name in drifted if args.check else ():
        what = "differs from what WORKFLOWS give it" if name == FALLBACK else \
            "has a docs-only paths block that differs from DOCS_ONLY_PATHS"
        print(f"{name} {what}; run python3 scripts/ci/docs_only_paths.py --sync", file=sys.stderr)
    return 1 if drifted else 0


if __name__ == "__main__":
    raise SystemExit(main())

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
  labels     labels whose `labeled` event starts it whatever the paths (full-ci always does);
  draft      true for a workflow that also runs on a draft head (scripts/ci/head_tier.py's cheap tier);
             any other callee starts on a draft only with full-ci, and runs when the PR is marked ready
             for review, so every callee must listen to `ready_for_review` (`check` says so).
A `full-ci` label on the pull request starts every callee its types allow.

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
# The step table's jobs that run only on a full-tier head (head_tier.py): a draft, or a base merge into an idle pull
# request, routes them nowhere, as cmux-next.yml's path_route turned every Mac tier off for one.
FULL_TIER_JOBS = ("mac",)
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


def table_steps(config: dict, files: list[str], table: Path | None = None, full: bool = True) -> list[str] | None:
    """The steps of the callee's `table_jobs` this change routes; None when the table cannot be read. FULL: the head
    is in the full tier (else FULL_TIER_JOBS route nothing)."""
    # Any failure to read the table (a missing file, bad TOML, a wrong shape, a runner that does not import)
    # starts the pipeline, whose own run reports it: the router routes more, never less, and never fails on it.
    try:
        routed = ci_steps.route(ci_steps.load(table or ci_steps.TABLE), files)
    except Exception:  # noqa: BLE001
        return None
    steps = [step for job in config["table_jobs"] if full or job not in FULL_TIER_JOBS for step in routed.get(job, [])]
    # A step whose inputs are `["**"]` replaced a job that ran on every change its workflow's shared docs-only
    # filter let through (scripts/ci/docs_only_paths.py): a docs-only change alone does not start the pipeline for it.
    if files and docs_only_paths.docs_only(files):
        table = ci_steps.load(table or ci_steps.TABLE).steps
        steps = [step for step in steps if table[step].inputs != ("**",)]
    return steps


def table_jobs_routed(callees: dict, files: list[str] | None, table: Path | None = None,
                      full: bool = True) -> list[str]:
    """Which of the step table's jobs the change routes, for pr-pipeline.yml's job `if:`s: every `table_jobs` job
    when the change or the table is unknown (the router routes more, never less). FULL: the head is in the full
    tier; else no job of FULL_TIER_JOBS."""
    jobs = [job for config in callees.values() for job in config.get("table_jobs", [])
            if full or job not in FULL_TIER_JOBS]
    if files is None:
        return jobs
    try:
        routed = ci_steps.route(ci_steps.load(table or ci_steps.TABLE), files)
    except Exception:  # noqa: BLE001
        return jobs
    return [job for job in jobs if routed.get(job)]


def route(event: dict, callees: dict, files: list[str] | None,
          draft_switch: str = "1", decided: tuple[str, str] | None = None) -> tuple[list[str], dict[str, str]]:
    """(the callee files to start, a reason per callee) for one pull_request event. DECIDED: head_tier's
    (tier, reason) when the caller read the head's facts (route mode); else the draft rule alone."""
    tier, tier_reason = decided or head_tier.tier("pull_request", event, draft_switch)
    cheap = tier == "cheap"
    # Fast-track (scripts/ci/fast_track.py): a docs, plans, skills, copy or tests-only change gets the cheap tier.
    fast = False
    if not cheap and tier != "none" and files is not None and fast_track.enabled():
        fast, fast_reason = fast_track.classify(files)
        cheap = fast
    action = str(event.get("action") or "")
    pr = event.get("pull_request") or {}
    labels = {str(label.get("name") or "") for label in pr.get("labels") or []}
    added = str((event.get("label") or {}).get("name") or "") if action == "labeled" else ""
    if added == head_tier.LAND_LABEL:
        # The land handoff (head_tier's land rule): the same head now runs the full tier, as when a draft is marked
        # ready, so every callee that skips a cheap head starts on it (each listens to ready_for_review).
        action, added = "ready_for_review", ""
    start, why = [], {}
    for name, config in sorted(callees.items()):
        if action not in config["types"]:
            why[name] = f"does not listen to '{action}'"
            continue
        if added and (added == FULL_CI or added in config.get("labels", [])):
            start.append(name)
            why[name] = f"label '{added}' added"
            continue
        if FULL_CI in labels:
            start.append(name)
            why[name] = "full-ci"
            continue
        if tier == "none":
            why[name] = tier_reason
            continue
        if cheap and fast and not config.get("draft"):
            why[name] = "fast-track: runs after the merge (post-merge batch and push runs)"
            continue
        if cheap and not config.get("draft"):
            why[name] = ("draft: starts when marked ready for review (or with full-ci)" if pr.get("draft") is not False
                         else tier_reason)
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
            steps = table_steps(config, files, full=tier == "full" or FULL_CI in labels)
            if steps == []:
                why[name] = "the change routes no step of " + ", ".join(config["table_jobs"])
                continue
            start.append(name)
            why[name] = "the step table could not be read: starts" if steps is None else "routes " + ", ".join(steps)
            continue
        start.append(name)
        why[name] = "a changed file reaches it"
    return start, why


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
    it on the cheap tier (or idle), `success` once it runs the full tier, empty where the land rule does not apply."""
    if (os.environ.get("CI_LAND_TIER", "1").strip() in ("0", "")) or not head_tier.land_rule_applies(event):
        return ""
    return "success" if decided[0] == "full" else "pending"


def write_outputs(start: list[str], why: dict[str, str], files: list[str] | None,
                  table: list[str] | None = None, status: str = "") -> None:
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        out.write(f"start={json.dumps(start, separators=(',', ':'))}\n")
        out.write(f"table={json.dumps(table or [], separators=(',', ':'))}\n")
        out.write(f"land_status={status}\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = ["### pr router", "",
             f"changed files: {len(files) if files is not None else 'unknown'}", "",
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
        decided = head_tier.decide("pull_request", event)
        start, why = route(event, callees, files, decided=decided)
        labels = {str(label.get("name") or "") for label in (event.get("pull_request") or {}).get("labels") or []}
        full = decided[0] == "full" or FULL_CI in labels
        write_outputs(start, why, files, table_jobs_routed(callees, files, full=full),
                      land_status(event, decided))
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

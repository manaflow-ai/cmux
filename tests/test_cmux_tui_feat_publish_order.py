#!/usr/bin/env python3
"""No cmux-tui tree publication waits for the daemon tests; promotion does.

On 2026-10-14 none of the last ~30 feat-cmux-next tips had a tree on
files.cmux.com. publish-tree's `if` already ignored the daemon-test result on
feat-cmux-next, but its `needs` still named cmux-next-daemon-tests, and a job
starts only after every job it needs has finished. A feat-cmux-next push's
daemon tests take one reserved runner for ~30 min while pushes land every 2-5
min, so 12 sat queued and no feat-cmux-next run reached its publish job. Every
DEV build and dev reload waits on these trees.

cx-y0nf2: every other ref that runs the daemon tests (a pin, next-batch/*,
main, an opted-in lane push, a same-repository pull request) publishes the
same way, with source.json daemonTests "separate". Before, those refs
published only after the tests passed, so a pin's tree waited ~1 h for the
macOS runner. Nightly-next promotion still needs the daemon-tests marker,
which only publish-tree-tested writes, after this run's tests of the key pass.

This evaluates each publishing job's `if` with GitHub's expression rules for
a feat-cmux-next push and for other refs, and walks its `needs`.
"""

import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")
DAEMON = "cmux-next-daemon-tests"
KEY = "8729cadfd262d8c13cad8f8ad5d7d54ca4984e01"
FAILURES = []


def _check(ok, message):
    print(("ok: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def jobs():
    with open(WORKFLOW, encoding="utf-8") as handle:
        return yaml.safe_load(handle)["jobs"]


def needs(job):
    value = job.get("needs", [])
    return [value] if isinstance(value, str) else list(value)


def all_needs(all_jobs, name):
    seen, stack = set(), list(needs(all_jobs[name]))
    while stack:
        current = stack.pop()
        if current not in seen:
            seen.add(current)
            stack.extend(needs(all_jobs[current]))
    return seen


def evaluate(expression, context):
    """GitHub's expression subset these `if`s use, translated to Python."""
    text = str(expression).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    strings = []

    def keep(match):
        strings.append(match.group(0))
        return f"__S{len(strings) - 1}__"

    text = re.sub(r"'[^']*'", keep, text)

    def lookup(match):
        return f"C({match.group(0)!r})"

    text = re.sub(r"\b(?:github|needs|inputs|vars|steps)(?:\.[A-Za-z0-9_-]+)+", lookup, text)
    text = text.replace("&&", " and ").replace("||", " or ")
    text = re.sub(r"!(?!=)", " not ", text)
    text = text.replace("startsWith(", "starts_with(").replace("contains(", "contains_(")
    for index, literal in enumerate(strings):
        text = text.replace(f"__S{index}__", literal)

    def C(path):
        if path not in context:
            raise KeyError(path)
        return context[path]

    scope = {
        "C": C,
        "starts_with": lambda value, prefix: str(value).startswith(prefix),
        "contains_": lambda haystack, needle: needle in haystack,
        "cancelled": lambda: False,
        "always": lambda: True,
        "success": lambda: True,
    }
    return bool(eval(" ".join(text.split()), {"__builtins__": {}}, scope))


def context(ref, event="push", daemon_tests="true", daemon_result="success"):
    values = {
        "github.event_name": event,
        "github.ref": ref,
        "github.repository": "manaflow-ai/cmux",
        "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux" if event == "pull_request_target" else "",
        "needs.tree-preflight.result": "success",
        "needs.tree-preflight.outputs.key": KEY,
        "needs.tree-preflight.outputs.daemon_tests": daemon_tests,
        "needs.tree-preflight.outputs.tree_ready": "false",
        "needs.build-ok.result": "success",
        "needs.publish.result": "success",
    }
    if daemon_result is not None:
        values[f"needs.{DAEMON}.result"] = daemon_result
        values[f"needs.{DAEMON}.outputs.key"] = KEY if daemon_result == "success" else ""
    return values


def publishers(all_jobs):
    return [name for name, job in all_jobs.items()
            if any(step.get("name", "").startswith("Publish the") and "trusted helper" in step.get("name", "")
                   for step in job.get("steps", []))]


def runs(all_jobs, name, values):
    """Whether the job starts with these results; a need it lacks is not finished."""
    job = all_jobs[name]
    if DAEMON in all_needs(all_jobs, name) and f"needs.{DAEMON}.result" not in values:
        return False
    try:
        return evaluate(job.get("if", "true"), values)
    except KeyError:
        return False


def main():
    all_jobs = jobs()
    tree_publishers = publishers(all_jobs)
    _check(bool(tree_publishers), f"some job publishes the tree ({tree_publishers})")

    # A feat-cmux-next push whose daemon tests are still queued: daemon_result None.
    for event in ("push", "workflow_dispatch"):
        feat = context("refs/heads/feat-cmux-next", event=event, daemon_result=None)
        starting = [name for name in tree_publishers if runs(all_jobs, name, feat)]
        _check(len(starting) == 1,
               f"a feat-cmux-next {event} publishes its tree while its daemon tests are still queued ({starting})")
        for name in starting:
            _check(DAEMON not in all_needs(all_jobs, name),
                   f"{name} does not wait for the daemon tests on feat-cmux-next")
        for result in ("failure", "cancelled", "success"):
            done = context("refs/heads/feat-cmux-next", event=event, daemon_result=result)
            starting = [name for name in tree_publishers if runs(all_jobs, name, done)]
            _check(len(starting) == 1, f"one feat-cmux-next {event} publisher, daemon tests {result} ({starting})")

    # Every other ref that runs the daemon tests publishes as soon as it is
    # built, whatever they do (cx-y0nf2), and no publisher writes the marker.
    tested_refs = [
        ("push", "refs/heads/cmux-tui-pin-0123456789ab"),
        ("push", "refs/heads/next-batch/abc"),
        ("push", "refs/heads/main"),
        ("push", "refs/heads/codex/opted-in-lane"),
        ("workflow_dispatch", "refs/heads/cmux-tui-pin-0123456789ab"),
        ("pull_request_target", "refs/heads/feat-cmux-next"),
    ]
    for event, ref in tested_refs:
        for result in (None, "failure", "cancelled", "skipped", "success"):
            values = context(ref, event=event, daemon_result=result)
            starting = [name for name in tree_publishers if runs(all_jobs, name, values)]
            _check(len(starting) == 1,
                   f"{event} {ref} publishes once with its daemon tests {result or 'queued'} ({starting})")
    for name in tree_publishers:
        _check(DAEMON not in all_needs(all_jobs, name), f"{name} does not need the daemon tests")
        _check("cmux-tui-mark-daemon-tested.sh" not in str(all_jobs[name]["steps"]),
               f"{name} never writes the daemon-tests marker")
        _check('"daemonTests": "separate"' in str(all_jobs[name]["steps"]),
               f"{name} publishes source.json with daemonTests separate")

    # A lane-branch push without the trailer publishes build-only: its daemon
    # test job is skipped, so nothing holds the publish.
    lane = context("refs/heads/codex/some-lane", daemon_tests="false", daemon_result="skipped")
    starting = [name for name in tree_publishers if runs(all_jobs, name, lane)]
    _check(len(starting) == 1, f"a lane-branch push publishes without the daemon tests ({starting})")

    # Promotion stays gated on the daemon-tests marker, written only after the tests pass.
    marker = all_jobs["publish-tree-tested"]
    _check(DAEMON in needs(marker) and f"needs.{DAEMON}.result == 'success'" in str(marker["if"]),
           "publish-tree-tested writes the marker only after the daemon tests pass")
    for ref, event in (("refs/heads/feat-cmux-next", "push"), ("refs/heads/cmux-tui-pin-0123456789ab", "push"),
                       ("refs/heads/feat-cmux-next", "pull_request_target")):
        base = context(ref, event=event, daemon_result="success")
        base.update({"needs.tree-owner-wait.outputs.unmarked": "false",
                     **{f"needs.{name}.result": "success" for name in tree_publishers}})
        _check(evaluate(marker["if"], base), f"{event} {ref}: the marker follows passing daemon tests of a published tree")
        for result in ("failure", "cancelled", "skipped"):
            failed = dict(base, **{f"needs.{DAEMON}.result": result})
            _check(not evaluate(marker["if"], failed), f"{event} {ref}: no marker when the daemon tests are {result}")
        other_key = dict(base, **{f"needs.{DAEMON}.outputs.key": "0" * 40})
        _check(not evaluate(marker["if"], other_key), f"{event} {ref}: no marker when the tested key differs")
    marker_steps = [step for step in all_jobs["publish-tree-tested"]["steps"]
                    if "cmux-tui-mark-daemon-tested.sh" in step.get("run", "")]
    writers = [name for name, job in all_jobs.items()
               if "cmux-tui-mark-daemon-tested.sh" in str(job.get("steps", ""))]
    _check(len(marker_steps) == 1 and writers == ["publish-tree-tested"],
           f"only publish-tree-tested writes the daemon-tests marker ({writers})")

    # An unmarked tree is re-tested only once the run that owns or published
    # it ended (tests/test_cmux_tui_owner_wait_defers.py and
    # tests/test_cmux_tui_lane_daemon_tests.py run those steps).
    _check("unmarked=true" in str(all_jobs["tree-owner-wait"]["steps"])
           and "daemon_tested=false" in str(all_jobs["tree-preflight"]["steps"]),
           "tree-owner-wait and tree-preflight still send an unmarked tree to the daemon tests")
    _check(set(tree_publishers) <= set(needs(marker)),
           f"publish-tree-tested follows every tree publisher ({needs(marker)})")
    for name in tree_publishers:
        _check(f"needs.{name}.result == 'success'" in str(marker["if"]),
               f"publish-tree-tested marks a tree {name} published")
    promote = all_jobs["request-nightly-next"]
    _check("needs.publish-tree-tested.result == 'success'" in str(promote["if"]),
           "nightly-next promotion still follows the marker job")

    # The run that ends unpublished still reports, whichever job would have published.
    notify = all_jobs["notify-unpublished-tree"]
    for name in tree_publishers:
        _check(name in needs(notify) and f"needs.{name}.result != 'success'" in str(notify["if"]),
               f"notify-unpublished-tree waits for {name} and stays quiet when it published")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("PASS: no tree publication waits for the daemon tests; only publish-tree-tested marks a tree tested")
    return 0


if __name__ == "__main__":
    sys.exit(main())

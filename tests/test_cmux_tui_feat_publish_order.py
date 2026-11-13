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
macOS runner. The feat-cmux-next channel still needs the daemon-tests marker,
which only publish-tree-tested writes, after this run's tests of the key pass.
Nightly-next promotion does not (2026-10-28): its tree-commit markers
(mark-tree-commits) follow the publish, not the daemon tests.

No tree publication waits for the Windows build either (2026-10-21): the
Windows leg (24 min median, 32 p90) ended last in 217 of 219 published trees,
so every nightly-next promotion waited for a target the nightly does not
ship. build-windows is its own call, and publish-windows and
publish-tree-windows (the same steps, CMUX_TUI_PUBLISH_PASS=windows) add the
Windows daemon to the tree the first pass published.

This evaluates each publishing job's `if` with GitHub's expression rules for
a feat-cmux-next push and for other refs, and walks its `needs`.
"""

import json
import os
import re
import sys
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import workflow_jobs  # noqa: E402
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")
DAEMON = "cmux-next-daemon-tests"
KEY = "8729cadfd262d8c13cad8f8ad5d7d54ca4984e01"
FAILURES = []


def _check(ok, message):
    print(("ok: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def jobs():
    return workflow_jobs.jobs(Path(WORKFLOW))


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
        "needs.tree-preflight.result": "success",
        "needs.tree-preflight.outputs.key": KEY,
        "needs.tree-preflight.outputs.daemon_tests": daemon_tests,
        "needs.tree-preflight.outputs.tree_ready": "false",
        "needs.build.result": "success",
        "needs.build-darwin-fallback.result": "skipped",
        "needs.darwin-fallback-plan.outputs.recovered": "",
        "needs.publish.result": "success",
    }
    if daemon_result is not None:
        values[f"needs.{DAEMON}.result"] = daemon_result
        values[f"needs.{DAEMON}.outputs.key"] = KEY if daemon_result == "success" else ""
        # The feat-cmux-next promotion gate runs the tests on its Mac pool.
        values[f"needs.{DAEMON}.outputs.runner_os"] = "macOS"
    return values


def windows_pass(job):
    return workflow_jobs.resolve(job).env.get("CMUX_TUI_PUBLISH_PASS") == "windows"


def publishers(all_jobs, windows=False):
    """The jobs that publish the tree; windows=True: the Windows passes that add to it."""
    return [name for name, job in all_jobs.items()
            if windows_pass(job) == windows
            and any(step.get("name", "").startswith("Publish the") and "trusted helper" in step.get("name", "")
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


def built_nothing(ref, state, adopt_result="success"):
    """A push whose tree a lane run already published (the PR-first merge): no build, no publish."""
    values = context(ref, daemon_result=None)
    values.update({
        "needs.tree-preflight.outputs.tree_ready": "true",
        "needs.tree-preflight.outputs.run_macos": "false",
        "needs.tree-preflight.outputs.owns_key": "false",
        "needs.tree-owner-wait.outputs.takeover": "false",
        "needs.build-linux.result": "skipped",
        "needs.build.result": "skipped",
        "needs.publish.result": "skipped",
        "needs.verify-publish.result": "skipped",
        "needs.adopt-commit-manifest.result": adopt_result,
        "needs.adopt-commit-manifest.outputs.state": state,
    })
    return values


def machine_channel_follows_an_adopted_manifest(all_jobs):
    """2026-11-13, 93d73d7b (the squash merge of #42609, run 43479235288): its tree was published by
    the lane head's run, so build-linux, publish and verify-publish skipped, and both Cloud machine
    channel jobs with them. adopt-commit-manifest wrote cmux-tui/<sha>/manifest.json at 18:07:54Z, and
    the channel stayed on the previous commit until the next build at 18:22Z. The channel moves from
    the adopted manifest too, onto the fat cmux-tui/<sha>/ names that manifest serves: a run that
    builds nothing has no machine/ copy of its commit (only point-machine-channel-early uploads one,
    from this run's build-linux), and updater/channel.rs allowed_urls accepts both paths."""
    channel_jobs = ("point-machine-channel-early", "point-machine-channel")
    feat = "refs/heads/feat-cmux-next"

    for state in ("adopted", "present"):
        moving = [name for name in channel_jobs if runs(all_jobs, name, built_nothing(feat, state))]
        _check(moving == ["point-machine-channel"],
               f"a feat-cmux-next push whose tree was ready (manifest {state}) points the machine channel ({moving})")
    for state, result in (("pending", "success"), ("missing", "success"), ("", "failure"), ("", "skipped")):
        moving = [name for name in channel_jobs if runs(all_jobs, name, built_nothing(feat, state, result))]
        _check(not moving, f"no commit manifest (adopt {result}, state {state or 'none'}): the channel stays ({moving})")
    for ref in ("refs/heads/main", "refs/heads/codex/some-lane", "refs/heads/nightly-next"):
        moving = [name for name in channel_jobs if runs(all_jobs, name, built_nothing(ref, "adopted"))]
        _check(not moving, f"only feat-cmux-next moves the machine channel, not {ref} ({moving})")

    # The run that built and published still points after verify-publish, as before.
    built = context(feat, daemon_result=None)
    built.update({"needs.verify-publish.result": "success", "needs.adopt-commit-manifest.result": "skipped",
                  "needs.adopt-commit-manifest.outputs.state": ""})
    _check(runs(all_jobs, "point-machine-channel", built), "a published feat-cmux-next build points the machine channel")

    job = all_jobs["point-machine-channel"]
    _check("adopt-commit-manifest" in needs(job), f"point-machine-channel follows adopt-commit-manifest ({needs(job)})")
    step = next((step for step in job["steps"] if step.get("name") == "Sign and upload the channel"), {})
    script, env = step.get("run", ""), step.get("env", {})
    point = script.split("scripts/ci/cmux-machine-channel-point.sh", 1)[0]
    _check("cmux-tui/$GITHUB_SHA/manifest.json" in point and "--manifest" in point and "--machine-path" not in point,
           "its payload comes from this commit's manifest, onto the fat cmux-tui/<sha>/ names (no --machine-path)")
    # The signed Linux release file signs only this run's own build artifacts: a run that built
    # nothing has none, so it signs nothing (and logs no warning for it).
    _check('VERIFY_PUBLISH == success' in script.replace('"', "").replace("$", ""),
           "the Linux release file is signed only by a run that built and published")
    _check(env.get("VERIFY_PUBLISH") == "${{ needs.verify-publish.result }}",
           "the step reads verify-publish's result")

    # The fat URL the manifest payload names is the first of the two the updater accepts.
    rust = Path(ROOT, "cmux-tui/crates/cmux-host/src/updater/channel.rs").read_text(encoding="utf-8")
    _check('format!("{FILES_PREFIX}{commit}/{published_name}")' in rust
           and 'pub const FILES_PREFIX: &str = "https://files.cmux.com/cmux-tui/";' in rust,
           "updater/channel.rs allowed_urls accepts https://files.cmux.com/cmux-tui/<commit>/<name>")
    payload_py = Path(ROOT, "scripts/ci/cmux-machine-channel.py").read_text(encoding="utf-8")
    _check('FILES = "https://files.cmux.com/cmux-tui"' in payload_py
           and "url = f\"{FILES}/{args.commit}/{'machine/' if args.machine_path else ''}{published}\"" in payload_py,
           "cmux-machine-channel.py names <FILES>/<commit>/<name> without --machine-path")


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
        ("push", "refs/heads/next-batch/abc"),
        ("push", "refs/heads/main"),
        ("push", "refs/heads/codex/opted-in-lane"),
    ]
    for event, ref in tested_refs:
        for result in (None, "failure", "cancelled", "skipped", "success"):
            values = context(ref, event=event, daemon_result=result)
            starting = [name for name in tree_publishers if runs(all_jobs, name, values)]
            _check(len(starting) == 1,
                   f"{event} {ref} publishes once with its daemon tests {result or 'queued'} ({starting})")
    for event in ("push", "workflow_dispatch"):
        for result in (None, "failure", "cancelled", "skipped", "success"):
            values = context("refs/heads/cmux-tui-pin-0123456789ab", event=event, daemon_result=result)
            starting = [name for name in tree_publishers if runs(all_jobs, name, values)]
            _check(not starting, f"{event} on a pin ref never publishes ({starting})")
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

    # The daemon-tests marker (the feat-cmux-next channel's gate) is written only after the tests pass.
    marker = all_jobs["publish-tree-tested"]
    _check(DAEMON in needs(marker) and f"needs.{DAEMON}.result == 'success'" in str(marker["if"]),
           "publish-tree-tested writes the marker only after the daemon tests pass")
    for ref, event in (("refs/heads/feat-cmux-next", "push"), ("refs/heads/cmux-tui-pin-0123456789ab", "push")):
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
           "the request job still follows the daemon-tests marker job")

    # The tree-commit markers, which nightly-next promotion requires, follow the
    # publish and never the daemon tests (2026-10-28: run 40651931144's tests
    # failed fetching Zig packages and no commit was marked for hours).
    mark = all_jobs["mark-tree-commits"]
    _check(DAEMON not in all_needs(all_jobs, "mark-tree-commits"),
           f"mark-tree-commits does not wait for the daemon tests ({sorted(all_needs(all_jobs, 'mark-tree-commits'))})")
    _check(set(tree_publishers) <= set(needs(mark)), f"mark-tree-commits follows every tree publisher ({needs(mark)})")
    for event in ("push", "workflow_dispatch"):
        for published in ("success", "skipped"):
            values = context("refs/heads/feat-cmux-next", event=event, daemon_result=None)
            values.update({f"needs.{name}.result": published for name in tree_publishers})
            _check(runs(all_jobs, "mark-tree-commits", values),
                   f"a feat-cmux-next {event} marks its commits with publish {published}, its daemon tests still queued")
        failed = context("refs/heads/feat-cmux-next", event=event, daemon_result=None)
        failed.update({f"needs.{name}.result": "failure" for name in tree_publishers})
        _check(not runs(all_jobs, "mark-tree-commits", failed),
               f"a feat-cmux-next {event} whose publish failed marks nothing")

    # The run that ends unpublished still reports, whichever job would have published.
    notify = all_jobs["notify-unpublished-tree"]
    for name in tree_publishers:
        _check(name in needs(notify) and f"needs.{name}.result != 'success'" in str(notify["if"]),
               f"notify-unpublished-tree waits for {name} and stays quiet when it published")

    # Nothing on the path to the tree and nightly-next waits for the Windows build.
    _check("build-windows" in all_jobs, "Windows builds in its own job, build-windows")
    for name in [*tree_publishers, "publish", "publish-tree-tested", "request-nightly-next"]:
        _check("build-windows" not in all_needs(all_jobs, name), f"{name} does not wait for build-windows")
    _check(all_jobs["build"]["with"].get("include_windows") is False,
           "the macOS and Linux build call builds no Windows target")
    # build-windows reads what it builds from the keyed profile file (cmux-tui-build-profiles.json).
    profile_ref = "${{ fromJSON(needs.tree-preflight.outputs.build_profiles).windows.%s }}"
    windows_profile = json.loads(Path(ROOT, "scripts/cmux-next/cmux-tui-build-profiles.json").read_text(encoding="utf-8"))["windows"]
    windows_with = {k: windows_profile[k] if v == profile_ref % k else v for k, v in all_jobs["build-windows"]["with"].items()}
    _check(windows_with.get("include_windows") is True and windows_with.get("target_set") == "windows",
           "build-windows builds only the Windows target")
    windows_publishers = publishers(all_jobs, windows=True)
    _check(windows_publishers == ["publish-tree-windows"], f"one Windows tree pass ({windows_publishers})")
    for name in windows_publishers:
        job = all_jobs[name]
        _check({"publish-tree", "publish-windows"} <= set(needs(job)) and "build-windows" in all_needs(all_jobs, name),
               f"{name} adds to the tree publish-tree published, after build-windows")
        _check(job["steps"] is all_jobs["publish-tree"]["steps"], f"{name} runs publish-tree's own steps")
        _check(name in needs(all_jobs["notify-unpublished-tree"]), f"notify-unpublished-tree stays the run's last job ({name})")
    _check(all_jobs["publish-windows"]["steps"] is all_jobs["publish"]["steps"]
           and windows_pass(all_jobs["publish-windows"])
           and "needs.build-windows.outputs.windows_built == 'true'" in str(all_jobs["publish-windows"]["if"]),
           "publish-windows runs publish's own steps, only for a Windows build that uploaded its artifact")

    machine_channel_follows_an_adopted_manifest(all_jobs)

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("PASS: no tree publication waits for the daemon tests; only publish-tree-tested marks a tree tested")
    return 0


if __name__ == "__main__":
    sys.exit(main())

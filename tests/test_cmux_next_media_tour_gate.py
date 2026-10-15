#!/usr/bin/env python3
"""The cmux-next "Tour the app" job runs on merges and on opted-in pull requests.

It ran on every push to every feat-cmux-next pull request that touched UI
paths: on 2026-10-14 it had 32 queued and 8 running jobs on the owned Macs'
gui runners, one per mini, which saturated them. It now runs for a push to
feat-cmux-next (a merge: one tour at a time, the newest merge waiting) and for
a pull request labeled `media-tour`. A pull request event without the label,
or a label event for another label, starts no job and cancels no tour.

This evaluates the workflow's own trigger, concurrency and job conditions for
each event, runs the publish job's pull request lookup with a fake gh, and
runs its comment step with a stub publisher to check the note it posts.
"""

import json
import os
import re
import stat
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next-media.yml")
sys.path.insert(0, os.path.join(ROOT, "tests"))
from test_ci_fork_runner_routing import parse_expression  # noqa: E402

REPO = "manaflow-ai/cmux"
LABEL = "media-tour"
FAILURES = []


def _check(ok, message):
    print(("ok: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def lookup(context, path):
    value = context
    for part in re.findall(r"[^.\[\]]+|\*", path):
        if part == "*":
            continue
        if isinstance(value, list):
            value = [item.get(part) if isinstance(item, dict) else None for item in value]
        elif isinstance(value, dict):
            value = value.get(part)
        else:
            return None
    return value


def evaluate(node, context):
    """GitHub Actions semantics for the subset these conditions use."""
    kind = node[0]
    if kind == "or":
        value = None
        for child in node[1]:
            value = evaluate(child, context)
            if value:
                return value
        return value
    if kind == "and":
        value = None
        for child in node[1]:
            value = evaluate(child, context)
            if not value:
                return value
        return value
    if kind == "not":
        return not evaluate(node[1], context)
    if kind == "literal":
        text = node[1]
        if text.startswith("'"):
            return text[1:-1].replace("''", "'")
        return {"true": True, "false": False, "null": None}.get(text, text)
    if kind == "ref":
        return lookup(context, node[1])
    if kind == "cmp":
        left, right = evaluate(node[2], context), evaluate(node[3], context)
        norm = lambda v: "" if v is None else str(v).lower()  # noqa: E731
        return (norm(left) == norm(right)) == (node[1] == "==")
    if kind == "call":
        args = [evaluate(arg, context) for arg in node[2]]
        if node[1] == "contains":
            haystack, needle = args
            if isinstance(haystack, list):
                return any(str(item).lower() == str(needle).lower() for item in haystack)
            return str(needle).lower() in str(haystack or "").lower()
        if node[1] == "format":
            return re.sub(r"\{(\d+)\}", lambda m: str(args[1 + int(m.group(1))]), args[0])
    raise ValueError(f"unsupported expression {node!r}")


def expression(text, context):
    text = str(text).strip()
    parts = re.split(r"\$\{\{(.*?)\}\}", text)
    if len(parts) == 3 and not parts[0] and not parts[2]:
        return evaluate(parse_expression(parts[1]), context)
    if len(parts) == 1:
        return evaluate(parse_expression(text), context)
    return "".join(part if i % 2 == 0 else str(evaluate(parse_expression(part), context) or "")
                   for i, part in enumerate(parts))


def pr_event(action, labels, label=None, fork=False, number=42):
    event = {"action": action, "pull_request": {
        "number": number, "labels": [{"name": name} for name in labels],
        "head": {"sha": "h" * 40, "repo": {"full_name": "someone/cmux" if fork else REPO}},
        "base": {"sha": "b" * 40}}}
    if label:
        event["label"] = {"name": label}
    return {"github": {"event_name": "pull_request", "repository": REPO, "repository_owner": "manaflow-ai",
                       "sha": "m" * 40, "run_id": 9000, "event": event}, "vars": {}}


def push_event():
    return {"github": {"event_name": "push", "repository": REPO, "repository_owner": "manaflow-ai",
                       "ref": "refs/heads/feat-cmux-next", "sha": "a" * 40, "run_id": 9001,
                       "event": {"before": "f" * 40}}, "vars": {}}


def main():
    workflow = yaml.safe_load(open(WORKFLOW, encoding="utf-8"))
    triggers = workflow.get(True) or workflow.get("on")
    jobs = workflow["jobs"]

    pr_trigger = triggers["pull_request"]
    _check("labeled" in pr_trigger["types"], "adding the label starts a tour")
    push = triggers.get("push") or {}
    _check(push.get("branches") == ["feat-cmux-next"], "a merge to feat-cmux-next starts a tour")
    _check(push.get("paths") == pr_trigger["paths"], "merges and pull requests share the UI path filter")

    route_if = jobs["route"]["if"]
    group = workflow["concurrency"]["group"]
    cancel = workflow["concurrency"]["cancel-in-progress"]
    opted_group = expression(group, pr_event("synchronize", [LABEL]))
    cases = [
        ("a pull request push without the label tours nothing", pr_event("synchronize", ["dev-build"]), False),
        ("an opened pull request without the label tours nothing", pr_event("opened", []), False),
        ("a pull request push with the label tours", pr_event("synchronize", [LABEL]), True),
        ("adding the label tours", pr_event("labeled", [LABEL], label=LABEL), True),
        ("adding another label to a labeled pull request tours nothing",
         pr_event("labeled", [LABEL, "dev-build"], label="dev-build"), False),
        ("a fork pull request never tours", pr_event("synchronize", [LABEL], fork=True), False),
        ("a merge to feat-cmux-next tours", push_event(), True),
    ]
    for why, context, want in cases:
        got = bool(expression(route_if, context))
        _check(got == want, f"{why} (route if -> {got})")
        same_repo = lookup(context, "github.event.pull_request.head.repo.full_name") in (None, REPO)
        if not want and context["github"]["event_name"] == "pull_request" and same_repo:
            other = expression(group, context)
            _check(other != opted_group, f"{why}, and cancels no tour of the pull request ({other!r})")

    _check(expression(cancel, pr_event("synchronize", [LABEL])) is True,
           "a newer opted-in push still cancels the pull request's older tour")
    _check(not expression(cancel, push_event()), "a merge tour in progress is never cancelled")
    merge_group = expression(group, push_event())
    _check(merge_group == expression(group, dict(push_event(), github=dict(push_event()["github"], sha="b" * 40))),
           f"merge tours share one group, so the newest merge waits and older pending ones are replaced ({merge_group!r})")

    route_env = jobs["route"]["steps"][-1]["env"]
    _check(str(expression(route_env["SAME_REPO"], push_event())).lower() == "true", "a merge counts as same-repository")
    tour_env = jobs["tour"]["env"]
    _check(expression(tour_env["BASE_SHA"], push_event()) == "f" * 40, "a merge tour compares against the previous head")
    _check(expression(tour_env["HEAD_SHA"], push_event()) == "a" * 40, "a merge tour tours the merged head")
    _check(expression(tour_env["TOUR_TAG"], pr_event("synchronize", [LABEL])) == "ci-media-pr-42",
           "a pull request keeps its own tag")
    _check(expression(tour_env["TOUR_TAG"], push_event()) == "ci-media-feat-cmux-next", "merges share one warm tag")

    # The publish job comments on the merged pull request for a merge tour.
    publish = jobs["publish"]
    target = next((s for s in publish["steps"] if s.get("id") == "target"), None)
    _check(target is not None, "the publish job looks up the pull request to comment on")
    with tempfile.TemporaryDirectory() as tmp:
        if target is None:
            raise SystemExit(f"{len(FAILURES)} failure(s)")
        fake_gh = os.path.join(tmp, "gh")
        with open(fake_gh, "w") as handle:
            handle.write('#!/bin/sh\necho "$*" >> "$GH_LOG"\nprintf \'77\\t%s\\n\' "' + "e" * 40 + '"\n')
        os.chmod(fake_gh, os.stat(fake_gh).st_mode | stat.S_IXUSR)
        for name, context, want_pr, want_sha, want_calls in (
            ("merge", push_event(), "77", "e" * 40, 1),
            ("pull request", pr_event("synchronize", [LABEL]), "42", "h" * 40, 0),
        ):
            output, log = os.path.join(tmp, f"out-{name}"), os.path.join(tmp, f"log-{name}")
            open(output, "w").close()
            open(log, "w").close()
            env = {key: str(expression(value, context) or "") for key, value in target["env"].items()}
            env.update(PATH=f"{tmp}:{os.environ['PATH']}", GITHUB_OUTPUT=output, GH_LOG=log,
                       GITHUB_REPOSITORY=REPO)
            result = subprocess.run(["bash", "-e", "-c", target["run"]], env=env, capture_output=True, text=True)
            out = dict(l.split("=", 1) for l in open(output).read().splitlines() if "=" in l)
            calls = len(open(log).read().splitlines())
            _check(result.returncode == 0 and out.get("pr") == want_pr and out.get("sha") == want_sha
                   and calls == want_calls,
                   f"the {name} tour posts on #{out.get('pr')} at {out.get('sha', '')[:8]} "
                   f"({result.returncode}, {calls} gh calls, {result.stderr.strip()[-200:]})")
    upload = next(s for s in publish["steps"] if str(s.get("name", "")).startswith("Upload the media"))
    _check(upload["env"].get("PR") == "${{ steps.target.outputs.pr }}"
           and upload["env"].get("HEAD_SHA") == "${{ steps.target.outputs.sha }}",
           "the comment goes to the looked-up pull request")
    # A UI tour whose capture died before writing capture-receipt.json still
    # leaves the tour job green (capture is continue-on-error), so the comment
    # must say the capture failed, not "The tour produced no media" (#20763).
    _check(jobs["tour"].get("outputs", {}).get("is_ui") == "${{ steps.scope.outputs.is_ui }}",
           "the tour job tells the publish job whether it ran a UI tour")
    for why, tour_result, receipt, want, unwanted in (
        ("a UI tour whose capture wrote no receipt", "success", None,
         "The capture step failed before writing a receipt; see the run log.", None),
        ("a UI tour whose build failed", "failure", None,
         "failed before the tour ran", "capture step failed"),
        ("a UI tour with a receipt", "success", {"status": "ok", "tours": ["new-tab"]},
         None, "capture step failed"),
    ):
        with tempfile.TemporaryDirectory() as tmp:
            media = os.path.join(tmp, "temp", "media")
            os.makedirs(media)
            os.makedirs(os.path.join(tmp, "scripts", "cmux-next", "media"))
            if receipt is not None:
                with open(os.path.join(media, "capture-receipt.json"), "w") as handle:
                    json.dump(receipt, handle)
            argv_log = os.path.join(tmp, "publish-argv.json")
            with open(os.path.join(tmp, "scripts", "cmux-next", "media", "publish.py"), "w") as handle:
                handle.write("import json, sys\njson.dump(sys.argv[1:], open(%r, 'w'))\n" % argv_log)
            context = pr_event("synchronize", [LABEL])
            context["needs"] = {"route": {"result": "success", "outputs": {"reason": "", "runs_on": "gui"}},
                                "tour": {"result": tour_result, "outputs": {"is_ui": "true"}}}
            context["steps"] = {"target": {"outputs": {"pr": "42", "sha": "h" * 40}}}
            env = {key: str(expression(value, context) or "") for key, value in upload["env"].items()}
            env.update(PATH=os.environ["PATH"], RUNNER_TEMP=os.path.join(tmp, "temp"),
                       GITHUB_REPOSITORY=REPO)
            result = subprocess.run(["bash", "-e", "-c", upload["run"]], cwd=tmp, env=env,
                                    capture_output=True, text=True)
            args = json.load(open(argv_log)) if os.path.exists(argv_log) else []
            note = args[args.index("--note") + 1] if "--note" in args else None
            ok = result.returncode == 0 and note is not None
            if want is not None:
                ok = ok and want in note
            if unwanted is not None:
                ok = ok and unwanted not in (note or "")
            _check(ok, f"{why}: the comment note is {note!r} ({result.returncode}, {result.stderr.strip()[-200:]})")

    checkout = publish["steps"][0]
    _check(expression(checkout["with"]["ref"], push_event()) == "a" * 40,
           "a merge tour's publisher comes from the merged feat-cmux-next head")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("PASS: the tour runs on merges and on media-tour pull requests only")


if __name__ == "__main__":
    main()

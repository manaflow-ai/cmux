#!/usr/bin/env python3
"""The cmux-next "Tour the app" job runs on the nightly tip and once per `media-tour` label.

It ran on every push to every feat-cmux-next pull request that touched UI
paths: on 2026-10-14 it had 32 queued and 8 running jobs on the owned Macs'
gui runners, one per mini, which saturated them. Then it ran for a labeled
pull request on every push, and from 2026-10-19 for an unlabeled one whose
Swift UI change a specific tour covered. Since 2026-10-21 (Leo: only on a merge
or on demand) it ran for every push to feat-cmux-next (a merge): 144 tours and
3,408 Mac-minutes a day on 2026-10-26. Since 2026-10-27 a push to nightly-next
(the nightly tip) replaces the per-merge tour; it spans many merges, so it
posts on no pull request. It also runs for a dispatch and the `labeled` event
that adds `media-tour`. No push of a pull request or of feat-cmux-next starts a
run; to tour a newer head, re-add the label. A label event for another label
starts no job and cancels no tour.

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
        if node[1] == "cancelled":
            return False  # these runs are never cancelled
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
                       "ref": "refs/heads/nightly-next", "sha": "a" * 40, "run_id": 9001,
                       "event": {"before": "f" * 40}}, "vars": {}}


def dispatch_event(base_sha=""):
    """The batch queue's tour of a group branch (docs/ci/cmux-next-batch.md#groups)."""
    return {"github": {"event_name": "workflow_dispatch", "repository": REPO, "repository_owner": "manaflow-ai",
                       "ref": "refs/heads/next-batch/1-1", "sha": "c" * 40, "run_id": 9002, "event": {}},
            "inputs": {"base_sha": base_sha}, "vars": {}}


def main():
    workflow = yaml.safe_load(open(WORKFLOW, encoding="utf-8"))
    triggers = workflow.get(True) or workflow.get("on")
    jobs = workflow["jobs"]

    pr_trigger = triggers["pull_request"]
    _check(pr_trigger["types"] == ["labeled"],
           f"only a label event starts a pull request run; no push does ({pr_trigger['types']})")
    push = triggers.get("push") or {}
    _check(push.get("branches") == ["nightly-next"],
           f"only the nightly tip (a push to nightly-next) starts a push tour, not every merge ({push.get('branches')})")
    # GitHub matches push paths against the first 300 changed files only; a nightly tip spans many
    # merges, so a filter could drop a UI change past that window. The route job decides instead.
    _check("paths" not in push and "paths-ignore" not in push,
           "a nightly tip has no push path filter; the route job takes no Mac when nothing UI changed")
    _check(bool(pr_trigger.get("paths")), "a pull request's label tour keeps the UI path filter")

    route_if = jobs["route"]["if"]
    group = workflow["concurrency"]["group"]
    cancel = workflow["concurrency"]["cancel-in-progress"]
    opted_group = expression(group, pr_event("labeled", [LABEL], label=LABEL))
    cases = [
        ("a pull request push without the label tours nothing", pr_event("synchronize", ["dev-build"]), False),
        ("an opened pull request without the label tours nothing", pr_event("opened", []), False),
        ("a later push of a labeled pull request does not tour again", pr_event("synchronize", [LABEL]), False),
        ("reopening a labeled pull request does not tour again", pr_event("reopened", [LABEL]), False),
        ("adding the label tours", pr_event("labeled", [LABEL], label=LABEL), True),
        ("adding media-tour-mac alone tours nothing",
         pr_event("labeled", ["media-tour-mac"], label="media-tour-mac"), False),
        ("adding another label to a labeled pull request tours nothing",
         pr_event("labeled", [LABEL, "dev-build"], label="dev-build"), False),
        ("adding no-media-tour reaches the route, which cancels the running tour and posts nothing",
         pr_event("labeled", ["no-media-tour"], label="no-media-tour"), True),
        ("a fork pull request never tours", pr_event("labeled", [LABEL], label=LABEL, fork=True), False),
        ("a nightly-next tip tours", push_event(), True),
        ("a batch dispatch with a base tours", dispatch_event("d" * 40), True),
        ("a dispatch without a base tours nothing", dispatch_event(""), False),
    ]
    for why, context, want in cases:
        got = bool(expression(route_if, context))
        _check(got == want, f"{why} (route if -> {got})")
        same_repo = lookup(context, "github.event.pull_request.head.repo.full_name") in (None, REPO)
        if not want and context["github"]["event_name"] == "pull_request" and same_repo:
            other = expression(group, context)
            _check(other != opted_group, f"{why}, and cancels no tour of the pull request ({other!r})")

    _check(expression(cancel, pr_event("labeled", [LABEL], label=LABEL)) is True,
           "re-adding the label cancels the pull request's older tour")
    _check(not expression(cancel, push_event()), "a nightly tour in progress is never cancelled")
    merge_group = expression(group, push_event())
    _check(merge_group != expression(group, dict(push_event(), github=dict(push_event()["github"], sha="b" * 40))),
           f"each nightly tip has its own group, so no tour is replaced by a newer one ({merge_group!r})")

    # The route job decides; without a wanted tour no Mac is taken and nothing is posted.
    _check(jobs["tour"]["if"] == "${{ needs.route.outputs.runs_on != '' }}", "the tour needs a picked runner")
    # A nightly tour spans many merges and posts on no pull request; a pull request
    # run only hands its tour to a run on feat-cmux-next (the pr-media environment
    # admits no PR ref).
    for wanted, want in (("true", True), ("false", False)):
        needs = {"route": {"result": "success", "outputs": {"wanted": wanted}}}
        publish_if = jobs["publish"]["if"].replace("!cancelled() && ", "")  # a run that is not cancelled
        hand_off_if = jobs["hand-off"]["if"].replace(" && !cancelled()", "")
        _check(not expression(publish_if, dict(push_event(), needs=needs)),
               f"a nightly tour posts on no pull request (route wanted={wanted})")
        _check(not expression(publish_if, dict(pr_event("synchronize", []), needs=needs)),
               f"a pull request run never publishes itself (route wanted={wanted})")
        _check(bool(expression(hand_off_if, dict(pr_event("synchronize", []), needs=needs))) == want,
               f"the hand-off job {'starts the publisher' if want else 'starts nothing'} when the route wanted={wanted}")
        _check(not expression(hand_off_if, dict(push_event(), needs=needs)), "a nightly tour needs no hand-off")
    handed = dispatch_event("")
    handed["inputs"] = {"base_sha": "", "publish_run": "555"}
    _check(bool(expression(jobs["publish"]["if"].replace("!cancelled() && ", ""), handed)),
           "a hand-off dispatch publishes the pull request run's tour")
    _check(not expression(jobs["route"]["if"], handed), "a hand-off dispatch tours nothing")
    _check(jobs["publish"].get("environment") == "pr-media" and "environment" not in jobs["hand-off"],
           "only the publisher runs in the pr-media environment")
    decide = next((s for s in jobs["route"]["steps"] if s.get("id") == "decide"), None)
    _check(decide is not None and "media_auto_tour.py" in decide.get("run", ""),
           "the route asks media_auto_tour.py whether a pull request gets a tour")
    pick = next(s for s in jobs["route"]["steps"] if s.get("id") == "pick")
    _check("steps.decide.outputs.wanted == 'true'" in str(pick.get("if", "")),
           "no runner is picked when no tour is wanted")

    route_env = pick["env"]
    _check(str(expression(route_env["SAME_REPO"], push_event())).lower() == "true",
           "a nightly tip counts as same-repository")
    tour_env = jobs["tour"]["env"]
    _check(expression(tour_env["BASE_SHA"], push_event()) == "f" * 40,
           "a nightly tour compares against the previous nightly tip")
    _check(expression(tour_env["HEAD_SHA"], push_event()) == "a" * 40, "a nightly tour tours the new tip")
    # The tag comes from the slot the tour claims on its Mac (tests/test_media_tag_lock.py), not from the
    # pull request, so a Mac keeps K warm pairs instead of one per pull request it toured.
    _check("TOUR_TAG" not in tour_env, "no per-pull-request tag")
    _check(str(expression(tour_env["CMUX_MEDIA_TOUR_SLOTS"], push_event())) == "2",
           "two warm tour slots per Mac unless vars.CMUX_MEDIA_TOUR_SLOTS says otherwise")
    _check(expression(tour_env["BASE_SHA"], dispatch_event("d" * 40)) == "d" * 40,
           "a batch tour compares against the stack's base, so it maps the union of the group's tours")
    _check(expression(tour_env["HEAD_SHA"], dispatch_event("d" * 40)) == "c" * 40, "a batch tour tours the group branch")
    _check(str(expression(route_env["SAME_REPO"], dispatch_event("d" * 40))).lower() == "true",
           "a batch dispatch counts as same-repository, so an owned Mac takes the tour")
    _check(bool(expression(route_env["PR_XCODE_APP"], dict(dispatch_event("d" * 40), vars={"CMUX_CI_XCODE_APP_PR": "x"}))),
           "a batch dispatch gets the PR Xcode pin")
    _check(not expression(jobs["publish"]["if"], dispatch_event("d" * 40)),
           "a batch dispatch publishes nothing; the queue reads the tour's artifact")

    # The publish job comments on the pull request whose run handed off its tour.
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
        handed = dispatch_event("")
        handed["inputs"] = {"base_sha": "", "publish_run": "555"}
        for name, context, want_pr, want_sha, want_calls in (
            ("handed-off pull request", handed, "77", "e" * 40, 1),
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
            context["needs"] = {"route": {"result": "success",
                                          "outputs": {"reason": "", "runs_on": "gui", "wanted": "true"}},
                                "tour": {"result": tour_result, "outputs": {"is_ui": "true"}}}
            context["steps"] = {"target": {"outputs": {"pr": "42", "sha": "h" * 40}}}
            env = {key: str(expression(value, context) or "") for key, value in upload["env"].items()}
            env.update(PATH=os.environ["PATH"], RUNNER_TEMP=os.path.join(tmp, "temp"),
                       GITHUB_REPOSITORY=REPO)
            result = subprocess.run(["bash", "-e", "-c", upload["with"]["command"]], cwd=tmp, env=env,
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
    publisher = dict(handed, github=dict(handed["github"], ref="refs/heads/feat-cmux-next", sha="a" * 40))
    _check(expression(checkout["with"]["ref"], publisher) == "a" * 40,
           "the publisher comes from the protected branch's own revision, never the pull request's")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("PASS: the tour runs on the nightly tip, dispatches and the event that adds media-tour")


if __name__ == "__main__":
    main()

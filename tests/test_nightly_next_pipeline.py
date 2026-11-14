#!/usr/bin/env python3
"""A nightly-next push run builds; a dispatched sign run signs and publishes, so build N+1 overlaps sign N.

The lag bound (cmuxterm-hq goals/nightly-30min.md, Model 2026-11-08): the peak lag is about A + R + P, where
R is one run end to end and P the publish period. With one push run holding the push group from decide to the
GitHub release, P = R. Splitting the run at the unsigned app makes P = max(B, S), the slower stage:

- a push run (decide = pipeline) keeps the push group only through the unsigned-app build, then
  dispatch-nightly-next-sign dispatches the existing unsigned resume (nightly_next_unsigned_run/attempt) with
  nightly_next_sign_stage set. The push run skips prepare, sign, verify, recovery, the tree-marker wait,
  publish, the webview checks and the daemon attestation (the sign run runs both) and the Sentry dSYM upload
  (the tail runs it), so its group frees as soon as the build's artifacts are up and the sign run is dispatched.
- that sign run takes its own workflow-level group (nightly-build-nightly-next-sign, cancel-in-progress false):
  one sign run at a time, and GitHub replaces a pending one with a newer dispatch, so nothing started is
  cancelled and the newest build signs next.
- the sign run is a loop run: it dispatches its post-publish tail (run_tail false) and retries a failed sign at
  the newest head (retry-nightly-next). The push run retries only a failed build (no sign dispatched).
- a sign run whose build a newer published build already passed leaves before the signer (resolve's superseded),
  and the sign job's own superseded refusal and the feed's compare-and-swap stay.
- the resume may read a push run that is still finishing (its producers succeeded, artifacts are immutable and
  digest-checked); every other resume still needs a completed source.
Main, RC, manual runs and the loop's retry keep the whole pipeline in one run.
"""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_jobs  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / ".github" / "workflows" / "nightly.yml").read_text()
DOC = yaml.safe_load(TEXT)
JOBS = DOC["jobs"]
PIPELINE_OFF = "needs.decide.outputs.pipeline != 'true'"
failures: list[str] = []


def needs(name: str) -> list[str]:
    value = JOBS.get(name, {}).get("needs") or []
    return [value] if isinstance(value, str) else list(value)


def cond(name: str) -> str:
    return str(JOBS.get(name, {}).get("if", ""))


inputs = DOC.get(True, DOC.get("on", {})).get("workflow_dispatch", {}).get("inputs", {})
if "nightly_next_sign_stage" not in inputs:
    failures.append("workflow_dispatch needs the nightly_next_sign_stage input")
if len(inputs) > 25:
    failures.append(f"workflow_dispatch takes at most 25 inputs, nightly.yml has {len(inputs)}")

group = str(DOC.get("concurrency", {}).get("group", ""))
if "inputs.nightly_next_sign_stage != '' && 'sign'" not in group:
    failures.append("a sign-stage dispatch must take its own nightly-next sign group")
if DOC.get("concurrency", {}).get("cancel-in-progress") is not False:
    failures.append("the workflow-level group never cancels a started run")
# The push group is unchanged: push and the loop's retry.
if "(github.event_name == 'push' || github.event_name == 'workflow_dispatch' && inputs.nightly_next_loop_retry != '') && 'push'" not in group:
    failures.append("the push group still takes pushes and the loop's retry")

run_name = str(DOC.get("run-name", ""))
sign_title = run_name.find("Sign nightly-next run {0} attempt {1}")
resume_title = run_name.find("Resume nightly-next run {0} attempt {1}")
if sign_title < 0 or resume_title < 0 or sign_title > resume_title:
    failures.append("a sign run's title names its build run before the resume title, so main's feed watch does "
                    "not count it as a resume")

decide = JOBS["decide"]
if "pipeline" not in (decide.get("outputs") or {}):
    failures.append("decide must output pipeline")
script = "\n".join(str(step.get("with", {}).get("script", "")) for step in decide.get("steps", []))
env = {k: str(v) for step in decide.get("steps", []) for k, v in (step.get("env") or {}).items()}
if "inputs.nightly_next_sign_stage" not in env.get("SIGN_STAGE", ""):
    failures.append("decide reads nightly_next_sign_stage (SIGN_STAGE)")
if "vars.NIGHTLY_NEXT_PIPELINE" not in env.get("NIGHTLY_NEXT_PIPELINE", ""):
    failures.append("decide reads the NIGHTLY_NEXT_PIPELINE switch")
if "const resumeOutsideLoop = unsignedResume && !signStage;" not in script:
    failures.append("decide must build a sign stage's resume, and still nothing for any other resume")
if "if (resumeOutsideLoop) shouldBuild = false;" not in script:
    failures.append("decide must still build nothing for an unsigned resume the loop did not ask for")
m = re.search(r"const pipeline = ([^;]+);", script)
if m is None:
    failures.append("decide must compute pipeline")
else:
    for term in ("context.eventName === 'push'", "isNextRef", "process.env.NIGHTLY_NEXT_PIPELINE !== 'off'",
                 "!notaryPaused", "!notaryTest", "shouldPublish"):
        if term not in m.group(1):
            failures.append(f"pipeline is only a publishing nightly-next push ({term})")
if not re.search(r"signStage && \(!unsignedResume", script):
    failures.append("decide must refuse a sign stage that is not an unsigned resume")

# The push run builds and prepares: the sign stage's other roots skip there.
for name in ("find-nightly-next-recovery", "await-nightly-tree-marker", "route-visual-gate-nightly"):
    if PIPELINE_OFF not in cond(name):
        failures.append(f"{name} must skip in a pipelined push run ({PIPELINE_OFF})")

dispatch = JOBS.get("dispatch-nightly-next-sign")
if dispatch is None:
    failures.append("no dispatch-nightly-next-sign job hands the unsigned app to the sign stage")
else:
    for job in ("decide", "resolve-nightly-cmux-tui-client", "build-nightly-app", "build-nightly-ghostty-cli-helper",
                "build-nightly-remote-daemon", "prepare-nightly-variant"):
        if job not in needs("dispatch-nightly-next-sign"):
            failures.append(f"dispatch-nightly-next-sign must wait for {job}: the resume reads what it uploads")
        elif job != "decide" and f"needs.{job}.result == 'success'" not in cond("dispatch-nightly-next-sign"):
            failures.append(f"dispatch-nightly-next-sign dispatches only after {job} succeeded")
    for job in ("pick-nightly-sign-runner", "build-sign-notarize-nightly", "publish-nightly",
                "sentry-dsyms-nightly", "check-nightly-webviews"):
        if job in needs("dispatch-nightly-next-sign"):
            failures.append(f"dispatch-nightly-next-sign must not wait for {job}")
    for term in ("!cancelled()", "needs.decide.outputs.pipeline == 'true'",
                 "needs.resolve-nightly-cmux-tui-client.outputs.superseded != 'true'"):
        if term not in cond("dispatch-nightly-next-sign"):
            failures.append(f"dispatch-nightly-next-sign runs only in a pipelined push run ({term})")
    if (dispatch.get("permissions") or {}).get("actions") != "write":
        failures.append("dispatch-nightly-next-sign dispatches nightly.yml: it needs actions: write")
    runs = [str(s.get("run", "")) for s in dispatch.get("steps", []) if "gh workflow run" in str(s.get("run", ""))]
    if len(runs) != 1 or "nightly.yml" not in runs[0] or sorted(re.findall(r"-f (\w+)=", runs[0])) != [
            "nightly_next_sign_stage", "nightly_next_unsigned_attempt", "nightly_next_unsigned_run"]:
        failures.append("dispatch-nightly-next-sign dispatches nightly.yml once with the unsigned run, its attempt "
                        "and nightly_next_sign_stage")
    elif "--ref nightly-next" not in runs[0] or "while" in runs[0]:
        failures.append("dispatch-nightly-next-sign dispatches once on nightly-next, no loop")
    runs_on = workflow_jobs.single_runs_on(dispatch)
    if "blacksmith" in runs_on.lower() or "CI_NIGHTLY_MINI" not in runs_on:
        failures.append("dispatch-nightly-next-sign runs on the nightly mini")
if TEXT.count("-f nightly_next_sign_stage=") != 1:
    failures.append("only dispatch-nightly-next-sign dispatches a sign stage")

retry = JOBS.get("retry-nightly-next", {})
for job in ("dispatch-nightly-next-sign", "resolve-nightly-cmux-tui-client"):
    if job not in needs("retry-nightly-next"):
        failures.append(f"retry-nightly-next must need {job}")
for term in ("needs.dispatch-nightly-next-sign.result != 'success'", "inputs.nightly_next_sign_stage != ''",
             "needs.resolve-nightly-cmux-tui-client.outputs.superseded != 'true'", "needs.publish-nightly.result != 'success'"):
    if term not in cond("retry-nightly-next"):
        failures.append(f"retry-nightly-next retries a failed build or a failed sign stage, never a handed-off "
                        f"build or a superseded one ({term})")
if "dispatch-nightly-next-sign" not in needs("report-nightly-failure"):
    failures.append("report-nightly-failure must see a failed sign dispatch")

run_tail = str((JOBS.get("published-build", {}).get("outputs") or {}).get("run_tail", ""))
if "github.event_name != 'push' && inputs.nightly_next_loop_retry == '' && inputs.nightly_next_sign_stage == ''" not in run_tail:
    failures.append("published-build's run_tail is false in a sign run too: it dispatches its tail")

resolve = JOBS["resolve-nightly-cmux-tui-client"]
steps = {str(s.get("id", "")): s for s in resolve.get("steps", [])}
early = steps.get("sign-superseded")
if early is None:
    failures.append("resolve must check a sign stage's build against the published feed before the signer")
else:
    if "inputs.nightly_next_sign_stage != ''" not in str(early.get("if", "")) or not early.get("continue-on-error"):
        failures.append("the early superseded check runs only in a sign stage, and an unreadable feed leaves it to "
                        "the sign job's refusal")
    script_path = ROOT / "scripts" / "ci" / "nightly-steps" / "resolve-sign-stage-superseded.sh"
    if "resolve-sign-stage-superseded.sh" not in str(early.get("run", "")) or not script_path.exists() \
            or "--superseded-ok" not in script_path.read_text():
        failures.append("the early check runs nightly_version.py check-build --superseded-ok")
if "steps.sign-superseded.outputs.superseded" not in str((resolve.get("outputs") or {}).get("superseded", "")):
    failures.append("resolve's superseded output carries the sign stage's check")
if "Refuse a resumed build superseded by a published feed" not in TEXT:
    failures.append("the sign job keeps its own superseded refusal")
for job, step_id in (("resolve-nightly-cmux-tui-client", "resume_source"), ("build-nightly-app", "resume")):
    step = next((s for s in JOBS[job].get("steps", []) if s.get("id") == step_id), {})
    if "inputs.nightly_next_sign_stage" not in str((step.get("env") or {}).get("NIGHTLY_NEXT_SIGN_STAGE", "")):
        failures.append(f"{job}'s resume step tells resume-unsigned-nightly.py it is a sign stage")

# The resume reads a live push run only in a sign stage, and only once its producers succeeded.
spec = importlib.util.spec_from_file_location("resume", ROOT / "scripts" / "ci" / "resume-unsigned-nightly.py")
resume = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resume)
REPO = "manaflow-ai/cmux"
SHA = "a" * 40
run = {"id": 7, "run_attempt": 1, "path": ".github/workflows/nightly.yml", "event": "push", "head_branch": "nightly-next",
       "status": "in_progress", "conclusion": None, "head_sha": SHA,
       "repository": {"full_name": REPO, "id": 1}, "head_repository": {"full_name": REPO}}
window = {"started_at": "2026-11-08T10:00:00Z", "completed_at": "2026-11-08T10:20:00Z", "conclusion": "success",
          "run_attempt": 1}
jobs = [dict(window, name=n) for n in ("build-nightly-app", "build-nightly-ghostty-cli-helper")]
identity = {"id": 7, "head_sha": SHA, "head_branch": "nightly-next", "repository_id": 1, "head_repository_id": 1}
artifacts = [{"name": n, "expired": False, "created_at": "2026-11-08T10:10:00Z", "digest": "sha256:" + "0" * 64,
              "workflow_run": identity} for n in (*resume.ARTIFACTS, f"nightly-next-dsyms-{SHA}")]


def accepts(source: dict, live_ok: bool, job_list=jobs) -> bool:
    try:
        resume.validate(source, job_list, artifacts, REPO, "7", "1", live_ok=live_ok)
        return True
    except SystemExit:
        return False
    except TypeError:
        return False


if not accepts(run, True):
    failures.append("a sign stage resumes a push run that is still finishing once its producers succeeded")
if accepts(run, False):
    failures.append("any other resume still needs a completed source run")
if accepts({**run, "status": "completed", "conclusion": "cancelled"}, True):
    failures.append("a cancelled source is never resumed")
if not accepts({**run, "status": "completed", "conclusion": "success"}, False):
    failures.append("a completed push run still resumes")
if accepts(run, True, [dict(jobs[0], conclusion=None), jobs[1]]):
    failures.append("a live source resumes only once build-nightly-app succeeded")

# The push run ends at the sign dispatch. GitHub holds a workflow-level concurrency group until every job of the
# run has ended, so a job that can still run in a pipelined push run beside or after the build holds the push
# group past the dispatch (sentry-dsyms-nightly, up to 45 min, did). Evaluate every job's `if:` over the needs
# graph for a pipelined push run whose build succeeded: a value the run decides (a var, an output this file does
# not pin) is unknown, and a job whose `if:` is not false for certain counts as one that can run.
UNKNOWN = object()


def truthy(value) -> bool:
    return value not in ("", None, False, 0, "false")


def tokenize(text: str) -> list[str]:
    pattern = r"'(?:[^']|'')*'|&&|\|\||==|!=|[!(),]|[A-Za-z_][\w.*-]*|\d+"
    if re.sub(pattern, "", text).strip():
        raise ValueError(f"unparsed expression: {text}")
    return re.findall(pattern, text)


def evaluate(expression, context: dict, job_needs: list[str], results: dict):
    """GitHub's expression subset nightly.yml's `if:`s use, in three values: a known one, or UNKNOWN."""
    if isinstance(expression, bool):
        return expression
    text = str(expression).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    tokens = tokenize(text)
    pos = 0
    status = False

    def peek():
        return tokens[pos] if pos < len(tokens) else None

    def take(expected=None):
        nonlocal pos
        token = tokens[pos]
        if expected is not None and token != expected:
            raise ValueError(f"expected {expected} in {text}")
        pos += 1
        return token

    def success():
        values = [results[n] for n in job_needs]
        if all(v == "success" for v in values):
            return True
        return UNKNOWN if all(v in ("success", UNKNOWN) for v in values) else False

    def call(name):
        nonlocal status
        args = []
        take("(")
        while peek() != ")":
            args.append(either())
            if peek() == ",":
                take(",")
        take(")")
        if name in ("always", "cancelled", "success", "failure"):
            status = True
        if name == "always":
            return True
        if name == "cancelled":
            return False
        if name == "success":
            return success()
        if name == "failure":
            return False
        if name == "contains":
            haystack, needle = args
            if needle is UNKNOWN:
                return UNKNOWN
            if isinstance(haystack, list):
                if needle in haystack:
                    return True
                return UNKNOWN if UNKNOWN in haystack else False
            return UNKNOWN if haystack is UNKNOWN else str(needle).lower() in str(haystack).lower()
        raise ValueError(f"unknown function {name}")

    def atom():
        token = take()
        if token == "(":
            value = either()
            take(")")
            return value
        if token == "!":
            value = atom()
            return UNKNOWN if value is UNKNOWN else not truthy(value)
        if token.startswith("'"):
            return token[1:-1].replace("''", "'")
        if token.isdigit():
            return int(token)
        if token in ("true", "false"):
            return token == "true"
        if peek() == "(":
            return call(token)
        if token.startswith("needs.*."):
            field = token.removeprefix("needs.*.")
            if field == "result":
                return [results[n] for n in job_needs]
            return ["" if results[n] == "skipped" else context.get(f"needs.{n}.{field}", UNKNOWN) for n in job_needs]
        if token.startswith("needs."):
            need = token.split(".")[1]
            if need not in job_needs:
                raise ValueError(f"{token} is not in this job's needs")
            if token.endswith(".result"):
                return results[need]
            if results[need] == "skipped":
                return ""
        return context.get(token, UNKNOWN)

    def compare():
        left = atom()
        while peek() in ("==", "!="):
            op = take()
            right = atom()
            if left is UNKNOWN or right is UNKNOWN:
                left = UNKNOWN
            else:
                same = str(left).lower() == str(right).lower()
                left = same if op == "==" else not same
        return left

    def conjunction():
        left = compare()
        while peek() == "&&":
            take()
            right = compare()
            if left is UNKNOWN:
                left = right if right is not UNKNOWN and not truthy(right) else UNKNOWN
            elif truthy(left):
                left = right
        return left

    def either():
        left = conjunction()
        while peek() == "||":
            take()
            right = conjunction()
            if left is UNKNOWN:
                left = right if right is not UNKNOWN and truthy(right) else UNKNOWN
            elif not truthy(left):
                left = right
        return left

    value = either()
    if pos != len(tokens):
        raise ValueError(f"trailing tokens in {text}")
    if not status:
        gate = success()
        if gate is False:
            return False
        if gate is UNKNOWN:
            return UNKNOWN if value is UNKNOWN or truthy(value) else False
    return value


def simulate(context: dict, outputs: dict) -> dict:
    """Each job's result: success (it runs, and this run's jobs succeed), skipped, or UNKNOWN (it may run)."""
    results: dict = {}
    pending = list(JOBS)
    while pending:
        ready = [n for n in pending if all(need in results for need in needs(n))]
        if not ready:
            raise ValueError(f"cycle or unknown need among {pending}")
        for name in ready:
            pending.remove(name)
            job = JOBS[name]
            ran = evaluate(job["if"], context, needs(name), results) if "if" in job else \
                evaluate("success()", context, needs(name), results)
            results[name] = UNKNOWN if ran is UNKNOWN else "success" if truthy(ran) else "skipped"
            for key, value in outputs.get(name, {}).items():
                context[f"needs.{name}.outputs.{key}"] = value
    return results


PUSH = {"github.event_name": "push", "github.ref": "refs/heads/nightly-next", "github.repository": "manaflow-ai/cmux",
        "github.repository_owner": "manaflow-ai", "github.event.schedule": "",
        **{f"inputs.{name}": "" for name in inputs}}
# What decide outputs for a pipelined push (const pipeline: a publishing nightly-next push, no pause, no notary
# test; a push takes no dispatch input), and resolve's outputs for a build the run goes on to dispatch.
PIPELINED = {
    "decide": {"pipeline": "true", "one_job": "false", "track": "nightly-next", "should_build": "true", "should_publish": "true",
               "no_publish": "false", "notary_test": "false", "notary_paused": "false", "continue_only": "false",
               "republish_run": "", "fast_build": "false", "build_only": "false"},
    "resolve-nightly-cmux-tui-client": {"already_published": "false", "superseded": "", "build_sha": SHA},
    # A push run restores nothing (no resume step), so it has no prepared app of another run.
    "build-nightly-app": {"prepared": ""},
}
# A producer the app build installs from beside it (the web bundles; build-nightly-app builds them itself when
# they are not up yet), so it is part of the build stage though the dispatch does not wait for it.
BUILD_STAGE_EXTRA = {"build-nightly-inputs"}


def ancestors(name: str) -> set[str]:
    found: set[str] = set()
    stack = [name]
    while stack:
        for need in needs(stack.pop()):
            if need not in found:
                found.add(need)
                stack.append(need)
    return found


try:
    push_results = simulate(dict(PUSH), PIPELINED)
except ValueError as error:
    failures.append(f"the pipelined push run's `if:`s do not evaluate: {error}")
else:
    allowed = ancestors("dispatch-nightly-next-sign") | {"dispatch-nightly-next-sign"} | BUILD_STAGE_EXTRA
    can_run = {n for n, r in push_results.items() if r != "skipped"}
    if push_results.get("dispatch-nightly-next-sign") != "success":
        failures.append("a pipelined push run whose build succeeded dispatches the sign stage")
    for name in sorted(can_run - allowed):
        failures.append(f"{name} can run in a pipelined push run: it holds the push group after the sign dispatch "
                        f"(skip it there with {PIPELINE_OFF}, and run its work in the sign run or its tail)")
    for name in sorted(allowed - can_run):
        failures.append(f"{name} is in the build stage but does not run in a pipelined push run")

# What the push run skips happens in the sign run (a sign-stage dispatch of the unsigned resume) or in the tail
# run that sign run dispatches (nightly_next_post_publish).
SIGN = {**PUSH, "github.event_name": "workflow_dispatch", "inputs.nightly_next_sign_stage": "true",
        "inputs.nightly_next_unsigned_run": "7", "inputs.nightly_next_unsigned_attempt": "1"}
SIGN_OUTPUTS = {
    "decide": {**PIPELINED["decide"], "pipeline": "false"},
    "resolve-nightly-cmux-tui-client": PIPELINED["resolve-nightly-cmux-tui-client"],
    # The push run prepared the app: the sign run's resume restored that prepared app (prepared).
    "build-nightly-app": {"prepared": "true"},
    # A sign run dispatches its tail (run_tail false, as checked above), and publishes its own new build.
    "published-build": {"run_tail": "false", "cross_run": "", "track": "nightly-next", "publish_result": "success",
                        "publish_refused": "false", "publish_tag_status": "updated", "publish_build_sha": SHA,
                        "publish_already_published": "false", "sign_stage": "true"},
}
TAIL = {**PUSH, "github.event_name": "workflow_dispatch", "inputs.nightly_next_post_publish": '{"tail": true}'}
try:
    sign_results = simulate(dict(SIGN), SIGN_OUTPUTS)
    tail_results = simulate(dict(TAIL), {})
except ValueError as error:
    failures.append(f"the sign run's `if:`s do not evaluate: {error}")
else:
    for name, where, results in (("check-nightly-webviews", "the sign run", sign_results),
                                 ("attest-nightly-remote-daemon", "the sign run", sign_results),
                                 ("sentry-dsyms-nightly", "the sign run's tail run", tail_results)):
        if results.get(name) == "skipped":
            failures.append(f"{name} must run in {where}: the pipelined push run skips it")
    if sign_results.get("publish-nightly") == "skipped" or sign_results.get("build-sign-notarize-nightly") == "skipped":
        failures.append("the sign run's simulation must reach the signer and publish-nightly")
    if sign_results.get("sentry-dsyms-nightly") not in (None, "skipped"):
        failures.append("sentry-dsyms-nightly runs in the tail, not in the sign run, which holds the sign group")

# A sign run starts at the signer: the push run prepared the app (prepare-nightly-variant ran there, and the
# dispatch waited for it), and the sign run's resume restores that prepared app instead of the unsigned app, the
# helper and the license trees, which only the preparation reads. It re-uploads only what this run's jobs read
# (the prepared app, the daemon, the source archive). Measured 2026-11-12 (sign run 43282010692): 2.9 min of
# preparation and its hops, and 2.0 min re-uploading the unsigned app, before the signer started.
TAIL_SIGN = {**TAIL}
TAIL_SIGN_OUTPUTS = {"published-build": {**SIGN_OUTPUTS["published-build"], "cross_run": "true", "run_tail": "true"}}
try:
    sign_results = simulate(dict(SIGN), SIGN_OUTPUTS)
    tail_sign_results = simulate(dict(TAIL_SIGN), TAIL_SIGN_OUTPUTS)
    legacy_sign = simulate(dict(SIGN), {**SIGN_OUTPUTS, "build-nightly-app": {"prepared": ""}})
except ValueError as error:
    failures.append(f"the sign run's `if:`s do not evaluate: {error}")
else:
    if push_results.get("prepare-nightly-variant-primary") != "success" \
            or push_results.get("prepare-nightly-variant") != "success":
        failures.append("a pipelined push run prepares the app before it dispatches the sign run")
    if "needs.prepare-nightly-variant.result == 'success'" not in cond("dispatch-nightly-next-sign"):
        failures.append("dispatch-nightly-next-sign dispatches only after prepare-nightly-variant succeeded")
    if sign_results.get("prepare-nightly-variant-primary") != "skipped":
        failures.append("a sign run whose push run prepared the app prepares nothing again")
    if sign_results.get("prepare-nightly-variant") == "skipped" or sign_results.get("pick-nightly-sign-runner") == "skipped":
        failures.append("a sign run with the push run's prepared app goes on to the sign runner pick")
    if legacy_sign.get("prepare-nightly-variant-primary") == "skipped":
        failures.append("a sign run of a push run that did not prepare (an older run) still prepares the app itself")
    # The sign group frees at the feed: the dSYMs on R2 go to the tail run of a sign run, which the record names
    # (sign_stage). The GitHub release stays in the sign run: the next sign run's decide reads its body
    # (published_sha), the span of that build's release notes and PR comments.
    if sign_results.get("keep-published-dsyms") != "skipped":
        failures.append("keep-published-dsyms runs in a sign run's tail run, not in the sign run, which holds the sign group")
    if tail_sign_results.get("keep-published-dsyms") == "skipped":
        failures.append("keep-published-dsyms must run in the tail run of a sign run (published-build's sign_stage)")
    if tail_sign_results.get("publish-nightly-next-github") != "skipped":
        failures.append("publish-nightly-next-github stays in the sign run: the next decide reads the release body")
    if sign_results.get("publish-nightly-next-github") == "skipped":
        failures.append("publish-nightly-next-github runs in the sign run that published")
    # A push loop run (pipeline off) keeps its dSYMs in the run, and its tail never keeps them again.
    loop_tail = simulate(dict(TAIL), {"published-build": {**TAIL_SIGN_OUTPUTS["published-build"], "sign_stage": ""}})
    if loop_tail.get("keep-published-dsyms") != "skipped":
        failures.append("keep-published-dsyms runs in a tail run only for a sign run's build")

build_app = JOBS["build-nightly-app"]
resume_step = next((s for s in build_app.get("steps", []) if s.get("id") == "resume"), {})
if "prepared-app" not in str((resume_step.get("env") or {}).get("NIGHTLY_NEXT_PREPARED_ARTIFACT", "")):
    failures.append("the sign stage's resume names the push run's prepared app (NIGHTLY_NEXT_PREPARED_ARTIFACT)")
if "steps.resume.outputs.prepared" not in str((build_app.get("outputs") or {}).get("prepared", "")):
    failures.append("build-nightly-app outputs whether the resume restored a prepared app (prepared)")
uploads = {str(s.get("name", "")): s for s in build_app.get("steps", []) if "upload-artifact" in str(s.get("uses", ""))}
for artifact in ("cmux-nightly-unsigned-app", "cmux-nightly-ghostty-cli-helper", "cmux-next-license-trees"):
    for name, step in uploads.items():
        if name.startswith(f"Retain resumed {artifact}") and "steps.resume.outputs.prepared != 'true'" not in str(step.get("if", "")):
            failures.append(f"{name!r}: only the preparation reads it, so a prepared resume does not re-upload it")
prepared_uploads = [s for n, s in uploads.items() if n.startswith("Retain the resumed prepared app")]
if not prepared_uploads or any("steps.resume.outputs.prepared == 'true'" not in str(s.get("if", "")) or
                               "prepared-app" not in str((s.get("with") or {}).get("name", ""))
                               for s in prepared_uploads):
    failures.append("a prepared resume re-uploads the prepared app under the name the sign job downloads")

# The resume's prepared mode: the push run's prepare-nightly-variant succeeded in that attempt, and its artifact is
# digest-checked and from that run, as every other restored artifact.
PREPARED = f"cmux-nightly-prepared-app-arm64-{SHA[:7]}"
prep_jobs = [*jobs, dict(window, name="prepare-nightly-variant-primary (arm64)", started_at="2026-11-08T10:20:00Z",
                         completed_at="2026-11-08T10:23:00Z"),
             dict(window, name="prepare-nightly-variant (arm64)", started_at="2026-11-08T10:23:00Z",
                  completed_at="2026-11-08T10:23:10Z")]
prep_artifact = {"name": PREPARED, "expired": False, "created_at": "2026-11-08T10:22:00Z", "digest": "sha256:" + "1" * 64,
                 "workflow_run": identity}


def prepared(job_list, artifact_list, name=PREPARED, live_ok=True):
    source = run if live_ok else {**run, "status": "completed", "conclusion": "success"}
    try:
        result = resume.validate(source, job_list, artifact_list, REPO, "7", "1", live_ok=live_ok, prepared=name)
    except (SystemExit, TypeError):
        return "refused"
    return (result.get("prepared") or {}).get("name") or "legacy"


if prepared(prep_jobs, [*artifacts, prep_artifact]) != PREPARED:
    failures.append("a sign stage restores the push run's prepared app once prepare-nightly-variant succeeded")
if prepared(jobs, artifacts) != "legacy":
    failures.append("a push run that did not prepare (an older run) resumes as before, from the unsigned app")
if prepared(prep_jobs, [*artifacts, prep_artifact], live_ok=False) != "legacy":
    failures.append("only a sign stage reads the prepared app")
if prepared(prep_jobs, artifacts) != "refused":
    failures.append("a push run that prepared but has no prepared artifact is refused")
if prepared(prep_jobs, [*artifacts, dict(prep_artifact, digest="")]) != "refused":
    failures.append("a prepared artifact without a digest is refused")
if prepared(prep_jobs, [*artifacts, dict(prep_artifact, workflow_run={**identity, "id": 8})]) != "refused":
    failures.append("a prepared artifact of another run is refused")
if prepared(prep_jobs, [*artifacts, dict(prep_artifact, created_at="2026-11-08T10:30:00Z")]) != "refused":
    failures.append("a prepared artifact made outside the preparation jobs is refused")
failed_prep = [*jobs, dict(prep_jobs[-1], conclusion="failure")]
if prepared(failed_prep, [*artifacts, prep_artifact]) != "legacy":
    failures.append("a preparation that did not succeed is never restored")
if prepared(prep_jobs, [*artifacts, prep_artifact], name=f"cmux-nightly-prepared-app-arm64-{'b' * 7}") != "refused":
    failures.append("the prepared app must be of the compiled source (its short sha)")

# The record names a sign run (sign_stage), so its tail keeps the dSYMs; a record without it (an older run) is valid.
spec = importlib.util.spec_from_file_location("published", ROOT / "scripts" / "ci" / "nightly_published_build.py")
published = importlib.util.module_from_spec(spec)
spec.loader.exec_module(published)
rec = published.record({}, "7", "1", SHA)
if "sign_stage" not in rec:
    failures.append("the published build's record says whether a sign run published it (sign_stage)")
else:
    if not published.valid(rec) or not published.valid({k: v for k, v in rec.items() if k != "sign_stage"}):
        failures.append("a record with or without sign_stage is valid")
pb_outputs = JOBS["published-build"].get("outputs") or {}
if "steps.record.outputs.sign_stage" not in str(pb_outputs.get("sign_stage", "")):
    failures.append("published-build outputs sign_stage")
if "inputs.nightly_next_sign_stage" not in str(JOBS["dispatch-published-in"].get("env", {}).get("SIGN_STAGE", "")):
    failures.append("dispatch-published-in packs whether this is a sign run (SIGN_STAGE)")

# verify-signed-nightly read the signed app over one connection (4.4 min on 2026-11-12); a sign stage fetches it
# over ranged HTTP first (digest-checked), the action download as the fallback.
verify_steps = JOBS["verify-signed-nightly"].get("steps", [])
fast = next((s for s in verify_steps if str(s.get("name", "")).startswith("Download signed app (parallel)")), None)
if fast is None or "inputs.nightly_next_sign_stage != ''" not in str(fast.get("if", "")) or not fast.get("continue-on-error"):
    failures.append("verify-signed-nightly downloads the signed app over ranged HTTP in a sign stage, best effort")
elif "download-run-artifact.py" not in str(fast.get("run", "")):
    failures.append("the ranged download is download-run-artifact.py, which checks the artifact's digest")

# nightly-sign.yml (shadow) admits a run by the nightly-prepared-app notice of its prepare-nightly-variant job, or
# of the primary leg it reused. A prepared resume skips the primary, so the fallback leg records the digest of the
# restored prepared app, the tarball whose zip the resume checked against the push run's artifact digest.
# By name, as tests/test_nightly_sign_shadow_workflow.py imports it: a load by path here made a second module object
# of scripts/ci/nightly_sign_admit.py beside that one (tests/test_script_module_loads.py names it).
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import nightly_sign_admit as admit  # noqa: E402
import hashlib  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402

with tempfile.TemporaryDirectory() as tmp:
    tarball = Path(tmp) / "prepared" / "cmux-prepared-app.tar.gz"
    tarball.parent.mkdir()
    tarball.write_bytes(b"prepared app")
    if getattr(resume, "prepared_sha256", lambda _root: None)(Path(tmp)) != hashlib.sha256(b"prepared app").hexdigest():
        failures.append("the resume reports the sha256 of the restored prepared tarball (prepared_sha256)")
if "steps.resume.outputs.prepared_sha256" not in str((build_app.get("outputs") or {}).get("prepared_sha256", "")):
    failures.append("build-nightly-app outputs the restored prepared app's sha256 (prepared_sha256)")
reuse = next((s for s in JOBS["prepare-nightly-variant"].get("steps", []) if s.get("id") == "reuse"), {})
reuse_env = {k: str(v) for k, v in (reuse.get("env") or {}).items()}
if "needs.build-nightly-app.outputs.prepared_sha256" not in reuse_env.get("PREPARED_SHA256", ""):
    failures.append("the fallback leg reads the restored prepared app's sha256 (PREPARED_SHA256)")


def reuse_notices(**env):
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out"
        out.touch()
        base = {"PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(out), "NIGHTLY_VARIANT": "arm64",
                "NIGHTLY_FAST_BUILD": "false", "NIGHTLY_SHOULD_PUBLISH": "true", "ARTIFACT": PREPARED,
                "PRIMARY_RESULT": "skipped", "RESUMED_PREPARED": "true", "PREPARED_SHA256": "c" * 64}
        done = subprocess.run(["bash", "-c", str(reuse.get("run", ""))], env={**base, **env}, capture_output=True,
                              text=True, timeout=30)
        notices = re.findall(rf"^::notice title={admit.DIGEST_TITLE}::(.*)$", done.stdout, re.M)
        return done.returncode, notices, out.read_text()


code, notices, outputs = reuse_notices()
if code != 0 or "exists=true" not in outputs or len(notices) != 1:
    failures.append(f"a prepared resume's fallback leg records one {admit.DIGEST_TITLE} digest (got {notices})")
else:
    match = admit.DIGEST_MESSAGE.match(notices[0])
    if not match or match.groups() != ("arm64", PREPARED, "c" * 64, "true", "false"):
        failures.append(f"the fallback leg's digest record is the one nightly_sign_admit parses: {notices[0]!r}")
code, notices, _ = reuse_notices(PREPARED_SHA256="")
if code == 0 or notices:
    failures.append("a prepared resume without the restored app's sha256 fails the fallback leg, records nothing")
code, notices, _ = reuse_notices(PRIMARY_RESULT="success", RESUMED_PREPARED="", PREPARED_SHA256="")
if code != 0 or notices:
    failures.append("after a primary success the fallback records nothing: the primary's record is the producer's")

if failures:
    print("FAIL: nightly-next build and sign stages pipelined\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next build and sign stages pipelined")

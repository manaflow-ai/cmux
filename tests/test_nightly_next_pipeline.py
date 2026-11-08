#!/usr/bin/env python3
"""A nightly-next push run builds; a dispatched sign run signs and publishes, so build N+1 overlaps sign N.

The lag bound (cmuxterm-hq goals/nightly-30min.md, Model 2026-11-08): the peak lag is about A + R + P, where
R is one run end to end and P the publish period. With one push run holding the push group from decide to the
GitHub release, P = R. Splitting the run at the unsigned app makes P = max(B, S), the slower stage:

- a push run (decide = pipeline) keeps the push group only through the unsigned-app build, then
  dispatch-nightly-next-sign dispatches the existing unsigned resume (nightly_next_unsigned_run/attempt) with
  nightly_next_sign_stage set. The push run skips prepare, sign, verify, recovery, the tree-marker wait and
  publish, so its group frees as soon as the build's artifacts are up.
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

# The push run builds only: the sign stage's roots skip there.
for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant", "find-nightly-next-recovery",
             "await-nightly-tree-marker", "route-visual-gate-nightly"):
    if PIPELINE_OFF not in cond(name):
        failures.append(f"{name} must skip in a pipelined push run ({PIPELINE_OFF})")

dispatch = JOBS.get("dispatch-nightly-next-sign")
if dispatch is None:
    failures.append("no dispatch-nightly-next-sign job hands the unsigned app to the sign stage")
else:
    for job in ("decide", "resolve-nightly-cmux-tui-client", "build-nightly-app", "build-nightly-ghostty-cli-helper",
                "build-nightly-remote-daemon"):
        if job not in needs("dispatch-nightly-next-sign"):
            failures.append(f"dispatch-nightly-next-sign must wait for {job}: the resume reads what it uploads")
        elif job != "decide" and f"needs.{job}.result == 'success'" not in cond("dispatch-nightly-next-sign"):
            failures.append(f"dispatch-nightly-next-sign dispatches only after {job} succeeded")
    for job in ("prepare-nightly-variant", "pick-nightly-sign-runner", "build-sign-notarize-nightly", "publish-nightly",
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
    runs_on = str(dispatch.get("runs-on", ""))
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
    "decide": {"pipeline": "true", "track": "nightly-next", "should_build": "true", "should_publish": "true",
               "no_publish": "false", "notary_test": "false", "notary_paused": "false", "continue_only": "false",
               "republish_run": "", "fast_build": "false", "build_only": "false"},
    "resolve-nightly-cmux-tui-client": {"already_published": "false", "superseded": "", "build_sha": SHA},
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
    # A sign run dispatches its tail (run_tail false, as checked above).
    "published-build": {"run_tail": "false"},
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

if failures:
    print("FAIL: nightly-next build and sign stages pipelined\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next build and sign stages pipelined")

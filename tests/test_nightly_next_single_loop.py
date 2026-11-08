#!/usr/bin/env python3
"""nightly-next is one latest-wins loop on the nightly mini.

Leo, 2026-11-06: "when it finishes, it starts another one, like the latest one at that
present moment". One run at a time does the whole pipeline; the push group keeps one pending place,
which the newest arrival takes. A failed run is retried at the newest commit by the loop itself
(retry-nightly-next), in the same group, and main's feed watch resume builds nothing: run
42251281669 (a watch resume of an older run) signed beside push run 42244796779 and held its
publish 23 min.

A loop run holds the push group only through publish and the GitHub release (whose body and tag the next
run's decide reads), then dispatches the deltas, notes, reel and PR comments as a run-scoped run
(dispatch-published-in). Holding it through that whole tail made the newest head wait about 79 min per
cycle (172 of 198 push runs replaced while pending in 26 h, 2026-11-07).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / ".github" / "workflows" / "nightly.yml").read_text()
DOC = yaml.safe_load(TEXT)
JOBS = DOC["jobs"]
failures: list[str] = []

group = str(DOC.get("concurrency", {}).get("group", ""))
if "github.event_name == 'workflow_dispatch' && inputs.nightly_next_loop_retry != ''" not in group:
    failures.append("the loop's retry dispatch must take the nightly-next push group")
inputs = DOC.get(True, DOC.get("on", {})).get("workflow_dispatch", {}).get("inputs", {})
if "nightly_next_loop_retry" not in inputs:
    failures.append("workflow_dispatch needs the nightly_next_loop_retry input")

retry = JOBS.get("retry-nightly-next")
if retry is None:
    failures.append("no retry-nightly-next job retries a failed run")
else:
    cond = str(retry.get("if", ""))
    for term in ("!cancelled()", "needs.publish-nightly.result != 'success'", "github.ref == 'refs/heads/nightly-next'",
                 "needs.decide.outputs.should_build == 'true'", "needs.decide.outputs.no_publish != 'true'"):
        if term not in cond:
            failures.append(f"retry-nightly-next must run only after a failed nightly-next build ({term})")
    if (retry.get("permissions") or {}).get("actions") != "write":
        failures.append("retry-nightly-next dispatches nightly.yml: it needs actions: write")
    body = "\n".join(str(step.get("run", "")) for step in retry.get("steps", []))
    for piece in ("git/ref/heads/nightly-next", '"$head" != "$SHA"', '-gt 2', "nightly_next_loop_retry=",
                  "gh workflow run nightly.yml"):
        if piece not in body:
            failures.append(f"retry-nightly-next must check the head, cap at two and dispatch ({piece})")
    # A push can land between the head check and the dispatch and lose its pending place to the retry;
    # the retry then runs at that newer head, so resuming this run's unsigned app would publish the older one.
    if "nightly_next_unsigned_run" in body:
        failures.append("retry-nightly-next must build the head again, never resume this run's unsigned app")
    runs_on = str(retry.get("runs-on", ""))
    if "blacksmith" in runs_on.lower() or "ubuntu-24.04' ||" in runs_on.replace("'ubuntu-24.04' || vars", ""):
        failures.append("retry-nightly-next stays on the nightly mini")

# A loop run's group ends at the GitHub release: the deltas, notes and comments are dispatched.
dispatch = JOBS.get("dispatch-published-in")
if dispatch is None:
    failures.append("a loop run must dispatch its tail after the GitHub release (dispatch-published-in)")
else:
    dispatch_needs = dispatch.get("needs") or []
    if "publish-nightly-next-github" not in dispatch_needs:
        failures.append("dispatch-published-in must wait for the GitHub release: the next decide reads its body and tag")
    if "needs.published-build.outputs.run_tail != 'true'" not in str(dispatch.get("if", "")):
        failures.append("dispatch-published-in must dispatch only from a loop run (run_tail)")
run_tail = str((JOBS.get("published-build", {}).get("outputs") or {}).get("run_tail", ""))
if "github.event_name != 'push' && inputs.nightly_next_loop_retry == ''" not in run_tail:
    failures.append("published-build's run_tail must be false in a push run and in the loop's retry")
for name in ("generate-nightly-deltas", "sign-release-notes", "published-in"):
    if "needs.published-build.outputs.run_tail == 'true'" not in str(JOBS.get(name, {}).get("if", "")):
        failures.append(f"{name} must not hold a loop run's push group (run_tail)")

decide = "\n".join(str(step.get("with", {}).get("script", "")) for step in JOBS["decide"].get("steps", []))
if "resumeOutsideLoop" not in decide or "if (resumeOutsideLoop) shouldBuild = false;" not in decide:
    failures.append("decide must build nothing for an unsigned resume the loop did not ask for")
if "LOOP_RETRY" not in decide:
    failures.append("decide must validate nightly_next_loop_retry")

if failures:
    print("FAIL: nightly-next single loop\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next single loop")

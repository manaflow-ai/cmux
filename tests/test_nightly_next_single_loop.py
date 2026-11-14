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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_jobs  # noqa: E402

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
    # The step's run block lives in scripts/ci/nightly-steps/ (nightly.yml's size budget).
    for script in re.findall(r"scripts/ci/nightly-steps/[\w.-]+\.sh", body):
        body += "\n" + (ROOT / script).read_text()
    for piece in ("git/ref/heads/nightly-next", '"$head" != "$SHA"', '-gt 2', "nightly_next_loop_retry=",
                  "gh workflow run nightly.yml"):
        if piece not in body:
            failures.append(f"retry-nightly-next must check the head, cap at two and dispatch ({piece})")
    # A push can land between the head check and the dispatch and lose its pending place to the retry;
    # the retry then runs at that newer head, so resuming this run's unsigned app would publish the older one.
    if "nightly_next_unsigned_run" in body:
        failures.append("retry-nightly-next must build the head again, never resume this run's unsigned app")
    runs_on = workflow_jobs.single_runs_on(retry)
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

# A loop retry that started just before a newer push leaves the build slot to that push's run (runs 43395284047
# and 43395323737, 2026-11-13: retry 2 of c31b2b678 was dispatched at 08:42:11, nightly-next moved to 7341dd7 at
# 08:42:29, and the push run waited 19 min for a retry of the older commit). The check runs in resolve, before any
# build job starts, so no started build is ever left; the push run is pending in the same group and builds the head.
resolve_steps = {step.get("id"): step for step in JOBS["resolve-nightly-cmux-tui-client"].get("steps", [])}
leave = resolve_steps.get("superseded") or {}
leave_if = " ".join(str(leave.get("if", "")).split())
# Latest wins at the slot (runs 43558081148 and 43560964857, 2026-11-14): push run 43558081148 of a22a4eb1 waited
# 23 min in the group behind another build, started at 05:06 with 20 newer feat-cmux-next commits and built the old
# head; it failed and its retry built a22a4eb1 again (60.9 min from landing to the feed). Every push run and retry
# reaches the step; the script waits there for the tick's promotion when the run is stale (a retry, or a push that
# waited YIELD_STALE_MINUTES in the group) and feat-cmux-next moved, and main's rolling rule counts a run in this
# step as no holder (LEAVE_SLOT_STEP in scripts/ci/nightly_next_rolling.py).
if leave.get("name") != "Leave the build slot to a newer nightly-next push":
    failures.append("main's rolling rule finds the waiting run by this step's name; keep it")
if "inputs.nightly_next_loop_retry != ''" not in leave_if or "github.event_name == 'push' ||" not in leave_if:
    failures.append("every push run and loop retry reaches the leave-slot step (the script decides whether it waits)")
if "github.ref == 'refs/heads/nightly-next'" not in leave_if:
    failures.append("only nightly-next runs leave the build slot")


def leave_slot(heads: list[str], tip: str, *, feat: str = "", created_min_ago: float = 0.5, **env_extra) -> str:
    """Runs resolve-leave-build-slot.sh with a gh whose nightly-next ref answers `heads` in turn (the last one
    repeats), feat-cmux-next answers `feat` and the run was created `created_min_ago` minutes ago."""
    import datetime as dt
    import os
    import subprocess
    import tempfile
    created = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=created_min_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "heads").write_text("\n".join(heads) + "\n")
        fake = Path(tmp) / "gh"
        fake.write_text(f"""#!/bin/sh
case "$2" in
  */heads/nightly-next) n=$(cat {tmp}/n 2>/dev/null || echo 1); sed -n "${{n}}p" {tmp}/heads | grep . || tail -n 1 {tmp}/heads
                        echo $((n + 1)) > {tmp}/n ;;
  */heads/feat-cmux-next) echo {feat} ;;
  */actions/runs/*) echo {created} ;;
esac
""")
        fake.chmod(0o755)
        out = Path(tmp) / "out"
        env = {key: value for key, value in os.environ.items() if key not in ("LOOP_RETRY", "SUPERSEDE_SKIP")}
        env.update(PATH=f"{tmp}:{os.environ['PATH']}", GITHUB_OUTPUT=str(out), TIP_SHA=tip, REPOSITORY="o/r",
                   GITHUB_RUN_ID="1", YIELD_MINUTES="1", YIELD_POLL_SECONDS="0")
        env.update(env_extra)
        subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/resolve-leave-build-slot.sh")], env=env,
                       check=True, capture_output=True, timeout=120)
        return out.read_text()


OLD_HEAD, NEW_HEAD = "c31b2b6786669f7d25210f6496653b58bcc71dd3", "7341dd7bef6021463ef2ad54a9189502e8361adf"
FEAT_TIP = "fdb12f557063a1c5d4bb55b4ef47c6e70f6ef0b3"
if leave_slot([NEW_HEAD], OLD_HEAD, LOOP_RETRY="1").strip() != "superseded=true":
    failures.append("a loop retry whose head nightly-next moved past must leave the build slot")
if leave_slot([NEW_HEAD], OLD_HEAD, SUPERSEDE_SKIP="1").strip() != "superseded=true":
    failures.append("a push run leaves a moved head at once with vars.NIGHTLY_NEXT_SUPERSEDE_SKIP == '1'")
if leave_slot([OLD_HEAD], OLD_HEAD, LOOP_RETRY="1").strip() != "superseded=false":
    failures.append("a run at the nightly-next head with nothing newer on feat-cmux-next keeps the build slot")
if leave_slot([""], OLD_HEAD, LOOP_RETRY="1").strip() != "superseded=false":
    failures.append("an unread nightly-next ref keeps the build slot")
# The a22a4eb1 case: the run is stale and feat-cmux-next moved; the tick promotes a newer commit while it waits.
if leave_slot([OLD_HEAD, OLD_HEAD, NEW_HEAD], OLD_HEAD, feat=FEAT_TIP, created_min_ago=23).strip() != "superseded=true":
    failures.append("a push run that waited 23 min in the group must wait for the tick's promotion and leave to it")
if leave_slot([OLD_HEAD, NEW_HEAD], OLD_HEAD, feat=FEAT_TIP, LOOP_RETRY="1").strip() != "superseded=true":
    failures.append("a loop retry must wait for the tick to promote a newer buildable commit and leave to it")
if leave_slot([OLD_HEAD, NEW_HEAD], OLD_HEAD, feat=FEAT_TIP, created_min_ago=1).strip() != "superseded=false":
    failures.append("a fresh push run never waits for a promotion")
if leave_slot([OLD_HEAD], OLD_HEAD, feat=FEAT_TIP, created_min_ago=23, YIELD_MINUTES="0").strip() != "superseded=false":
    failures.append("a stale run with nothing promoted in YIELD_MINUTES builds its own commit")

decide = "\n".join(str(step.get("with", {}).get("script", "")) for step in JOBS["decide"].get("steps", []))
if "resumeOutsideLoop" not in decide or "if (resumeOutsideLoop) shouldBuild = false;" not in decide:
    failures.append("decide must build nothing for an unsigned resume the loop did not ask for")
if "LOOP_RETRY" not in decide:
    failures.append("decide must validate nightly_next_loop_retry")

if failures:
    print("FAIL: nightly-next single loop\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next single loop")

#!/usr/bin/env python3
"""Evidence-only adapter for one existing CMUX unittest recipe. No build/merge authority."""
import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

RECIPE = "tests/test_docs_deploy_auth_guard.py"
STEP = "Validate docs deployment authentication guard"
PHASES = ("preparation", "parsing", "typechecking", "tests", "packaging", "live")
STATES = {"passed", "failed", "skipped", "unsupported", "interrupted"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def envelope():
    return {
        "schema_version": "cmux-verification/v1",
        "authority": "evidence_only",
        "recipe": {"id": RECIPE, "revision": None, "claim_class": "python-workflow-guard-tests",
                   "argv": ["python3", RECIPE]},
        "source": {"semantics": "latest_checkout_at_execution", "repository": None,
                   "base_sha": None, "head_sha": None, "checkout_sha": None, "merge_sha": None, "tree": None,
                   "before": None, "after": None, "exact_snapshot": None},
        "environment": {"platform": None, "architecture": None, "toolchain": None,
                        "configuration": "workflow guard", "build_input_identity": None},
        "checks": [{"phase": p, "status": "skipped", "executed": False,
                    "evidence": None} for p in PHASES],
        "tests": {"selection": [RECIPE], "selected": None, "discovered": None,
                  "executed": None, "runner_reported": None, "skipped": None,
                  "accepted_baselines": []},
        "artifacts": {"produced": None, "launched": None},
        "review": {"status": "unsupported", "reviewed_head": None, "current_head": None,
                   "evidence": None},
        "evidence": {},
        "integrations": {"glaeda_request_id": None, "glaeda_run_id": None,
                         "stensibly_run_id": None, "stensibly_settlement_id": None},
    }


def check(result, phase):
    return next(c for c in result["checks"] if c["phase"] == phase)


def unittest_summary(log):
    """One terminal unittest summary only; do not count unrelated job output."""
    runs = re.findall(r"^Ran (\d+) tests? in [^\n]+$", log, re.M)
    finals = re.findall(r"^(OK(?: \([^\n]*\))?|FAILED \([^\n]*\))$", log, re.M)
    if len(runs) != 1 or len(finals) != 1:
        return {"runner_reported": None, "executed": None, "skipped": None}, False
    count = int(runs[0])
    skipped = re.search(r"skipped=(\d+)", finals[0])
    skipped = int(skipped[1]) if skipped else 0
    if skipped > count:
        return {"runner_reported": None, "executed": None, "skipped": None}, False
    return {"runner_reported": count, "executed": count - skipped, "skipped": skipped}, finals[0].startswith("OK")


def assess(result):
    """Conservative derived qualifications, never a replacement for provider conclusions."""
    if result.get("schema_version") != "cmux-verification/v1":
        raise ValueError("unsupported receipt schema_version")
    reasons = []
    for c in result["checks"]:
        if c["status"] not in STATES:
            raise ValueError("unsupported check status")
        if c["status"] == "passed" and (not c["executed"] or not c["evidence"]):
            reasons.append("passed_check_without_execution_evidence:" + c["phase"])
    source = result["source"]
    # This slice does not establish immutable materialization, even with clean equal HEADs.
    reasons.append("exact_snapshot_not_established")
    before, after = source["before"], source["after"]
    if before and after and before != after:
        reasons.append("source_drift_observed")
    if not before or not after or before.get("clean") is not True or after.get("clean") is not True:
        reasons.append("dirty_or_unknown_source")
    tc = check(result, "tests")
    if tc.get("reported_status", tc["status"]) == "passed" and not (result["tests"]["executed"] or 0) > 0:
        tc["reported_status"] = "passed"
        tc["status"] = "failed"
        reasons.append("no_observed_executed_tests")
    review = result["review"]
    current = review["current_head"]
    review_current = bool(review["status"] == "passed" and review["evidence"] and current
                          and current == review["reviewed_head"])
    if review["status"] == "passed" and not review_current:
        reasons.append("review_head_stale_or_unknown")
    produced, launched = result["artifacts"]["produced"], result["artifacts"]["launched"]
    fields = ("sha256", "tag", "bundle_id", "source_identity")
    artifact_matches = bool(produced and launched and all(produced.get(k) and
                            produced[k] == launched.get(k) for k in fields))
    if check(result, "live")["status"] == "passed" and not artifact_matches:
        reasons.append("launched_artifact_mismatch_or_unknown")
    result["assessment"] = {"exact_verification": False, "review_current": review_current,
                            "launched_matches_produced": artifact_matches,
                            "qualifications": reasons}
    return result


def observe(repo):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()
    try:
        status = git("status", "--porcelain", "--untracked-files=normal")
        # Path names and raw diffs never enter the public receipt.
        diff = subprocess.check_output(["git", "-C", str(repo), "diff", "HEAD", "--binary"])
        return {"commit": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}"),
                "clean": not bool(status), "tracked_diff_sha256": digest(diff),
                "status_sha256": digest(status.encode())}
    except (subprocess.CalledProcessError, OSError):
        return {"commit": None, "tree": None, "clean": None}


def local(repo):
    r = envelope()
    r["source"]["repository"] = "cmux (caller-supplied checkout)"
    r["source"]["before"] = observe(repo)
    r["source"]["head_sha"] = r["source"]["before"]["commit"]
    r["source"]["checkout_sha"] = r["source"]["before"]["commit"]
    r["source"]["tree"] = r["source"]["before"].get("tree")
    recipe = repo / RECIPE
    if not recipe.is_file():
        check(r, "tests").update(status="unsupported")
        r["source"]["after"] = observe(repo)
        return assess(r)
    r["recipe"]["revision"] = "sha256:" + digest(recipe.read_bytes())
    r["environment"].update(platform=platform.system(), architecture=platform.machine(),
                             toolchain=subprocess.check_output(["python3", "--version"], text=True).strip())
    started = datetime.now(timezone.utc).isoformat()
    try:
        completed = subprocess.run(["python3", RECIPE], cwd=repo, capture_output=True, text=True,
                                   timeout=60)
        output = completed.stdout + completed.stderr
        code = completed.returncode
        state = "interrupted" if code < 0 or code in (130, 143) else "failed"
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        output, code, state = "", None, "interrupted"
    r["source"]["after"] = observe(repo)
    counts, ok = unittest_summary(output)
    r["tests"].update(counts)
    if code == 0 and ok and (counts["executed"] or 0) > 0:
        state = "passed"
    r["evidence"] = {"kind": "local_process", "started_at": started,
                     "completed_at": datetime.now(timezone.utc).isoformat(), "exit_code": code,
                     "output_sha256": digest(output.encode()),
                     "summary": safe_summary(output)}
    check(r, "tests").update(status=state, executed=True, evidence="evidence")
    return assess(r)


def safe_summary(output):
    return [s for s in output.splitlines() if re.fullmatch(
        r"Ran \d+ tests? in [\d.]+s|OK(?: \([a-zA-Z0-9=, ]+\))?|FAILED \([a-zA-Z0-9=, ]+\)", s)][:3]


def ci(run, job, log):
    if job["run_id"] != run["id"]:
        raise ValueError("job does not belong to run")
    steps = [s for s in job["steps"] if s["name"] == STEP]
    if len(steps) != 1:
        raise ValueError("expected exactly one supported recipe step")
    step = steps[0]
    r = envelope()
    r["source"].update(repository=run["repository"]["full_name"], head_sha=run["head_sha"])
    prs = run.get("pull_requests", [])
    if len(prs) == 1:
        r["source"]["base_sha"] = prs[0]["base"]["sha"]
    # Strip timestamps/ANSI before matching anchored recipe output. Never publish raw logs.
    clean = re.sub(r"\x1b\[[0-9;]*m", "", log)
    clean = re.sub(r"^\S+Z ", "", clean, flags=re.M)
    checkout = re.search(r"\[command\][^\n]*git log -1 --format=%H\n([0-9a-f]{40})\n", clean)
    actual = checkout[1] if checkout else None
    r["source"]["before"] = {"commit": actual, "clean": None}
    r["source"]["checkout_sha"] = actual
    merge = re.search(r"HEAD is now at ([0-9a-f]+) Merge ([0-9a-f]{40}) into ([0-9a-f]{40})", clean)
    if merge and actual and actual.startswith(merge[1]) and merge[2] == run["head_sha"]:
        r["source"]["merge_sha"] = actual
    starts = list(re.finditer(r"^##\[group\]Run python3 " + re.escape(RECIPE) + r"\n", clean, re.M))
    selected_log = ""
    if len(starts) == 1:
        selected_log = clean[starts[0].end():].split("##[group]", 1)[0]
    counts, ok = unittest_summary(selected_log)
    r["tests"].update(counts)
    conclusion = step.get("conclusion")
    state = {"success": "passed", "failure": "failed", "skipped": "skipped",
             "cancelled": "interrupted", "timed_out": "interrupted"}.get(conclusion, "unsupported")
    if step.get("status") != "completed":
        state = "interrupted"
    if state == "passed" and not (ok and (counts["executed"] or 0) > 0):
        state = "failed"  # provider success remains intact below
    r["recipe"]["revision"] = actual  # observed checkout; workflow revision remains unknown
    r["environment"]["runner_labels"] = job.get("labels", [])
    r["evidence"] = {"kind": "github_actions", "run_id": run["id"],
                     "run_attempt": run["run_attempt"], "event": run["event"],
                     "run_conclusion": run["conclusion"], "job_id": job["id"],
                     "job_name": job["name"], "job_conclusion": job["conclusion"],
                     "step_number": step["number"], "step_name": step["name"],
                     "step_conclusion": conclusion, "started_at": step.get("started_at"),
                     "completed_at": step.get("completed_at"),
                     "workflow_path": run["path"], "workflow_revision": None,
                     "url": f'https://github.com/{run["repository"]["full_name"]}/actions/runs/{run["id"]}/job/{job["id"]}',
                     "log_sha256": digest(log.encode()), "summary": safe_summary(selected_log)}
    check(r, "tests").update(status=state, executed=bool(selected_log), evidence="evidence")
    return assess(r)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)
    loc = sub.add_parser("local")
    loc.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1],
                     help="CMUX checkout (defaults to this script’s repository)")
    imp = sub.add_parser("ci")
    for name in ("run", "job", "log"):
        imp.add_argument("--" + name, type=Path, required=True)
    replay = sub.add_parser("replay-ci")
    replay.add_argument("receipt", type=Path)
    fixture = sub.add_parser("assess")
    fixture.add_argument("receipt", type=Path)
    args = p.parse_args()
    if args.mode == "local":
        result = local(args.repo.resolve())
    elif args.mode == "ci":
        result = ci(json.loads(args.run.read_text()), json.loads(args.job.read_text()), args.log.read_text())
    elif args.mode == "replay-ci":
        data = json.loads(args.receipt.read_text())
        result = ci(data["run"], data["job"], data["log"])
    else:
        data = json.loads(args.receipt.read_text())
        result = assess(data.get("receipt", data))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if check(result, "tests")["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())

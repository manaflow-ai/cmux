#!/usr/bin/env python3
"""Observe a candidate job-input closure without using it to skip execution.

The warm-source table declares paths potentially independent of a job. The
existing input list and Swift graph reads take precedence; every other path,
including a new or unknown directory, remains an input. These are candidates,
not proofs: production full runs must validate them before any enforcement.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import job_input_fingerprint as inputs
import job_reuse

TABLE = ".github/warm-sources.json"
SCRIPT = "scripts/ci/rebuild_mirror.py"
SCHEMA = "ci-rebuild-mirror/v1"


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def under(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + "/")


def policy_identity(root: str, rev: str, job: str) -> str:
    """Identity of the declarations and planner code used by mirror evidence."""
    table = json.loads(inputs.git(root, "show", f"{rev}:{TABLE}"))
    policy = table["jobs"][f"cmux-next.yml:{job}"]["rebuild_mirror"]
    return digest({"policy": policy, "script": inputs.git(root, "rev-parse", f"{rev}:{SCRIPT}"),
                   "fingerprint": inputs.git(root, "rev-parse", f"{rev}:scripts/ci/job_input_fingerprint.py"),
                   "job_reuse": inputs.git(root, "rev-parse", f"{rev}:scripts/ci/job_reuse.py"),
                   "workflow": inputs.git(root, "rev-parse", f"{rev}:{inputs.WORKFLOW}"),
                   "graph": inputs.git(root, "rev-parse", f"{rev}:{inputs.GRAPH}")})


def candidate(root: str, rev: str, job: str, full: dict) -> tuple[str, dict]:
    """A proposed key. Never narrow a key when its declarations cannot be read."""
    if not full.get("tree") or job not in inputs.JOBS:
        raise inputs.Unresolved("job has no declared input closure")
    table = json.loads(inputs.git(root, "show", f"{rev}:{TABLE}"))
    policy = table["jobs"][f"cmux-next.yml:{job}"]["rebuild_mirror"]
    independent = policy["independent"]
    if not valid_paths(independent):
        raise inputs.Unresolved("independent paths must be literal repository-relative roots")
    # A missing graph is uncertainty, not an empty set of test reads.
    graph = json.loads(inputs.git(root, "show", f"{rev}:{inputs.GRAPH}"))
    if not isinstance(graph, dict) or not isinstance(graph.get("targets"), dict) or not graph["targets"]:
        raise inputs.Unresolved("missing Swift target graph")
    for target in graph["targets"].values():
        if (not isinstance(target, dict) or not isinstance(target.get("reads", []), list)
                or any(not isinstance(p, str) for p in target.get("reads", []))
                or (target.get("reads") and not valid_paths([inputs.normalize(p) for p in target["reads"]]))):
            raise inputs.Unresolved("malformed Swift target reads")
    declared = policy.get("inputs")
    if not valid_paths(declared):
        raise inputs.Unresolved("job has no declared input paths")
    keep = inputs.input_paths(root, rev, job) + declared + [TABLE, SCRIPT]
    result = subprocess.run(["git", "-C", root, "ls-tree", "-rz", "--full-tree", rev],
                            check=True, capture_output=True, timeout=120)
    selected, omitted = {}, []
    for entry in result.stdout.split(b"\0"):
        if not entry:
            continue
        meta, path_bytes = entry.split(b"\t", 1)
        path = path_bytes.decode("utf-8", errors="strict")
        if any(under(path, p) for p in independent) and not any(under(path, p) for p in keep):
            omitted.append(path)
        else:
            selected[path] = meta.decode("ascii")
    value = {key: val for key, val in full.items() if key != "tree"}
    value.update(schema=SCHEMA, inputs=selected)
    # Bind evidence to the actual planner and declarations, never a mutable version label.
    policy_key = policy_identity(root, rev, job)
    value["policy"] = policy_key
    return digest(value), {"policy": policy_key, "omitted_paths": len(omitted),
                           "input_paths": len(selected)}


def valid_paths(paths: object) -> bool:
    return (isinstance(paths, list) and bool(paths)
            and all(isinstance(p, str) and p and not p.startswith(("/", ":"))
                    and not any(part in ("", ".", "..") for part in p.split("/"))
                    and not any(c in p for c in "*?[\\\n\r\t") for p in paths))


def start(root: str, rev: str, job: str, full: dict, output: Path) -> None:
    """Save the prediction before execution. Lookup failures never predict a skip."""
    record = {"schema": SCHEMA, "job": job, "started_at": time.time(), "mode": "mirror",
              "sha": inputs.git(root, "rev-parse", f"{rev}^{{commit}}"),
              # Actions identifies a PR job by its branch head, while checkout
              # and the execution receipt use its synthetic merge commit.
              "head_sha": os.environ.get("REBUILD_HEAD_SHA", ""),
              "repository": os.environ.get("GITHUB_REPOSITORY", ""),
              "run_id": os.environ.get("GITHUB_RUN_ID", ""),
              "attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
              "full_fingerprint": digest(full), "candidate_skip": False}
    try:
        key, details = candidate(root, rev, job, full)
        record.update(details)
        record["candidate_key"] = f"job-pass-mirror-{job}-{key[:40]}"
        hit = job_reuse.lookup(record["candidate_key"], None)
        record["candidate_skip"] = hit.get("hit") == "true"
        record["previous_run"] = hit.get("run_url")
        record["previous_sha"] = hit.get("sha")
    except (inputs.Unresolved, job_reuse.Miss, OSError, ValueError, KeyError, TypeError, AttributeError,
            subprocess.SubprocessError) as error:
        record["uncertain"] = str(error)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(record, sort_keys=True) + "\n")
    print("mirror=true")
    # The workflow's promotion path looks up the narrowed candidate namespace,
    # while the legacy reuse key remains the full-tree fingerprint.
    if record.get("candidate_key"):
        print(f"candidate_key={record['candidate_key']}")


def finish(plan: Path, outcome: str, output: Path, execution_receipt: Path | None = None) -> dict:
    record = json.loads(plan.read_text())
    if record.get("schema") != SCHEMA or record.get("mode") != "mirror":
        raise ValueError("not a mirror plan")
    if outcome not in ("success", "failure", "cancelled", "skipped"):
        raise ValueError("unknown job outcome")
    record.update(outcome=outcome, finished_at=time.time())
    if outcome == "success":
        try:
            if execution_receipt is None:
                raise ValueError("no full-run receipt")
            execution = json.loads(execution_receipt.read_text())
            registry = json.loads(inputs.git(".", "show", f"{record['sha']}:scripts/cmux-next/fast-tier.json"))
            expected = sorted(e["name"] for e in registry["entries"] if e["kind"] in ("cargo", "script"))
            entries = execution["entries"]
            if (execution.get("schema") != "cmux-next-fast-tier-receipt.v1" or execution.get("status") != "pass"
                    or sorted(execution.get("kinds", [])) != ["cargo", "script"] or not expected
                    or sorted(e["name"] for e in entries) != expected
                    or any(e["status"] != "PASS" for e in entries)
                    or execution.get("github", {}).get("GITHUB_SHA") != record["sha"]
                    or str(execution.get("github", {}).get("GITHUB_RUN_ID")) != record["run_id"]):
                raise ValueError("full-run receipt does not prove all selected entries passed at this head")
            record["execution_receipt"] = digest(execution)
        except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
            record["uncertain"] = str(error)
    record["execution_minutes"] = max(0, record["finished_at"] - record["started_at"]) / 60
    record["false_skip"] = record.get("candidate_skip") is True and outcome == "failure"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(record, sort_keys=True) + "\n")
    # Only an actually executed success publishes a candidate green. The workflow
    # never skips execution in mirror mode, including on an existing whole-tree hit.
    if outcome == "success" and not record.get("uncertain") and record.get("candidate_key"):
        print(f"key={record['candidate_key']}")
    return record


def report(records: list[dict]) -> dict:
    """Summarize complete observations. Zero observations is not a zero error rate.

    This reports eligibility only; it cannot enable skipping. Missing artifacts
    require the collector's reconciliation with scheduled runs before promotion.
    """
    unique = {}
    for row in records:
        identity = (row.get("repository"), row.get("run_id"), row.get("attempt"), row.get("job"))
        if row.get("schema") != SCHEMA or not all(identity):
            raise ValueError("mirror receipt lacks identity")
        if identity in unique and unique[identity] != row:
            raise ValueError("conflicting mirror receipts")
        unique[identity] = row
    rows = list(unique.values())
    completed = [r for r in rows if not r.get("uncertain")
                 and (r.get("outcome") == "failure"
                      or (r.get("outcome") == "success" and r.get("execution_receipt")))]
    skipped = [r for r in completed if r.get("candidate_skip") is True]
    failures = [r for r in skipped if r["outcome"] == "failure"]
    duration = sum(r["execution_minutes"] for r in completed)
    saved = sum(r["execution_minutes"] for r in skipped if r["outcome"] == "success")
    return {"schema": SCHEMA, "observations": len(rows), "complete": len(completed),
            "incomplete": len(rows) - len(completed), "candidate_skips": len(skipped),
            "false_skips": len(failures),
            "false_skip_rate": len(failures) / len(skipped) if skipped else None,
            "full_execution_minutes": duration, "candidate_execution_minutes": duration - saved,
            "potential_saved_execution_minutes": saved, "actual_saved_machine_minutes": 0,
            "enforcement": False,
            "note": "Execution-step estimate only; reconcile runner minutes and merged PRs separately."}


def verify_evidence(root: str, rev: str, job: str, evidence: Path | None = None,
                    raw: str | None = None) -> tuple[bool, str]:
    """Fail closed unless protected promotion evidence proves a full mirror day."""
    try:
        if raw is None:
            if evidence is None:
                return False, "evidence is unavailable"
            raw = evidence.read_text(encoding="utf-8")
        value = json.loads(raw)
        if not isinstance(value, dict):
            return False, "evidence is not an object"
        if value.get("schema") != "ci-rebuild-evidence/v1" or value.get("enabled") is not True:
            return False, "evidence is not enabled"
        if value.get("policy") != policy_identity(root, rev, job):
            return False, "evidence policy does not match this checkout"
        window = value.get("window_seconds")
        if (isinstance(window, bool) or not isinstance(window, (int, float))
                or not math.isfinite(window) or window < 86400):
            return False, "evidence window is shorter than 24 hours"
        rate = value.get("false_skip_rate")
        if (isinstance(rate, bool) or not isinstance(rate, (int, float))
                or not math.isfinite(rate) or rate != 0):
            return False, "evidence false-skip rate is not zero"
        complete = value.get("complete")
        if isinstance(complete, bool) or not isinstance(complete, int) or complete <= 0:
            return False, "evidence has no complete observations"
        measured_at = str(value.get("measured_at") or "")
        if not measured_at:
            return False, "evidence has no measurement timestamp"
        try:
            stamp = datetime.datetime.fromisoformat(measured_at.replace("Z", "+00:00"))
            if stamp.tzinfo is None:
                return False, "evidence timestamp has no timezone"
            age = time.time() - stamp.timestamp()
        except ValueError:
            return False, "evidence timestamp is not ISO-8601"
        if age < -300 or age > 7 * 86400:
            return False, "evidence timestamp is stale"
        return True, "eligible"
    except (ArithmeticError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        return False, f"evidence unavailable: {error}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    end = commands.add_parser("finish")
    end.add_argument("--plan", type=Path, required=True)
    end.add_argument("--outcome", required=True)
    end.add_argument("--output", type=Path, required=True)
    end.add_argument("--execution-receipt", type=Path, required=True)
    summary = commands.add_parser("report")
    summary.add_argument("receipts", type=Path, nargs="+")
    verify = commands.add_parser("verify-evidence")
    verify.add_argument("--root", default=".")
    verify.add_argument("--rev", default="HEAD")
    verify.add_argument("--job", default="fast-tier-cargo")
    verify.add_argument("--evidence", type=Path)
    verify.add_argument("--evidence-json")
    args = parser.parse_args()
    if args.command == "finish":
        finish(args.plan, args.outcome, args.output, args.execution_receipt)
    elif args.command == "report":
        print(json.dumps(report([json.loads(p.read_text()) for p in args.receipts]), indent=2))
    else:
        eligible, reason = verify_evidence(args.root, args.rev, args.job, args.evidence, args.evidence_json)
        print(f"eligible={'true' if eligible else 'false'}")
        print(f"reason={reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

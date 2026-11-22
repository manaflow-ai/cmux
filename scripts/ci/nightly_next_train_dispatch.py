#!/usr/bin/env python3
"""Dispatch the NEXT release train and retain a durable dispatch receipt.

The tick runs this helper from the main branch's tooling checkout. GitHub can
accept a workflow dispatch and still fail the caller transiently, so the
dispatch is attempted twice. A failed second attempt returns a failure and
leaves the named release owner in the receipt for handoff.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Callable, Sequence


SCHEMA = "cmux.nightly-next-train-dispatch.v1"
OWNER = "nightly-next release owner"
MAX_OUTPUT = 4000


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def clipped(value: str) -> str:
    value = value.strip()
    if len(value) <= MAX_OUTPUT:
        return value
    return value[-MAX_OUTPUT:]


def write_receipt(path: Path, receipt: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def lookup_run(repo: str, workflow: str, ref: str, started_at: str,
               run: Callable[..., subprocess.CompletedProcess[str]]) -> tuple[dict[str, Any] | None, str | None]:
    command = [
        "gh", "run", "list", "--repo", repo, "--workflow", workflow,
        "--event", "workflow_dispatch", "--branch", ref, "--limit", "10",
        "--json", "databaseId,url,headBranch,headSha,status,createdAt",
    ]
    result = run([
        "gh", "run", "list", "--repo", repo, "--workflow", workflow,
        "--event", "workflow_dispatch", "--branch", ref, "--limit", "10",
        "--json", "databaseId,url,headBranch,headSha,status,createdAt",
    ], capture_output=True, text=True, check=False)
    if result.returncode:
        return None, clipped(result.stderr or result.stdout)
    try:
        rows = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as error:
        return None, f"run lookup returned invalid JSON: {error}"
    if not isinstance(rows, list):
        return None, "run lookup returned a non-list JSON value"
    candidates = [
        row for row in rows
        if isinstance(row, dict)
        and row.get("headBranch") == ref
        and str(row.get("createdAt", "")) >= started_at
    ]
    if not candidates:
        return None, "dispatch accepted but no matching run was visible yet"
    candidate = candidates[0]
    fields = ("databaseId", "url", "headBranch", "headSha", "status", "createdAt")
    return {key: candidate.get(key) for key in fields}, None


def dispatch(repo: str, workflow: str, ref: str, mode: str, path: Path,
             run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> int:
    receipt: dict[str, Any] = {
        "schema": SCHEMA,
        "repository": repo,
        "workflow": workflow,
        "event": "workflow_dispatch",
        "ref": ref,
        "inputs": {"mode": mode},
        "requested_by": {
            "event": os.environ.get("GITHUB_EVENT_NAME"),
            "run_id": os.environ.get("GITHUB_RUN_ID"),
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "sha": os.environ.get("GITHUB_SHA"),
        },
        "owner": OWNER,
        "attempts": [],
        "outcome": "started",
    }
    write_receipt(path, receipt)

    command = ["gh", "workflow", "run", workflow, "--repo", repo, "--ref", ref, "-f", f"mode={mode}"]
    status = 1
    for attempt in range(1, 3):
        started_at = now()
        try:
            result = run([
                "gh", "workflow", "run", workflow, "--repo", repo,
                "--ref", ref, "-f", f"mode={mode}",
            ], capture_output=True, text=True, check=False)
        except OSError as error:
            result = subprocess.CompletedProcess(command, 127, "", str(error))
        completed_at = now()
        status = result.returncode
        entry: dict[str, Any] = {
            "attempt": attempt,
            "started_at": started_at,
            "completed_at": completed_at,
            "exit_code": status,
            "command": command,
            "stdout": clipped(result.stdout),
            "stderr": clipped(result.stderr),
        }
        if status == 0:
            found, lookup_error = lookup_run(repo, workflow, ref, started_at, run)
            entry["run"] = found
            if lookup_error:
                entry["run_lookup_error"] = lookup_error
            receipt["attempts"].append(entry)
            receipt["outcome"] = "dispatched"
            receipt["dispatched_at"] = completed_at
            write_receipt(path, receipt)
            print(f"nightly-next train dispatched on attempt {attempt}; receipt={path}")
            return 0
        receipt["attempts"].append(entry)
        receipt["last_failure"] = completed_at
        write_receipt(path, receipt)
        if attempt == 1:
            print("::warning::nightly-next train dispatch failed; retrying once", file=sys.stderr)

    receipt["outcome"] = "failed"
    receipt["failure_owner"] = OWNER
    receipt["owner_action"] = "inspect the receipt and retry the nightly-next tick"
    write_receipt(path, receipt)
    print(
        f"::error title=nightly-next train dispatch::{OWNER} must inspect {path} after two failed attempts",
        file=sys.stderr,
    )
    return status or 1


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--workflow", default="nightly-next-train.yml")
    parser.add_argument("--ref", default="feat-cmux-next")
    parser.add_argument("--mode", default="drive")
    parser.add_argument("--receipt", type=Path, default=Path("nightly-next-train-dispatch.json"))
    args = parser.parse_args(argv)
    return dispatch(args.repo, args.workflow, args.ref, args.mode, args.receipt)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run synthetic native/gallery journeys and compare their semantic receipts.

This is an index over adapter evidence, not a second CUA activity recorder.
CUA frames and events remain owned by the helper and its retention policy.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import sys
import time

VERSION = 1
IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9._-]{0,95}\Z")
STATUSES = {"passed", "failed", "unavailable"}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def read(path):
    with Path(path).open() as stream:
        return json.load(stream)


def write(path, value):
    # Evidence is private, including on a shared fleet host. No implicit publisher.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def fields(value, required, optional=()):
    if not isinstance(value, dict):
        raise ValueError("expected an object")
    if set(value) - set(required) - set(optional) or set(required) - set(value):
        raise ValueError("unknown or missing fields")


def identifier(value):
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ValueError("invalid identifier")


def validate(manifest):
    fields(manifest, ("workflowVersion", "id", "fixture", "steps", "untested"))
    if manifest["workflowVersion"] != VERSION or manifest["fixture"] != "synthetic":
        raise ValueError("only version 1 synthetic workflows are supported")
    identifier(manifest["id"])
    if not isinstance(manifest["untested"], list) or not all(isinstance(x, str) for x in manifest["untested"]):
        raise ValueError("untested must be a string array")
    steps = manifest["steps"]
    if not isinstance(steps, list) or not 1 <= len(steps) <= 30:
        raise ValueError("a workflow has 1 to 30 bounded steps")
    seen = set()
    previous = None
    for step in steps:
        fields(step, ("id", "driver", "from", "to", "action", "target", "args", "expect"))
        for key in ("id", "from", "to", "action"):
            identifier(step[key])
        if step["id"] in seen:
            raise ValueError("duplicate step id")
        seen.add(step["id"])
        if previous is not None and step["from"] != previous:
            raise ValueError("disconnected state graph")
        previous = step["to"]
        if step["driver"] not in ("native", "gallery"):
            raise ValueError("unknown adapter")
        if not isinstance(step["target"], dict) or not step["target"]:
            raise ValueError("every action requires an explicit target")
        if not isinstance(step["args"], dict) or not isinstance(step["expect"], dict) or not step["expect"]:
            raise ValueError("args and expect must be objects")
    canonical(manifest)
    return manifest


def metadata(context):
    source = context.get("source_sha", "")
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("source_sha must be an exact commit")
    for key in ("artifact", "host"):
        if not isinstance(context.get(key), str) or not context[key].strip():
            raise ValueError("artifact and host must identify the fleet run")
    env = context.get("environment")
    fields(env, ("viewport", "theme", "locale", "density", "scale", "reducedMotion"))
    fields(env["viewport"], ("width", "height"))
    for value in env["viewport"].values():
        if type(value) is not int or value <= 0:
            raise ValueError("viewport dimensions must be positive integers")
    if env["theme"] not in ("light", "dark") or type(env["reducedMotion"]) is not bool:
        raise ValueError("invalid theme or motion setting")
    if not isinstance(env["locale"], str) or not env["locale"]:
        raise ValueError("locale is required")
    if not isinstance(env["density"], str) or not env["density"]:
        raise ValueError("density is required")
    if type(env["scale"]) not in (float, int) or env["scale"] <= 0:
        raise ValueError("scale must be positive")
    canonical(env)
    # Runtime credentials, MCP launch config and machine-local paths never enter receipts.
    return {"source_sha": source, "artifact": context["artifact"], "host": context["host"],
            "environment": env}


def checked_result(result):
    fields(result, ("status", "state", "assertions", "evidence", "metrics", "event_refs"),
           ("reason", "first_failed_step"))
    if result["status"] not in STATUSES or not isinstance(result["state"], dict):
        raise ValueError("invalid adapter result")
    if not isinstance(result["assertions"], list):
        raise ValueError("invalid assertions")
    for assertion in result["assertions"]:
        fields(assertion, ("name", "ok"))
        if not isinstance(assertion["name"], str) or type(assertion["ok"]) is not bool:
            raise ValueError("assertions must report an observed boolean")
    if any(not a["ok"] for a in result["assertions"]):
        result["status"] = "failed"
    elif result["status"] == "passed" and not result["assertions"]:
        result["status"] = "unavailable"
        result["reason"] = "no_assertions_executed"
    for key in ("evidence", "metrics"):
        if not isinstance(result[key], dict):
            raise ValueError("invalid adapter evidence")
    if not isinstance(result["event_refs"], list):
        raise ValueError("invalid activity references")
    canonical(result)
    return result


def unavailable(reason):
    return {"status": "unavailable", "reason": reason, "state": {}, "assertions": [],
            "evidence": {}, "metrics": {}, "event_refs": []}


def execute(manifest, context, out, adapters=None):
    validate(manifest)
    build = metadata(context)
    out = Path(out)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    steps = []
    stopped = False
    for step in manifest["steps"]:
        step_dir = out / step["id"]
        step_dir.mkdir(mode=0o700)
        start = time.monotonic()
        if stopped:
            result = unavailable("previous_step_did_not_pass")
        else:
            try:
                adapter = adapters[step["driver"]] if adapters else importlib.import_module(step["driver"]).run_step
                result = checked_result(adapter(step, context, step_dir))
            except Exception as error:
                # Tool exceptions may contain typed text, tokens or entire replies. Never log them.
                result = unavailable("adapter_error:" + type(error).__name__)
        stopped = stopped or result["status"] != "passed"
        row = {"id": step["id"], "driver": step["driver"], "from": step["from"],
               "to": step["to"], "action": step["action"], **result,
               "duration_ms": round((time.monotonic() - start) * 1000, 3)}
        row["state_hash"] = digest(row["state"])
        write(step_dir / "receipt.json", row)
        steps.append(row)
    first = next((s["id"] for s in steps if s["status"] != "passed"), None)
    receipt = {"workflowVersion": VERSION, "workflow": manifest["id"],
               "manifest_sha256": digest(manifest), "build": build,
               "status": next((s["status"] for s in steps if s["id"] == first), "passed"),
               "first_failed_step": first, "untested": manifest["untested"], "steps": steps}
    write(out / "receipt.json", receipt)
    # Only state/edge references are indexed; actions and their text stay in the source fixture.
    write(out / "graph.json", {"workflow": manifest["id"], "edges": [
        {"stepId": s["id"], "from": s["from"], "to": s["to"], "status": s["status"],
         "stateHash": s["state_hash"], "receipt": f"{s['id']}/receipt.json",
         "eventRefs": s["event_refs"]} for s in steps]})
    return receipt


def compare(baseline, candidate):
    if baseline.get("workflowVersion") != VERSION or candidate.get("workflowVersion") != VERSION:
        return {"status": "incomparable", "reason": "receipt_version"}
    if baseline.get("workflow") != candidate.get("workflow") or baseline.get("manifest_sha256") != candidate.get("manifest_sha256"):
        return {"status": "incomparable", "reason": "different_workflow"}
    if baseline.get("build", {}).get("environment") != candidate.get("build", {}).get("environment"):
        return {"status": "incomparable", "reason": "different_environment"}
    # A result without executed assertions cannot establish equivalence, even to itself.
    old = baseline.get("steps")
    new = candidate.get("steps")
    for rows in (old, new):
        if not isinstance(rows, list) or not rows:
            return {"status": "unavailable", "reason": "missing_observation"}
        for row in rows:
            if (not isinstance(row, dict) or not all(key in row for key in
                    ("id", "driver", "from", "to", "action", "status", "state", "assertions"))
                    or row["status"] not in STATUSES or not isinstance(row["state"], dict)
                    or not isinstance(row["assertions"], list)
                    or any(not isinstance(a, dict) or set(a) != {"name", "ok"}
                           or type(a["ok"]) is not bool for a in row["assertions"])):
                return {"status": "incomparable", "reason": "invalid_receipt"}
    for index in range(max(len(old), len(new))):
        left = old[index] if index < len(old) else None
        right = new[index] if index < len(new) else None
        step_id = (right or left)["id"]
        if left is None or right is None:
            return {"status": "diverged", "step": step_id, "field": "step_count"}
        for field in ("id", "driver", "from", "to", "action", "status", "state", "assertions"):
            if left.get(field) != right.get(field):
                return {"status": "diverged", "step": step_id, "field": field}
        if right["status"] == "unavailable" or not right["assertions"]:
            return {"status": "unavailable", "step": step_id, "reason": "missing_observation"}
    return {"status": "equivalent"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check")
    check.add_argument("manifest")
    for name in ("run", "replay"):
        run = sub.add_parser(name)
        run.add_argument("manifest")
        run.add_argument("--context", required=True)
        run.add_argument("--out", required=True)
        if name == "replay":
            run.add_argument("--baseline", required=True)
    diff = sub.add_parser("compare")
    diff.add_argument("baseline")
    diff.add_argument("candidate")
    listing = sub.add_parser("list")
    listing.add_argument("root")
    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            manifest = validate(read(args.manifest))
            print(json.dumps({"workflow": manifest["id"], "steps": len(manifest["steps"])}))
            return 0
        if args.command == "list":
            for path in sorted(Path(args.root).glob("**/receipt.json")):
                receipt = read(path)
                if "workflow" in receipt and "build" in receipt:
                    print(json.dumps({"workflow": receipt["workflow"], **receipt["build"],
                                      "status": receipt["status"], "receipt": str(path),
                                      "steps": [{"id": s["id"], "status": s["status"],
                                                 "evidence": s["evidence"]} for s in receipt["steps"]]}))
            return 0
        if args.command == "compare":
            result = compare(read(args.baseline), read(args.candidate))
        else:
            manifest = validate(read(args.manifest))
            if args.command == "replay":
                baseline = read(args.baseline)
                if baseline.get("manifest_sha256") != digest(manifest):
                    raise ValueError("replay requires the original source fixture")
            receipt = execute(manifest, read(args.context), args.out)
            result = {"status": receipt["status"], "receipt": str(Path(args.out) / "receipt.json"),
                      "first_failed_step": receipt["first_failed_step"]}
            if args.command == "replay":
                result = compare(baseline, receipt)
                result["run_status"] = receipt["status"]
                write(Path(args.out) / "comparison.json", result)
        print(json.dumps(result))
        return 0 if result["status"] in ("passed", "equivalent") and result.get("run_status", "passed") == "passed" else 1
    except (ValueError, OSError, KeyError, TypeError) as error:
        # Configuration files may contain launch credentials; report only the error class.
        print("workflow: invalid input (" + type(error).__name__ + ")", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

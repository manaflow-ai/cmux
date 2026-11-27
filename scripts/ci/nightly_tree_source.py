#!/usr/bin/env python3
"""Publish observational tree lineage; never contact or change the claim authority.

Artifact metadata names join nightly dependencies to publisher runs. Owner names
are stable for exact-name lookup; readers must check JSON run_attempt against the
run's current attempt before trusting one. A missing marker means unknown.
"""
import json
import os
from pathlib import Path
import re
import sys


def marker(kind, env):
    if kind == "dependency":
        if env.get("TREE_PENDING") != "true":
            return None
    elif kind == "owner":
        if env.get("OWNS_KEY") != "true" or env.get("TREE_READY") != "false":
            return None
    else:
        raise ValueError("unknown tree marker kind")
    key = env.get("TREE_KEY", "")
    if not re.fullmatch(r"[0-9a-f]{40}", key):
        raise ValueError("canonical v2 tree key must be 40 hex characters")
    value = {"schema_version": 1, "kind": kind, "key": key}
    for source, dest in (("GITHUB_RUN_ID", "run_id"), ("GITHUB_RUN_ATTEMPT", "run_attempt")):
        raw = env.get(source, "")
        if not re.fullmatch(r"[1-9][0-9]*", raw):
            raise ValueError(f"{source} must be a positive integer")
        value[dest] = int(raw)
    if kind == "dependency":
        sha = env.get("BUILD_SHA", "")
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("build SHA must be 40 hex characters")
        value["build_sha"] = sha
        name = f"nightly-tree-dependency-{key}-{sha}-attempt-{value['run_attempt']}"
    else:
        name = f"cmux-tui-tree-owner-{key}"
    return name, value


def main():
    result = marker(sys.argv[1], os.environ)
    if result is None:
        return
    name, value = result
    path = Path(os.environ["RUNNER_TEMP"]) / f"tree-{value['kind']}.json"
    path.write_text(json.dumps(value, sort_keys=True) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"name={name}\npath={path}\n")


if __name__ == "__main__":
    main()

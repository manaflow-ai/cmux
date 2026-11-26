#!/usr/bin/env python3
"""Drop the tooling-tests steps an earlier run of the same pull request already passed with the same inputs.

Leo, 2026-11-25: "de facto, im asking for 99% fewer minutes of ci time, period." tooling_steps.py picks the steps a
pull request's diff against its base can fail, and every new head runs all of them again. That includes a head
that only merged the base or touched files those steps never read. `record`, the job's last step, writes the merge
commit's tree (path, mode and blob id of each tracked file) and the ids of the steps that ran and passed. Those go
up as the artifact tooling-tests-passed-<attempt>. On the next head, `reuse` diffs this merge commit's tree against
each earlier record. It asks tooling_steps.route the same question it asks of a base diff: which steps can this
diff fail? A selected step that passed in that earlier run and that route does not select for the diff since then
is dropped, and the summary names the run that vouches for it.

That is never weaker than the routing tooling-tests already trusts. A step route skips for a base diff is vouched
for by the base. A step skipped here is vouched for by an earlier run of this pull request that ran it to success
on a tree that differs from this one only in files route says it cannot read. Every check route makes (closures,
listed globs, read folders, spelled-out names, whole-tree listings) is the same, and so is everything it runs all
of: a change since then to the workflow, the router, this file or a local action. Only steps that ran count, never
ones reused or skipped, so a vouch never chains.

The rules:
- Only same-repository runs of the branch count. A fork's run can rewrite its workflow and publish anything.
- CI_TOOLING_REUSE=off turns reuse off.
- CI_TOOLING_REUSE_AUDIT_PERCENT (10 by default) of runs reuse nothing and run what they would have reused.
- Any API error, a slow API or a malformed artifact reuses nothing.

    python3 tooling_reuse.py record --workflow W --job J --steps-json-env STEPS --out FILE
    python3 tooling_reuse.py reuse --workflow W --job J --route-output FILE --repository R --branch B --run-id N
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import subprocess
import sys
import time
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable
from urllib.parse import quote, urlencode

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tooling_steps  # noqa: E402

ARTIFACT_PREFIX = "tooling-tests-passed-"
RECORD_FILE = "tooling-passed.json"
RUNS_TO_CHECK = 4
REQUEST_TIMEOUT_SECONDS = 15
LOOKUP_TIMEOUT_SECONDS = 50
DEFAULT_AUDIT_PERCENT = 10


@dataclass
class Record:
    label: str  # the run that vouches, as the summary names it
    tree: dict[str, str]
    passed: set[str]


def tree_of(root: Path) -> dict[str, str]:
    """{path: "mode oid"} for every file of HEAD's tree."""
    out = subprocess.run(["git", "-C", str(root), "ls-tree", "-r", "-z", "--full-tree", "HEAD"],
                         check=True, capture_output=True).stdout.decode("utf-8", "surrogateescape")
    tree = {}
    for entry in out.split("\0"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        mode, _, rest = meta.partition(" ")
        tree[path] = f"{mode} {rest.rpartition(' ')[2]}"
    return tree


def diff(before: dict[str, str], after: dict[str, str]) -> tuple[list[str], list[str]]:
    """(changed paths, added or deleted paths) from one tree to the other."""
    added_deleted = sorted(before.keys() ^ after.keys())
    changed = sorted({*added_deleted, *(p for p in before.keys() & after.keys() if before[p] != after[p])})
    return changed, added_deleted


def reusable(root: Path, workflow: str, job: str, selected: list[str], tree: dict[str, str],
             records: Iterable[Record]) -> dict[str, tuple[str, str]]:
    """{step: (vouching run, why)} for each selected step an earlier record vouches for, newest record first."""
    found: dict[str, tuple[str, str]] = {}
    for record in records:
        wanted = [k for k in selected if k not in found and k in record.passed]
        if not wanted:
            continue
        changed, added_deleted = diff(record.tree, tree)
        if not changed:
            for key in wanted:
                found[key] = (record.label, "the merge tree is the same")
            continue
        decision = tooling_steps.route(root, workflow, job, changed, "pull_request", added_deleted)
        if decision.all:
            continue
        verdicts = {s.key: s for s in decision.steps}
        for key in wanted:
            verdict = verdicts.get(key)
            if verdict is not None and not verdict.run:
                found[key] = (record.label, f"{len(changed)} file(s) changed since; {verdict.reason}")
    return found


def audited(run_id: str, percent: int) -> bool:
    """True for about `percent` in 100 runs, the same answer for every attempt of one run."""
    return int(hashlib.sha256(run_id.encode()).hexdigest()[:8], 16) % 100 < percent


def read_route_output(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            values[key] = value
    return values


def github(repository: str, token: str) -> Callable[[str], bytes]:
    deadline = time.monotonic() + LOOKUP_TIMEOUT_SECONDS

    def call(path: str) -> bytes:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("tooling-tests result lookup deadline reached")
        request = urllib.request.Request(f"https://api.github.com/repos/{repository}/{path}")
        request.add_header("Accept", "application/vnd.github+json")
        # Not sent on to the artifact zip's storage redirect, which takes its own signed URL.
        request.add_unredirected_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(request, timeout=min(REQUEST_TIMEOUT_SECONDS, remaining)) as response:
            return response.read()

    return call


def fetch_records(repository: str, branch: str, workflow: str, call: Callable[[str], bytes]) -> list[Record]:
    """The records of the branch's latest same-repository pull request runs of the workflow, newest first."""
    query = urlencode({"event": "pull_request", "branch": branch, "per_page": RUNS_TO_CHECK})
    name = quote(Path(workflow).name)
    runs = json.loads(call(f"actions/workflows/{name}/runs?{query}"))["workflow_runs"]
    records = []
    for run in runs:
        if (run.get("head_repository") or {}).get("full_name") != repository:
            continue
        artifacts = json.loads(call(f"actions/runs/{run['id']}/artifacts?per_page=100"))["artifacts"]
        artifacts = [a for a in artifacts if not a.get("expired") and str(a.get("name", "")).startswith(ARTIFACT_PREFIX)]
        for artifact in sorted(artifacts, key=lambda a: str(a.get("name")), reverse=True):
            with zipfile.ZipFile(io.BytesIO(call(f"actions/artifacts/{artifact['id']}/zip"))) as archive:
                data = json.loads(archive.read(RECORD_FILE))
            tree, passed = data.get("tree"), data.get("passed")
            if not isinstance(tree, dict) or not isinstance(passed, list):
                continue
            label = f"run {run['id']} attempt {data.get('attempt', '?')} ({str(run.get('head_sha', ''))[:10]})"
            records.append(Record(label, {str(k): str(v) for k, v in tree.items()}, {str(p) for p in passed}))
    return records


def apply(route_output: Path, root: Path, workflow: str, job: str,
          lookup: Callable[[], list[Record]]) -> dict[str, tuple[str, str]]:
    """Rewrite route_output without the reused steps and return them. Any error leaves it as it was."""
    try:
        values = read_route_output(route_output)
        if values.get("tooling_all") == "true":
            decision = tooling_steps.route(root, workflow, job, None, "push")
            selected = [k for k in decision.selected if k]
        else:
            selected = values.get("tooling_steps", "").split()
        if not selected:
            return {}
        found = reusable(root, workflow, job, selected, tree_of(root), lookup())
    except Exception as error:  # noqa: BLE001 - reuse is optional; run every selected step
        print(f"tooling-tests result lookup failed; every selected step runs: {error}", file=sys.stderr)
        return {}
    if found:
        remaining = " ".join(k for k in selected if k not in found)
        route_output.write_text(f"tooling_steps= {remaining} \ntooling_all=false\n", encoding="utf-8")
    return found


def record(workflow: str, job: str, root: Path, steps_json: str, out: Path, attempt: str) -> list[str]:
    """Write the tree and the selectable steps that ran and passed. Reused and skipped steps' outcome is skipped."""
    steps = json.loads(steps_json or "{}")
    document = tooling_steps.load_yaml(root / workflow)
    job_steps = tooling_steps.mapping(tooling_steps.mapping(document.get("jobs")).get(job)).get("steps") or []
    keys = [str(s.get("id")) for s in job_steps if tooling_steps.selectable(s) and s.get("id")]
    runner = steps.get("setup-tooling-run") if isinstance(steps.get("setup-tooling-run"), dict) else {}
    side_by_side = str((runner.get("outputs") or {}).get("passed") or "")  # tooling_steps.py run's passes
    passed = [k for k in keys if (isinstance(steps.get(k), dict) and steps[k].get("outcome") == "success")
              or f" {k} " in side_by_side]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"attempt": attempt, "passed": passed, "tree": tree_of(root)}), encoding="utf-8")
    return passed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("record", "reuse"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
        cmd.add_argument("--workflow", required=True)
        cmd.add_argument("--job", required=True)
        if name == "record":
            cmd.add_argument("--steps-json-env", required=True, help="the variable holding toJSON(steps)")
            cmd.add_argument("--out", type=Path, required=True)
            cmd.add_argument("--attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", ""))
        else:
            cmd.add_argument("--route-output", type=Path, required=True, help="tooling_steps.py's output; rewritten")
            cmd.add_argument("--repository", required=True)
            cmd.add_argument("--branch", required=True)
            cmd.add_argument("--run-id", required=True)
            cmd.add_argument("--summary", type=Path)
    args = parser.parse_args(argv)
    root = Path(args.root)
    if args.command == "record":
        passed = record(args.workflow, args.job, root, os.environ.get(args.steps_json_env, ""), args.out, args.attempt)
        print(f"{args.job}: recorded {len(passed)} passed step(s) for later heads of this pull request")
        return 0
    if os.environ.get("CI_TOOLING_REUSE", "").strip().lower() == "off":
        print("CI_TOOLING_REUSE=off: no earlier result is reused")
        return 0
    try:
        percent = int(os.environ.get("CI_TOOLING_REUSE_AUDIT_PERCENT") or DEFAULT_AUDIT_PERCENT)
    except ValueError:
        percent = DEFAULT_AUDIT_PERCENT
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    call = github(args.repository, token)
    found = apply(args.route_output, root, args.workflow, args.job,
                  lambda: fetch_records(args.repository, args.branch, args.workflow, call))
    if found and audited(args.run_id, percent):
        print(f"audit run ({percent}%): the {len(found)} step(s) earlier runs vouch for run anyway")
        lines = [f"Audit run: {len(found)} step(s) an earlier run of this pull request vouches for run anyway."]
        found_text = [f"- `{k}` (vouched by {label})" for k, (label, _) in found.items()]
        # Put back what apply took out: the audit runs the full selection.
        values = read_route_output(args.route_output)
        restored = " ".join([*values.get("tooling_steps", "").split(), *found])
        args.route_output.write_text(f"tooling_steps= {restored} \ntooling_all=false\n", encoding="utf-8")
    else:
        lines = [f"{len(found)} selected step(s) reuse a pass from an earlier run of this pull request:"] if found else []
        found_text = [f"- `{k}` passed in {label}: {why}" for k, (label, why) in found.items()]
    for k, (label, why) in found.items():
        print(f"reuse {k}: {label}: {why}")
    if args.summary and lines:
        with args.summary.open("a", encoding="utf-8") as stream:
            stream.write("\n".join(["", *lines, "", *found_text]) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

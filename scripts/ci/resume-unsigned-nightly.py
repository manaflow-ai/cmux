#!/usr/bin/env python3
"""Recover trusted nightly-next compile outputs without running their contents.

plan validates a completed protected push and its exact producer attempt.
restore repeats that validation, downloads immutable artifact IDs, verifies
GitHub's SHA256 digests, and restores inputs for the existing signing jobs.
Only workflow_dispatch on nightly-next may use this path. No signing secret
is needed by either command.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import zipfile

spec = importlib.util.spec_from_file_location("artifact_download", Path(__file__).with_name("download-run-artifact.py"))
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)

ARTIFACTS = {
    "cmux-nightly-unsigned-app": ("build-nightly-app", "app"),
    "cmux-nightly-remote-daemon": ("build-nightly-app", "daemon"),
    "cmux-nightly-ghostty-cli-helper": ("build-nightly-ghostty-cli-helper", "ghostty"),
    "cmux-next-license-trees": ("build-nightly-ghostty-cli-helper", "licenses"),
    "cmux-next-source-archive": ("build-nightly-ghostty-cli-helper", "source"),
}


HELPER_RESOLVER = "resolve-nightly-ghostty-cli-helper"


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def validate(run, jobs, artifacts, repo, run_id, attempt):
    require(repo == "manaflow-ai/cmux", "unsigned resume is restricted to manaflow-ai/cmux")
    require(run.get("repository", {}).get("full_name") == repo and
            run.get("head_repository", {}).get("full_name") == repo, "source repository mismatch")
    require(run.get("id") == int(run_id) and run.get("run_attempt") == int(attempt), "source run/attempt mismatch")
    require(run.get("path") == ".github/workflows/nightly.yml" and run.get("event") == "push" and
            run.get("head_branch") == "nightly-next", "source must be a protected nightly-next push")
    require(run.get("status") == "completed" and run.get("conclusion") in {"failure", "success"},
            "source must have completed; never race a live run")
    producers = {}
    for name in {owner for owner, _ in ARTIFACTS.values()}:
        candidates = [job for job in jobs if job.get("name") == name]
        require(len(candidates) == 1 and candidates[0].get("conclusion") == "success" and
                candidates[0].get("run_attempt") == int(attempt), f"producer {name} did not succeed in requested attempt")
        producers[name] = candidates[0]
    # A helper reused from an earlier nightly (nightly_ghostty_helper_reuse.py)
    # is uploaded by the resolver job of the same attempt, not the build job.
    for job in jobs:
        if (job.get("name") == HELPER_RESOLVER and job.get("conclusion") == "success" and
                job.get("run_attempt") == int(attempt)):
            producers[HELPER_RESOLVER] = job
    selected = {}
    for name, (owner, _) in ARTIFACTS.items():
        owners = [owner] + ([HELPER_RESOLVER] if name == "cmux-nightly-ghostty-cli-helper" and
                            HELPER_RESOLVER in producers else [])
        matches = [a for a in artifacts if a.get("name") == name and not a.get("expired") and
                   any(producers[o]["started_at"] <= a.get("created_at", "") <= producers[o]["completed_at"]
                       for o in owners)]
        require(len(matches) == 1, f"missing or ambiguous {name} for producer attempt")
        artifact = matches[0]
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")) is not None,
                f"missing digest for {name}")
        identity = artifact.get("workflow_run", {})
        require(identity.get("id") == int(run_id) and identity.get("head_sha") == run["head_sha"] and
                identity.get("head_branch") == "nightly-next" and
                identity.get("repository_id") == identity.get("head_repository_id") == run["repository"]["id"],
                f"artifact source mismatch: {name}")
        selected[name] = artifact
    # The successful compiler writes its exact resolved source SHA into the
    # dSYM artifact name; the workflow's head can be ahead of that source.
    job = producers["build-nightly-app"]
    sources = [a["name"].removeprefix("nightly-next-dsyms-") for a in artifacts
               if a.get("name", "").startswith("nightly-next-dsyms-") and not a.get("expired") and
               job["started_at"] <= a.get("created_at", "") <= job["completed_at"]]
    require(len(sources) == 1 and re.fullmatch(r"[0-9a-f]{40}", sources[0]), "no exact compiled source receipt")
    return {"run_id": str(run_id), "attempt": str(attempt), "head_sha": run["head_sha"],
            "build_sha": sources[0], "build": f"{run_id}{int(attempt):02d}", "artifacts": selected}


def plan(run_id, attempt):
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GH_TOKEN"]
    require(os.environ.get("GITHUB_REF") == "refs/heads/nightly-next" and
            os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "resume only dispatches on nightly-next")
    prefix = f"/repos/{repo}"
    # A failed-job rerun must not erase the provenance of an earlier successful
    # compile. Read the requested attempt, never the run's mutable latest view.
    run = download.api_json(f"{prefix}/actions/runs/{run_id}/attempts/{attempt}", token)
    jobs = download.api_json(f"{prefix}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", token)
    artifacts = download.api_json(f"{prefix}/actions/runs/{run_id}/artifacts?per_page=100", token)
    require(jobs.get("total_count", 101) <= 100 and artifacts.get("total_count", 101) <= 100,
            "source exceeds bounded lookup; refusing partial provenance")
    result = validate(run, jobs["jobs"], artifacts["artifacts"], repo, run_id, attempt)
    for base, head in ((result["head_sha"], os.environ["GITHUB_SHA"]),
                       (result["build_sha"], result["head_sha"])):
        comparison = download.api_json(f"{prefix}/compare/{base}...{head}", token)
        require(comparison.get("status") in {"ahead", "identical"}, "source is not an ancestor of trusted control ref")
    return result


def extract(archive, destination):
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            path = PurePosixPath(entry.filename)
            require(not path.is_absolute() and ".." not in path.parts and "\\" not in entry.filename and
                    not stat.S_ISLNK(entry.external_attr >> 16), "unsafe artifact ZIP member")
        bundle.extractall(destination)


def restore(receipt, root):
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, artifact in receipt["artifacts"].items():
            archive = str(Path(tmp) / f"{artifact['id']}.zip")
            download.download(artifact, os.environ["GH_TOKEN"], archive, 32)
            download.verify(archive, artifact)
            extract(archive, root / ARTIFACTS[name][1])
    manifests = list((root / "daemon").glob("cmuxd-remote-manifest-*.json"))
    require(len(manifests) == 1 and manifests[0].name == f"cmuxd-remote-manifest-{receipt['build']}.json",
            "daemon build number does not match original run/attempt")
    version = json.loads(manifests[0].read_text())["appVersion"]
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-nightly\." + receipt["build"], version),
            "daemon version does not match original nightly identity")
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "restore"))
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--out", type=Path, default=Path("unsigned-resume"))
    args = parser.parse_args()
    require(re.fullmatch(r"[1-9][0-9]*", args.run_id) and re.fullmatch(r"[1-9][0-9]?", args.attempt),
            "invalid source run or attempt")
    receipt = plan(args.run_id, args.attempt)
    outputs = {key: receipt[key] for key in ("run_id", "attempt", "build_sha", "build")}
    if args.command == "restore":
        outputs["version"] = restore(receipt, args.out)
        (args.out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")
    print(json.dumps(outputs))


if __name__ == "__main__":
    main()

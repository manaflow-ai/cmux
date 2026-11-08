#!/usr/bin/env python3
"""Fetch a completed nightly-next run's verified build so this run can publish it again.

nightly.yml's nightly_next_republish_run (and _attempt) dispatch builds, signs and notarizes
nothing: job republish-nightly-next runs this, and publish-nightly takes what it hands over as a
recovered build. That run's workflow and .publish-tooling are the tip's, so a fix to publication
reaches a build that was already signed, notarized and verified (run 41815641855 passed "Verify
final nightly DMG" and then published nothing, a since-fixed supersede bug). Every publication
guard still runs there: the lease, the recheck against the feeds, the lineage and webview gate,
the tested-digest match, and each write.

This refuses unless the source is a completed protected nightly-next push whose signing job and
both verify jobs succeeded in the requested attempt (and whose cmux-tui tree marker check did not
fail), and each artifact taken was uploaded by its producer during that attempt with a SHA-256
digest GitHub recorded, which every download is checked against. Its DMGs must match the digests
its secret-free verify job tested. No secret is needed.

Usage: republish-verified-nightly.py --run-id N --attempt N [--out DIR]
Env: GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_REF, GITHUB_EVENT_NAME, GH_TOKEN (actions: read),
CHANNEL_DMG_PREFIX; GITHUB_OUTPUT receives run_id, attempt, build, build_sha, tip_sha, behind,
behind_hours, cef (the source signed a Chromium runtime pack, so its app's pin names one) and
source_archive (the source made a cmux-next source tarball; its artifact always carries the
license trees, and the tarball only while CMUX_NEXT_PUBLISH_SOURCE_ARCHIVE was 1).
"""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("unsigned_resume", HERE / "resume-unsigned-nightly.py")
resume = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resume)
download = resume.download
require = resume.require

SIGNER = "build-sign-notarize-nightly (arm64)"
SIGNED_CHECK = "Verify signed nightly app (arm64)"
DMG_CHECK = "Verify final nightly DMG (arm64)"
REQUIRED_JOBS = (SIGNER, SIGNED_CHECK, DMG_CHECK, "build-nightly-app")
# NIGHTLY_NEXT_TREE_AT_INSTALL: as recover-tree-marker-ok.sh, a failed or unfinished marker check
# holds the build; one that was skipped (the tree had published) or never existed does not.
TREE_MARKER = "await-nightly-tree-marker"
# name: (jobs that may upload it, directory under --out, required). A republished build is laid
# out as a recovered one (recover-continue-pending-notarization.sh): the variant holds the DMGs,
# the appcast, the SSH daemon assets and source-archive/.
ARTIFACTS = {
    "cmux-nightly-variant-arm64": ((SIGNER,), "variant", True),
    "cmux-nightly-tested-arm64": ((DMG_CHECK,), "tested", True),
    "cmux-nightly-remote-daemon": (("build-nightly-remote-daemon", "attest-nightly-remote-daemon",
                                    "build-nightly-app"), "variant", True),
    "cmux-next-source-archive": (("build-nightly-ghostty-cli-helper", "build-nightly-app"),
                                 "variant/source-archive", False),
    "cef-runtime-pack": ((SIGNER,), "cef-runtime", False),
}
DSYMS = "nightly-next-dsyms-"


def jobs_named(jobs, name, attempt):
    return [job for job in jobs if job.get("name") == name and job.get("run_attempt") == int(attempt)]


def validate(run, jobs, artifacts, repo, run_id, attempt):
    require(repo == "manaflow-ai/cmux", "republish is restricted to manaflow-ai/cmux")
    require(run.get("repository", {}).get("full_name") == repo and
            run.get("head_repository", {}).get("full_name") == repo, "source repository mismatch")
    require(run.get("id") == int(run_id) and run.get("run_attempt") == int(attempt), "source run/attempt mismatch")
    # A push: its build number is its run and attempt, and its dSYM artifact names its build commit.
    require(run.get("path") == ".github/workflows/nightly.yml" and run.get("event") == "push" and
            run.get("head_branch") == "nightly-next", "source must be a protected nightly-next push")
    require(run.get("status") == "completed", "source must have completed; never race a live run")
    producers = {}
    for name in REQUIRED_JOBS:
        found = jobs_named(jobs, name, attempt)
        require(len(found) == 1 and found[0].get("conclusion") == "success",
                f"source job {name!r} did not succeed in attempt {attempt}; nothing verified to republish")
        producers[name] = found[0]
    for job in jobs_named(jobs, TREE_MARKER, attempt):
        require(job.get("conclusion") in {"success", "skipped"},
                f"source's cmux-tui tree marker check is {job.get('conclusion') or 'unfinished'}")
    for owners, _, _ in ARTIFACTS.values():
        for name in owners:
            found = jobs_named(jobs, name, attempt)
            if len(found) == 1 and found[0].get("conclusion") == "success":
                producers[name] = found[0]

    def made_by(artifact, owners):
        return any(name in producers and
                   producers[name]["started_at"] <= artifact.get("created_at", "") <= producers[name]["completed_at"]
                   for name in owners)

    selected = {}
    for name, (owners, _, required) in ARTIFACTS.items():
        live = [a for a in artifacts if a.get("name") == name and not a.get("expired")]
        if not live and not required:
            continue
        matches = [a for a in live if made_by(a, owners)]
        require(len(live) == 1 and len(matches) == 1,
                f"missing, expired or ambiguous {name} from attempt {attempt}")
        artifact = matches[0]
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest") or "") is not None,
                f"missing digest for {name}")
        identity = artifact.get("workflow_run", {})
        require(identity.get("id") == int(run_id) and identity.get("head_sha") == run["head_sha"] and
                identity.get("head_branch") == "nightly-next" and
                identity.get("repository_id") == identity.get("head_repository_id") == run["repository"]["id"],
                f"artifact source mismatch: {name}")
        selected[name] = artifact
    builder = producers["build-nightly-app"]
    sources = [a["name"].removeprefix(DSYMS) for a in artifacts
               if a.get("name", "").startswith(DSYMS) and
               builder["started_at"] <= a.get("created_at", "") <= builder["completed_at"]]
    require(len(sources) == 1 and re.fullmatch(r"[0-9a-f]{40}", sources[0]), "no exact compiled source receipt")
    return {"run_id": str(run_id), "attempt": str(attempt), "head_sha": run["head_sha"],
            "build_sha": sources[0], "build": f"{run_id}{int(attempt):02d}", "artifacts": selected}


def hours_between(earlier: str, later: str) -> str:
    def parse(value):
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    return f"{max(0.0, (parse(later) - parse(earlier)).total_seconds() / 3600):.1f}"


def plan(run_id, attempt):
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GH_TOKEN"]
    tip = os.environ["GITHUB_SHA"]
    require(os.environ.get("GITHUB_REF") == "refs/heads/nightly-next" and
            os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "republish only dispatches on nightly-next")
    require(re.fullmatch(r"[0-9a-f]{40}", tip) is not None, "no workflow commit")
    prefix = f"/repos/{repo}"
    # The requested attempt, never the run's mutable latest view (resume-unsigned-nightly.py).
    run = download.api_json(f"{prefix}/actions/runs/{run_id}/attempts/{attempt}", token)
    jobs = download.api_json(f"{prefix}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", token)
    artifacts = download.api_json(f"{prefix}/actions/runs/{run_id}/artifacts?per_page=100", token)
    require(jobs.get("total_count", 101) <= 100 and artifacts.get("total_count", 101) <= 100,
            "source exceeds bounded lookup; refusing partial provenance")
    receipt = validate(run, jobs["jobs"], artifacts["artifacts"], repo, run_id, attempt)
    for base, head in ((receipt["head_sha"], tip), (receipt["build_sha"], receipt["head_sha"])):
        comparison = download.api_json(f"{prefix}/compare/{base}...{head}", token)
        require(comparison.get("status") in {"ahead", "identical"},
                "source is not an ancestor of this run's nightly-next commit")
    behind = download.api_json(f"{prefix}/compare/{receipt['build_sha']}...{tip}", token)
    tip_commit = download.api_json(f"{prefix}/commits/{tip}", token)
    receipt.update(tip_sha=tip, behind=str(int(behind.get("ahead_by") or 0)),
                   behind_hours=hours_between(behind["base_commit"]["commit"]["committer"]["date"],
                                              tip_commit["commit"]["committer"]["date"]))
    return receipt


def check_bytes(root: Path, build: str, prefix: str):
    """The layout publish-nightly reads, and only DMGs the verify job tested."""
    variant = root / "variant"
    require(re.fullmatch(r"[a-z0-9-]+", prefix or "") is not None, "no DMG prefix")
    for name in (f"{prefix}-arm64.dmg", f"{prefix}-arm64-{build}.dmg", "appcast-arm64.xml",
                 f"cmuxd-remote-manifest-{build}.json"):
        require((variant / name).is_file(), f"the source's verified build has no {name}")
    manifest = json.loads((variant / f"cmuxd-remote-manifest-{build}.json").read_text())
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-nightly\." + build, str(manifest.get("appVersion"))) is not None,
            "daemon version does not match the source's nightly identity")
    tested = set()
    for path in (root / "tested").glob("*.sha256"):
        tested |= {line.strip() for line in path.read_text().splitlines() if line.strip()}
    dmgs = sorted(variant.glob("*.dmg"))
    for dmg in dmgs:
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        require(f"{digest}  {dmg.name}" in tested, f"{dmg.name} ({digest}) is not a DMG the source's verify job tested")
    return len(dmgs)


def restore(receipt, root: Path, prefix: str):
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, artifact in receipt["artifacts"].items():
            archive = str(Path(tmp) / f"{artifact['id']}.zip")
            download.download(artifact, os.environ["GH_TOKEN"], archive, 16)
            download.verify(archive, artifact)
            destination = root / ARTIFACTS[name][1]
            destination.mkdir(parents=True, exist_ok=True)
            resume.extract(archive, destination)
    return check_bytes(root, receipt["build"], prefix)


def has_source_tarball(root: Path) -> bool:
    """github-source-archive.sh publishes exactly one cmux-next-source-*.tar.gz from source-archive/."""
    return len(list((root / ARTIFACTS["cmux-next-source-archive"][1]).glob("cmux-next-source-*.tar.gz"))) == 1


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--out", type=Path, default=Path("republished"))
    args = parser.parse_args()
    require(re.fullmatch(r"[1-9][0-9]*", args.run_id) and re.fullmatch(r"[1-9][0-9]?", args.attempt),
            "invalid source run or attempt")
    receipt = plan(args.run_id, args.attempt)
    count = restore(receipt, args.out, os.environ.get("CHANNEL_DMG_PREFIX", ""))
    outputs = {key: receipt[key] for key in ("run_id", "attempt", "build", "build_sha", "tip_sha", "behind", "behind_hours")}
    outputs["cef"] = "true" if "cef-runtime-pack" in receipt["artifacts"] else "false"
    outputs["source_archive"] = "true" if has_source_tarball(args.out) else "false"
    (args.out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")
    print(json.dumps(outputs))
    print(f"{count} DMG(s) of build {receipt['build']} ({receipt['build_sha']}) match the digests run "
          f"{receipt['run_id']} attempt {receipt['attempt']} verified")


if __name__ == "__main__":
    main()

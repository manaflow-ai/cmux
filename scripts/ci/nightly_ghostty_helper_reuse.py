#!/usr/bin/env python3
"""Reuse an earlier nightly's Ghostty CLI helper when its inputs are unchanged.

The helper needs an SDK 15 Xcode (Zig 0.15.2 cannot link it on macOS 26), and
Zig cannot link it on Linux without a macOS SDK. Its bytes depend only on the
Ghostty gitlink (which also pins the Zig version through build.zig.zon), the
build script and the Zig version script. So a nightly whose build commit has
the same inputs as an earlier nightly's build commit takes that nightly's
helper artifact instead of waiting for a Mac.

A source is an unexpired `cmux-nightly-ghostty-cli-helper` artifact from a
nightly.yml run of this repository on main or nightly-next. Its build commit
comes from the log of the job that uploaded it, inside that job's time window.
Only a stripped helper counts: a build job whose strip step succeeded (its
`ghostty-cli-helper-build=<sha>` line, or its `git checkout --force <sha>`),
or a resolver's `ghostty-cli-helper-stripped-build=<sha>` line.
The artifact is downloaded by ID, checked against GitHub's SHA256 digest,
unpacked safely and must be a Mach-O with exactly the architectures this run
ships.

Writes hit, key, source_run and source_build_sha to GITHUB_OUTPUT. A miss is
not an error: the workflow builds the helper on a Mac.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

spec = importlib.util.spec_from_file_location("artifact_download", Path(__file__).with_name("download-run-artifact.py"))
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)
spec = importlib.util.spec_from_file_location("unsigned_resume", Path(__file__).with_name("resume-unsigned-nightly.py"))
resume = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resume)

ARTIFACT = "cmux-nightly-ghostty-cli-helper"
SCHEMA = "ghostty-cli-helper-reuse-v1"
INPUT_FILES = ("scripts/build-ghostty-cli-helper.sh", "scripts/ghostty-zig-version.sh")
TRUSTED_BRANCHES = {"main", "nightly-next"}
TRUSTED_EVENTS = {"push", "workflow_dispatch", "schedule"}
MAX_CANDIDATES = 15
SHA = re.compile(r"[0-9a-f]{40}")
CPU = {0x0100000C: "arm64", 0x01000007: "x86_64"}


def input_key(repo: str, sha: str, token: str) -> str:
    """Hash of everything the helper's bytes depend on at commit sha."""
    quote = urllib.parse.quote
    ghostty = download.api_json(f"/repos/{repo}/contents/ghostty?ref={sha}", token)
    if ghostty.get("type") != "submodule" or not SHA.fullmatch(ghostty.get("sha", "")):
        raise SystemExit(f"ghostty is not a submodule at {sha}")
    lines = [SCHEMA, f"ghostty={ghostty['sha']}"]
    for path in INPUT_FILES:
        blob = download.api_json(f"/repos/{repo}/contents/{quote(path)}?ref={sha}", token)
        if blob.get("type") != "file" or not SHA.fullmatch(blob.get("sha", "")):
            raise SystemExit(f"{path} is missing at {sha}")
        lines.append(f"{path}={blob['sha']}")
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def macho_archs(path: Path) -> set[str]:
    data = path.read_bytes()
    if len(data) < 8:
        return set()
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack(">I", data[4:8])[0]
        if count > 4 or len(data) < 8 + 20 * count:
            return set()
        types = [struct.unpack(">I", data[8 + 20 * i:12 + 20 * i])[0] for i in range(count)]
    elif data[:4] == b"\xcf\xfa\xed\xfe":
        types = [struct.unpack("<I", data[4:8])[0]]
    else:
        return set()
    if any(cpu not in CPU for cpu in types) or len(set(types)) != len(types):
        return set()
    return {CPU[cpu] for cpu in types}


PRODUCERS = ("build-nightly-ghostty-cli-helper", "resolve-nightly-ghostty-cli-helper")
MARKER = re.compile(r"ghostty-cli-helper-build=([0-9a-f]{40})\b")
# The shipped helper is stripped in the build job (#25885), so only a stripped
# helper may be reused: a build job whose strip step succeeded, or a resolver
# that reused one and says so with this marker.
STRIP_STEP = "Strip the Ghostty CLI helper"
STRIPPED_MARKER = re.compile(r"ghostty-cli-helper-stripped-build=([0-9a-f]{40})\b")
CHECKOUT = re.compile(r"git checkout --progress --force ([0-9a-f]{40})\b")


def job_log(repo: str, job_id: int, token: str) -> str:
    def call() -> str:
        opener = urllib.request.build_opener(download.NoRedirect)
        req = urllib.request.Request(f"{download.API}/repos/{repo}/actions/jobs/{job_id}/logs",
                                     headers={"Authorization": f"Bearer {token}"})
        try:
            opener.open(req, timeout=60)
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308) and error.headers.get("Location"):
                try:
                    with urllib.request.urlopen(error.headers["Location"], timeout=60) as resp:
                        return resp.read().decode("utf-8", "replace")
                except urllib.error.HTTPError as missing:
                    if missing.code == 404:  # a live job's log is not a blob yet
                        return ""
                    raise
            if error.code == 404:
                return ""
            raise
        raise SystemExit("job log did not redirect to blob storage")

    return download.with_retries(call, f"job {job_id} log")


def trusted_run(run: dict, repo: str) -> bool:
    return (run.get("path") == ".github/workflows/nightly.yml" and run.get("event") in TRUSTED_EVENTS and
            run.get("head_branch") in TRUSTED_BRANCHES and
            run.get("repository", {}).get("full_name") == repo and
            run.get("head_repository", {}).get("full_name") == repo)


def producer_build_sha(artifact: dict, jobs: list[dict], read_log) -> str | None:
    """The build commit of the job that uploaded artifact, or None."""
    created = artifact.get("created_at", "")
    for job in jobs:
        if (job.get("name") not in PRODUCERS or not job.get("started_at") or
                not job["started_at"] <= created <= (job.get("completed_at") or "9999")):
            continue
        if job["name"] == PRODUCERS[0]:
            if not any(step.get("name") == STRIP_STEP and step.get("conclusion") == "success"
                       for step in job.get("steps", [])):
                return None
            log = read_log(job["id"])
            shas = set(MARKER.findall(log)) or set(CHECKOUT.findall(log))
        else:
            shas = set(STRIPPED_MARKER.findall(read_log(job["id"])))
        return shas.pop() if len(shas) == 1 else None
    return None


def candidates(repo: str, token: str) -> list[dict]:
    listed = download.api_json(f"/repos/{repo}/actions/artifacts?name={ARTIFACT}&per_page=50", token)
    usable = [a for a in listed.get("artifacts", []) if a.get("name") == ARTIFACT and not a.get("expired") and
              re.fullmatch(r"sha256:[0-9a-f]{64}", a.get("digest") or "")]
    return sorted(usable, key=lambda a: a.get("created_at", ""), reverse=True)[:MAX_CANDIDATES]


def find(repo: str, build_sha: str, token: str, accept) -> tuple[str, dict | None, str]:
    """The newest trusted helper with this build's inputs that accept() takes."""
    key = input_key(repo, build_sha, token)
    keys = {build_sha: key}
    for artifact in candidates(repo, token):
        run_id = artifact.get("workflow_run", {}).get("id")
        if not run_id:
            continue
        run = download.api_json(f"/repos/{repo}/actions/runs/{run_id}", token)
        if not trusted_run(run, repo):
            continue
        jobs = []
        for page in range(1, 4):
            listed = download.api_json(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100&page={page}", token)
            jobs += listed.get("jobs", [])
            if len(jobs) >= listed.get("total_count", 0):
                break
        sha = producer_build_sha(artifact, jobs, lambda job_id: job_log(repo, job_id, token))
        if sha is None:
            continue
        if sha not in keys:
            keys[sha] = input_key(repo, sha, token)
        if keys[sha] == key and accept(artifact):
            return key, artifact, sha
    return key, None, ""


def fetch(artifact: dict, token: str, out: Path, archs: set[str]) -> bool:
    """Download, verify and install one candidate; False when it does not fit."""
    with tempfile.TemporaryDirectory() as tmp:
        archive = str(Path(tmp) / "helper.zip")
        download.download(artifact, token, archive, 8)
        download.verify(archive, artifact)
        unpacked = Path(tmp) / "unpacked"
        resume.extract(archive, unpacked)
        helper = unpacked / "ghostty"
        if not helper.is_file() or helper.is_symlink():
            print(f"artifact {artifact.get('id')} has no ghostty helper; skipping")
            return False
        found = macho_archs(helper)
        if found != archs:
            print(f"artifact {artifact.get('id')} has architectures {sorted(found)}, not {sorted(archs)}; skipping")
            return False
        out.mkdir(parents=True, exist_ok=True)
        (out / "ghostty").write_bytes(helper.read_bytes())
        (out / "ghostty").chmod(0o755)
        return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--build-sha", required=True)
    parser.add_argument("--archs", required=True, help="space-separated: arm64, or arm64 x86_64")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GH_TOKEN"]
    if not SHA.fullmatch(args.build_sha):
        raise SystemExit("invalid build sha")
    archs = set(args.archs.split())
    if archs not in ({"arm64"}, {"arm64", "x86_64"}):
        raise SystemExit(f"unsupported architectures: {args.archs}")
    key, artifact, sha = find(repo, args.build_sha, token, lambda a: fetch(a, token, args.out, archs))
    outputs = {"hit": "false", "key": key, "source_run": "", "source_build_sha": ""}
    if artifact is not None:
        outputs.update(hit="true", source_run=str(artifact["workflow_run"]["id"]), source_build_sha=sha)
    print(f"helper input key {key}: " + (f"reusing run {outputs['source_run']} (build {sha})"
                                          if outputs["hit"] == "true" else "no earlier helper; building"))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for name, value in outputs.items():
            output.write(f"{name}={value}\n")


if __name__ == "__main__":
    sys.exit(main())

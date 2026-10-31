#!/usr/bin/env python3
"""Admit a "Nightly macOS build" run for signing and fetch its prepared apps.

    nightly_sign_admit.py --repo OWNER/REPO --source-run-id N --source-run-attempt N --out DIR

nightly-sign.yml runs this from the default branch on a `workflow_run` of
nightly.yml. It never checks out or runs code from the source run's ref: the
source run is data. Everything it trusts comes from the GitHub API, never from
an artifact's contents:

- identity: the run attempt exists and is the latest; the run's workflow file
  is .github/workflows/nightly.yml (path and workflow id); the run and its head
  belong to this repository; the event can publish; the run succeeded;
- ref: the head branch is main, nightly-next or rc/*, and the head SHA is on
  that branch now (compare HEAD_SHA...refs/heads/BRANCH is identical or ahead;
  a full ref, because a tag can share the branch's name);
- channel: from the head branch (main and nightly-next: nightly; rc/*: rc);
- variants: the successful `prepare-nightly-variant (<variant>)` jobs of the
  admitted attempt; a run whose build-nightly-app job passed but prepared no
  app is refused, not skipped. That job is the fallback preparation: after a
  successful `prepare-nightly-variant-primary (<variant>)` leg it reuses the
  primary's upload and records nothing, so the digest is then the primary leg's;
- digests: each prepare job records the sha256 of the tarball it uploaded as a
  check-run annotation of that job (title nightly-prepared-app). The artifact
  zip must match the artifact digest the API records, and the tarball inside
  must match the producing job's sha256. The same record carries the run's
  publish decision; a run that does not publish (a fast dogfood build) is
  skipped.

Exit 0 with `admitted=true` when every check passes, exit 0 with
`admitted=false` when there is nothing to sign (the run failed, built no app,
or a newer attempt exists), and exit 1 when a check refuses the source.
Needs GH_TOKEN with actions:read and checks:read. Runs nothing it downloads.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
SOURCE_WORKFLOW_PATH = ".github/workflows/nightly.yml"
SOURCE_WORKFLOW_FILE = "nightly.yml"
PUBLISHING_EVENTS = {"push", "schedule", "workflow_dispatch"}
VARIANTS = ("universal", "arm64", "x86_64")
PREPARE_JOB = "prepare-nightly-variant"
PREPARE_JOB_NAME = re.compile(r"^prepare-nightly-variant \(([^()]*)\)$")
PRIMARY_JOB_NAME = re.compile(r"^prepare-nightly-variant-primary \(([^()]*)\)$")
DIGEST_TITLE = "nightly-prepared-app"
DIGEST_MESSAGE = re.compile(
    r"^variant=(\S+) artifact=(\S+) sha256=([0-9a-f]{64}) publish=(true|false) fast=(true|false)$"
)
BUILD_JOB = "build-nightly-app"
TARBALL = "cmux-prepared-app.tar.gz"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
PER_PAGE = 100
CHUNK = 1 << 20


class Refused(Exception):
    """A check failed: the source run is not admitted."""


class Skipped(Exception):
    """Nothing to sign; not an error."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


class GitHub:
    def __init__(self, token: str) -> None:
        self.token = token

    def _request(self, url: str) -> urllib.request.Request:
        request = urllib.request.Request(
            url,
            headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"},
        )
        # Unredirected: urllib never copies the token onto a redirect.
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        return request

    def get(self, path: str) -> object:
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(self._request(f"{API}{path}"), timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as error:
            raise Refused(f"GitHub API {path} answered HTTP {error.code}") from error
        except (OSError, ValueError) as error:
            raise Refused(f"GitHub API {path} failed: {error}") from error

    def pages(self, path: str, key: str | None) -> list:
        items: list = []
        sep = "&" if "?" in path else "?"
        for page in range(1, 51):
            data = self.get(f"{path}{sep}per_page={PER_PAGE}&page={page}")
            chunk = data if key is None else (data or {}).get(key, [])
            if not isinstance(chunk, list):
                raise Refused(f"GitHub API {path} returned no list")
            items.extend(chunk)
            if len(chunk) < PER_PAGE:
                return items
        raise Refused(f"GitHub API {path} has more than 50 pages")

    def blob_url(self, archive_url: str) -> str:
        """The signed blob location. The token never goes to the blob host."""
        if not archive_url.startswith(f"{API}/"):
            raise Refused("artifact download URL is not on the GitHub API host")
        opener = urllib.request.build_opener(NoRedirect)
        try:
            opener.open(self._request(archive_url), timeout=60)
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308) and error.headers.get("Location"):
                return error.headers["Location"]
            raise Refused(f"artifact download answered HTTP {error.code}") from error
        except OSError as error:
            raise Refused(f"artifact download failed: {error}") from error
        raise Refused("artifact download did not redirect to a blob")


def fail(message: str) -> None:
    raise Refused(message)


def channel_for(branch: str) -> tuple[str, str]:
    """(channel, track) from the source run's head branch."""
    if branch == "main":
        return "nightly", "nightly"
    if branch == "nightly-next":
        return "nightly", "nightly-next"
    if branch.startswith("rc/") and len(branch) > 3:
        return "rc", "rc"
    fail(f"head branch {branch!r} does not publish a signed build")
    raise AssertionError


def check_identity(gh: GitHub, repo: str, run_id: str, attempt: str) -> dict:
    run = gh.get(f"/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}")
    if not isinstance(run, dict):
        fail("source run attempt record is not an object")
    if str(run.get("id")) != run_id or str(run.get("run_attempt")) != attempt:
        fail(f"source run record is run {run.get('id')} attempt {run.get('run_attempt')}, not {run_id} attempt {attempt}")
    if run.get("path") != SOURCE_WORKFLOW_PATH:
        fail(f"source run workflow is {run.get('path')!r}, not {SOURCE_WORKFLOW_PATH}")
    workflow = gh.get(f"/repos/{repo}/actions/workflows/{SOURCE_WORKFLOW_FILE}")
    if not isinstance(workflow, dict) or workflow.get("path") != SOURCE_WORKFLOW_PATH:
        fail(f"{SOURCE_WORKFLOW_PATH} is not a workflow of {repo}")
    if run.get("workflow_id") != workflow.get("id"):
        fail(f"source run workflow id {run.get('workflow_id')} is not {SOURCE_WORKFLOW_PATH} ({workflow.get('id')})")
    if (run.get("repository") or {}).get("full_name") != repo:
        fail("source run belongs to another repository")
    if (run.get("head_repository") or {}).get("full_name") != repo:
        fail("source run head is in another repository")
    if run.get("event") not in PUBLISHING_EVENTS:
        fail(f"source run event {run.get('event')!r} cannot publish")
    head_sha = str(run.get("head_sha") or "")
    if not SHA40.match(head_sha):
        fail("source run has no head SHA")
    if run.get("status") != "completed":
        fail(f"source run attempt is {run.get('status')!r}, not completed")

    latest = gh.get(f"/repos/{repo}/actions/runs/{run_id}")
    if str((latest or {}).get("run_attempt")) != attempt:
        raise Skipped(f"source run has a newer attempt ({latest.get('run_attempt')}); that attempt is checked on its own")
    if run.get("conclusion") != "success":
        raise Skipped(f"source run concluded {run.get('conclusion')!r}")
    return run


def check_ref(gh: GitHub, repo: str, run: dict) -> tuple[str, str, str, int]:
    branch = str(run.get("head_branch") or "")
    channel, track = channel_for(branch)
    head_sha = run["head_sha"]
    base = urllib.parse.quote(head_sha, safe="")
    head = urllib.parse.quote(f"refs/heads/{branch}", safe="/")
    comparison = gh.get(f"/repos/{repo}/compare/{base}...{head}?per_page=1")
    status = (comparison or {}).get("status")
    if status not in ("identical", "ahead"):
        fail(f"head SHA {head_sha} is not on {branch} (compare status {status!r})")
    ahead_by = (comparison or {}).get("ahead_by", 0)
    return branch, channel, track, int(ahead_by) if isinstance(ahead_by, int) else -1


def prepare_jobs(gh: GitHub, repo: str, run: dict) -> tuple[dict[str, dict], dict[str, dict]]:
    """The successful prepare jobs by variant, and the successful primary legs by variant."""
    jobs = gh.pages(f"/repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest", "jobs")
    attempt = int(run["run_attempt"])
    for job in jobs:
        job_attempt = job.get("run_attempt")
        if not isinstance(job_attempt, int) or job_attempt > attempt:
            fail(f"job {job.get('name')!r} is from attempt {job_attempt}, not attempt {attempt} or before")
    found: dict[str, dict] = {}
    for job in jobs:
        match = PREPARE_JOB_NAME.match(str(job.get("name", "")))
        if not match:
            continue
        variant = match.group(1)
        if variant not in VARIANTS:
            fail(f"source run has a {PREPARE_JOB} job for an unknown variant {variant!r}")
        if variant in found:
            fail(f"source run has two {PREPARE_JOB} jobs for {variant}")
        if str(job.get("run_id")) != str(run["id"]) or job.get("head_sha") != run["head_sha"]:
            fail(f"{PREPARE_JOB} ({variant}) is not a job of the source run")
        if job.get("conclusion") == "success":
            found[variant] = job
        elif job.get("conclusion") != "skipped":
            fail(f"{PREPARE_JOB} ({variant}) concluded {job.get('conclusion')!r} in a successful run")
    if not found:
        # A build_only run skips its prepare jobs and is skipped here. A run that
        # built an app and has no prepare job at all (a nightly.yml without the
        # producer) is refused, so it shows red instead of passing silently.
        # A matrix job skipped by its `if:` is listed once, by its bare name.
        has_prepare = any(
            str(job.get("name", "")) == PREPARE_JOB or PREPARE_JOB_NAME.match(str(job.get("name", "")))
            for job in jobs
        )
        if not has_prepare and any(job.get("name") == BUILD_JOB and job.get("conclusion") == "success" for job in jobs):
            fail(f"source run built an app ({BUILD_JOB} passed) but has no {PREPARE_JOB} job")
        raise Skipped("source run prepared no app (no successful prepare-nightly-variant job)")
    primaries: dict[str, dict] = {}
    for job in jobs:
        match = PRIMARY_JOB_NAME.match(str(job.get("name", "")))
        if not match or match.group(1) not in found or job.get("conclusion") != "success":
            continue
        if str(job.get("run_id")) != str(run["id"]) or job.get("head_sha") != run["head_sha"]:
            fail(f"{PREPARE_JOB}-primary ({match.group(1)}) is not a job of the source run")
        if match.group(1) in primaries:
            fail(f"source run has two {PREPARE_JOB}-primary jobs for {match.group(1)}")
        primaries[match.group(1)] = job
    return found, primaries


def digest_records(gh: GitHub, repo: str, job: dict) -> list:
    annotations = gh.pages(f"/repos/{repo}/check-runs/{job['id']}/annotations", None)
    return [a for a in annotations if a.get("title") == DIGEST_TITLE]


def producer_digest(gh: GitHub, repo: str, job: dict, variant: str, channel: str,
                    primary: dict | None = None) -> tuple[str, str, bool, dict]:
    """The digest record of the job that uploaded the variant's tarball, and that job.

    The prepare job records it when it prepared the app itself. After a successful
    primary leg it reused the primary's upload and records nothing; the primary leg's
    record is then the producer's."""
    records = digest_records(gh, repo, job)
    if not records and primary is not None:
        job, records = primary, digest_records(gh, repo, primary)
    if len(records) != 1:
        fail(f"{PREPARE_JOB} ({variant}) recorded {len(records)} prepared app digests, not 1")
    record = records[0]
    if record.get("annotation_level") != "notice":
        fail(f"{PREPARE_JOB} ({variant}) digest record is not a notice")
    match = DIGEST_MESSAGE.match(str(record.get("message", "")).strip())
    if not match:
        fail(f"{PREPARE_JOB} ({variant}) digest record is malformed")
    recorded_variant, artifact, sha256, publish, fast = match.groups()
    if recorded_variant != variant:
        fail(f"{PREPARE_JOB} ({variant}) recorded a digest for {recorded_variant}")
    if not re.fullmatch(rf"cmux-{re.escape(channel)}-prepared-app-{re.escape(variant)}-[0-9a-f]{{7,40}}", artifact):
        fail(f"{PREPARE_JOB} ({variant}) names artifact {artifact!r}, not a {channel} {variant} prepared app")
    return artifact, sha256, publish == "true" and fast == "false", job


def find_artifact(gh: GitHub, repo: str, run: dict, name: str) -> dict:
    query = urllib.parse.quote(name, safe="")
    listed = gh.pages(f"/repos/{repo}/actions/runs/{run['id']}/artifacts?name={query}", "artifacts")
    matches = [
        a for a in listed
        if a.get("name") == name and not a.get("expired")
        and str((a.get("workflow_run") or {}).get("id")) == str(run["id"])
        and (a.get("workflow_run") or {}).get("head_sha") == run["head_sha"]
    ]
    if not matches:
        fail(f"artifact {name} is not in the source run")
    # A re-run attempt can leave more than one. The newest belongs to the
    # latest attempt; the producer digest check below catches any other.
    return max(matches, key=lambda a: str(a.get("created_at", "")))


def fetch_tarball(gh: GitHub, artifact: dict, expected_tarball: str, dest: Path) -> None:
    digest = str(artifact.get("digest") or "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        fail(f"artifact {artifact.get('name')} has no recorded sha256 digest")
    url = gh.blob_url(str(artifact.get("archive_download_url", "")))
    dest.parent.mkdir(parents=True, exist_ok=True)
    zip_path = dest.parent / "artifact.zip"
    zip_hash = hashlib.sha256()
    limit = int(artifact.get("size_in_bytes") or 0) + (64 << 20)
    written = 0
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=300) as resp, zip_path.open("wb") as out:
            while chunk := resp.read(CHUNK):
                written += len(chunk)
                if written > limit:
                    fail(f"artifact {artifact.get('name')} is larger than the API records")
                zip_hash.update(chunk)
                out.write(chunk)
    except OSError as error:
        fail(f"artifact {artifact.get('name')} download failed: {error}")
    if f"sha256:{zip_hash.hexdigest()}" != digest:
        fail(f"artifact {artifact.get('name')} sha256 {zip_hash.hexdigest()} is not the recorded {digest}")
    try:
        with zipfile.ZipFile(zip_path) as archive:
            names = archive.namelist()
            if names != [TARBALL]:
                fail(f"artifact {artifact.get('name')} holds {names}, not only {TARBALL}")
            tar_hash = hashlib.sha256()
            with archive.open(TARBALL) as member, dest.open("wb") as out:
                while chunk := member.read(CHUNK):
                    tar_hash.update(chunk)
                    out.write(chunk)
    except zipfile.BadZipFile as error:
        fail(f"artifact {artifact.get('name')} is not a zip: {error}")
    finally:
        zip_path.unlink(missing_ok=True)
    if tar_hash.hexdigest() != expected_tarball:
        dest.unlink(missing_ok=True)
        fail(
            f"artifact {artifact.get('name')} tarball sha256 {tar_hash.hexdigest()} is not "
            f"{expected_tarball}, the sha256 its producing job recorded"
        )


def admit(gh: GitHub, repo: str, run_id: str, attempt: str, out: Path) -> dict:
    run = check_identity(gh, repo, run_id, attempt)
    branch, channel, track, ahead_by = check_ref(gh, repo, run)
    jobs, primaries = prepare_jobs(gh, repo, run)
    records = {}
    for variant in VARIANTS:
        if variant in jobs:
            records[variant] = producer_digest(gh, repo, jobs[variant], variant, channel, primaries.get(variant))
    publishes = {publish for _, _, publish, _ in records.values()}
    if publishes != {True}:
        if publishes == {False}:
            raise Skipped("source run does not publish (should_publish is false or it is a fast build)")
        fail("prepare jobs of one run disagree on whether the run publishes")
    variants = []
    for variant, (artifact_name, sha256, _, producer) in records.items():
        artifact = find_artifact(gh, repo, run, artifact_name)
        fetch_tarball(gh, artifact, sha256, out / variant / TARBALL)
        variants.append({"variant": variant, "artifact": artifact_name, "sha256": sha256, "job_id": producer["id"]})
    # The attempt must still be the latest after the downloads.
    latest = gh.get(f"/repos/{repo}/actions/runs/{run_id}")
    if str((latest or {}).get("run_attempt")) != attempt:
        for variant in variants:
            (out / variant["variant"] / TARBALL).unlink(missing_ok=True)
        raise Skipped(f"source run got a newer attempt ({latest.get('run_attempt')}) during admission")
    return {
        "admitted": True,
        "source_run_id": run_id,
        "source_run_attempt": attempt,
        "source_head_sha": run["head_sha"],
        "source_branch": branch,
        "channel": channel,
        "track": track,
        # Commits the branch is ahead of the head SHA. Shadow records it; the
        # signing step must refuse a SHA older than the published one.
        "ahead_by": ahead_by,
        "variants": variants,
    }


def write_outputs(result: dict) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    lines = [f"admitted={'true' if result.get('admitted') else 'false'}"]
    for key in ("reason", "channel", "track", "source_branch", "source_head_sha", "ahead_by"):
        if key in result:
            lines.append(f"{key}={result[key]}")
    if result.get("admitted"):
        lines.append(f"variants={json.dumps([v['variant'] for v in result['variants']])}")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Nightly signing admission\n\n")
            if result.get("admitted"):
                handle.write(
                    f"Admitted run {result['source_run_id']} attempt {result['source_run_attempt']}: "
                    f"`{result['source_branch']}` at `{result['source_head_sha']}`, channel {result['channel']}.\n\n"
                )
                for v in result["variants"]:
                    handle.write(f"- {v['variant']}: `{v['artifact']}` sha256 `{v['sha256']}` (job {v['job_id']})\n")
            else:
                handle.write(f"{result.get('verdict', 'not admitted')}: {result.get('reason', '')}\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--source-run-id", required=True)
    parser.add_argument("--source-run-attempt", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    result: dict
    code = 0
    try:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
            fail("invalid repository")
        if not re.fullmatch(r"[1-9][0-9]{0,19}", args.source_run_id):
            fail("invalid source run id")
        if not re.fullmatch(r"[1-9][0-9]{0,4}", args.source_run_attempt):
            fail("invalid source run attempt")
        if not token:
            fail("GH_TOKEN is not set")
        result = admit(GitHub(token), args.repo, args.source_run_id, args.source_run_attempt, args.out)
        print(f"admitted: run {args.source_run_id} attempt {args.source_run_attempt}")
    except Skipped as reason:
        result = {"admitted": False, "verdict": "skipped", "reason": str(reason)}
        print(f"skipped: {reason}")
    except Refused as reason:
        result = {"admitted": False, "verdict": "refused", "reason": str(reason)}
        print(f"refused: {reason}", file=sys.stderr)
        code = 1
    result_path = args.out / "admission.json"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    write_outputs(result)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Reuse the compiled, unsigned cmux NEXT DEV Release app when nothing it is built from changed.

The DEV Release compile (cmux-next.yml, cmux-scheme-compile, push and dev_daily runs on
feat-cmux-next only) keys its product with `job_input_fingerprint.py dev-release-product`: the
git object ids of every tree path that can reach the app (the whole tree minus docs, tests and
other products), the whole cmux-next.yml, Xcode, the SDK, the arch, the cmux-tui tree it bundles
and RECIPE. The key is content only: no branch, commit or path.

`record` writes `manifest.json` after a compile (or a reuse) uploaded the app as the run's
`cmux-next-dev-daily-unsigned-<sha>` artifact, with the Swift compilation mode the compile resolved
(`swift_mode`: singlefile or wholemodule) beside the one asked for (`swift_mode_requested`, often
`auto`). The key keeps only the requested mode: both resolved modes are a correct product of the same
inputs, and a reuse carries its source's resolved mode forward. The workflow uploads it as the artifact
`cmux-next-dev-release-product-<key>`. `lookup` finds the newest such record from a trusted run
(a push or dispatch of cmux-next.yml on feat-cmux-next in this repository), downloads that run's
app archive, checks its SHA-256 against the record and prints `hit=true` and `archive=`. Signing,
packaging and publishing still run at the exact SHA (cmux-next-dev-daily.yml stamps CMUXCommit).

Every problem (no record, an untrusted or expired one, a digest mismatch, an API or network
error, the deadline) is a miss with a reason, and the job compiles. The lookup only runs in the
DEV lane: GITHUB_WORKFLOW_REF must be cmux-next.yml on refs/heads/feat-cmux-next, so a nightly or
stable build can never take a reused product (hq#3967).
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path

SCHEMA = "cmux-next-dev-release-product/v1"
# Bump to invalidate every recorded product (a change to how the product is built or packed that
# no keyed input shows). Passed to the fingerprint as `recipe`.
RECIPE = "dev-release-product-v1"
RECORD_PREFIX = "cmux-next-dev-release-product-"
PRODUCT_PREFIX = "cmux-next-dev-daily-unsigned-"
WORKFLOW_PATH = ".github/workflows/cmux-next.yml"
BRANCH = "feat-cmux-next"
TRUSTED_EVENTS = ("push", "workflow_dispatch")
KEY = re.compile(r"^[0-9a-f]{64}$")
SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
MAX_ARCHIVE_BYTES = 4 * 1024**3
CANDIDATES = 3
MAX_JSON_BYTES = 8 * 1024**2
# The jobs that produce the app (cmux-next-dev-daily.yml SOURCE_APP_PRODUCER_JOBS): the one that
# recorded a product must have finished successfully, or its record is not taken.
PRODUCER_JOBS = ("cmux NEXT DEV Release compile", "cmux app scheme compile (Debug)",
                 "cmux NEXT DEV Release compile (landing)")


@dataclass(frozen=True)
class Lane:
    """Where one product's records come from and what they are called. Each lane has its own record
    and product artifact names, workflow and branch, so a record one lane wrote is never read by
    another (their keys differ too: the fingerprint job's name is part of the key)."""

    name: str
    schema: str
    recipe: str
    record_prefix: str
    product_prefix: str
    archive_suffix: str
    workflow_path: str
    branch: str
    events: tuple[str, ...]
    producer_jobs: tuple[str, ...]
    # Take only records whose producer job ran on a fresh VM from a clean start (check_builder).
    fresh_builder: bool = False


DEV = Lane("DEV", SCHEMA, RECIPE, RECORD_PREFIX, PRODUCT_PREFIX, ".app.zip", WORKFLOW_PATH, BRANCH,
           TRUSTED_EVENTS, PRODUCER_JOBS)
# cmux NEXT Nightly's unsigned app before stamping (keyed by job_input_fingerprint.py nightly-release-product): nightly.yml's
# build-nightly-app on nightly-next push runs only. Nothing here is a DEV name.
NIGHTLY_NEXT_RECIPE = "nightly-release-product-v1"
NIGHTLY_NEXT = Lane(
    name="nightly-next",
    schema="cmux-nightly-next-release-product/v1",
    recipe=NIGHTLY_NEXT_RECIPE,
    record_prefix="cmux-nightly-next-release-product-",
    product_prefix="cmux-nightly-next-release-archive-",
    archive_suffix=".tar.gz",
    workflow_path=".github/workflows/nightly.yml",
    branch="nightly-next",
    events=("push",),
    producer_jobs=("build-nightly-app",),
    fresh_builder=True,
)

# A fresh VM per job (GitHub-hosted or Blacksmith) keeps nothing between jobs: no compiler cache,
# kept build tree or helper binary another job (a pull request's among them) could have left for
# the build to link. GitHub's jobs API names the runner group, which a job cannot choose.
FRESH_RUNNER_GROUPS = {"github-hosted": "GitHub Actions", "blacksmith": "blacksmith scale sets - "}
BLACKSMITH_RUNNER = re.compile(r"^blacksmith-[0-9]+vcpu-[a-z0-9.-]+$")
# What the build started from, measured before it compiled (nightly_release_product_reuse.builder).
CLEAN_START = {"derived_data": "empty", "compilation_cache": "empty"}


def builder_kind(runner_name: str, runner_environment: str = "", runner_group: str | None = None) -> str:
    """github-hosted, blacksmith or owned (anything else: a kept machine). With `runner_group` (the
    jobs API's runner_group_name) the group decides; without, the runner's own environment."""
    if runner_group is not None:
        if runner_group == FRESH_RUNNER_GROUPS["github-hosted"]:
            return "github-hosted"
        if runner_group.startswith(FRESH_RUNNER_GROUPS["blacksmith"]) and BLACKSMITH_RUNNER.match(runner_name):
            return "blacksmith"
        return "owned"
    if BLACKSMITH_RUNNER.match(runner_name):
        return "blacksmith"
    if runner_environment == "github-hosted" and runner_name.startswith("GitHub Actions "):
        return "github-hosted"
    return "owned"


def clean_builder(builder: object) -> str:
    """'' when `builder` (a record's builder field) is a fresh VM that started clean, else why not."""
    if not isinstance(builder, dict):
        return "the record names no builder"
    if builder.get("kind") not in FRESH_RUNNER_GROUPS or builder.get("fresh_vm") is not True:
        return f"the record's builder {builder.get('runner_name')!r} is {builder.get('kind')!r}, not a fresh VM"
    if builder.get("start") != CLEAN_START:
        return f"the record's build did not start clean ({builder.get('start')!r})"
    if not builder.get("runner_name"):
        return "the record names no runner"
    return ""


def check_builder(manifest: dict, jobs: list[dict], lane: Lane) -> None:
    """The record says a fresh VM built it from a clean start, and GitHub shows its producer job on
    that runner, in that runner's fresh-VM group."""
    builder = manifest.get("builder")
    why = clean_builder(builder)
    if why:
        raise Miss(why)
    for job in jobs:
        if (job.get("name") in lane.producer_jobs and job.get("conclusion") == "success"
                and job.get("runner_name") == builder["runner_name"]
                and builder_kind(str(job.get("runner_name") or ""), runner_group=str(job.get("runner_group_name") or "")) == builder["kind"]):
            return
    raise Miss(f"GitHub does not show the producer job on the fresh {builder['kind']} runner {builder['runner_name']!r}")


class Miss(Exception):
    """This record (or every record) cannot be used; the message is the reason."""


class Api:
    """The GitHub REST calls the lookup makes. Tests replace it."""

    def __init__(self, token: str, repo: str, base: str, deadline: float):
        self.token, self.repo, self.base, self.deadline = token, repo, base.rstrip("/"), deadline

    def left(self) -> float:
        left = self.deadline - time.monotonic()
        if left <= 1:
            raise Miss("the lookup ran out of time")
        return left

    def json(self, path: str) -> dict:
        request = urllib.request.Request(f"{self.base}/repos/{self.repo}/{path}", headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with urllib.request.urlopen(request, timeout=min(20, self.left())) as response:
                body = bytearray()
                # A total deadline: a slow-drip response must not outlive the lookup.
                while chunk := response.read(1 << 16):
                    body += chunk
                    if len(body) > MAX_JSON_BYTES:
                        raise Miss(f"GET {path.split('?')[0]} answered over {MAX_JSON_BYTES} bytes")
                    self.left()
                return json.loads(body.decode())
        except (OSError, ValueError, urllib.error.URLError) as error:
            raise Miss(f"GET {path.split('?')[0]} failed: {error}") from error

    def download(self, url: str, dest: Path) -> None:
        # curl, not urllib: the artifact URL redirects to blob storage, which refuses the GitHub
        # token; curl sends a -H header only to the first host. The header goes on stdin, never argv.
        command = ["curl", "-fsSL", "--retry", "2", "--connect-timeout", "10",
                   "--max-time", str(int(self.left())), "-H", "@-", "-o", str(dest), url]
        try:
            result = subprocess.run(command, input=f"Authorization: Bearer {self.token}\n", text=True,
                                    capture_output=True, timeout=self.left() + 5)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise Miss(f"download failed: {error}") from error
        if result.returncode != 0:
            raise Miss(f"download failed (curl {result.returncode}): {result.stderr.strip()[:200]}")


def record_name(key: str, lane: Lane = DEV) -> str:
    return lane.record_prefix + key


def lane_guard(env: dict[str, str], lane: Lane = DEV) -> None:
    """Only the lane's own workflow on its own branch may take a reused product. The DEV lane is
    cmux-next.yml on feat-cmux-next: never nightly or stable."""
    repo = env.get("GITHUB_REPOSITORY", "")
    expected = f"{repo}/{lane.workflow_path}@refs/heads/{lane.branch}"
    if not repo or env.get("GITHUB_WORKFLOW_REF", "") != expected:
        raise Miss(f"not the {lane.name} lane ({env.get('GITHUB_WORKFLOW_REF') or 'no GITHUB_WORKFLOW_REF'}); "
                   f"only {lane.workflow_path} on {lane.branch} reuses a product")


def trusted_records(artifacts: list[dict], key: str, repository_id: str, lane: Lane = DEV) -> list[dict]:
    """Unexpired records of `key` from this repository's runs on the lane's branch, newest first."""
    trusted = []
    for item in artifacts:
        run = item.get("workflow_run") or {}
        if item.get("name") != record_name(key, lane) or item.get("expired"):
            continue
        if str(run.get("repository_id")) != repository_id or str(run.get("head_repository_id")) != repository_id:
            continue
        if run.get("head_branch") != lane.branch or not run.get("id"):
            continue
        trusted.append(item)
    return sorted(trusted, key=lambda item: item.get("created_at") or "", reverse=True)


def check_run(run: dict, repo: str, lane: Lane = DEV) -> None:
    if run.get("event") not in lane.events:
        raise Miss(f"run {run.get('id')} is a {run.get('event')} run, not {' or '.join(lane.events)}")
    if run.get("path") != lane.workflow_path or run.get("head_branch") != lane.branch:
        raise Miss(f"run {run.get('id')} is {run.get('path')} on {run.get('head_branch')}, "
                   f"not {lane.workflow_path} on {lane.branch}")
    if (run.get("repository") or {}).get("full_name") != repo or (run.get("head_repository") or {}).get("full_name") != repo:
        raise Miss(f"run {run.get('id')} is not this repository's own")


def check_producer(jobs: list[dict], run_id: int, lane: Lane = DEV) -> None:
    producers = [job for job in jobs if job.get("name") in lane.producer_jobs]
    if not any(job.get("status") == "completed" and job.get("conclusion") == "success" for job in producers):
        states = ", ".join(f"{job.get('name')}: {job.get('conclusion') or job.get('status')}" for job in producers)
        raise Miss(f"run {run_id}'s app job did not finish successfully ({states or 'no app job'})")


def check_manifest(manifest: dict, key: str, run_id: int, lane: Lane = DEV) -> None:
    if manifest.get("schema") != lane.schema:
        raise Miss(f"record schema {manifest.get('schema')!r} is not {lane.schema}")
    if manifest.get("key") != key:
        raise Miss("the record names another key")
    if manifest.get("run_id") != run_id:
        raise Miss("the record names another run than the one that uploaded it")
    sha = manifest.get("source_sha", "")
    if not SHA.match(str(sha)) or manifest.get("product_artifact") != lane.product_prefix + sha:
        raise Miss("the record names no product artifact of its commit")
    if not DIGEST.match(str(manifest.get("archive_sha256", ""))):
        raise Miss("the record has no archive digest")
    name = str(manifest.get("archive_name", ""))
    if not name or "/" in name or name.startswith(".") or not name.endswith(lane.archive_suffix):
        raise Miss(f"the record's archive name {name!r} is not a plain {lane.archive_suffix} name")
    size = manifest.get("archive_bytes")
    if not isinstance(size, int) or not 0 < size <= MAX_ARCHIVE_BYTES:
        raise Miss(f"the record's archive size {size!r} is out of range")


def extract_verified(bundle: Path, manifest: dict, out_dir: Path) -> Path:
    """Copy the record's archive out of the downloaded artifact zip, checking size and SHA-256."""
    name = manifest["archive_name"]
    try:
        with zipfile.ZipFile(bundle) as artifact:
            info = artifact.getinfo(name)
            if info.file_size != manifest["archive_bytes"]:
                raise Miss(f"the archive is {info.file_size} bytes, the record says {manifest['archive_bytes']}")
            out_dir.mkdir(parents=True, exist_ok=True)
            dest = out_dir / name
            digest = hashlib.sha256()
            with artifact.open(info) as source, dest.open("wb") as sink:
                for chunk in iter(lambda: source.read(1 << 20), b""):
                    digest.update(chunk)
                    sink.write(chunk)
    except KeyError as error:
        raise Miss(f"the product artifact has no {name}") from error
    except (zipfile.BadZipFile, OSError) as error:
        raise Miss(f"the product artifact is not a readable zip: {error}") from error
    if digest.hexdigest() != manifest["archive_sha256"]:
        dest.unlink(missing_ok=True)
        raise Miss("the archive's SHA-256 does not match the record (corrupt or replaced)")
    return dest


def read_record(api: Api, item: dict, scratch: Path) -> dict:
    path = scratch / f"record-{item.get('id')}.zip"
    api.download(item["archive_download_url"], path)
    try:
        with zipfile.ZipFile(path) as record:
            return json.loads(record.read("manifest.json").decode())
    except (KeyError, zipfile.BadZipFile, ValueError, OSError) as error:
        raise Miss(f"record {item.get('id')} has no readable manifest.json: {error}") from error


def try_record(api: Api, item: dict, key: str, repo: str, out_dir: Path, scratch: Path,
               lane: Lane = DEV) -> dict[str, str]:
    run_id = int(item["workflow_run"]["id"])
    check_run(api.json(f"actions/runs/{run_id}"), repo, lane)
    jobs = api.json(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100").get("jobs", [])
    check_producer(jobs, run_id, lane)
    manifest = read_record(api, item, scratch)
    check_manifest(manifest, key, run_id, lane)
    if lane.fresh_builder:
        check_builder(manifest, jobs, lane)
    query = urllib.parse.urlencode({"name": manifest["product_artifact"], "per_page": 10})
    products = [a for a in api.json(f"actions/runs/{run_id}/artifacts?{query}").get("artifacts", [])
                if a.get("name") == manifest["product_artifact"] and not a.get("expired")]
    if len(products) != 1:
        raise Miss(f"run {run_id} has no unexpired {manifest['product_artifact']}")
    bundle = scratch / f"product-{products[0].get('id')}.zip"
    api.download(products[0]["archive_download_url"], bundle)
    try:
        archive = extract_verified(bundle, manifest, out_dir)
    finally:
        bundle.unlink(missing_ok=True)
    return {"hit": "true", "archive": str(archive), "source_run_id": str(run_id),
            "source_sha": manifest["source_sha"], "archive_sha256": manifest["archive_sha256"],
            "compiled_run_id": str(manifest.get("compiled_run_id") or run_id),
            # What the source compile resolved its requested mode to (`auto` -> singlefile or wholemodule);
            # empty for a record written before it was kept.
            "swift_mode": str(manifest.get("swift_mode") or ""),
            "swift_mode_requested": str(manifest.get("swift_mode_requested") or "")}


def lookup(api: Api, key: str, env: dict[str, str], out_dir: Path, lane: Lane = DEV) -> dict[str, str]:
    lane_guard(env, lane)
    if not KEY.match(key):
        raise Miss(f"{key!r} is not a product key (the fingerprint gave none)")
    repository_id = env.get("GITHUB_REPOSITORY_ID", "").strip()
    if not repository_id:
        raise Miss("GITHUB_REPOSITORY_ID is not set, so no record can be trusted")
    query = urllib.parse.urlencode({"name": record_name(key, lane), "per_page": 30})
    records = trusted_records(api.json(f"actions/artifacts?{query}").get("artifacts", []), key, repository_id, lane)
    if not records:
        raise Miss("no product was recorded for these inputs (a product input changed)")
    reasons = []
    with tempfile.TemporaryDirectory(prefix="cmux-dev-product-") as scratch:
        for item in records[:CANDIDATES]:
            try:
                return try_record(api, item, key, env["GITHUB_REPOSITORY"], out_dir, Path(scratch), lane)
            except (Miss, KeyError, TypeError, ValueError) as why:
                reasons.append(f"run {(item.get('workflow_run') or {}).get('id')}: {why}")
    raise Miss("; ".join(reasons))


def summarize(outputs: dict[str, str], key: str, summary: str | None, lane: Lane = DEV) -> None:
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if outputs.get("hit") == "true":
        url = f"{server}/{repo}/actions/runs/{outputs['source_run_id']}"
        mode = swift_mode_note(outputs.get("swift_mode_requested", ""), outputs.get("swift_mode", ""))
        line = (f"{lane.name} Release product: **hit**. Reused the app {url} compiled at `{outputs['source_sha'][:12]}` "
                f"(key `{key[:16]}`, sha256 `{outputs['archive_sha256'][:16]}`{', swift_mode ' + mode if mode else ''}); "
                "xcodebuild skipped.")
        print(f"::notice title={lane.name} Release product reused::{url} at {outputs['source_sha'][:12]}, key {key[:16]}",
              file=sys.stderr)
    else:
        line = f"{lane.name} Release product: **miss** ({outputs.get('reason', 'unknown')}); compiling."
        print(f"::notice title={lane.name} Release product miss::{outputs.get('reason', 'unknown')}", file=sys.stderr)
    if summary:
        try:
            with open(summary, "a", encoding="utf-8") as stream:
                stream.write(line + "\n")
        except OSError:
            pass


def swift_mode_note(requested: str, resolved: str) -> str:
    """`auto -> wholemodule`, `singlefile`, or "" when nothing was recorded."""
    if requested and resolved and requested != resolved:
        return f"{requested} -> {resolved}"
    return resolved or requested


SWIFT_MODES = ("auto", "singlefile", "wholemodule")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def record(args: argparse.Namespace, env: dict[str, str], lane: Lane = DEV) -> dict:
    if not KEY.match(args.key) or not SHA.match(args.sha):
        raise SystemExit("record: --key must be 64 hex and --sha 40 hex")
    archive = Path(args.archive)
    manifest = {
        "schema": lane.schema, "key": args.key, "recipe": lane.recipe, "source_sha": args.sha,
        "run_id": int(env["GITHUB_RUN_ID"]), "run_attempt": int(env.get("GITHUB_RUN_ATTEMPT", "1")),
        "product_artifact": lane.product_prefix + args.sha, "archive_name": archive.name,
        "archive_bytes": archive.stat().st_size, "archive_sha256": sha256_file(archive),
        "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        # Provenance: where these bytes were compiled. A reuse records the run it took them from.
        "origin": "reused" if args.reused_from_run else "compiled",
        "compiled_run_id": int(args.compiled_run or args.reused_from_run or env["GITHUB_RUN_ID"]),
    }
    if args.reused_from_run:
        manifest["reused_from"] = {"run_id": int(args.reused_from_run), "source_sha": args.reused_from_sha}
    # Reporting only: the key never holds the resolved mode (see the module docstring).
    for field in ("swift_mode", "swift_mode_requested"):
        value = (getattr(args, field, "") or "").strip()
        if value:
            if value not in SWIFT_MODES:
                # A report field never costs the record: an unknown value is left out, not fatal.
                print(f"record: ignoring --{field.replace('_', '-')} {value!r} (not one of {', '.join(SWIFT_MODES)})",
                      file=sys.stderr)
                continue
            manifest[field] = value
    if getattr(args, "builder", ""):
        manifest["builder"] = json.loads(Path(args.builder).read_text())
    if lane.fresh_builder and clean_builder(manifest.get("builder")):
        raise SystemExit(f"record: {clean_builder(manifest.get('builder'))}; nothing recorded")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def main(argv: list[str] | None = None, lane: Lane = DEV) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    find = sub.add_parser("lookup", help="print hit=true|false, reason= and archive= for $GITHUB_OUTPUT")
    find.add_argument("--key", required=True, help="the lane's job_input_fingerprint.py product fingerprint")
    find.add_argument("--out", required=True, help="directory for the verified archive")
    find.add_argument("--timeout", type=float, default=180, help="seconds for the whole lookup")
    find.add_argument("--skip", default="", help="a reason to skip the lookup (no_reuse, switched off)")
    find.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    rec = sub.add_parser("record", help="write the manifest.json of an uploaded product")
    rec.add_argument("--key", required=True)
    rec.add_argument("--sha", required=True, help="the commit this run built (its product artifact's name)")
    rec.add_argument("--archive", required=True)
    rec.add_argument("--out", required=True)
    rec.add_argument("--reused-from-run", default="")
    rec.add_argument("--reused-from-sha", default="")
    rec.add_argument("--compiled-run", default="", help="the run that ran xcodebuild for these bytes")
    rec.add_argument("--builder", default="", help="the builder JSON nightly_release_product_reuse.py builder wrote")
    rec.add_argument("--swift-mode", default="", help="the Swift compilation mode the compile resolved (or the reused source's)")
    rec.add_argument("--swift-mode-requested", default="", help="the mode the compile was asked for (the key's)")
    args = parser.parse_args(argv)
    env = dict(os.environ)
    if args.command == "record":
        manifest = record(args, env, lane)
        print(f"record={record_name(args.key, lane)}")
        print(f"archive_sha256={manifest['archive_sha256']}")
        if manifest.get("swift_mode"):
            print(f"swift_mode={manifest['swift_mode']}")
        return 0
    outputs: dict[str, str]
    try:
        if args.skip:
            raise Miss(args.skip)
        api = Api(env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or "", env.get("GITHUB_REPOSITORY", ""),
                  env.get("GITHUB_API_URL", "https://api.github.com"), time.monotonic() + args.timeout)
        if not api.token:
            raise Miss("no token to read artifacts with")
        outputs = lookup(api, args.key, env, Path(args.out), lane)
    except Miss as why:
        outputs = {"hit": "false", "reason": " ".join(str(why).split())[:500]}
    except Exception as error:  # noqa: BLE001 - a lookup bug must never fail the compile job
        outputs = {"hit": "false", "reason": f"lookup error: {type(error).__name__}: {error}"[:500]}
    summarize(outputs, args.key, args.summary, lane)
    for name, value in outputs.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

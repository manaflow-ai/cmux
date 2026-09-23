#!/usr/bin/env python3
"""Reuse compiled products, never test outcomes, across trusted CI runs.

Product compatibility is independent of CI orchestration identity. GitHub's
immutable commit/tree data is re-fingerprinted against the current product-input
contract before an artifact is trusted; exact producer/consumer revisions stay
in provenance. Missing provenance, old artifacts, API errors and corrupt
downloads are cache misses.
"""
from __future__ import annotations

import base64
import hashlib
import gzip
import http.client
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode

import app_host_test_products as products
import parallel_artifact_download as parallel
import product_input_identity as product_inputs

RECEIPT = "cmux-product-reuse.json"
PREFIX = "app-host-products-v1-"
# Current product archives are ~0.8 GiB compressed. Bound every expansion layer
# independently, including hardlink copies, with room for the UI product set.
MAX_ARCHIVE_BYTES = 2 * 1024**3
MAX_MEMBER_BYTES = 4 * 1024**3
MAX_EXPANDED_BYTES = 16 * 1024**3
MAX_TAR_BYTES = 20 * 1024**3
MAX_MEMBERS = 200_000

# Producers publish one artifact per run attempt, so the exact artifact name is
# known before any request. Attempts beyond the third are rare enough that a
# fourth lookup costs more than the compile it would occasionally avoid.
LOOKUP_ATTEMPTS = 3
ARTIFACTS_PER_PAGE = 100
MAX_CANDIDATES = 6

# Producer events permitted for each consumer event. Pull-request consumers are
# further restricted to the same pull request; merge groups may adopt an exact
# product from either an in-repository PR or an earlier merge-group run.
#
# A dispatch consumer is at least as trusted as a merge group, because starting
# one requires write access, so it may adopt any exact product CI compiled as
# well as the ones earlier dispatches of its own lane compiled. Nothing adopts a
# dispatch product in the other direction: CI's trust surface is unchanged.
PERMITTED_PRODUCERS = {
    "pull_request": {"pull_request"},
    "merge_group": {"pull_request", "merge_group"},
    "workflow_dispatch": {"pull_request", "merge_group", "workflow_dispatch"},
}

# The workflow each event is trusted to run from, keyed by event so a future
# dispatchable ci.yml or pull-request-triggered E2E lane cannot inherit the
# other one's trust by accident.
TRUSTED_WORKFLOWS = {
    "pull_request": ".github/workflows/ci.yml",
    "merge_group": ".github/workflows/ci.yml",
    "workflow_dispatch": ".github/workflows/test-e2e.yml",
}

# The job, and the step inside it, that must have compiled a product before that
# workflow's artifact may be adopted.
COMPILE_JOBS = {
    ".github/workflows/ci.yml": (
        "macOS compile admission", "Compile app-host test product",
    ),
    ".github/workflows/test-e2e.yml": (
        "build", "Build the app-host and UI test product",
    ),
}


def read(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def contract():
    versions = {}
    for command in ("rustc", "cargo", "go", "zig", "node", "bun"):
        executable = shutil.which(command)
        versions[command] = read(executable, "version" if command in {"go", "zig"} else "--version") if executable else "absent"
    return {
        "product_inputs": product_inputs.local_identity(),
        "xcode": read("xcodebuild", "-version"),
        "sdk": read("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "os": read("sw_vers", "-buildVersion"),
        "architecture": platform.machine(),
        "tools": versions,
        # Only non-secret build controls belong in the public artifact receipt.
        "environment": {k: os.environ.get(k, "") for k in (
            "CMUX_CI_XCODE_APP", "CMUX_CI_REQUIRED_MACOS_SDK_MAJOR", "CMUX_SKIP_ZIG_BUILD",
            "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
            "OTHER_SWIFT_FLAGS", "OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS", "OTHER_LDFLAGS",
            "RUSTFLAGS", "CFLAGS", "CXXFLAGS", "LDFLAGS", "ImageOS", "ImageVersion")},
        "runner": os.environ.get("CMUX_PRODUCT_RUNNER", ""),
    }


def key(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def github_product_identity(api, revision):
    """Recompute one revision's product identity from GitHub-owned Git objects."""
    cache = getattr(api, "_product_identity_cache", None)
    if cache is None:
        cache = {}
        setattr(api, "_product_identity_cache", cache)
    if revision in cache:
        return cache[revision]

    commit = api.get(f"git/commits/{revision}")
    tree_sha = commit["tree"]["sha"]
    tree_payload = api.get(f"git/trees/{tree_sha}?recursive=1")
    if tree_payload.get("truncated"):
        raise ValueError("GitHub tree is truncated")
    entries = tree_payload.get("tree")
    if not isinstance(entries, list):
        raise ValueError("GitHub tree is unavailable")

    def workflow_text(path):
        workflow_entry = next(
            (
                entry for entry in entries
                if isinstance(entry, dict)
                and entry.get("path") == path
                and entry.get("type") == "blob"
            ),
            None,
        )
        if workflow_entry is None or not isinstance(workflow_entry.get("sha"), str):
            raise ValueError(f"workflow blob is unavailable: {path}")
        blob = api.get(f"git/blobs/{workflow_entry['sha']}")
        if blob.get("encoding") != "base64" or not isinstance(blob.get("content"), str):
            raise ValueError(f"workflow blob encoding is invalid: {path}")
        return base64.b64decode(blob["content"]).decode("utf-8")

    workflow = workflow_text(product_inputs.CI_WORKFLOW)
    e2e_workflow = workflow_text(product_inputs.E2E_WORKFLOW)
    value = product_inputs.identity_from_tree_lines(
        product_inputs.github_tree_lines(entries),
        workflow,
        e2e_workflow,
    )
    cache[revision] = value
    return value


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def get(self, path):
        return json.loads(read("gh", "api", f"repos/{self.repository}/{path}"))

    def download(self, artifact_id, target, size):
        # One connection to the artifact blob sustains about 2 MB/s on the
        # Blacksmith macOS fleet, so a ~900 MB product took longer than any
        # budget worth waiting for and every candidate timed out into a
        # compile. The test job reads the same blob in under a minute over
        # parallel range requests; this uses that transport.
        parallel.download_zip(self.repository, artifact_id, target, size)


def record_reason(reasons, reason):
    """Record a bounded, non-sensitive cache miss reason once."""
    if reason not in reasons:
        reasons.append(reason)
        print(f"Compiled-product reuse miss: {reason}.")


def pull_request_numbers(run):
    """Return the PR numbers GitHub associates with a workflow run."""
    pulls = run.get("pull_requests")
    if not isinstance(pulls, list):
        return set()
    return {item["number"] for item in pulls
            if isinstance(item, dict) and isinstance(item.get("number"), int)}


def commit_parents(revision):
    """Read one commit object's parent revisions from the local checkout.

    `git rev-parse <revision>^2` cannot answer this. The compile admission job
    checks out at the default fetch depth of one, and a shallow repository
    grafts its boundary commits as parentless, so every revision walk reports
    no parents at all. The commit object itself is transferred intact and still
    names each parent.
    """
    header = read("git", "cat-file", "commit", revision).split("\n\n", 1)[0]
    return [line.split(" ", 1)[1] for line in header.splitlines()
            if line.startswith("parent ")]


def attested_checkout(run, current_revision):
    """Bind the local checkout to the revision GitHub attests for this run.

    A pull request run checks out `github.sha`, the ephemeral merge of the pull
    request head into the base, so its checkout is never the run's `head_sha`.
    That merge commit names the attested head as its second parent, which is
    what makes the local tree the tested form of that head rather than an
    unrelated revision. Every other event checks out the attested commit, and
    those keep requiring it exactly.

    The tree itself is still not taken on trust: `load_consumer` goes on to
    require the local product-input fingerprint to equal the one recomputed
    from GitHub's copy of `head_sha`, so a checkout that carries different
    compiled-product inputs than the attested head cannot adopt its products.
    """
    if current_revision == run.get("head_sha"):
        return True
    if run.get("event") != "pull_request":
        return False
    if not re.fullmatch(r"[0-9a-f]{6,40}", str(current_revision)):
        return False
    parents = commit_parents(current_revision)
    return len(parents) == 2 and parents[1] == run["head_sha"]


def attested_producer_revision(api, run, revision, product_inputs):
    """Whether `revision` is the revision GitHub attests this producer built.

    A pull request producer seals `git rev-parse HEAD`, which is the ephemeral
    merge of the pull request head into the base, while the run's `head_sha` is
    that head. Requiring them to be equal rejected every pull request producer,
    and only after its archive had already been downloaded and expanded, so no
    pull request could ever adopt an earlier run of its own compiled product.

    This mirrors `attested_checkout` on the consumer side and then goes one
    step further: the sealed revision's own tree is re-fingerprinted from
    GitHub's immutable Git objects, so the merge that was actually compiled --
    not just the head it names -- has to carry these product inputs.
    """
    head = run.get("head_sha")
    if run.get("event") == "workflow_dispatch":
        # A dispatch's head names the workflow definition, while its sealed
        # revision names the checkout it compiled. Bind both: the actual E2E
        # build recipe GitHub ran must equal the recipe in the product identity,
        # and the sealed checkout must still re-fingerprint to that identity.
        if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{6,40}", head):
            return False
        actual_workflow = github_product_identity(api, head)
        if actual_workflow.get("e2e_recipe") != product_inputs.get("e2e_recipe"):
            return False
        return github_product_identity(api, revision) == product_inputs
    if revision == head:
        return True
    if run.get("event") != "pull_request":
        return False
    parents = api.get(f"git/commits/{revision}").get("parents")
    if not isinstance(parents, list) or len(parents) != 2:
        return False
    second = parents[1]
    if not isinstance(second, dict) or second.get("sha") != head:
        return False
    return github_product_identity(api, revision) == product_inputs


def trusted_ci_run(run, repository):
    """Require the event's own trusted workflow and an in-repository source."""
    head_repository = run.get("head_repository")
    event = run.get("event")
    return (
        event in PERMITTED_PRODUCERS
        and run.get("path") == TRUSTED_WORKFLOWS[event]
        and isinstance(head_repository, dict)
        and str(head_repository.get("full_name", "")).casefold() == repository.casefold()
    )


def permitted_pair(producer, consumer, repository):
    """Apply the explicit trusted producer/consumer matrix."""
    if not trusted_ci_run(producer, repository) or not trusted_ci_run(consumer, repository):
        return False
    consumer_event = consumer["event"]
    if producer["event"] not in PERMITTED_PRODUCERS[consumer_event]:
        return False
    if consumer_event == "pull_request":
        producer_prs = pull_request_numbers(producer)
        consumer_prs = pull_request_numbers(consumer)
        return len(consumer_prs) == 1 and producer_prs == consumer_prs
    return True


def elapsed_seconds(started_at, completed_at):
    """Measure an Actions step interval when both timestamps are available."""
    if not started_at or not completed_at:
        return None
    try:
        started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        completed = datetime.fromisoformat(completed_at.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return max(0.0, (completed - started).total_seconds())


def compile_step_seconds(job, step_name="Compile app-host test product"):
    """Return the producer's actual compile-step duration when it compiled."""
    steps = job.get("steps")
    if not isinstance(steps, list):
        return None
    for step in steps:
        if (step.get("name") == step_name
                and step.get("status") == "completed"
                and step.get("conclusion") == "success"):
            return elapsed_seconds(step.get("started_at"), step.get("completed_at"))
    return None


def load_consumer(api, value, current_run, current_attempt, current_revision, reasons):
    """Verify the running consumer and product inputs against GitHub."""
    try:
        run = api.get(f"actions/runs/{current_run}")
        if str(run.get("run_attempt")) != str(current_attempt):
            record_reason(reasons, "consumer_attempt_mismatch")
            return None
        if not trusted_ci_run(run, api.repository):
            record_reason(reasons, "consumer_untrusted")
            return None
        # A dispatch takes the revision under test as a workflow input, so its
        # `head_sha` names the workflow definition's ref and attests nothing
        # about the checkout. The binding that matters is the same either way:
        # the tree this job fingerprinted has to equal GitHub's immutable copy
        # of the revision it claims, which is checked directly below. A locally
        # modified checkout still cannot adopt anything.
        dispatched = run.get("event") == "workflow_dispatch"
        head = current_revision if dispatched else run.get("head_sha")
        if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{6,40}", head):
            record_reason(reasons, "consumer_revision_invalid")
            return None
        if not dispatched and not attested_checkout(run, current_revision):
            record_reason(reasons, "consumer_revision_mismatch")
            return None
        if github_product_identity(api, head) != value["product_inputs"]:
            record_reason(reasons, "consumer_product_inputs_mismatch")
            return None
        return run
    except (TypeError, AttributeError, ValueError, KeyError, OSError,
            UnicodeError, subprocess.SubprocessError):
        record_reason(reasons, "consumer_provenance_unavailable")
        return None


def artifact_name(value, attempt):
    """Name a producer publishes for one product contract and run attempt."""
    return f"{PREFIX}{key(value)}-{attempt}"


def candidates(api, value, reasons):
    """List this contract's artifacts by exact name, newest first.

    Scanning recent repository artifacts only reaches back as far as artifact
    churn allows, which is minutes here, while these artifacts are retained for
    days. Asking for each attempt's exact name instead reaches every retained
    artifact for this contract in one bounded request per attempt. A failed or
    malformed listing is a miss for that attempt alone, never an exception.
    """
    found = []
    for attempt in range(1, LOOKUP_ATTEMPTS + 1):
        name = artifact_name(value, attempt)
        query = urlencode({"name": name, "per_page": ARTIFACTS_PER_PAGE})
        try:
            batch = api.get(f"actions/artifacts?{query}")["artifacts"]
        except (TypeError, AttributeError, ValueError, KeyError, OSError,
                UnicodeError, subprocess.SubprocessError):
            record_reason(reasons, "artifact_listing_unavailable")
            continue
        if not isinstance(batch, list):
            record_reason(reasons, "artifact_listing_invalid")
            continue
        # Re-check the name locally: candidate enumeration must not depend on
        # the server honoring the filter.
        found.extend((attempt, a) for a in batch
                     if isinstance(a, dict) and a.get("name") == name)
    # Prefer the most recent artifacts across attempts, so a rerun's earlier
    # attempt is considered before older runs of the same contract.
    found.sort(key=lambda item: str(item[1].get("created_at") or ""), reverse=True)
    return found[:MAX_CANDIDATES]


def select(api, value, current_run, current_attempt, consumer, reasons):
    """Inspect at most six exact-name artifacts and their producers."""
    matches = candidates(api, value, reasons)
    if not matches:
        record_reason(reasons, "no_matching_contract_artifact")
    for producer_attempt, artifact in matches:
        try:
            if artifact.get("expired"):
                record_reason(reasons, "artifact_expired")
                continue
            size = artifact.get("size_in_bytes")
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                record_reason(reasons, "artifact_size_invalid")
                continue
            if size > MAX_ARCHIVE_BYTES:
                record_reason(reasons, "artifact_oversize")
                continue
            workflow_run = artifact.get("workflow_run")
            run_id = workflow_run.get("id") if isinstance(workflow_run, dict) else None
            if not run_id:
                record_reason(reasons, "artifact_run_missing")
                continue
            if str(run_id) == str(current_run) and producer_attempt >= int(current_attempt):
                record_reason(reasons, "artifact_not_from_earlier_attempt")
                continue
            # Query the exact producer attempt. The top-level run endpoint points
            # at the latest attempt and would otherwise make prior rerun artifacts
            # look stale even though their attempt-scoped receipt is still valid.
            run = api.get(f"actions/runs/{run_id}/attempts/{producer_attempt}")
            if str(run.get("run_attempt")) != str(producer_attempt):
                record_reason(reasons, "producer_attempt_mismatch")
                continue
            if not permitted_pair(run, consumer, api.repository):
                record_reason(reasons, "producer_consumer_pair_disallowed")
                continue
            # GitHub's immutable Git objects, not a candidate-authored receipt,
            # establish product compatibility before download. Admission-only
            # source changes may differ while compiled-product inputs stay exact.
            #
            head = run.get("head_sha")
            if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{6,40}", head):
                record_reason(reasons, "producer_revision_invalid")
                continue
            if run.get("event") == "workflow_dispatch":
                # The dispatch head attests the workflow recipe, not the checkout.
                # Reject a product before download when that actual recipe differs
                # from the E2E recipe sealed into this contract.
                actual_workflow = github_product_identity(api, head)
                if actual_workflow.get("e2e_recipe") != value["product_inputs"].get("e2e_recipe"):
                    record_reason(reasons, "producer_recipe_mismatch")
                    continue
            elif github_product_identity(api, head) != value["product_inputs"]:
                record_reason(reasons, "producer_product_inputs_mismatch")
                continue
            jobs = []
            for page in range(1, 4):
                batch = api.get(
                    f"actions/runs/{run_id}/attempts/{producer_attempt}/jobs?per_page=100&page={page}"
                )["jobs"]
                if not isinstance(batch, list):
                    raise ValueError("invalid jobs listing")
                jobs.extend(batch)
                if len(batch) < 100:
                    break
            # The compile job must finish successfully; unrelated producer tests
            # may still be running because no test result is reused here.
            # A reusable workflow reports "<caller job> / <job name>", so this
            # is "macos / macOS compile admission" when ci.yml reaches the job
            # through ci-macos.yml. Match the final segment.
            compile_name, compile_step = COMPILE_JOBS[run["path"]]
            compile_job = next((job for job in jobs
                                if str(job.get("name") or "").rsplit(" / ", 1)[-1] == compile_name
                                and job.get("status") == "completed"
                                and job.get("conclusion") == "success"), None)
            if compile_job is None:
                record_reason(reasons, "producer_compile_unsuccessful")
                continue
            digest = artifact.get("digest")
            if not isinstance(digest, str) or not digest.startswith("sha256:"):
                record_reason(reasons, "artifact_digest_missing")
                continue
            run = dict(run)
            run["_compile_seconds"] = compile_step_seconds(compile_job, compile_step)
            run["_producer_attempt"] = producer_attempt
            yield artifact, run
        except (TypeError, AttributeError, ValueError, KeyError, OSError,
                subprocess.SubprocessError):
            # A stale candidate can disappear between the bounded artifact list
            # and its attempt/job/tree lookup. Treat only that candidate as a miss.
            record_reason(reasons, "producer_provenance_unavailable")
            continue


def bounded_copy(source, output, limit):
    copied = 0
    while True:
        chunk = source.read(min(1024 * 1024, limit - copied + 1))
        if not chunk:
            return copied
        copied += len(chunk)
        if copied > limit:
            raise ValueError("archive expansion limit exceeded")
        output.write(chunk)


class BoundedReader:
    def __init__(self, source, limit):
        self.source, self.remaining = source, limit

    def read(self, size=-1):
        size = self.remaining + 1 if size < 0 else min(size, self.remaining + 1)
        chunk = self.source.read(size)
        self.remaining -= len(chunk)
        if self.remaining < 0:
            raise ValueError("tar stream expansion limit exceeded")
        return chunk


class BoundedTarInfo(tarfile.TarInfo):
    @classmethod
    def frombuf(cls, buf, encoding, errors):
        info = super().frombuf(buf, encoding, errors)
        # PAX/GNU extension bodies are read into memory by tarfile before it
        # yields a member, so their limits must be checked at header parsing.
        if info.size > MAX_MEMBER_BYTES or (info.type in {tarfile.XHDTYPE, tarfile.XGLTYPE,
                tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK} and info.size > 1024 * 1024):
            raise ValueError("tar header size limit exceeded")
        return info


def unpack(archive, staging, digest):
    if archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("archive size limit exceeded")
    h = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    if "sha256:" + h.hexdigest() != digest:
        raise ValueError("artifact digest mismatch")
    compressed = staging / "app-host-products.tar.gz"
    with zipfile.ZipFile(archive) as z:
        if z.namelist() != ["app-host-products.tar.gz"]:
            raise ValueError("unexpected artifact contents")
        info = z.infolist()[0]
        if info.file_size > MAX_ARCHIVE_BYTES:
            raise ValueError("zip expansion limit exceeded")
        with z.open(info) as source, compressed.open("wb") as output:
            bounded_copy(source, output, MAX_ARCHIVE_BYTES)
    expanded = 0
    hardlinks = []
    # Limit the decompressed stream too: tar metadata/PAX headers must not
    # bypass the per-file limits or force getmembers() to allocate unboundedly.
    with gzip.open(compressed, "rb") as gz:
        try:
            with tarfile.open(fileobj=BoundedReader(gz, MAX_TAR_BYTES), mode="r|", tarinfo=BoundedTarInfo) as tar:
                for count, member in enumerate(tar, 1):
                    if count > MAX_MEMBERS:
                        raise ValueError("archive member count limit exceeded")
                    parts = Path(member.name).parts
                    if parts[:2] != ("Build", "Products") or ".." in parts:
                        raise tarfile.ExtractError("unscoped product path")
                    if not (member.isdir() or member.isfile() or member.islnk()):
                        raise tarfile.ExtractError("unsupported product entry")
                    if member.size > MAX_MEMBER_BYTES or expanded + member.size > MAX_EXPANDED_BYTES:
                        raise ValueError("archive member size limit exceeded")
                    target = staging / member.name
                    if member.isdir():
                        target.mkdir(parents=True, exist_ok=True)
                    elif member.isfile():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        with tar.extractfile(member) as source, target.open("wb") as output:
                            copied = bounded_copy(source, output, min(MAX_MEMBER_BYTES, MAX_EXPANDED_BYTES - expanded))
                        if copied != member.size:
                            raise ValueError("truncated archive member")
                        expanded += copied
                        target.chmod(member.mode & 0o777)
                    else:
                        target_parts = Path(member.linkname).parts
                        if target_parts[:2] != ("Build", "Products") or ".." in target_parts:
                            raise tarfile.ExtractError("unscoped product hardlink")
                        hardlinks.append(member)
        except (gzip.BadGzipFile, EOFError) as error:
            raise tarfile.ReadError("invalid compressed product archive") from error
    for member in hardlinks:
        source_path = staging / member.linkname
        target = staging / member.name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise tarfile.ExtractError("duplicate product hardlink")
        with source_path.open("rb") as source, target.open("wb") as output:
            expanded += bounded_copy(source, output, min(MAX_MEMBER_BYTES, MAX_EXPANDED_BYTES - expanded))
        target.chmod(source_path.stat().st_mode & 0o777)



def producer_record(run, receipt, artifact):
    """Describe the immediate artifact producer without changing product identity."""
    return {
        "run_id": str(run["id"]),
        "run_attempt": str(run["run_attempt"]),
        "run_url": run.get("html_url", ""),
        "revision": receipt["revision"],
        "artifact_id": artifact["id"],
        "artifact_digest": artifact["digest"],
    }


def valid_revision(value):
    """Return whether a provenance revision has the expected Git SHA form."""
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{6,40}", value) is not None


def valid_positive_decimal(value):
    """Return whether a string contains one positive decimal integer."""
    return isinstance(value, str) and value.isdecimal() and int(value) > 0


def valid_artifact_id(value):
    """Return whether an artifact identifier is a positive integer."""
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def valid_digest(value):
    """Return whether a provenance digest is one complete SHA-256 identifier."""
    return isinstance(value, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value) is not None


def valid_metric(value):
    """Accept unavailable metrics or finite, non-negative numeric measurements."""
    if value is None:
        return True
    return (isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(float(value))
            and value >= 0)


def valid_producer_record(record):
    """Validate the full producer identity written by schema-2 provenance."""
    return (
        isinstance(record, dict)
        and valid_positive_decimal(record.get("run_id"))
        and valid_positive_decimal(record.get("run_attempt"))
        and isinstance(record.get("run_url"), str)
        and valid_revision(record.get("revision"))
        and valid_artifact_id(record.get("artifact_id"))
        and valid_digest(record.get("artifact_digest"))
    )


def valid_legacy_provenance(record):
    """Validate the older provenance shape emitted before schema 2."""
    if not isinstance(record, dict):
        return False
    if "schema" in record:
        return False
    if not (
        isinstance(record.get("run_url"), str)
        and valid_revision(record.get("revision"))
        and valid_artifact_id(record.get("artifact_id"))
        and valid_revision(record.get("consumer_revision"))
    ):
        return False
    if "metrics" in record:
        metrics = record["metrics"]
        if not isinstance(metrics, dict) or not all(valid_metric(value) for value in metrics.values()):
            return False
    upstream = record.get("upstream")
    return upstream is None or valid_upstream_provenance(upstream)


def valid_upstream_provenance(record):
    """Validate legacy or schema-2 provenance before carrying it to a new hop."""
    if not isinstance(record, dict):
        return False
    schema = record.get("schema")
    if schema is None:
        return valid_legacy_provenance(record)
    if schema != 2:
        return False

    metrics = record.get("metrics")
    metric_names = {
        "compile_seconds_avoided",
        "lookup_seconds",
        "transfer_seconds",
        "restore_seconds",
        "total_reuse_seconds",
        "macos_runner_minutes_saved",
    }
    if (not isinstance(metrics, dict)
            or set(metrics) != metric_names
            or not all(valid_metric(metrics[name]) for name in metric_names)):
        return False

    consumer = record.get("consumer")
    if not (
        valid_producer_record(record.get("original_producer"))
        and valid_producer_record(record.get("immediate_producer"))
        and isinstance(consumer, dict)
        and valid_positive_decimal(consumer.get("run_id"))
        and valid_positive_decimal(consumer.get("run_attempt"))
        and valid_revision(consumer.get("revision"))
        and record.get("restore_route") == "github_artifact"
        and isinstance(record.get("candidate_misses"), list)
        and all(isinstance(reason, str) for reason in record["candidate_misses"])
    ):
        return False

    # Validate the legacy mirror too: downstream readers may still consume it.
    if not (
        isinstance(record.get("run_url"), str)
        and valid_revision(record.get("revision"))
        and valid_artifact_id(record.get("artifact_id"))
        and valid_digest(record.get("artifact_digest"))
        and valid_revision(record.get("consumer_revision"))
    ):
        return False
    upstream = record.get("upstream")
    return upstream is None or valid_upstream_provenance(upstream)


def original_producer(upstream, immediate):
    """Preserve the oldest fully identified producer across schema-2 reuse hops."""
    if isinstance(upstream, dict) and upstream.get("schema") == 2:
        return upstream["original_producer"]
    return immediate


def upstream_compile_seconds(upstream):
    """Carry the original measured compile duration through multi-hop reuse."""
    if not isinstance(upstream, dict) or upstream.get("schema") != 2:
        return None
    return upstream["metrics"]["compile_seconds_avoided"]


def restore(api, value, derived, current_run, current_identity, current_attempt="1", report=None):
    """Restore in staging; a miss never leaves partial products in DerivedData."""
    reuse_started = time.monotonic()
    reasons = []
    consumer = load_consumer(
        api,
        value,
        current_run,
        current_attempt,
        current_identity["revision"],
        reasons,
    )
    if consumer is None:
        if report is not None:
            report.update(reason="miss", miss_reasons=",".join(reasons))
        return False

    for artifact, run in select(api, value, current_run, current_attempt, consumer, reasons):
        lookup_seconds = time.monotonic() - reuse_started
        with tempfile.TemporaryDirectory(prefix="cmux-reuse-") as tmp:
            staging = Path(tmp)
            archive = staging / "artifact.zip"
            transfer_started = time.monotonic()
            try:
                api.download(artifact["id"], archive, artifact["size_in_bytes"])
            # urllib surfaces a truncated or malformed response as
            # HTTPException, not OSError; any transport failure is a miss.
            except (OSError, ValueError, EOFError, http.client.HTTPException,
                    parallel.TransportError):
                record_reason(reasons, "artifact_download_error")
                continue
            transfer_seconds = time.monotonic() - transfer_started
            restore_started = time.monotonic()
            try:
                unpack(archive, staging, artifact["digest"])
            except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile):
                record_reason(reasons, "archive_invalid")
                continue

            root = staging / "Build/Products"
            try:
                receipt = json.loads((root / RECEIPT).read_text())
                if (receipt["contract"] != value
                        or receipt["run_id"] != str(run["id"])
                        or receipt["run_attempt"] != str(run["run_attempt"])):
                    raise ValueError("artifact producer contract mismatch")
                # Bind the candidate-authored receipt back to a GitHub-attested
                # producer revision, re-fingerprinting whatever it names.
                revision = receipt["revision"]
                if (not isinstance(revision, str)
                        or not re.fullmatch(r"[0-9a-f]{6,40}", revision)
                        or not attested_producer_revision(
                            api, run, revision, value["product_inputs"])):
                    raise ValueError("producer revision mismatch")
                original = json.loads((root / products.RECEIPT).read_text())
                if original["revision"] != receipt["revision"]:
                    raise ValueError("producer revision mismatch")
                provenance_path = root / "cmux-original-producer.json"
                upstream = json.loads(provenance_path.read_text()) if provenance_path.exists() else None
                if upstream is not None and not valid_upstream_provenance(upstream):
                    raise ValueError("invalid upstream provenance")
                products.restore(staging, {**current_identity, "revision": original["revision"]})
                # Relocate once more from staging into the actual consumer location.
                products.stamp(staging, current_identity)
            except (TypeError, AttributeError, ValueError, KeyError, OSError,
                    subprocess.SubprocessError):
                record_reason(reasons, "product_provenance_invalid")
                continue

            # After relocation starts, any failure must abort to main's cleanup.
            destination = derived / "Build/Products"
            if destination.exists():
                raise ValueError("reuse destination must be empty")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(root), destination)
            products.restore(derived, current_identity)

            restore_seconds = time.monotonic() - restore_started
            total_reuse_seconds = time.monotonic() - reuse_started
            compile_seconds = upstream_compile_seconds(upstream)
            if compile_seconds is None:
                compile_seconds = run.get("_compile_seconds")
            saved_minutes = None
            if isinstance(compile_seconds, (int, float)):
                saved_minutes = max(0.0, compile_seconds - total_reuse_seconds) / 60.0
            metrics = {
                "compile_seconds_avoided": round(compile_seconds, 3) if isinstance(compile_seconds, (int, float)) else None,
                "lookup_seconds": round(lookup_seconds, 3),
                "transfer_seconds": round(transfer_seconds, 3),
                "restore_seconds": round(restore_seconds, 3),
                "total_reuse_seconds": round(total_reuse_seconds, 3),
                "macos_runner_minutes_saved": round(saved_minutes, 3) if saved_minutes is not None else None,
            }
            immediate = producer_record(run, receipt, artifact)
            provenance = destination / "cmux-original-producer.json"
            provenance.write_text(json.dumps({
                "schema": 2,
                "original_producer": original_producer(upstream, immediate),
                "immediate_producer": immediate,
                "consumer": {
                    "run_id": str(current_run),
                    "run_attempt": str(current_attempt),
                    "revision": current_identity["revision"],
                },
                "restore_route": "github_artifact",
                "metrics": metrics,
                "candidate_misses": reasons,
                # Legacy fields retained for downstream readers of the v1 receipt.
                "run_url": run.get("html_url", ""),
                "revision": receipt["revision"],
                "artifact_id": artifact["id"],
                "artifact_digest": artifact["digest"],
                "consumer_revision": current_identity["revision"],
                "upstream": upstream,
            }, indent=2))
            if report is not None:
                report.update(
                    reason="hit",
                    miss_reasons=",".join(reasons),
                    producer_run_id=str(run["id"]),
                    producer_run_attempt=str(run["run_attempt"]),
                    artifact_id=str(artifact["id"]),
                    **metrics,
                )
            print("Reused exact compiled products; tests still run in this workflow.")
            return True

    if report is not None:
        report.update(reason="miss", miss_reasons=",".join(reasons))
    return False


def main():
    mode, derived_raw = sys.argv[1:]
    derived = Path(derived_raw)
    try:
        value = contract()
    except (OSError, subprocess.SubprocessError):
        value = None
        print("Build environment cannot be fingerprinted; compiling normally.")
    if mode == "key":
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            fingerprint = key(value) if value is not None else "unavailable-" + os.environ["GITHUB_RUN_ID"]
            out.write(f"key={fingerprint}\n")
    elif mode == "seal":
        if value is None:
            return
        root = derived / "Build/Products"
        (root / RECEIPT).write_text(json.dumps({"contract": value,
            "revision": read("git", "rev-parse", "HEAD"),
            "run_id": os.environ["GITHUB_RUN_ID"], "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"]}))
    elif mode == "restore":
        hit = False
        report = {
            "reason": "miss",
            "miss_reasons": "",
            "producer_run_id": "",
            "producer_run_attempt": "",
            "artifact_id": "",
            "compile_seconds_avoided": None,
            "lookup_seconds": None,
            "transfer_seconds": None,
            "restore_seconds": None,
            "total_reuse_seconds": None,
            "macos_runner_minutes_saved": None,
        }
        try:
            if value is None:
                report["miss_reasons"] = "fingerprint_unavailable"
            elif os.environ.get("GITHUB_EVENT_NAME") in PERMITTED_PRODUCERS:
                hit = restore(
                    GitHub(os.environ["GITHUB_REPOSITORY"]),
                    value,
                    derived,
                    os.environ["GITHUB_RUN_ID"],
                    products.identity(),
                    os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
                    report,
                )
            else:
                report["miss_reasons"] = "consumer_event_disallowed"
        except (TypeError, AttributeError, ValueError, KeyError, OSError,
                subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile):
            print("Compiled-product reuse unavailable; compiling normally.")
            report["reason"] = "fallback"
            report["miss_reasons"] = "reuse_api_or_validation_error"
            shutil.rmtree(derived, ignore_errors=True)
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            out.write(f"hit={'true' if hit else 'false'}\n")
            for name, item in report.items():
                value_out = "" if item is None else str(item)
                out.write(f"{name}={value_out}\n")
    else:
        raise ValueError("expected key, seal or restore")


if __name__ == "__main__":
    main()

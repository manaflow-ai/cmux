#!/usr/bin/env python3
"""Reuse compiled products, never test outcomes, across trusted CI runs.

A conservative first version: the entire git tree and build environment must
match. Missing provenance, old artifacts, API errors and corrupt downloads are
cache misses. The original CMUXCommit embedded in the app is retained.
"""
from __future__ import annotations

import hashlib
import gzip
import json
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

import app_host_test_products as products

RECEIPT = "cmux-product-reuse.json"
PREFIX = "app-host-products-v1-"
# Current product archives are ~0.8 GiB compressed. Bound every expansion layer
# independently, including hardlink copies, with room for the UI product set.
MAX_ARCHIVE_BYTES = 2 * 1024**3
MAX_MEMBER_BYTES = 4 * 1024**3
MAX_EXPANDED_BYTES = 16 * 1024**3
MAX_TAR_BYTES = 20 * 1024**3
MAX_MEMBERS = 200_000

# Producer events permitted for each consumer event. Pull-request consumers are
# further restricted to the same pull request; merge groups may adopt an exact
# product from either an in-repository PR or an earlier merge-group run.
PERMITTED_PRODUCERS = {
    "pull_request": {"pull_request"},
    "merge_group": {"pull_request", "merge_group"},
}


def read(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def contract():
    versions = {}
    for command in ("rustc", "cargo", "go", "zig", "node", "bun"):
        executable = shutil.which(command)
        versions[command] = read(executable, "version" if command in {"go", "zig"} else "--version") if executable else "absent"
    return {
        "tree": read("git", "rev-parse", "HEAD^{tree}"),
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


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def get(self, path):
        return json.loads(read("gh", "api", f"repos/{self.repository}/{path}"))

    def download(self, artifact_id, target):
        with target.open("wb") as out:
            subprocess.run(["gh", "api", f"repos/{self.repository}/actions/artifacts/{artifact_id}/zip"],
                           stdout=out, check=True, timeout=120)


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


def trusted_ci_run(run, repository):
    """Require the repository CI workflow and an in-repository event source."""
    head_repository = run.get("head_repository")
    return (
        run.get("path") == ".github/workflows/ci.yml"
        and run.get("event") in PERMITTED_PRODUCERS
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


def compile_step_seconds(job):
    """Return the producer's actual compile-step duration when it compiled."""
    steps = job.get("steps")
    if not isinstance(steps, list):
        return None
    for step in steps:
        if (step.get("name") == "Compile app-host test product"
                and step.get("status") == "completed"
                and step.get("conclusion") == "success"):
            return elapsed_seconds(step.get("started_at"), step.get("completed_at"))
    return None


def load_consumer(api, value, current_run, current_attempt, reasons):
    """Verify the running consumer and its checkout tree against GitHub."""
    try:
        run = api.get(f"actions/runs/{current_run}")
        if str(run.get("run_attempt")) != str(current_attempt):
            record_reason(reasons, "consumer_attempt_mismatch")
            return None
        if not trusted_ci_run(run, api.repository):
            record_reason(reasons, "consumer_untrusted")
            return None
        head = run.get("head_sha")
        if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{6,40}", head):
            record_reason(reasons, "consumer_revision_invalid")
            return None
        if api.get(f"git/commits/{head}")["tree"]["sha"] != value["tree"]:
            record_reason(reasons, "consumer_tree_mismatch")
            return None
        return run
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        record_reason(reasons, "consumer_provenance_unavailable")
        return None


def select(api, value, current_run, current_attempt, consumer, reasons):
    """Inspect at most 300 recent artifacts and six matching producers."""
    prefix = PREFIX + key(value) + "-"
    candidates = []
    for page in range(1, 4):
        batch = api.get(f"actions/artifacts?per_page=100&page={page}")["artifacts"]
        if not isinstance(batch, list):
            raise ValueError("invalid artifact listing")
        candidates.extend(
            a for a in batch
            if isinstance(a, dict)
            and isinstance(a.get("name"), str)
            and a["name"].startswith(prefix)
        )
        if len(candidates) >= 6 or len(batch) < 100:
            break
    if not candidates:
        record_reason(reasons, "no_matching_contract_artifact")
    for artifact in candidates[:6]:
        try:
            suffix = artifact["name"][len(prefix):]
            if artifact.get("expired"):
                record_reason(reasons, "artifact_expired")
                continue
            if not suffix.isdecimal():
                record_reason(reasons, "artifact_attempt_invalid")
                continue
            producer_attempt = int(suffix)
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
            if str(run.get("run_attempt")) != suffix:
                record_reason(reasons, "producer_attempt_mismatch")
                continue
            if not permitted_pair(run, consumer, api.repository):
                record_reason(reasons, "producer_consumer_pair_disallowed")
                continue
            # GitHub's run head, not a candidate-authored receipt, establishes the
            # source identity before downloading. The whole tree includes the CI
            # workflow and every build/packaging script; different producer code
            # cannot vouch for this checkout.
            head = run.get("head_sha")
            if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{6,40}", head):
                record_reason(reasons, "producer_revision_invalid")
                continue
            if api.get(f"git/commits/{head}")["tree"]["sha"] != value["tree"]:
                record_reason(reasons, "producer_tree_mismatch")
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
            compile_job = next((job for job in jobs
                                if job.get("name") == "macOS compile admission"
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
            run["_compile_seconds"] = compile_step_seconds(compile_job)
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


def original_producer(upstream, immediate):
    """Preserve the oldest known producer across republished reuse hops."""
    if not isinstance(upstream, dict):
        return immediate
    recorded = upstream.get("original_producer")
    if isinstance(recorded, dict):
        return recorded
    node = upstream
    oldest = None
    while isinstance(node, dict):
        if node.get("revision"):
            oldest = {
                "run_id": str(node.get("run_id", "")),
                "run_attempt": str(node.get("run_attempt", "")),
                "run_url": node.get("run_url", ""),
                "revision": node.get("revision", ""),
                "artifact_id": node.get("artifact_id"),
                "artifact_digest": node.get("artifact_digest", ""),
            }
        node = node.get("upstream")
    return oldest or immediate


def upstream_compile_seconds(upstream):
    """Carry the original measured compile duration through multi-hop reuse."""
    if not isinstance(upstream, dict):
        return None
    metrics = upstream.get("metrics")
    if not isinstance(metrics, dict):
        return None
    value = metrics.get("compile_seconds_avoided")
    return float(value) if isinstance(value, (int, float)) else None


def restore(api, value, derived, current_run, current_identity, current_attempt="1", report=None):
    """Restore in staging; a miss never leaves partial products in DerivedData."""
    reuse_started = time.monotonic()
    reasons = []
    consumer = load_consumer(api, value, current_run, current_attempt, reasons)
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
                api.download(artifact["id"], archive)
            except (OSError, subprocess.SubprocessError):
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
                # Verify the actual checkout commit against GitHub, independent of
                # the artifact name and the earlier pre-download selection check.
                for revision in (receipt["revision"], run["head_sha"]):
                    if (not isinstance(revision, str)
                            or not re.fullmatch(r"[0-9a-f]{6,40}", revision)):
                        raise ValueError("invalid producer revision")
                    if api.get(f"git/commits/{revision}")["tree"]["sha"] != value["tree"]:
                        raise ValueError("producer source tree mismatch")
                original = json.loads((root / products.RECEIPT).read_text())
                if original["revision"] != receipt["revision"]:
                    raise ValueError("producer revision mismatch")
                provenance_path = root / "cmux-original-producer.json"
                upstream = json.loads(provenance_path.read_text()) if provenance_path.exists() else None
                if upstream is not None and not isinstance(upstream, dict):
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

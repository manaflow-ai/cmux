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
import zipfile
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


def select(api, value, current_run):
    """Inspect at most 300 recent artifacts and six matching producers."""
    prefix = PREFIX + key(value) + "-"
    candidates = []
    for page in range(1, 4):
        batch = api.get(f"actions/artifacts?per_page=100&page={page}")["artifacts"]
        candidates.extend(a for a in batch if a.get("name", "").startswith(prefix))
        if len(candidates) >= 6 or len(batch) < 100:
            break
    for artifact in candidates[:6]:
        try:
            suffix = artifact["name"][len(prefix):]
            if artifact.get("expired") or not suffix.isdecimal():
                continue
            if artifact.get("size_in_bytes", MAX_ARCHIVE_BYTES + 1) > MAX_ARCHIVE_BYTES:
                continue
            run_id = artifact.get("workflow_run", {}).get("id")
            if not run_id or str(run_id) == str(current_run):
                continue
            run = api.get(f"actions/runs/{run_id}")
            if not isinstance(run, dict):
                raise ValueError("invalid workflow run response")
            if (run.get("path") != ".github/workflows/ci.yml"
                    or run.get("event") not in {"pull_request", "merge_group"}
                    or run.get("head_repository", {}).get("full_name") != api.repository
                    or suffix != str(run["run_attempt"])):
                continue
            # GitHub's run head, not a candidate-authored receipt, establishes the
            # source identity before downloading. The whole tree includes the CI
            # workflow and every build/packaging script; different producer code
            # cannot vouch for this checkout. This inherits CI's existing trust in
            # the candidate workflow, not an independent base-controlled attestation.
            head = run.get("head_sha", "")
            if not re.fullmatch(r"[0-9a-f]{6,40}", head):
                continue
            commit = api.get(f"git/commits/{head}")
            if not isinstance(commit, dict) or not isinstance(commit.get("tree"), dict):
                raise ValueError("invalid commit response")
            if commit["tree"].get("sha") != value["tree"]:
                continue
            attempt = run["run_attempt"]
            jobs = []
            for page in range(1, 4):
                response = api.get(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
                if not isinstance(response, dict) or not isinstance(response.get("jobs"), list):
                    raise ValueError("invalid workflow jobs response")
                batch = response["jobs"]
                jobs.extend(batch)
                if len(batch) < 100:
                    break
            # The compile job must finish; unrelated tests in the producer run may
            # still be running. No test result is being reused here.
            if not any(j.get("name") == "macOS compile admission" and j.get("status") == "completed"
                       and j.get("conclusion") == "success" for j in jobs):
                continue
            if not artifact.get("digest", "").startswith("sha256:"):
                continue
            yield artifact, run
        except Exception as error:
            # An artifact can disappear, or its run/jobs response can be stale or
            # malformed, between pagination and lookup. Treat that candidate as a
            # cache miss while preserving the global artifact-list fallback path.
            print(f"Skipping unusable candidate {artifact.get('id', '?')} ({type(error).__name__}).")
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



def restore(api, value, derived, current_run, current_identity):
    """Restore in staging; a miss never leaves partial products in DerivedData."""
    for artifact, run in select(api, value, current_run):
        with tempfile.TemporaryDirectory(prefix="cmux-reuse-") as tmp:
            staging = Path(tmp)
            archive = staging / "artifact.zip"
            try:
                api.download(artifact["id"], archive)
                unpack(archive, staging, artifact["digest"])
                root = staging / "Build/Products"
                receipt = json.loads((root / RECEIPT).read_text())
                if receipt["contract"] != value or receipt["run_id"] != str(run["id"]) or receipt["run_attempt"] != str(run["run_attempt"]):
                    raise ValueError("artifact producer contract mismatch")
                # Verify the actual checkout commit against GitHub, independent of
                # the artifact name. Internal PR head trees must also match; when a
                # PR merge includes additional base changes, conservatively rebuild.
                for revision in (receipt["revision"], run["head_sha"]):
                    if not re.fullmatch(r"[0-9a-f]{6,40}", revision):
                        raise ValueError("invalid producer revision")
                    if api.get(f"git/commits/{revision}")["tree"]["sha"] != value["tree"]:
                        raise ValueError("producer source tree mismatch")
                original = json.loads((root / products.RECEIPT).read_text())
                if original["revision"] != receipt["revision"]:
                    raise ValueError("producer revision mismatch")
                products.restore(staging, {**current_identity, "revision": original["revision"]})
                # Relocate once more from staging into the actual consumer location.
                products.stamp(staging, current_identity)
            except (ValueError, KeyError, OSError, subprocess.SubprocessError,
                    tarfile.TarError, zipfile.BadZipFile) as error:
                print(f"Skipping build artifact {artifact['id']} ({type(error).__name__}).")
                continue
            # After relocation starts, any failure must abort to main's cleanup.
            destination = derived / "Build/Products"
            if destination.exists():
                raise ValueError("reuse destination must be empty")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(root), destination)
            products.restore(derived, current_identity)
            provenance = destination / "cmux-original-producer.json"
            upstream = json.loads(provenance.read_text()) if provenance.exists() else None
            provenance.write_text(json.dumps({
                "run_url": run["html_url"], "revision": receipt["revision"],
                "artifact_id": artifact["id"], "consumer_revision": current_identity["revision"],
                "upstream": upstream,
            }, indent=2))
            print(f"Reused compiled products from {run['html_url']} (producer {receipt['revision']}); tests still run here.")
            return True
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
        try:
            if value is not None and os.environ.get("GITHUB_EVENT_NAME") == "merge_group":
                hit = restore(GitHub(os.environ["GITHUB_REPOSITORY"]), value, derived,
                              os.environ["GITHUB_RUN_ID"], products.identity())
        except (ValueError, KeyError, OSError, subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile) as error:
            print(f"Build product reuse unavailable ({type(error).__name__}); compiling normally.")
            shutil.rmtree(derived, ignore_errors=True)
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            out.write(f"hit={'true' if hit else 'false'}\n")
    else:
        raise ValueError("expected key, seal or restore")


if __name__ == "__main__":
    main()

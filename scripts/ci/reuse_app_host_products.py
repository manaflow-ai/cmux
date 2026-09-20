#!/usr/bin/env python3
"""Reuse compiled products, never test outcomes, across trusted CI runs.

A conservative first version: the entire git tree and build environment must
match. Missing provenance, old artifacts, API errors and corrupt downloads are
cache misses. The original CMUXCommit embedded in the app is retained.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import zipfile
from pathlib import Path

import app_host_test_products as products

RECEIPT = "cmux-product-reuse.json"
BUILD_LOG = "cmux-build.log"
MAX_BUILD_LOG_BYTES = 256 * 1024**2
PREFIX = "app-host-products-v1-"
ARCHIVE = "app-host-products.aar"
ARCHIVER = Path(__file__).resolve().parent / "app-host-products-archive.sh"
# Current product archives are well under 1 GiB compressed. Bound the download,
# the entry listing and the extracted size independently, with room for the UI
# product set.
MAX_ARCHIVE_BYTES = 2 * 1024**3
MAX_MEMBER_BYTES = 4 * 1024**3
MAX_EXPANDED_BYTES = 16 * 1024**3
MAX_METADATA_BYTES = 1024**2
MAX_LISTING_BYTES = 256 * 1024**2
MAX_MEMBERS = 200_000
ARCHIVE_TOOL_TIMEOUT = 600


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
        suffix = artifact["name"][len(prefix):]
        if artifact.get("expired") or not suffix.isdecimal():
            continue
        if artifact.get("size_in_bytes", MAX_ARCHIVE_BYTES + 1) > MAX_ARCHIVE_BYTES:
            continue
        run_id = artifact.get("workflow_run", {}).get("id")
        if not run_id or str(run_id) == str(current_run):
            continue
        run = api.get(f"actions/runs/{run_id}")
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
        if api.get(f"git/commits/{head}")["tree"]["sha"] != value["tree"]:
            continue
        attempt = run["run_attempt"]
        jobs = []
        for page in range(1, 4):
            batch = api.get(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")["jobs"]
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


def list_archive(archive):
    """Read the entry listing without extracting; bound its size and duration."""
    with subprocess.Popen([str(ARCHIVER), "list", str(archive)], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, start_new_session=True) as process:
        def stop():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        timer = threading.Timer(ARCHIVE_TOOL_TIMEOUT, stop)
        timer.start()
        try:
            listing = io.BytesIO()
            bounded_copy(process.stdout, listing, MAX_LISTING_BYTES)
            status = process.wait()
        finally:
            timer.cancel()
            stop()
    if status != 0:
        raise ValueError("unreadable product archive")
    return json.loads(listing.getvalue())


def validate_entries(entries):
    """Accept only scoped directories, files and safe links.

    A link target that is relative and has no `..` component resolves below the
    link's own directory, so it stays inside Build/Products whatever else the
    archive contains. The packer drops dangling unportable links, so every
    archived link must obey the same scoped policy.
    """
    if not isinstance(entries, list):
        raise ValueError("unexpected archive listing")
    if len(entries) > MAX_MEMBERS:
        raise ValueError("archive member count limit exceeded")
    expanded = 0
    paths, links = set(), set()
    for entry in entries:
        kind, path = entry["TYP"], entry["PAT"]
        if kind not in {"D", "F", "L"}:
            raise ValueError("unsupported product entry")
        parts = path.split("/") if isinstance(path, str) else []
        if parts[:2] != ["Build", "Products"] or any(part in {"", ".", ".."} for part in parts):
            raise ValueError("unscoped product path")
        if path in paths:
            raise ValueError("duplicate product path")
        paths.add(path)
        if entry.get("MOD", 0) & ~0o777:
            raise ValueError("unsupported product mode")
        if kind == "L":
            target = entry["LNK"]
            if not isinstance(target, str) or any(part in {"", ".."} for part in target.split("/")):
                raise ValueError("unscoped product link")
            links.add(path)
        elif "LNK" in entry:
            raise ValueError("unexpected link target")
        size = entry.get("DAT", 0)
        if kind != "F" and size:
            raise ValueError("unexpected entry contents")
        metadata = entry.get("XAT", 0) + entry.get("ACL", 0)
        if metadata > MAX_METADATA_BYTES:
            raise ValueError("archive metadata size limit exceeded")
        if size > MAX_MEMBER_BYTES or expanded + size + metadata > MAX_EXPANDED_BYTES:
            raise ValueError("archive member size limit exceeded")
        expanded += size + metadata
    for path in paths:
        parts = path.split("/")
        if any("/".join(parts[:depth]) in links for depth in range(1, len(parts))):
            raise ValueError("product entry below a link")


def unpack(archive, staging, digest):
    if archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("archive size limit exceeded")
    h = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    if "sha256:" + h.hexdigest() != digest:
        raise ValueError("artifact digest mismatch")
    compressed = staging / ARCHIVE
    with zipfile.ZipFile(archive) as z:
        # An artifact in any other format, such as the earlier tar.gz, is a miss.
        if z.namelist() != [ARCHIVE]:
            raise ValueError("unexpected artifact contents")
        info = z.infolist()[0]
        if info.file_size > MAX_ARCHIVE_BYTES:
            raise ValueError("zip expansion limit exceeded")
        with z.open(info) as source, compressed.open("wb") as output:
            bounded_copy(source, output, MAX_ARCHIVE_BYTES)
    # Extraction follows the archive's own entry headers, so every limit is
    # checked against the listing before anything is written.
    validate_entries(list_archive(compressed))
    process = subprocess.Popen([str(ARCHIVER), "unpack", str(compressed), str(staging)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    try:
        status = process.wait(timeout=ARCHIVE_TOOL_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    if status:
        raise subprocess.CalledProcessError(status, process.args)


def build_log_bytes(path):
    """A cache hit must retain the actual warning evidence, never an empty stand-in."""
    if path.is_symlink() or not path.is_file():
        raise ValueError("build log must be a regular file")
    if not 0 < path.stat().st_size <= MAX_BUILD_LOG_BYTES:
        raise ValueError("build log is empty or exceeds the size limit")
    with path.open("rb") as source:
        data = source.read(MAX_BUILD_LOG_BYTES + 1)
    if not 0 < len(data) <= MAX_BUILD_LOG_BYTES:
        raise ValueError("build log is empty or exceeds the size limit")
    return data


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
                # Keep warning validation active on reuse hits. Old artifacts
                # without the producer log/digest are misses, not warning-free builds.
                build_log = build_log_bytes(root / BUILD_LOG)
                if hashlib.sha256(build_log).hexdigest() != receipt["build_log_sha256"]:
                    raise ValueError("producer build log digest mismatch")
                original = json.loads((root / products.RECEIPT).read_text())
                if original["revision"] != receipt["revision"]:
                    raise ValueError("producer revision mismatch")
                products.restore(staging, {**current_identity, "revision": original["revision"]})
                # Relocate once more from staging into the actual consumer location.
                products.stamp(staging, current_identity)
            except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError,
                    zipfile.BadZipFile) as error:
                print(f"Skipping build artifact {artifact['id']} ({type(error).__name__}).")
                continue
            # After relocation starts, any failure must abort to main's cleanup.
            destination = derived / "Build/Products"
            if destination.exists():
                raise ValueError("reuse destination must be empty")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(root), destination)
            products.restore(derived, current_identity)
            log_destination = derived / BUILD_LOG
            if log_destination.is_symlink():
                raise ValueError("build log destination must not be a symbolic link")
            log_destination.write_bytes(build_log)
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
        build_log = build_log_bytes(derived / BUILD_LOG)
        if (root / BUILD_LOG).is_symlink():
            raise ValueError("archived build log must not be a symbolic link")
        (root / BUILD_LOG).write_bytes(build_log)
        (root / RECEIPT).write_text(json.dumps({"contract": value,
            "revision": read("git", "rev-parse", "HEAD"),
            "build_log_sha256": hashlib.sha256(build_log).hexdigest(),
            "run_id": os.environ["GITHUB_RUN_ID"], "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"]}))
    elif mode == "restore":
        hit = False
        try:
            if value is not None and os.environ.get("GITHUB_EVENT_NAME") == "merge_group":
                hit = restore(GitHub(os.environ["GITHUB_REPOSITORY"]), value, derived,
                              os.environ["GITHUB_RUN_ID"], products.identity())
        except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
            print(f"Build product reuse unavailable ({type(error).__name__}); compiling normally.")
            shutil.rmtree(derived, ignore_errors=True)
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            out.write(f"hit={'true' if hit else 'false'}\n")
    else:
        raise ValueError("expected key, seal or restore")


if __name__ == "__main__":
    main()

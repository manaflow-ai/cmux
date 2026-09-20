#!/usr/bin/env python3
"""Reuse compiled products, never test outcomes, across trusted CI runs.

A conservative first version: the entire git tree and build environment must
match. Missing provenance, old artifacts, API errors and corrupt downloads are
cache misses. The original CMUXCommit embedded in the app is retained.
"""
from __future__ import annotations

import hashlib
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


def select(api, fingerprint, current_run):
    """Bound lookup to six same-key artifacts; validate their issuing job/run."""
    name = PREFIX + fingerprint
    candidates = api.get(f"actions/artifacts?name={name}&per_page=6")["artifacts"]
    for artifact in candidates[:6]:
        if artifact.get("expired") or artifact.get("name") != name:
            continue
        run_id = artifact.get("workflow_run", {}).get("id")
        if not run_id or str(run_id) == str(current_run):
            continue
        run = api.get(f"actions/runs/{run_id}")
        if (run.get("path") != ".github/workflows/ci.yml"
                or run.get("event") not in {"pull_request", "merge_group"}
                or run.get("head_repository", {}).get("full_name") != api.repository):
            continue
        # No arbitrary workflow artifact or failed/incomplete compile can vouch
        # for a build. Later test failures do not invalidate successful compilation.
        attempt = run["run_attempt"]
        jobs = []
        for page in range(1, 4):
            batch = api.get(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")["jobs"]
            jobs.extend(batch)
            if len(batch) < 100:
                break
        if not any(j.get("name") == "macOS compile admission" and j.get("conclusion") == "success" for j in jobs):
            continue
        if not artifact.get("digest", "").startswith("sha256:"):
            continue
        yield artifact, run


def unpack(archive, staging, digest):
    with archive.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else None
    if actual is None:
        h = hashlib.sha256()
        with archive.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                h.update(chunk)
        actual = h.hexdigest()
    if "sha256:" + actual != digest:
        raise ValueError("artifact digest mismatch")
    with zipfile.ZipFile(archive) as z:
        if z.namelist() != ["app-host-products.tar.gz"]:
            raise ValueError("unexpected artifact contents")
        z.extract("app-host-products.tar.gz", staging)
    with tarfile.open(staging / "app-host-products.tar.gz") as tar:
        # Producer uses tar -h, so only regular files, directories and internal
        # hardlinks are expected. Extract explicitly for older runner Pythons.
        members = tar.getmembers()
        for member in members:
            parts = Path(member.name).parts
            if parts[:2] != ("Build", "Products") or ".." in parts:
                raise tarfile.ExtractError("unscoped product path")
            if not (member.isdir() or member.isfile() or member.islnk()):
                raise tarfile.ExtractError("unsupported product entry")
            if member.islnk():
                target_parts = Path(member.linkname).parts
                if target_parts[:2] != ("Build", "Products") or ".." in target_parts:
                    raise tarfile.ExtractError("unscoped product hardlink")
        for member in members:
            target = staging / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)
        for member in members:
            if member.islnk():
                target = staging / member.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(staging / member.linkname, target)



def restore(api, value, derived, current_run, current_identity):
    """Restore in staging; a miss never leaves partial products in DerivedData."""
    for artifact, run in select(api, key(value), current_run):
        with tempfile.TemporaryDirectory(prefix="cmux-reuse-") as tmp:
            staging = Path(tmp)
            archive = staging / "artifact.zip"
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

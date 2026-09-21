#!/usr/bin/env python3
"""Reuse the exact assembled unsigned Release app across trusted CI runs.

Only compiled bytes move between runs. Every consumer reruns the Release artifact
validator. Exact source/build/helper/dependency identity is required; any miss or
invalid candidate falls back to the ordinary Release compile.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import os
import platform
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
from pathlib import Path, PurePosixPath

import reuse_app_host_products as app_host_reuse

PREFIX = "release-products-v1-"
RECEIPT = "cmux-release-product-reuse.json"
PROVENANCE = "cmux-release-original-producer.json"
ARCHIVE_NAME = "cmux-release-product.tar.gz"
APP_REL = PurePosixPath("Build/Products/Release/cmux.app")
RECEIPT_REL = PurePosixPath("Build/Products") / RECEIPT
MAX_ARCHIVE_BYTES = 2 * 1024**3
MAX_MEMBER_BYTES = 4 * 1024**3
MAX_EXPANDED_BYTES = 12 * 1024**3
MAX_TAR_BYTES = 16 * 1024**3
MAX_MEMBERS = 150_000

# Keep this list in one place so a build-flag change is an identity change.
BUILD_FLAGS = {
    "project": "cmux.xcodeproj",
    "scheme": "cmux",
    "configuration": "Release",
    "destination": "generic/platform=macOS",
    "ONLY_ACTIVE_ARCH": "NO",
    "COMPILATION_CACHE_ENABLE_CACHING": "YES",
    "COMPILATION_CACHE_LIMIT_SIZE": "3221225472",
    "COMPILER_INDEX_STORE_ENABLE": "NO",
    "CODE_SIGNING_ALLOWED": "NO",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon-Nightly",
    "CMUX_SKIP_ZIG_BUILD": "1",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def required_env(name: str, pattern: str | None = None) -> str:
    value = os.environ.get(name, "").strip()
    if not value or (pattern and not re.fullmatch(pattern, value)):
        raise ValueError(f"missing or invalid {name}")
    return value


def contract() -> dict:
    value = app_host_reuse.contract()
    archs = required_env("CMUX_RELEASE_ARCHS")
    if archs not in {"arm64", "arm64 x86_64"}:
        raise ValueError("invalid Release architectures")
    package_resolved = Path("cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    if not package_resolved.is_file():
        raise ValueError("Package.resolved is missing")
    value.update({
        "product": "unsigned-release-app-v1",
        "configuration": "Release",
        "release_architectures": archs,
        "package_resolved_sha256": sha256_file(package_resolved),
        "build_flags": BUILD_FLAGS,
        "ghostty_revision": app_host_reuse.read("git", "-C", "ghostty", "rev-parse", "HEAD"),
        "ghostty_helper": {
            "sha256": required_env("CMUX_RELEASE_GHOSTTY_HELPER_SHA256", r"[0-9a-f]{64}"),
            "toolchain_sha256": required_env("CMUX_RELEASE_GHOSTTY_HELPER_TOOLCHAIN_SHA256", r"[0-9a-f]{64}"),
            "sdk": required_env("CMUX_RELEASE_GHOSTTY_HELPER_SDK"),
        },
        "cmux_tui": {
            "commit": required_env("CMUX_RELEASE_TUI_COMMIT", r"[0-9a-f]{40}"),
            "manifest_sha256": required_env("CMUX_RELEASE_TUI_MANIFEST_SHA256", r"[0-9a-f]{64}"),
        },
        "producer_architecture": platform.machine(),
    })
    return value


def product_digest(app: Path) -> str:
    if not app.is_dir():
        raise ValueError("Release app is missing")
    digest = hashlib.sha256()
    root = app.parent
    entries = [app, *app.rglob("*")]
    for path in sorted(entries, key=lambda item: item.relative_to(root).as_posix()):
        rel = path.relative_to(root).as_posix().encode()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if path.is_symlink():
            kind = b"L"
            payload = os.readlink(path).encode()
        elif path.is_dir():
            kind = b"D"
            payload = b""
        elif path.is_file():
            kind = b"F"
            file_hash = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    file_hash.update(chunk)
            payload = file_hash.digest()
        else:
            raise ValueError(f"unsupported Release product entry: {path}")
        digest.update(kind + b"\0" + rel + b"\0" + f"{mode:o}".encode() + b"\0" + payload + b"\n")
    return digest.hexdigest()


def seal(derived: Path, value: dict) -> dict:
    app = derived / Path(APP_REL)
    root = derived / "Build/Products"
    root.mkdir(parents=True, exist_ok=True)
    receipt = {
        "schema_version": 1,
        "contract": value,
        "revision": app_host_reuse.read("git", "rev-parse", "HEAD"),
        "run_id": os.environ["GITHUB_RUN_ID"],
        "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "product_sha256": product_digest(app),
    }
    (root / RECEIPT).write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    return receipt


def pack(derived: Path, archive: Path) -> None:
    app = derived / Path(APP_REL)
    receipt = derived / Path(RECEIPT_REL)
    if not app.is_dir() or not receipt.is_file():
        raise ValueError("sealed Release product is missing")
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "w:gz", dereference=False) as tar:
        tar.add(app, arcname=APP_REL.as_posix(), recursive=True)
        tar.add(receipt, arcname=RECEIPT_REL.as_posix(), recursive=False)


def allowed_member(name: str) -> bool:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        return False
    normalized = path.as_posix().rstrip("/")
    app = APP_REL.as_posix()
    return normalized == RECEIPT_REL.as_posix() or normalized == app or normalized.startswith(app + "/")


def allowed_symlink(member_name: str, link_name: str) -> bool:
    if PurePosixPath(link_name).is_absolute():
        return False
    target = posixpath.normpath(posixpath.join(posixpath.dirname(member_name), link_name))
    app = APP_REL.as_posix()
    return target == app or target.startswith(app + "/")


def bounded_copy(source, output, limit: int) -> int:
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
    def __init__(self, source, limit: int):
        self.source = source
        self.remaining = limit

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
        if info.size > MAX_MEMBER_BYTES or (
            info.type in {tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK}
            and info.size > 1024 * 1024
        ):
            raise ValueError("tar header size limit exceeded")
        return info


def unpack(artifact_zip: Path, staging: Path, digest: str) -> None:
    if artifact_zip.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("artifact archive is too large")
    if "sha256:" + sha256_file(artifact_zip) != digest:
        raise ValueError("artifact digest mismatch")
    compressed = staging / ARCHIVE_NAME
    with zipfile.ZipFile(artifact_zip) as outer:
        if outer.namelist() != [ARCHIVE_NAME]:
            raise ValueError("unexpected artifact contents")
        info = outer.infolist()[0]
        if info.file_size > MAX_ARCHIVE_BYTES:
            raise ValueError("artifact expansion is too large")
        with outer.open(info) as source, compressed.open("wb") as output:
            bounded_copy(source, output, MAX_ARCHIVE_BYTES)

    expanded = 0
    hardlinks: list[tarfile.TarInfo] = []
    with gzip.open(compressed, "rb") as gz:
        try:
            with tarfile.open(fileobj=BoundedReader(gz, MAX_TAR_BYTES), mode="r|", tarinfo=BoundedTarInfo) as tar:
                for count, member in enumerate(tar, 1):
                    if count > MAX_MEMBERS:
                        raise ValueError("archive member count limit exceeded")
                    if not allowed_member(member.name):
                        raise tarfile.ExtractError("unscoped Release product path")
                    if member.size > MAX_MEMBER_BYTES or expanded + member.size > MAX_EXPANDED_BYTES:
                        raise ValueError("archive member size limit exceeded")
                    target = staging / member.name
                    if member.isdir():
                        target.mkdir(parents=True, exist_ok=True)
                        target.chmod(member.mode & 0o777)
                    elif member.isfile():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        with tar.extractfile(member) as source, target.open("wb") as output:
                            copied = bounded_copy(source, output, min(MAX_MEMBER_BYTES, MAX_EXPANDED_BYTES - expanded))
                        if copied != member.size:
                            raise ValueError("truncated archive member")
                        expanded += copied
                        target.chmod(member.mode & 0o777)
                    elif member.issym():
                        if not allowed_symlink(member.name, member.linkname):
                            raise tarfile.ExtractError("unscoped Release product symlink")
                        target.parent.mkdir(parents=True, exist_ok=True)
                        if target.exists() or target.is_symlink():
                            raise tarfile.ExtractError("duplicate Release product symlink")
                        target.symlink_to(member.linkname)
                    elif member.islnk():
                        if not allowed_member(member.linkname):
                            raise tarfile.ExtractError("unscoped Release product hardlink")
                        hardlinks.append(member)
                    else:
                        raise tarfile.ExtractError("unsupported Release product entry")
        except (gzip.BadGzipFile, EOFError) as error:
            raise tarfile.ReadError("invalid compressed Release product archive") from error

    for member in hardlinks:
        source = staging / member.linkname
        target = staging / member.name
        if not source.is_file():
            raise tarfile.ExtractError("missing Release product hardlink source")
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            raise tarfile.ExtractError("duplicate Release product hardlink")
        os.link(source, target)


def candidate_artifacts(api, value: dict) -> list[dict]:
    prefix = PREFIX + app_host_reuse.key(value) + "-"
    found: list[dict] = []
    for page in range(1, 4):
        batch = api.get(f"actions/artifacts?per_page=100&page={page}")["artifacts"]
        found.extend(artifact for artifact in batch if artifact.get("name", "").startswith(prefix))
        if len(found) >= 8 or len(batch) < 100:
            break
    return found[:8]


def producer_for(api, artifact: dict, value: dict, current_run: str, current_attempt: int) -> tuple[dict, int]:
    prefix = PREFIX + app_host_reuse.key(value) + "-"
    name = artifact.get("name", "")
    suffix = name[len(prefix):]
    if artifact.get("expired") or not suffix.isdecimal():
        raise ValueError("expired or malformed artifact")
    attempt = int(suffix)
    if artifact.get("size_in_bytes", MAX_ARCHIVE_BYTES + 1) > MAX_ARCHIVE_BYTES:
        raise ValueError("oversize artifact")
    run_id = artifact.get("workflow_run", {}).get("id")
    if not run_id:
        raise ValueError("artifact has no producer run")
    if str(run_id) == str(current_run) and attempt >= current_attempt:
        raise ValueError("artifact is from the current or a future attempt")
    run = api.get(f"actions/runs/{run_id}")
    if (
        run.get("path") != ".github/workflows/ci.yml"
        or run.get("event") not in {"pull_request", "merge_group"}
        or run.get("head_repository", {}).get("full_name") != api.repository
        or int(run.get("run_attempt", 0)) < attempt
    ):
        raise ValueError("untrusted producer run")
    head = run.get("head_sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("invalid producer revision")
    if api.get(f"git/commits/{head}")["tree"]["sha"] != value["tree"]:
        raise ValueError("producer source tree mismatch")
    jobs: list[dict] = []
    for page in range(1, 4):
        batch = api.get(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")["jobs"]
        jobs.extend(batch)
        if len(batch) < 100:
            break
    if not any(
        job.get("name") == "release-build"
        and job.get("status") == "completed"
        and job.get("conclusion") == "success"
        for job in jobs
    ):
        raise ValueError("producer Release job did not succeed")
    if not artifact.get("digest", "").startswith("sha256:"):
        raise ValueError("artifact digest is missing")
    return run, attempt


def restore(api, value: dict, derived: Path, current_run: str, current_attempt: int) -> dict:
    started = time.monotonic()
    artifacts = candidate_artifacts(api, value)
    if not artifacts:
        return {"hit": False, "outcome": "restore_miss", "reason": "no_exact_artifact", "restore_seconds": time.monotonic() - started}
    last_reason = "candidate_rejected"
    for artifact in artifacts:
        try:
            run, attempt = producer_for(api, artifact, value, current_run, current_attempt)
            with tempfile.TemporaryDirectory(prefix="cmux-release-reuse-") as tmp:
                staging = Path(tmp)
                archive = staging / "artifact.zip"
                api.download(artifact["id"], archive)
                unpack(archive, staging, artifact["digest"])
                receipt = json.loads((staging / Path(RECEIPT_REL)).read_text())
                if (
                    receipt.get("schema_version") != 1
                    or receipt.get("contract") != value
                    or receipt.get("run_id") != str(run["id"])
                    or receipt.get("run_attempt") != str(attempt)
                ):
                    raise ValueError("artifact producer receipt mismatch")
                revision = receipt.get("revision", "")
                if not re.fullmatch(r"[0-9a-f]{40}", revision):
                    raise ValueError("invalid receipt revision")
                if api.get(f"git/commits/{revision}")["tree"]["sha"] != value["tree"]:
                    raise ValueError("receipt source tree mismatch")
                app = staging / Path(APP_REL)
                if product_digest(app) != receipt.get("product_sha256"):
                    raise ValueError("Release product digest mismatch")
                destination = derived / Path(APP_REL)
                if destination.exists() or destination.is_symlink():
                    raise ValueError("reuse destination must be empty")
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(app), destination)
                products_root = derived / "Build/Products"
                shutil.copy2(staging / Path(RECEIPT_REL), products_root / RECEIPT)
                consumer_revision = app_host_reuse.read("git", "rev-parse", "HEAD")
                (products_root / PROVENANCE).write_text(json.dumps({
                    "route": "github_artifact",
                    "run_url": run.get("html_url", ""),
                    "run_id": str(run["id"]),
                    "run_attempt": str(attempt),
                    "revision": revision,
                    "artifact_id": artifact["id"],
                    "consumer_revision": consumer_revision,
                }, sort_keys=True, indent=2) + "\n")
                return {
                    "hit": True,
                    "outcome": "exact_restore",
                    "reason": "exact_match",
                    "restore_seconds": time.monotonic() - started,
                    "producer_run_id": str(run["id"]),
                    "producer_run_attempt": str(attempt),
                    "producer_url": run.get("html_url", ""),
                    "artifact_id": str(artifact["id"]),
                }
        except (ValueError, KeyError, OSError, subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile, json.JSONDecodeError) as error:
            last_reason = type(error).__name__
            print(f"Skipping Release product artifact {artifact.get('id', '?')} ({last_reason}).")
    return {"hit": False, "outcome": "fallback_rebuild", "reason": last_reason, "restore_seconds": time.monotonic() - started}


def write_outputs(values: dict) -> None:
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in values.items():
            if isinstance(value, bool):
                rendered = "true" if value else "false"
            elif isinstance(value, float):
                rendered = f"{value:.3f}"
            else:
                rendered = str(value).replace("\n", " ")
            output.write(f"{key}={rendered}\n")


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("usage: reuse_release_product.py <key|restore|seal|pack> <derived-data> [archive]")
    mode = sys.argv[1]
    derived = Path(sys.argv[2])
    if mode == "pack":
        if len(sys.argv) != 4:
            raise SystemExit("pack requires an archive path")
        pack(derived, Path(sys.argv[3]))
        return
    try:
        value = contract()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        if mode in {"seal"}:
            raise
        print(f"Release product fingerprint unavailable ({type(error).__name__}); compiling normally.")
        fallback = {
            "key": "unavailable-" + os.environ.get("GITHUB_RUN_ID", "local"),
            "hit": False,
            "outcome": "fallback_rebuild",
            "reason": "fingerprint_unavailable",
            "restore_seconds": 0.0,
        }
        write_outputs({"key": fallback["key"]} if mode == "key" else fallback)
        return
    fingerprint = app_host_reuse.key(value)
    if mode == "key":
        write_outputs({"key": fingerprint})
    elif mode == "seal":
        seal(derived, value)
    elif mode == "restore":
        try:
            result = restore(
                app_host_reuse.GitHub(os.environ["GITHUB_REPOSITORY"]),
                value,
                derived,
                os.environ["GITHUB_RUN_ID"],
                int(os.environ["GITHUB_RUN_ATTEMPT"]),
            )
        except (ValueError, KeyError, OSError, subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile, json.JSONDecodeError) as error:
            print(f"Release product reuse unavailable ({type(error).__name__}); compiling normally.")
            shutil.rmtree(derived, ignore_errors=True)
            result = {"hit": False, "outcome": "fallback_rebuild", "reason": type(error).__name__, "restore_seconds": 0.0}
        write_outputs({"key": fingerprint, **result})
    else:
        raise ValueError("expected key, restore, seal, or pack")


if __name__ == "__main__":
    main()

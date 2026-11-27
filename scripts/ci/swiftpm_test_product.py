#!/usr/bin/env python3
"""Seal and restore a private, exact-run SwiftPM test scratch directory.

This is a transport helper, not a cross-revision build cache. A miss never
replaces an existing scratch directory (including a warm .build symlink).
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

# Reuse the existing bounded streaming reader/header parser. These imports
# have no network effects; they and their dependencies use the standard library.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from reuse_app_host_products import BoundedReader, BoundedTarInfo  # noqa: E402

SCHEMA = "cmux-next-swiftpm-test-product/v1"
MAX_ARCHIVE = 4 * 1024**3
MAX_EXPANDED = 16 * 1024**3
MAX_FILES = 100_000
MAX_MANIFEST = 64 * 1024**2
PACKAGE_ROOT = "Packages/macOS/CmuxNext"
# Includes local macOS/iOS packages and their transitive package dependencies.
# Start conservatively; narrowing this closure needs measured misses/proof.
INPUT_ROOTS = ("Packages",)
ENV_KEYS = ("DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET",
            "SWIFT_EXEC", "CC", "CXX", "SWIFTFLAGS", "CFLAGS", "CXXFLAGS", "LDFLAGS",
            "TOOLCHAINS", "SWIFTPM_CUSTOM_LIBS_DIR", "SWIFTPM_CUSTOM_BIN_DIR")
PAYLOAD_SHAPE = "private-swiftpm-scratch-no-vcs/v1"


class Miss(ValueError):
    pass


def digest_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def canonical(path):
    return str(Path(path).resolve())


def checked_name(name):
    p = PurePosixPath(name)
    if not name or p.is_absolute() or ".." in p.parts or str(p) != name or "\x00" in name:
        raise Miss("unsafe product path")
    return p


def checked_link(name, target):
    if not target or PurePosixPath(target).is_absolute() or "\x00" in target:
        raise Miss("external product symlink")
    parts = list(PurePosixPath(name).parent.parts)
    for part in PurePosixPath(target).parts:
        if part == "..":
            if not parts:
                raise Miss("escaping product symlink")
            parts.pop()
        elif part != ".":
            parts.append(part)
    return "/".join(parts)


def entries(root, excluded=(), excluded_roots=()):
    """Walk without following symlinks; retain modes needed by test executables."""
    root = Path(root)
    if not root.is_dir():
        raise Miss("missing input directory: " + str(root))
    found = []
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in excluded and (Path(base) != root or d not in excluded_roots))
        for name in sorted([*dirs, *(f for f in files if f not in excluded)]):
            path = Path(base) / name
            rel = path.relative_to(root).as_posix()
            checked_name(rel)
            info = path.lstat()
            item = {"path": rel, "mode": stat.S_IMODE(info.st_mode) & 0o777}
            if path.is_symlink():
                target = os.readlink(path)
                checked_link(rel, target)
                item.update(kind="symlink", target=target)
            elif stat.S_ISDIR(info.st_mode):
                item.update(kind="directory")
            elif stat.S_ISREG(info.st_mode):
                item.update(kind="file", size=info.st_size)
            else:
                raise Miss("unsupported product entry: " + rel)
            found.append(item)
            if len(found) > MAX_FILES:
                raise Miss("too many product entries")
    return sorted(found, key=lambda item: item["path"])


def check_links(items):
    seen = {item["path"] for item in items}
    links = {item["path"]: item["target"] for item in items if item["kind"] == "symlink"}
    for item in items:
        parents = PurePosixPath(item["path"]).parents
        if any(str(parent) in links for parent in parents):
            raise Miss("product member has a symlink parent")
    for name, link in links.items():
        resolved = checked_link(name, link)
        for _ in range(100):
            parts = PurePosixPath(resolved).parts
            prefix = next(("/".join(parts[:i]) for i in range(1, len(parts) + 1) if "/".join(parts[:i]) in links), None)
            if prefix is None:
                break
            suffix = parts[len(PurePosixPath(prefix).parts):]
            resolved = "/".join((checked_link(prefix, links[prefix]), *suffix))
        else:
            raise Miss("cyclic product symlink")
        if resolved not in seen:
            raise Miss("unresolved product symlink")


def input_digest(root):
    # Includes ignored generated web/resources, not merely the Git tree. Nested
    # SwiftPM scratch directories are outputs, never source inputs.
    items = entries(root, excluded=(".build", ".git"))
    for item in items:
        if item["kind"] == "file":
            item["sha256"] = digest_file(Path(root) / item["path"])
    return hashlib.sha256(json.dumps(items, sort_keys=True).encode()).hexdigest()


def identity(checkout, scratch, run_id, run_attempt, configuration, flags):
    checkout = Path(checkout).resolve()
    def read(*argv):
        return subprocess.check_output(argv, cwd=checkout, text=True, timeout=60).strip()
    if read("git", "status", "--porcelain", "--untracked-files=no"):
        raise Miss("test products require a clean exact source revision")
    swift_path = shutil.which("swift")
    if not swift_path:
        raise Miss("Swift executable is unavailable")
    value = {
        "schema": SCHEMA, "run_id": str(run_id), "run_attempt": str(run_attempt),
        "revision": read("git", "rev-parse", "HEAD"),
        "tree": read("git", "rev-parse", "HEAD^{tree}"), "dirty": False,
        "repository": read("git", "remote", "get-url", "origin"),
        "checkout": str(checkout), "scratch": canonical(scratch),
        "xcode": read("xcodebuild", "-version"),
        "developer": canonical(os.environ.get("DEVELOPER_DIR") or read("xcode-select", "-p")),
        "swift": read(swift_path, "--version"),
        "swift_path": canonical(swift_path),
        "sdk": read("xcrun", "--sdk", "macosx", "--show-sdk-path"),
        "sdk_version": read("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "architecture": platform.machine(), "configuration": configuration,
        "flags": flags, "environment": {k: os.environ.get(k, "") for k in ENV_KEYS},
        "inputs": {name: input_digest(checkout / name) for name in INPUT_ROOTS},
    }
    validate_identity(value)
    return value


def validate_identity(value):
    required = {"schema", "run_id", "run_attempt", "revision", "tree", "dirty",
                "checkout", "scratch", "xcode", "swift", "swift_path", "sdk",
                "sdk_version", "architecture", "configuration", "flags", "environment", "inputs", "repository", "developer"}
    if not isinstance(value, dict) or set(value) != required or value["schema"] != SCHEMA:
        raise Miss("incomplete product identity")
    if value["dirty"] is not False or any(not isinstance(value[k], str) or not re.fullmatch(r"[0-9a-f]{40}", value[k]) for k in ("revision", "tree")):
        raise Miss("source identity is not a clean exact commit")
    for key in ("checkout", "scratch", "swift_path", "sdk", "developer"):
        if not isinstance(value[key], str) or not Path(value[key]).is_absolute() or os.path.normpath(value[key]) != value[key]:
            raise Miss("identity path must be absolute: " + key)
    for key in ("run_id", "run_attempt", "xcode", "swift", "sdk_version", "architecture", "configuration", "repository"):
        if not isinstance(value[key], str) or not value[key]:
            raise Miss("missing identity field: " + key)
    if re.search(r"https?://[^/]*@", value["repository"]):
        raise Miss("credential-bearing source URL is unsupported")
    if not isinstance(value["flags"], list) or not all(isinstance(s, str) for s in value["flags"]):
        raise Miss("flags must be an exact argument vector")
    if value["configuration"] not in ("debug", "release"):
        raise Miss("unsupported build configuration")
    if not isinstance(value["environment"], dict) or set(value["environment"]) != set(ENV_KEYS) or not all(isinstance(v, str) for v in value["environment"].values()):
        raise Miss("incomplete build environment")
    if not isinstance(value["inputs"], dict) or set(value["inputs"]) != set(INPUT_ROOTS) or not all(isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v) for v in value["inputs"].values()):
        raise Miss("missing materialized package input hashes")
    # Keep the first transport contract to the stock test build. Custom search
    # paths/toolchains/linker arguments can depend on files outside this snapshot.
    allowed = {"--build-tests": None, "-c": {value["configuration"]},
               "--configuration": {value["configuration"]},
               "--scratch-path": {value["scratch"]},
               "--package-path": {str(Path(value["checkout"]) / PACKAGE_ROOT)},
               "-debug-info-format": {"none", "dwarf"}}
    flags = iter(value["flags"])
    for flag in flags:
        if flag in ("--jobs", "-j"):
            if not re.fullmatch(r"[1-9][0-9]*", next(flags, "")):
                raise Miss("invalid job count")
        elif flag not in allowed or (allowed[flag] is not None and next(flags, "") not in allowed[flag]):
            raise Miss("unsupported test build flag: " + flag)
    if any(value["environment"][k] for k in ENV_KEYS if k not in ("DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET")):
        raise Miss("custom compiler/linker environment is unsupported")


def verify_source(expected):
    """Do not let an old identity file hide a changed checkout or overlay."""
    def read(*args):
        try:
            return subprocess.check_output(["git", *args], cwd=expected["checkout"], text=True, stderr=subprocess.PIPE, timeout=60).strip()
        except (OSError, subprocess.SubprocessError) as error:
            raise Miss("source context unavailable") from error
    current = {"revision": read("rev-parse", "HEAD"), "tree": read("rev-parse", "HEAD^{tree}"),
               "repository": read("remote", "get-url", "origin")}
    if read("status", "--porcelain", "--untracked-files=no") or any(current[k] != expected[k] for k in current):
        raise Miss("source revision/context changed")
    current_inputs = {name: input_digest(Path(expected["checkout"]) / name) for name in INPUT_ROOTS}
    if current_inputs != expected["inputs"]:
        raise Miss("materialized package inputs changed")


def require_test_bundle(items):
    bundles = [item["path"] for item in items if item["kind"] == "directory" and item["path"].endswith(".xctest")]
    if not bundles or any(not any(item["kind"] == "file" and item["mode"] & 0o111 and item["path"].startswith(bundle + "/Contents/MacOS/") for item in items) for bundle in bundles):
        raise Miss("scratch directory contains no built test executable or a partial test bundle")


class HashingReader:
    def __init__(self, source):
        self.source, self.hash = source, hashlib.sha256()

    def read(self, size=-1):
        chunk = self.source.read(size)
        self.hash.update(chunk)
        return chunk


def seal(scratch, archive, expected):
    validate_identity(expected)
    verify_source(expected)
    root, archive = Path(scratch).resolve(), Path(archive)
    if str(root) != expected["scratch"]:
        raise Miss("scratch path mismatch")
    if archive.resolve().is_relative_to(root):
        raise Miss("archive cannot be inside the scratch directory")
    # Git repositories/configs and download caches are not test products. Keep
    # resolved source checkouts, binary artifacts and SwiftPM graph metadata for
    # the hosted --skip-build compatibility probe, without their VCS internals.
    items = entries(root, excluded=(".git",), excluded_roots=("repositories", "downloads"))
    check_links(items)
    require_test_bundle(items)
    if sum(item.get("size", 0) for item in items) > MAX_EXPANDED:
        raise Miss("product expansion limit exceeded")
    # Build the immutable archive beside its destination; publish only after
    # closing it. The manifest hashes the bytes actually written, not a prior
    # read of a possibly changing build output.
    with tempfile.TemporaryDirectory(prefix=".swiftpm-seal-", dir=archive.parent) as temporary:
        output = Path(temporary) / "product.tar.gz"
        with tarfile.open(output, "w:gz", format=tarfile.PAX_FORMAT) as tar:
            for item in items:
                info = tarfile.TarInfo("scratch/" + item["path"])
                info.mode = item["mode"]
                if item["kind"] == "directory":
                    info.type = tarfile.DIRTYPE
                    tar.addfile(info)
                elif item["kind"] == "symlink":
                    info.type, info.linkname = tarfile.SYMTYPE, item["target"]
                    raw = item["target"].encode()
                    item.update(size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
                    tar.addfile(info)
                else:
                    info.size = item["size"]
                    with os.fdopen(os.open(root / item["path"], os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
                        reader = HashingReader(source)
                        tar.addfile(info, reader)
                        if source.read(1):
                            raise Miss("build output changed during sealing")
                    item["sha256"] = reader.hash.hexdigest()
            manifest = json.dumps({"shape": PAYLOAD_SHAPE, "identity": expected, "entries": items}, sort_keys=True).encode()
            if len(manifest) > MAX_MANIFEST:
                raise Miss("manifest size limit exceeded")
            info = tarfile.TarInfo("manifest.json")
            info.size = len(manifest)
            tar.addfile(info, io.BytesIO(manifest))
        if output.stat().st_size > MAX_ARCHIVE:
            raise Miss("archive size limit exceeded")
        verify_source(expected)
        # Do not overwrite another producer's immutable publication.
        os.link(output, archive)
    return {"outcome": "sealed", "sha256": digest_file(archive),
            "bytes": archive.stat().st_size, "entries": len(items)}


def inspect(archive, expected, sha256, staging=None):
    if staging is None:
        with tempfile.TemporaryDirectory(prefix="swiftpm-validate-") as temporary:
            return inspect(archive, expected, sha256, Path(temporary))
    validate_identity(expected)
    verify_source(expected)
    archive = Path(archive)
    if archive.stat().st_size > MAX_ARCHIVE or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise Miss("invalid archive size or digest")
    if digest_file(archive) != sha256:
        raise Miss("archive digest mismatch")
    actual, seen, links, manifest, expanded = [], set(), [], None, 0
    with gzip.open(archive, "rb") as gz:
        with tarfile.open(fileobj=BoundedReader(gz, MAX_EXPANDED + MAX_MANIFEST + MAX_FILES * 2048), mode="r|", tarinfo=BoundedTarInfo) as tar:
            for member in tar:
                if manifest is not None or len(seen) > MAX_FILES:
                    raise Miss("unexpected member after manifest or too many entries")
                if member.name == "manifest.json":
                    if not member.isfile() or member.size > MAX_MANIFEST:
                        raise Miss("invalid product manifest")
                    manifest = json.load(tar.extractfile(member))
                    continue
                if member.size < 0:
                    raise Miss("negative product member size")
                if not member.name.startswith("scratch/"):
                    raise Miss("unscoped product path")
                name = member.name[len("scratch/"):]
                parts = checked_name(name).parts
                if ".git" in parts or parts[0] in ("repositories", "downloads"):
                    raise Miss("VCS or download cache is not a test product")
                if name in seen:
                    raise Miss("duplicate product path")
                seen.add(name)
                if member.mode & ~0o777:
                    raise Miss("unsafe product mode")
                item = {"path": name, "mode": member.mode}
                target = Path(staging) / name if staging else None
                if member.isdir():
                    item.update(kind="directory")
                    if target:
                        target.mkdir(parents=True, exist_ok=True)
                elif member.issym():
                    checked_link(name, member.linkname)
                    raw = member.linkname.encode()
                    item.update(kind="symlink", target=member.linkname, size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
                    links.append((name, member.linkname))
                elif member.isfile():
                    expanded += member.size
                    if member.size > 4 * 1024**3 or expanded > MAX_EXPANDED:
                        raise Miss("product expansion limit exceeded")
                    item.update(kind="file", size=member.size)
                    h = hashlib.sha256()
                    if target:
                        target.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as source:
                        output = target.open("xb") if target else None
                        try:
                            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                                h.update(chunk)
                                if output:
                                    output.write(chunk)
                        finally:
                            if output:
                                output.close()
                    item["sha256"] = h.hexdigest()
                else:
                    raise Miss("unsupported product entry")
                actual.append(item)
    if not isinstance(manifest, dict) or set(manifest) != {"shape", "identity", "entries"} or manifest["shape"] != PAYLOAD_SHAPE or manifest["identity"] != expected:
        raise Miss("product identity mismatch or missing manifest")
    if manifest["entries"] != sorted(actual, key=lambda item: item["path"]):
        raise Miss("product contents mismatch")
    require_test_bundle(actual)
    # Resolve framework chains against the archive index, never the host.
    check_links(actual)
    verify_source(expected)
    if staging:
        for name, link in links:
            target = Path(staging) / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(link)
        for item in reversed(actual):
            if item["kind"] != "symlink":
                (Path(staging) / item["path"]).chmod(item["mode"])
    return {"outcome": "validated", "sha256": sha256, "entries": len(actual), "expanded_bytes": expanded}


def restore(archive, expected, sha256, destination):
    validate_identity(expected)
    destination = Path(destination)
    # Reject existing dirs, dangling links and aliases before creating staging.
    if str(destination.absolute()) != expected["scratch"] or canonical(destination.parent) != str(destination.parent.absolute()):
        raise Miss("restore scratch path mismatch")
    if os.path.lexists(destination):
        raise Miss("restore destination already exists")
    with tempfile.TemporaryDirectory(prefix=".swiftpm-restore-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "scratch"
        staged.mkdir()
        receipt = inspect(archive, expected, sha256, staged)
        # mkdir is the exclusive claim. Another consumer cannot acquire this
        # destination after our precheck, even on runners sharing one host.
        destination.mkdir()
        try:
            staged.rename(destination)
        except BaseException:
            try:
                destination.rmdir()  # Never delete another process's contents.
            except OSError:
                pass
            raise
    return dict(receipt, outcome="restored", scratch=str(destination))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("identity", "seal", "validate", "restore"))
    parser.add_argument("--identity", type=Path)
    parser.add_argument("--checkout", type=Path, default=Path.cwd())
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--sha256")
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID"))
    parser.add_argument("--run-attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT"))
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--flags-json", default="[]")
    args = parser.parse_args(argv)
    try:
        if args.operation == "identity":
            if not args.run_id or not args.run_attempt:
                raise Miss("run identity is required")
            result = identity(args.checkout, args.scratch, args.run_id, args.run_attempt, args.configuration, json.loads(args.flags_json))
        else:
            if args.identity is None or args.archive is None:
                raise Miss("identity and archive are required")
            expected = json.loads(args.identity.read_text())
            if args.operation == "seal":
                result = seal(args.scratch, args.archive, expected)
            elif args.operation == "validate":
                result = inspect(args.archive, expected, args.sha256 or "")
            else:
                result = restore(args.archive, expected, args.sha256 or "", args.scratch)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, OSError, tarfile.TarError, EOFError, subprocess.SubprocessError) as error:
        print(json.dumps({"outcome": "miss", "reason": str(error)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

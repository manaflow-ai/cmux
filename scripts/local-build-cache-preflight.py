#!/usr/bin/env python3
"""Reuse local build seeds; explicit --warm fetches compressed remote seeds.

Mutable SourcePackages directories belong to one caller. Populated destinations
are preserved. Only immutable, staged seeds are shared between callers.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager, nullcontext
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

DEFAULT_URL = "https://ci-cache.cmux.com"
LOCKFILE = "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SPM_CACHE_LAYOUT = "scripts/ci/swiftpm-cache-layout"
MAX_ARCHIVE = 2 * 1024**3
MAX_EXPANDED = 16 * 1024**3
MAX_MEMBERS = 300_000
DISK_RESERVE = 2 * 1024**3
GHOSTTY_SEED_RECIPE = "indexed-v1"


class CommandFailed(RuntimeError):
    def __init__(self, executable, status):
        self.status = status
        super().__init__(f"{Path(executable).name} failed ({status})")


def remaining(deadline):
    budget = deadline - time.monotonic()
    if budget <= 0:
        raise TimeoutError("cache preflight time budget exhausted")
    return budget


def run(command, deadline, *, env=None, cwd=None, pass_fds=()):
    # Kill the entire helper group on timeout, including a downloader child.
    timeout = remaining(deadline)
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen(command, stdout=log, stderr=log, env=env, cwd=cwd,
                                   start_new_session=True, pass_fds=pass_fds)
        try:
            status = process.wait(timeout=timeout)
        except BaseException as error:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            if isinstance(error, subprocess.TimeoutExpired):
                raise TimeoutError("cache helper exceeded the preflight time budget") from error
            raise
        if status:
            remaining(deadline)
            raise CommandFailed(command[0], status)


def spm_key(repo):
    # Actions hashFiles hashes the binary SHA256 digest of each matching file,
    # in pattern order. The workflows' key names Package.resolved, then the
    # cache layout version.
    digests = hashlib.sha256()
    for name in (LOCKFILE, SPM_CACHE_LAYOUT):
        digests.update(hashlib.sha256((repo / name).read_bytes()).digest())
    return "spm-" + digests.hexdigest()


def populated(path):
    return path.is_symlink() or (path.exists() and (not path.is_dir() or any(path.iterdir())))


@contextmanager
def locked(path, deadline):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # Inherit the same open file description: the acquired flock
            # remains held by this parent after the waiting helper exits.
            # The process-group watchdog bounds blocking acquisition.
            run([sys.executable, "-c",
                 "import fcntl,sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX)",
                 str(handle.fileno())], deadline, pass_fds=(handle.fileno(),))
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def fetch(url, output, deadline, limit=MAX_ARCHIVE):
    try:
        available = shutil.disk_usage(output.parent).free - DISK_RESERVE
        if available <= 0:
            raise RuntimeError("insufficient disk headroom for build cache")
        protocols = "=https" if url.lower().startswith("https://") else "=http,https"
        run(["curl", "--proto", protocols, "--proto-redir", protocols, "--fail", "--silent", "--show-error", "--location",
             "--connect-timeout", "5", "--max-time", str(min(90, remaining(deadline))),
             "--max-filesize", str(min(limit, available)), "--output", str(output), url], deadline)
        if output.stat().st_size > limit:
            raise ValueError("cache response exceeded its size limit")
        return True
    except TimeoutError:
        output.unlink(missing_ok=True)
        raise
    except CommandFailed as error:
        output.unlink(missing_ok=True)
        if error.status == 28:
            raise TimeoutError("cache download reached its transfer timeout") from error
        return False
    except (RuntimeError, OSError, ValueError):
        output.unlink(missing_ok=True)
        return False


def worker(operation, deadline, *arguments):
    run([sys.executable, str(Path(__file__).resolve()), "--internal-worker", operation,
         str(deadline), *(str(argument) for argument in arguments)], deadline)


def unpack(archive, extension, destination, deadline):
    # A single tar member can take longer than the remaining budget. Execute
    # the entire extraction in a killable process group, including zstd.
    worker("unpack", deadline, archive, extension, destination)


def unpack_worker(archive, extension, destination, deadline):
    if not hasattr(tarfile, "data_filter"):
        raise RuntimeError("Python tarfile.data_filter is required for safe cache extraction")
    process = None
    if extension == "tar.zst":
        process = subprocess.Popen(["zstd", "-dc", str(archive)], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
        stream = process.stdout
        mode = "r|"
    else:
        stream = archive.open("rb")
        mode = "r|gz"
    try:
        with stream, tarfile.open(fileobj=stream, mode=mode) as bundle:
            total = 0
            for count, member in enumerate(bundle, start=1):
                remaining(deadline)
                total += max(0, member.size)
                if count > MAX_MEMBERS or total > MAX_EXPANDED:
                    raise ValueError("cache archive expansion limit exceeded")
                if member.size and shutil.disk_usage(destination).free < member.size + DISK_RESERVE:
                    raise RuntimeError("insufficient disk headroom to expand build cache")
                # data_filter rejects escaping paths/links, devices and unsafe
                # modes. Extract incrementally, so links created earlier are
                # considered when validating every later member.
                bundle.extract(member, destination, filter="data")
            if process:
                # Consume the compressed stream through its checksum/footer;
                # closing at tar padding can otherwise turn corruption into a hit.
                while stream.read(1024 * 1024):
                    remaining(deadline)
        if process and process.wait(timeout=remaining(deadline)) != 0:
            raise ValueError("cache decompression failed")
    finally:
        if process and process.poll() is None:
            process.kill()
            process.wait()


def writable_tree(path, writable):
    for root, directories, files in os.walk(path):
        for name in directories + files:
            item = Path(root) / name
            if not item.is_symlink():
                mode = item.stat().st_mode & 0o777
                item.chmod((mode | 0o200) if writable else (mode & ~0o222))
        directory = Path(root)
        directory.chmod((directory.stat().st_mode & 0o777) | 0o700 if writable else 0o555)


def clone(source, destination, deadline):
    method = "copy"
    if platform.system() == "Darwin":
        try:
            run(["cp", "-cR", str(source), str(destination)], deadline)
            method = "apfs-clone"
        except RuntimeError:
            if destination.exists():
                writable_tree(destination, True)
                shutil.rmtree(destination)
    if not destination.exists():
        worker("copy", deadline, source, destination)
    else:
        worker("writable", deadline, destination, "1")
    remaining(deadline)
    return method


def file_sha256(path, deadline):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            remaining(deadline)
            digest.update(chunk)
    return digest.hexdigest()


def internal_worker(arguments):
    operation, deadline, *paths = arguments
    deadline = float(deadline)
    remaining(deadline)
    if operation == "unpack":
        unpack_worker(Path(paths[0]), paths[1], Path(paths[2]), deadline)
    elif operation == "copy":
        source, destination = map(Path, paths)
        size = sum(p.stat().st_size for p in source.rglob("*") if p.is_file() and not p.is_symlink())
        if shutil.disk_usage(destination.parent).free < size + DISK_RESERVE:
            raise RuntimeError("insufficient disk headroom to copy build cache")
        shutil.copytree(source, destination, symlinks=True)
        writable_tree(destination, True)
    elif operation == "writable":
        writable_tree(Path(paths[0]), paths[1] == "1")
    elif operation == "seal-spm":
        staging, archive, key = Path(paths[0]), Path(paths[1]), paths[2]
        (staging / "receipt.json").write_text(json.dumps({
            "schema_version": 1, "key": key, "archive_sha256": file_sha256(archive, deadline),
        }) + "\n")
        for downloaded in staging.glob("archive.*"):
            downloaded.unlink()
        writable_tree(staging, False)
    else:
        raise ValueError("unknown cache worker operation")
    remaining(deadline)
    return 0


def local_spm_seed(seed_root, requested):
    candidates = [requested]
    try:
        previous = (seed_root / "latest-local").read_text().strip()
        if re.fullmatch(r"spm-[0-9a-f]{64}", previous) and previous != requested:
            candidates.append(previous)
    except OSError:
        pass
    for candidate in candidates:
        entry = seed_root / candidate
        try:
            saved = json.loads((entry / "receipt.json").read_text())
            if (saved.get("schema_version") == 1 and saved.get("key") == candidate
                    and (entry / "SourcePackages").is_dir()):
                return entry / "SourcePackages", candidate
        except (OSError, ValueError):
            pass
    return None, None


def remember_local_spm(seed_root, key):
    # Readers never wait behind a remote warm-up. Only publish complete seeds.
    with tempfile.NamedTemporaryFile(mode="w", dir=seed_root, prefix=".latest-", delete=False) as pointer:
        temporary = Path(pointer.name)
        pointer.write(key + "\n")
    try:
        os.replace(temporary, seed_root / "latest-local")
    finally:
        temporary.unlink(missing_ok=True)


def seed_spm(repo, destination, cache, url, namespace, deadline, *, allow_network=False, warm_only=False):
    requested = spm_key(repo)
    result = {"requested_key": requested, "namespace": namespace,
              "destination": str(destination) if destination is not None else None}
    if destination is not None and populated(destination):
        return {**result, "status": "existing", "reason": "preserved populated destination"}
    origin = hashlib.sha256(url.encode()).hexdigest()[:16]
    seed_root = cache / "spm" / origin / namespace
    seed_root.mkdir(parents=True, exist_ok=True)
    source, matched = local_spm_seed(seed_root, requested)
    if source is not None:
        result["transport"] = "local-seed"
    for candidate in (requested, None):
        if source is not None or not allow_network:
            break
        if candidate is None:
            with tempfile.TemporaryDirectory(dir=seed_root) as temporary:
                pointer = Path(temporary) / "pointer"
                if not fetch(f"{url}/v1/{namespace}/latest/spm-", pointer, deadline, 512):
                    continue
                candidate = pointer.read_text().strip()
            if not re.fullmatch(r"spm-[0-9a-f]{64}", candidate) or candidate == requested:
                continue
        entry = seed_root / candidate
        with locked(seed_root / (candidate + ".lock"), deadline):
            metadata = entry / "receipt.json"
            if metadata.is_file() and (entry / "SourcePackages").is_dir():
                saved = json.loads(metadata.read_text())
                if saved.get("key") == candidate and saved.get("schema_version") == 1:
                    source, matched = entry / "SourcePackages", candidate
                    result["transport"] = "local-seed"
                    break
            if entry.exists():
                continue  # Never replace an unknown or partially published seed.
            with tempfile.TemporaryDirectory(prefix=".seed-", dir=seed_root) as temporary:
                staging = Path(temporary)
                for extension in ("tar.zst", "tar.gz"):
                    if extension == "tar.zst" and not shutil.which("zstd"):
                        continue
                    archive = staging / ("archive." + extension)
                    if not fetch(f"{url}/v1/{namespace}/objects/{candidate}.{extension}", archive, deadline):
                        continue
                    data = staging / "SourcePackages"
                    data.mkdir()
                    try:
                        unpack(archive, extension, data, deadline)
                        if not any(data.iterdir()):
                            raise ValueError("empty SwiftPM seed")
                        (data / "workspace-state.json").unlink(missing_ok=True)
                    except Exception:
                        shutil.rmtree(data)
                        raise
                    # Consumers use the extracted immutable seed. Keeping the
                    # compressed transport blob doubles long-lived disk usage.
                    worker("seal-spm", deadline, staging, archive, candidate)
                    remaining(deadline)
                    os.rename(staging, entry)
                    source, matched = entry / "SourcePackages", candidate
                    result["transport"] = "r2"
                    break
                if source:
                    break
    if source is None:
        return {**result, "status": "miss", "reason": "no usable local seed" if not allow_network else "no usable exact or prefix seed"}
    remember_local_spm(seed_root, matched)
    if warm_only:
        return {**result, "status": "warmed", "matched_key": matched,
                "match": "exact" if matched == requested else "prefix"}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with locked(destination.parent / ("." + destination.name + ".cache-preflight.lock"), deadline):
        if populated(destination):
            return {**result, "status": "existing", "reason": "destination populated while waiting"}
        with tempfile.TemporaryDirectory(prefix=".spm-clone-", dir=destination.parent) as temporary:
            prepared = Path(temporary) / "SourcePackages"
            method = clone(source, prepared, deadline)
            (prepared / "workspace-state.json").unlink(missing_ok=True)
            remaining(deadline)
            if destination.exists():
                destination.rmdir()  # Succeeds only while still empty.
            os.rename(prepared, destination)
    return {**result, "status": "hit", "matched_key": matched,
            "match": "exact" if matched == requested else "prefix", "materialization": method}


def prepare_ghostty_index(framework, deadline):
    with (framework / "Info.plist").open("rb") as stream:
        libraries = plistlib.load(stream).get("AvailableLibraries", [])
    indexed = []
    for library in libraries:
        if library.get("SupportedPlatform") != "macos":
            continue
        archive = framework / library["LibraryIdentifier"] / library["LibraryPath"]
        if (not archive.resolve().is_relative_to(framework.resolve())
                or archive.suffix != ".a" or not archive.is_file()):
            raise ValueError("GhosttyKit macOS archive is missing or outside the framework")
        # Same selected-toolchain operation as ensure-ghosttykit.sh, applied
        # before sealing. Info.plist handles both libghostty.a and renamed
        # ghostty-internal.a distributions without silently skipping either.
        run(["xcrun", "ranlib", str(archive)], deadline)
        indexed.append(str(archive.relative_to(framework)))
    if not indexed:
        raise ValueError("GhosttyKit has no macOS static archive to prepare")
    return indexed


def seed_ghostty(repo, cache, deadline, *, allow_network=False, warm_only=False):
    cache = cache.resolve()
    destination = repo / "GhosttyKit.xcframework"
    managed = destination.is_symlink() and (cache / "ghostty") in destination.resolve().parents
    if populated(destination) and not managed:
        return {"status": "existing", "reason": "preserved existing GhosttyKit", "verified_install": False}
    revision = subprocess.check_output(["git", "-C", str(repo / "ghostty"), "rev-parse", "HEAD"],
                                       text=True, timeout=min(10, remaining(deadline))).strip()
    dirty = subprocess.check_output(["git", "-C", str(repo / "ghostty"), "status", "--porcelain"],
                                    text=True, timeout=min(10, remaining(deadline))).strip()
    if dirty or os.environ.get("CMUX_GHOSTTYKIT_NO_PREBUILT") == "1" or os.environ.get("CMUX_GHOSTTYKIT_CRASH_REPORT_SUBDIR", "cmux/crash") != "cmux/crash":
        return {"status": "miss", "reason": "Ghostty needs a custom/local build", "verified_install": False}
    checksums = dict(line.split()[:2] for line in (repo / "scripts/ghosttykit-checksums.txt").read_text().splitlines()
                     if line.strip() and not line.startswith("#") and len(line.split()) >= 2)
    checksum = checksums.get(revision)
    if not checksum or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        return {"status": "miss", "reason": "Ghostty revision has no pinned checksum", "verified_install": False}
    root = cache / "ghostty"
    root.mkdir(parents=True, exist_ok=True)
    seed_key = checksum + "-" + GHOSTTY_SEED_RECIPE
    entry = root / seed_key
    if not entry.exists() and not allow_network:
        return {"status": "miss", "reason": "no usable local GhosttyKit seed", "verified_install": False}
    # Published seeds are immutable. Local readers must not wait for a warmer.
    with locked(root / (seed_key + ".lock"), deadline) if allow_network else nullcontext():
        if managed and destination.resolve() != entry / "GhosttyKit.xcframework":
            return {"status": "existing", "reason": "preserved GhosttyKit from another revision", "verified_install": False}
        if not entry.exists():
            with tempfile.TemporaryDirectory(prefix=".ghostty-", dir=root) as temporary:
                staging = Path(temporary)
                environment = dict(os.environ, GHOSTTY_SHA=revision,
                                   GHOSTTYKIT_OUTPUT_DIR=str(staging / "GhosttyKit.xcframework"),
                                   GHOSTTYKIT_CHECKSUMS_FILE=str(repo / "scripts/ghosttykit-checksums.txt"),
                                   GHOSTTYKIT_ARCHIVE_VALIDATOR=str(repo / "scripts/validate-xcframework-archive.py"),
                                   TMPDIR=str(staging),
                                   GHOSTTYKIT_DOWNLOAD_RETRIES="0",
                                   GHOSTTYKIT_DOWNLOAD_MAX_TIME=str(max(1, int(remaining(deadline)))))
                run(["bash", str(repo / "scripts/download-prebuilt-ghosttykit.sh")], deadline,
                    env=environment, cwd=repo)
                indexed = prepare_ghostty_index(staging / "GhosttyKit.xcframework", deadline)
                (staging / "receipt.json").write_text(json.dumps({"schema_version": 1, "revision": revision,
                    "archive_sha256": checksum, "recipe": GHOSTTY_SEED_RECIPE,
                    "indexed_archives": indexed}) + "\n")
                worker("writable", deadline, staging, "0")
                remaining(deadline)
                os.rename(staging, entry)
        receipt = json.loads((entry / "receipt.json").read_text())
        if (receipt.get("schema_version") != 1 or receipt.get("revision") != revision
                or receipt.get("archive_sha256") != checksum
                or receipt.get("recipe") != GHOSTTY_SEED_RECIPE or not receipt.get("indexed_archives")
                or not (entry / "GhosttyKit.xcframework/Info.plist").is_file()):
            raise ValueError("Ghostty seed receipt mismatch")
        if warm_only:
            return {"status": "warmed", "revision": revision, "archive_sha256": checksum,
                    "verified_install": False}
        if managed:
            return {"status": "hit", "revision": revision, "archive_sha256": checksum,
                    "verified_install": True, "materialization": "existing-immutable-link"}
        with locked(repo / ".ghosttykit-cache-preflight.lock", deadline):
            if populated(destination):
                return {"status": "existing", "verified_install": False}
            if destination.exists():
                destination.rmdir()
            remaining(deadline)
            destination.symlink_to(entry / "GhosttyKit.xcframework", target_is_directory=True)
    return {"status": "hit", "revision": revision, "archive_sha256": checksum,
            "verified_install": True, "materialization": "immutable-link"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--warm", action="store_true", help="Fetch compressed shared seeds only; do not change workspace outputs")
    modes.add_argument("--local-only", action="store_true", help="Reuse local seeds without cache downloads (default)")
    parser.add_argument("--source-packages-dir", type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--cache-root", type=Path, default=Path.home() / "Projects/.cmux-build-cache")
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args(argv)
    if args.warm and args.source_packages_dir is not None:
        parser.error("--warm populates shared seeds only; omit --source-packages-dir")
    if not args.warm and args.source_packages_dir is None:
        parser.error("local reuse requires --source-packages-dir")
    if not 0 < args.timeout <= 600:
        parser.error("timeout must be greater than zero and at most 600 seconds")
    deadline = time.monotonic() + args.timeout
    receipt = {"schema_version": 1, "mode": "warm" if args.warm else "local-only",
               "network_allowed": args.warm, "compiler_cache": "not_restored", "whole_app": "not_restored"}
    namespace = "macOS-" + {"arm64": "ARM64", "x86_64": "X64"}.get(platform.machine(), "unsupported")
    repo, cache = args.repo.resolve(), args.cache_root.resolve()
    destination = args.source_packages_dir.absolute() if args.source_packages_dir is not None else None
    if destination is not None and (destination.resolve() == cache or cache in destination.resolve().parents):
        parser.error("the mutable source-packages directory must be outside the shared seed cache")
    url = os.environ.get("CI_CACHE_R2_PUBLIC_URL", DEFAULT_URL).rstrip("/")
    for name, operation in (
        ("swiftpm", lambda: seed_spm(repo, destination, cache, url, namespace, deadline,
                                     allow_network=args.warm, warm_only=args.warm)),
        ("ghosttykit", lambda: seed_ghostty(repo, cache, deadline,
                                          allow_network=args.warm, warm_only=args.warm)),
    ):
        try:
            receipt[name] = operation()
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
            receipt[name] = {"status": "miss", "reason": str(error)}
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print("Build cache preflight: " + ", ".join(f"{name}={receipt[name]['status']}" for name in ("swiftpm", "ghosttykit")))
    # An optimization miss must not prevent normal package resolution/building.
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--internal-worker"]:
        raise SystemExit(internal_worker(sys.argv[2:]))
    raise SystemExit(main())

#!/usr/bin/env python3
"""The fleet-shared compile cache for the cmux NEXT DEV Release compile: CAS seeds.

The DEV compile (compile-dev-release.sh, host mode) builds every mini from the same paths
(HOME/Library/Caches/cmux-next-ci/dev-daily-release/host: src and one DerivedData per toolchain),
so one mini's Xcode compilation cache (DerivedData/CompilationCache.noindex) replays on another.
A host whose own cache is missing or older than the fleet's newest seed installs that seed before
it compiles, instead of compiling cold.

    pack     after a host build: write the host's origin marker (the commit its cache last built),
             and with --out pack the cache (tar, zstd) with pack.json (key, digest, size, origin)
    publish  PUT a pack to the shared store (the content-addressed cache on the fleet's external
             SSDs, CMUX_NEXT_DEV_CAS_URL), then write the record (manifest.json) the workflow
             uploads as the artifact cmux-next-dev-cas-seed-<key>
    restore  before a host build: find the newest record of this key from a trusted run, and when
             it is newer than this host's marker (or the host has no cache), download its blob by
             digest, check the SHA-256 and size, and install it in place of the host's cache
    key      print the key and its fields

Trust. Only feat-cmux-next's own push or dispatch runs of cmux-next.yml write records (GitHub
artifacts a pull request cannot add to those runs); a reader takes a record only from such a run
whose DEV compile job succeeded (the checks of dev_release_product_reuse.py). The store holds bytes
only: the reader checks them against the record's digest and size, so whoever else can write the
store (its token is in a feat-cmux-next-only environment) can fill its disk but never make a build
use its bytes. A record names its key and paths, which must equal the reader's own.

The key: Xcode's version and build, the developer dir, the SDK version and build, the Swift
version, the arch, the configuration, the Swift compilation mode, the cache size limit, the
product settings the DEV compile passes, the host paths and RECIPE. A different key is a different
seed line; within a key Xcode's own per-job keys decide what replays, so a seed can only miss,
never build wrong.

Every failure (no URL or token, no record, a bad digest, a network error, a full disk) is a miss
with a reason and the build compiles as before; nothing here fails a build.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))
import dev_release_product_reuse as reuse  # noqa: E402

SCHEMA = "cmux-next-dev-cas-seed/v1"
# Bump to start every seed line over (a change to how seeds are packed or what they hold).
RECIPE = "dev-cas-seed-v1"
RECORD_PREFIX = "cmux-next-dev-cas-seed-"
CAS_DIR = "CompilationCache.noindex"
BLOB = "seed.tar.zst"
MAX_BLOB_BYTES = 8 * 1024**3
# What a seed may unpack to beyond the cache size its record declares (tar headers, rounding), and
# the most entries it may hold: a seed past either is refused mid-stream, whatever its digest.
EXTRACT_SLACK_BYTES = 64 * 1024**2
MAX_MEMBERS = 2_000_000
# The most tar metadata (headers, PAX records, padding) the stream may carry between one member's
# data and the next member: tarfile reads a PAX record whole, into memory, before it yields the
# member, so this bounds that read.
MAX_METADATA_BYTES = 1024**2
ZSTD_EXIT_SECONDS = 60
# How many of the most recently uploaded trusted records a reader validates; it installs the one of
# the newest commit among them, whatever order they were uploaded in.
CANDIDATES = 5
KEY_ENV = (
    "CMUX_NEXT_CONFIGURATION", "CMUX_NEXT_SWIFT_COMPILATION_MODE", "CMUX_NEXT_PRODUCT_NAME",
    "CMUX_NEXT_BUNDLE_ID", "CMUX_NEXT_CODE_SIGN_ENTITLEMENTS", "CMUX_NEXT_AUTH_CALLBACK_SCHEME",
    "CMUX_NEXT_BROWSER_DATA_IMPORT", "CMUX_NEXT_TUI_MODE",
)
# The CAS's own limit and the size past which the DEV compile drops it (lib/compilation-cache.sh).
CAS_LIMIT_BYTES = 3221225472
CAS_MAX_BYTES = 6 * 1024**3
LANE = reuse.Lane("DEV compile cache", SCHEMA, RECIPE, RECORD_PREFIX, "", ".tar.zst", reuse.WORKFLOW_PATH,
                  reuse.BRANCH, reuse.TRUSTED_EVENTS, reuse.PRODUCER_JOBS)


class Miss(reuse.Miss):
    pass


class NotNewer(Miss):
    """The seed of the newest commit among the candidates is not newer than this host's cache."""


def note(message: str) -> None:
    print(f"dev-cas-seed: {message}", file=sys.stderr)


def run(command: list[str]) -> str:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def key_fields(derived_data: Path, build_root: Path, env: dict[str, str]) -> dict[str, str]:
    """What a seed must share with its reader. Nothing here is secret."""
    fields = {
        "recipe": RECIPE,
        "xcode": " ".join(run(["xcodebuild", "-version"]).split()),
        "developer_dir": env.get("DEVELOPER_DIR") or run(["xcode-select", "-p"]),
        "sdk": f"{run(['xcrun', '--sdk', 'macosx', '--show-sdk-version'])} "
               f"{run(['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'])}",
        "swift": (run(["xcrun", "swiftc", "--version"]).splitlines() or [""])[0],
        "arch": os.uname().machine,
        "cas_limit": str(CAS_LIMIT_BYTES),
        "derived_data": str(derived_data),
        "build_root": str(build_root),
    }
    for name in KEY_ENV:
        fields[name.lower()] = env.get(name, "")
    return fields


def key_of(fields: dict[str, str]) -> str:
    if not fields.get("xcode") or not fields.get("sdk", "").strip():
        raise Miss("no Xcode or SDK version to key the cache by")
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


def sha256_file(path: Path) -> str:
    return reuse.sha256_file(path)


def zstd_binary(env: dict[str, str]) -> str:
    for candidate in (env.get("CMUX_NEXT_DEV_CAS_ZSTD", ""), shutil.which("zstd") or "",
                      "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    raise Miss("no zstd on this host")


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def cas_present(derived_data: Path) -> bool:
    cas = derived_data / CAS_DIR
    try:
        return cas.is_dir() and not cas.is_symlink() and any(cas.iterdir())
    except OSError:
        return False


def tree_bytes(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temp, path)


# ---- pack and install: the CAS directory as a tar stream through zstd


def pack(derived_data: Path, out: Path, env: dict[str, str]) -> tuple[int, str]:
    """Write out/seed.tar.zst from derived_data's CAS; return (bytes, sha256). Regular files and
    directories only, names relative to DerivedData, no owner names."""
    cas = derived_data / CAS_DIR
    out.mkdir(parents=True, exist_ok=True)
    blob = out / BLOB
    with blob.open("wb") as sink:
        zstd = subprocess.Popen([zstd_binary(env), "-q", "-T0", "-3", "-c"], stdin=subprocess.PIPE, stdout=sink)
        try:
            with tarfile.open(fileobj=zstd.stdin, mode="w|", format=tarfile.PAX_FORMAT) as tar:
                for root, dirs, files in os.walk(cas):
                    dirs.sort()
                    for name in [*sorted(dirs), *sorted(files)]:
                        path = Path(root) / name
                        if path.is_symlink() or not (path.is_dir() or path.is_file()):
                            continue
                        info = tar.gettarinfo(str(path), arcname=str(path.relative_to(derived_data)))
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        if info.isfile():
                            with path.open("rb") as source:
                                tar.addfile(info, source)
                        else:
                            tar.addfile(info)
        finally:
            zstd.stdin.close()
            status = zstd.wait()
    if status:
        raise Miss(f"zstd exited {status} while packing")
    return blob.stat().st_size, sha256_file(blob)


def safe_member(member: tarfile.TarInfo) -> bool:
    parts = Path(member.name).parts
    return (bool(parts) and parts[0] == CAS_DIR and not member.name.startswith("/") and ".." not in parts
            and (member.isfile() or member.isdir()))


def copy_bounded(source, sink, left: int) -> int:
    """Copy SOURCE to SINK and return how many of LEFT bytes remain; refuse past LEFT."""
    while chunk := source.read(1 << 20):
        left -= len(chunk)
        if left < 0:
            raise Miss("the seed unpacks to more than its record declares")
        sink.write(chunk)
    return left


class CappedStream:
    """The decompressed seed as tarfile reads it, refused mid-stream past TOTAL bytes in all, or past
    MAX_METADATA_BYTES beyond the data of the member last yielded. Every byte tarfile reads (headers
    and PAX records included, which it reads before yielding a member) passes through here, so
    neither the disk nor the runner's memory takes more than the bound."""

    def __init__(self, raw, total: int, metadata: int = MAX_METADATA_BYTES):
        self.raw, self.total_left, self.metadata = raw, total, metadata
        self.gap_left = metadata

    def allow(self, data_bytes: int) -> None:
        """A member was yielded: its DATA_BYTES may follow, then the next member's metadata."""
        self.gap_left = self.metadata + max(0, data_bytes)

    def read(self, size: int = -1) -> bytes:
        chunk = self.raw.read(1 << 20 if size is None or size < 0 else min(size, 1 << 20))
        self.total_left -= len(chunk)
        self.gap_left -= len(chunk)
        if self.total_left < 0:
            raise Miss("the seed unpacks to more than its record declares")
        if self.gap_left < 0:
            raise Miss(f"the seed holds more than {self.metadata} bytes of tar metadata at once")
        return chunk


def extract(blob: Path, derived_data: Path, env: dict[str, str], max_bytes: int = CAS_MAX_BYTES) -> None:
    """Unpack the seed into derived_data/.cas-seed-incoming, then swap it in for the CAS. A member
    outside CompilationCache.noindex, a link or a device refuses the whole seed, and so does
    unpacking more than MAX_BYTES (counted as it streams, so a bomb never fills the disk) or more
    than MAX_MEMBERS entries. A refused seed leaves nothing behind and the host's cache as it was."""
    incoming = derived_data / ".cas-seed-incoming"
    shutil.rmtree(incoming, ignore_errors=True)
    incoming.mkdir(parents=True)
    try:
        unpack(blob, incoming, env, max_bytes)
    except BaseException:
        shutil.rmtree(incoming, ignore_errors=True)
        raise
    swap_in(incoming, derived_data)


def unpack(blob: Path, incoming: Path, env: dict[str, str], max_bytes: int) -> None:
    left, members = max_bytes, 0
    with blob.open("rb") as source:
        zstd = subprocess.Popen([zstd_binary(env), "-q", "-d", "-c"], stdin=source, stdout=subprocess.PIPE)
        stream = CappedStream(zstd.stdout, max_bytes)
        try:
            with tarfile.open(fileobj=stream, mode="r|") as tar:
                for member in tar:
                    stream.allow(member.size if member.isfile() else 0)
                    members += 1
                    if members > MAX_MEMBERS:
                        raise Miss(f"the seed holds more than {MAX_MEMBERS} entries")
                    if not safe_member(member):
                        raise Miss(f"the seed holds {member.name!r}, not a file or directory of the cache")
                    target = incoming / member.name
                    if member.isdir():
                        target.mkdir(parents=True, exist_ok=True)
                        continue
                    if member.size > left:
                        raise Miss("the seed unpacks to more than its record declares")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if target.is_symlink() or not target.resolve().is_relative_to(incoming.resolve()):
                        raise Miss(f"the seed's {member.name!r} lands outside the cache")
                    data = tar.extractfile(member)
                    with target.open("wb") as sink:
                        left = copy_bounded(data, sink, left)
                    os.chmod(target, (member.mode & 0o755) | 0o600)
            # The tar ended; zstd may still be writing its padding and exiting. Drain it to EOF,
            # through the same bounds, and let it finish on its own.
            stream.allow(0)
            while stream.read(1 << 20):
                pass
            status = zstd.wait(timeout=ZSTD_EXIT_SECONDS)
        except tarfile.TarError as error:
            raise Miss(f"the seed is not a readable tar: {error}") from error
        except Miss:
            raise
        except (OSError, ValueError, EOFError) as error:
            raise Miss(f"the seed could not be unpacked: {error}") from error
        except subprocess.TimeoutExpired as error:
            raise Miss(f"zstd did not exit within {ZSTD_EXIT_SECONDS} s of its output ending") from error
        finally:
            # Killed only when unpacking stopped early (a refused seed, a timeout, any error).
            if zstd.poll() is None:
                zstd.kill()
                zstd.wait()
            zstd.stdout.close()
    if status:
        raise Miss(f"zstd exited {status} while unpacking")


def swap_in(incoming: Path, derived_data: Path) -> None:
    if not (incoming / CAS_DIR).is_dir():
        raise Miss(f"the seed holds no {CAS_DIR}")
    old = derived_data / CAS_DIR
    retired = derived_data / ".cas-seed-retired"
    shutil.rmtree(retired, ignore_errors=True)
    if old.exists() or old.is_symlink():
        os.replace(old, retired)
    os.replace(incoming / CAS_DIR, old)
    shutil.rmtree(retired, ignore_errors=True)
    shutil.rmtree(incoming, ignore_errors=True)


# ---- the store: GET and PUT /v1/cache/<sha256>, the token on stdin, never in argv


def download(url: str, dest: Path, token: str, timeout: float, size: int, digest: str) -> None:
    """GET URL into DEST, hashing as it streams; refuse past SIZE bytes at once, and a body of
    another size or digest. A refused download leaves no file."""
    command = ["curl", "-fsS", "--connect-timeout", "5", "--max-time", str(max(1, int(timeout))),
               "--max-filesize", str(size), "-H", "@-", url]
    sha, got = hashlib.sha256(), 0
    try:
        curl_proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as error:
        raise Miss(f"the store did not answer: {error}") from error
    try:
        curl_proc.stdin.write(f"Authorization: Bearer {token}\n".encode())
        curl_proc.stdin.close()
        with dest.open("wb") as sink:
            while chunk := curl_proc.stdout.read(1 << 20):
                got += len(chunk)
                if got > size:
                    raise Miss(f"the store sent more than the record's {size} bytes")
                sha.update(chunk)
                sink.write(chunk)
        status = curl_proc.wait(timeout=30)
        if status:
            raise Miss(f"the store refused (curl {status}): {curl_proc.stderr.read().decode(errors='replace').strip()[:200]}")
        if got != size or sha.hexdigest() != digest:
            raise Miss("the store's bytes do not match the record (corrupt or replaced)")
    except BaseException:
        dest.unlink(missing_ok=True)
        raise
    finally:
        if curl_proc.poll() is None:
            curl_proc.kill()
            curl_proc.wait()
        curl_proc.stdout.close()
        curl_proc.stderr.close()


def curl(args: list[str], token: str, timeout: float) -> None:
    command = ["curl", "-fsS", "--connect-timeout", "5", "--max-time", str(max(1, int(timeout))), "-H", "@-", *args]
    try:
        result = subprocess.run(command, input=f"Authorization: Bearer {token}\n", text=True,
                                capture_output=True, timeout=timeout + 5)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Miss(f"the store did not answer: {error}") from error
    if result.returncode:
        raise Miss(f"the store refused (curl {result.returncode}): {result.stderr.strip()[:200]}")


def store_url(url: str, digest: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise Miss("CMUX_NEXT_DEV_CAS_URL is not an http(s) URL")
    return f"{url.rstrip('/')}/v1/cache/{digest}"


def credentials(env: dict[str, str]) -> tuple[str, str]:
    url, token = env.get("CMUX_NEXT_DEV_CAS_URL", "").strip(), env.get("CMUX_NEXT_DEV_CAS_TOKEN", "").strip()
    if not url or not token:
        raise Miss("the shared compile cache is off (no CMUX_NEXT_DEV_CAS_URL or token)")
    return url, token


# ---- records


def check_record(manifest: dict, key: str, fields: dict[str, str], run_id: int) -> None:
    if manifest.get("schema") != SCHEMA or manifest.get("key") != key:
        raise Miss("the record is another schema or key")
    if manifest.get("run_id") != run_id:
        raise Miss("the record names another run than the one that uploaded it")
    if manifest.get("key_fields") != fields:
        raise Miss("the record's key fields differ from this build's")
    if not reuse.DIGEST.match(str(manifest.get("blob_sha256", ""))):
        raise Miss("the record has no blob digest")
    size = manifest.get("blob_bytes")
    if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_BLOB_BYTES:
        raise Miss(f"the record's blob size {size!r} is out of range")
    cas = manifest.get("cas_bytes")
    if not isinstance(cas, int) or isinstance(cas, bool) or not 0 < cas <= CAS_MAX_BYTES:
        raise Miss(f"the record's cache size {cas!r} is out of range")
    if not reuse.SHA.match(str(manifest.get("source_sha", ""))) or not isinstance(manifest.get("committed_at"), int):
        raise Miss("the record names no source commit")


def newer(manifest: dict, marker: dict, derived_data: Path) -> str:
    """'' when the seed should replace this host's cache, else why not."""
    if not cas_present(derived_data):
        return ""
    if marker.get("sha") == manifest["source_sha"]:
        return f"this host's cache already holds {manifest['source_sha'][:12]}"
    local = marker.get("committed_at")
    if not isinstance(local, int):
        return "this host has a cache of unknown origin; keeping it"
    if local >= manifest["committed_at"]:
        return f"this host's cache ({str(marker.get('sha', ''))[:12]}) is as new as the newest seed"
    return ""


def find_seed(api: reuse.Api, key: str, fields: dict[str, str], env: dict[str, str], marker: dict,
              derived_data: Path, scratch: Path) -> tuple[dict, int]:
    reuse.lane_guard(env, LANE)
    repository_id = env.get("GITHUB_REPOSITORY_ID", "").strip()
    if not repository_id:
        raise Miss("GITHUB_REPOSITORY_ID is not set, so no record can be trusted")
    query = urllib.parse.urlencode({"name": RECORD_PREFIX + key, "per_page": 30})
    records = reuse.trusted_records(api.json(f"actions/artifacts?{query}").get("artifacts", []), key,
                                    repository_id, LANE)
    if not records:
        raise Miss("no seed was recorded for this key yet")
    # Landing builds run concurrently, so upload order is not commit order: an older commit can
    # publish after a newer one. Validate every candidate in the window, then pick by commit time.
    reasons, valid = [], []
    for item in records[:CANDIDATES]:
        try:
            run_id = int(item["workflow_run"]["id"])
            if str(run_id) == env.get("GITHUB_RUN_ID"):
                raise Miss("this run's own record")
            reuse.check_run(api.json(f"actions/runs/{run_id}"), env["GITHUB_REPOSITORY"], LANE)
            jobs = api.json(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100").get("jobs", [])
            reuse.check_producer(jobs, run_id, LANE)
            manifest = reuse.read_record(api, item, scratch)
            check_record(manifest, key, fields, run_id)
            valid.append((manifest, run_id))
        except (reuse.Miss, KeyError, TypeError, ValueError) as why:
            reasons.append(f"run {(item.get('workflow_run') or {}).get('id')}: {why}")
    if not valid:
        raise Miss("; ".join(reasons))
    # The newest commit wins; between seeds of one commit, the later run.
    manifest, run_id = max(valid, key=lambda pair: (pair[0]["committed_at"], pair[1]))
    why = newer(manifest, marker, derived_data)
    if why:
        raise NotNewer(f"run {run_id}: {why}")
    return manifest, run_id


# ---- commands


def cmd_pack(args: argparse.Namespace, env: dict[str, str]) -> int:
    derived_data, build_root = Path(args.derived_data), Path(args.build_root)
    sha = run(["git", "-C", str(build_root), "rev-parse", "HEAD"])
    committed = run(["git", "-C", str(build_root), "log", "-1", "--format=%ct"])
    if not reuse.SHA.match(sha) or not committed.isdigit():
        note("no commit in the host tree; no marker, no pack")
        return 0
    origin = {"sha": sha, "committed_at": int(committed), "built_at": int(time.time())}
    if not cas_present(derived_data):
        Path(args.marker).unlink(missing_ok=True)
        note("the host has no compilation cache after this build; no marker, no pack")
        return 0
    write_json(Path(args.marker), origin)
    if not args.out:
        return 0
    try:
        size = tree_bytes(derived_data / CAS_DIR)
        if size > CAS_MAX_BYTES:
            raise Miss(f"the cache is {size} bytes, over the {CAS_MAX_BYTES} the DEV compile keeps")
        fields = key_fields(derived_data, build_root, env)
        key = key_of(fields)
        started = time.monotonic()
        blob_bytes, digest = pack(derived_data, Path(args.out), env)
        write_json(Path(args.out) / "pack.json", {
            "schema": SCHEMA, "key": key, "key_fields": fields, "blob_sha256": digest, "blob_bytes": blob_bytes,
            "cas_bytes": size, "source_sha": sha, "committed_at": int(committed)})
        note(f"packed {size} cache bytes into {blob_bytes} ({digest[:16]}) in {time.monotonic() - started:.1f} s")
    except (Miss, OSError) as why:
        shutil.rmtree(args.out, ignore_errors=True)
        note(f"no seed packed: {why}")
    return 0


def cmd_publish(args: argparse.Namespace, env: dict[str, str]) -> int:
    pack_dir = Path(args.pack)
    info = read_json(pack_dir / "pack.json")
    try:
        url, token = credentials(env)
        reuse.lane_guard(env, LANE)
        blob = pack_dir / BLOB
        if info.get("schema") != SCHEMA or not blob.is_file() or blob.stat().st_size != info.get("blob_bytes"):
            raise Miss("no complete pack to publish")
        started = time.monotonic()
        curl(["-T", str(blob), store_url(url, info["blob_sha256"])], token, args.timeout)
        manifest = {key: info[key] for key in ("key", "key_fields", "blob_sha256", "blob_bytes", "cas_bytes",
                                                "source_sha", "committed_at")}
        manifest.update(schema=SCHEMA, recipe=RECIPE, run_id=int(env["GITHUB_RUN_ID"]),
                        run_attempt=int(env.get("GITHUB_RUN_ATTEMPT", "1")),
                        recorded_at=dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"))
        write_json(Path(args.out) / "manifest.json", manifest)
        note(f"published {info['blob_bytes']} bytes in {time.monotonic() - started:.1f} s")
        print(f"record={RECORD_PREFIX}{info['key']}")
    except (Miss, OSError, KeyError, ValueError) as why:
        note(f"not published: {why}")
    return 0


def cmd_restore(args: argparse.Namespace, env: dict[str, str]) -> int:
    derived_data, build_root, marker_path = Path(args.derived_data), Path(args.build_root), Path(args.marker)
    started = time.monotonic()
    try:
        url, token = credentials(env)
        gh_token = env.get("GH_TOKEN", "")
        if not gh_token:
            raise Miss("no token to read the seed records with")
        fields = key_fields(derived_data, build_root, env)
        key = key_of(fields)
        marker = read_json(marker_path)
        api = reuse.Api(gh_token, env.get("GITHUB_REPOSITORY", ""), env.get("GITHUB_API_URL", "https://api.github.com"),
                        started + args.timeout)
        scratch = Path(args.scratch)
        shutil.rmtree(scratch, ignore_errors=True)
        scratch.mkdir(parents=True)
        try:
            manifest, run_id = find_seed(api, key, fields, env, marker, derived_data, scratch)
            blob = scratch / BLOB
            download(store_url(url, manifest["blob_sha256"]), blob, token, api.left(),
                     manifest["blob_bytes"], manifest["blob_sha256"])
            fetched = time.monotonic() - started
            extract(blob, derived_data, env, min(manifest["cas_bytes"] + EXTRACT_SLACK_BYTES, CAS_MAX_BYTES))
            write_json(marker_path, {"sha": manifest["source_sha"], "committed_at": manifest["committed_at"],
                                     "seeded_from_run": run_id, "built_at": int(time.time())})
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        line = (f"installed the seed of {manifest['source_sha'][:12]} (run {run_id}, {manifest['blob_bytes']} bytes) "
                f"in {time.monotonic() - started:.1f} s ({fetched:.1f} s fetching)")
        print(f"compilation cache seed: {manifest['source_sha']}")
    except (reuse.Miss, OSError, KeyError, ValueError) as why:
        line = f"no seed installed: {' '.join(str(why).split())[:400]}"
    except Exception as error:  # noqa: BLE001 - a seed bug must never fail the compile
        line = f"no seed installed: {type(error).__name__}: {error}"[:400]
    note(line)
    if env.get("GITHUB_STEP_SUMMARY"):
        try:
            with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
                stream.write(f"DEV compile cache seed: {line}\n")
        except OSError:
            pass
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("pack", "restore", "key"):
        p = sub.add_parser(name)
        p.add_argument("--derived-data", required=True)
        p.add_argument("--build-root", required=True)
        if name != "key":
            p.add_argument("--marker", required=True, help="the host's origin marker (HOST_ROOT/cas-origin.json)")
        if name == "pack":
            p.add_argument("--out", default="", help="pack the cache here (else only the marker)")
        if name == "restore":
            p.add_argument("--scratch", required=True)
            p.add_argument("--timeout", type=float, default=240)
    pub = sub.add_parser("publish")
    pub.add_argument("--pack", required=True)
    pub.add_argument("--out", required=True)
    pub.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args(argv)
    env = dict(os.environ)
    if args.command == "key":
        fields = key_fields(Path(args.derived_data), Path(args.build_root), env)
        print(json.dumps({"key": key_of(fields), "fields": fields}, indent=2, sort_keys=True))
        return 0
    return {"pack": cmd_pack, "publish": cmd_publish, "restore": cmd_restore}[args.command](args, env)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Seed SwiftPM's binary-artifact cache with curl before a Linux `swift build|test`.

Linux SwiftPM (Swift 6.2 and 6.3) downloads a package's binary targets with FoundationNetworking, which
crashes (signal 4, `try!` in EasyHandle.swift:312, libcurl code 43) when several redirected downloads run at
once: swiftlang/swift-corelibs-foundation#5445. GitHub release URLs always redirect, and
Packages/macOS/CmuxNext pulls 12 of them, so every Linux `swift test` of it died in "Downloading binary
artifact" before compiling anything.

SwiftPM copies an artifact from its shared cache when the cache holds a file named after the URL
(`<cache>/artifacts/<url mangled to a C99 identifier>`, Workspace+BinaryArtifacts.swift) and checks that
copy against the manifest's checksum as it would a download. This script finds every zip binary target the
package graph declares, downloads each once with curl (which follows redirects fine) into a store keyed by
its SHA-256 checksum, checks the checksum, and links the file in at SwiftPM's cache name. SwiftPM then
downloads nothing.

Which artifacts: the package's own manifest and every local path dependency, evaluated with `swift package
dump-package` (manifests build URLs at evaluation time, so a text scan would miss them), plus every remote pin
in the root Package.resolved, whose manifests are read at the pinned revision with a one-commit, blob-less git
fetch. A pin's result is kept in the store by location and revision (a revision never changes), so a warm run
does not touch the network.

Trust: `dump-package` evaluates the snapshot's own manifests, which the command evaluates a moment later in
the same job anyway (contents: read, no secrets), so this adds no reach; the store only ever serves a file
whose SHA-256 matches the manifest that asks for it.

Fails soft: a manifest that does not evaluate, or an artifact that does not download, is reported with a
::warning:: and left for SwiftPM to fetch itself. A checksum that does not match the manifest is never cached.

    swiftpm_prefetch_binary_artifacts.py --store DIR (--package-path PATH | --command CMD [--directory DIR])

--command takes the shell command fast checks runs: it seeds only for `swift build|test` (or swift-build,
swift-test), at its --package-path (else --directory), and does nothing for any other command.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SWIFTPM_VERBS = ("build", "test")
SWIFTPM_TOOLS = ("swift-build", "swift-test")
COMMAND_PREFIXES = ("env", "exec", "time", "command", "nice")
SWIFTPM_INFO = ("-h", "-help", "--version", "--show-bin-path")
CHECKSUM = re.compile(r"[0-9a-f]{64}")
MANIFEST = re.compile(r"Package(@swift-[0-9.]+)?\.swift")
PIN_CACHE_VERSION = 1


def warn(message: str) -> None:
    print(f"::warning::swiftpm prefetch: {message}", flush=True)


def say(message: str) -> None:
    print(f"swiftpm prefetch: {message}", flush=True)


def command_env(command: str) -> dict[str, str]:
    """The NAME=VALUE assignments before the SwiftPM word of `command` (after an optional `env`): a manifest
    that reads one (CMUX_TERMINAL_CLIENT_MODEL_ONLY) is evaluated as the command will evaluate it."""
    try:
        words = shlex.split(command)
    except ValueError:
        return {}
    found = {}
    for word in words:
        if word in COMMAND_PREFIXES:
            continue
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", word)
        if not match:
            break
        found[match.group(1)] = match.group(2)
    return found


def command_cache_path(command: str, directory: str = ".") -> str | None:
    """The --cache-path a `swift build|test` command passes, resolved against `directory`, or None."""
    try:
        words = shlex.split(command)
    except ValueError:
        return None
    if "--" in words:
        words = words[:words.index("--")]
    found = None
    for j, word in enumerate(words):
        if word == "--cache-path" and j + 1 < len(words):
            found = words[j + 1]
        elif word.startswith("--cache-path="):
            found = word.split("=", 1)[1]
    if found is None:
        return None
    found = os.path.expanduser(found)
    return found if os.path.isabs(found) else os.path.abspath(os.path.join(directory or ".", found))


def package_paths(command: str, directory: str = ".") -> list[str]:
    """The package directories `command` builds when it is `swift build|test` (or swift-build|swift-test),
    possibly after env assignments or a wrapper word; [] for anything else, or a command shlex cannot read.
    Only the first command of a `&&`/`;` chain is read."""
    try:
        words = shlex.split(command)
    except ValueError:
        return []
    for stop, word in enumerate(words):
        if word in ("&&", "||", ";", "|"):
            words = words[:stop]
            break
    i = 0
    while i < len(words) and (words[i] in COMMAND_PREFIXES or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[i])):
        i += 1
    if i >= len(words):
        return []
    name, rest = os.path.basename(words[i]), words[i + 1:]
    if name == "swift" and rest and rest[0] in SWIFTPM_VERBS:
        rest = rest[1:]
    elif name not in SWIFTPM_TOOLS:
        return []
    options = rest[: rest.index("--")] if "--" in rest else rest
    if any(option in SWIFTPM_INFO or option.startswith("--help") for option in options):
        return []
    package = "."
    for j, option in enumerate(options):
        if option == "--package-path" and j + 1 < len(options):
            package = options[j + 1]
        elif option.startswith("--package-path="):
            package = option.split("=", 1)[1]
    return [os.path.normpath(os.path.join(directory or ".", package))]


def swiftpm_cache_key(url: str) -> str:
    """The file name SwiftPM's shared artifact cache gives `url`: TSCUtility's
    String.spm_mangledToC99ExtendedIdentifier, which keeps A-Z, a-z, 0-9 and `_`, writes `_` for every other
    ASCII character, and writes `_` over a leading digit. Its non-ASCII table is long, and release URLs are
    ASCII (percent-encoded), so a non-ASCII URL is refused rather than guessed."""
    if not url.isascii():
        raise ValueError(f"{url} is not ASCII")
    mangled = "".join(char if char == "_" or char.isalnum() else "_" for char in url)
    return "_" + mangled[1:] if mangled[:1].isdigit() else mangled


def swiftpm_artifact_cache(env=os.environ, cache_path: str | None = None) -> Path:
    """SwiftPM's shared binary-artifact cache on Linux: <--cache-path>/artifacts when the command passes one,
    else FileManager's caches directory ($XDG_CACHE_HOME, else ~/.cache) / org.swift.swiftpm / artifacts."""
    if cache_path:
        return Path(os.path.expanduser(cache_path)) / "artifacts"
    caches = env.get("XDG_CACHE_HOME") or os.path.join(env.get("HOME") or os.path.expanduser("~"), ".cache")
    return Path(caches) / "org.swift.swiftpm" / "artifacts"


def binary_artifacts(dump: dict) -> list[tuple[str, str]]:
    """(url, checksum) of each remote zip binary target in a dump-package JSON."""
    found = []
    for target in dump.get("targets") or []:
        if target.get("type") != "binary":
            continue
        url, checksum = target.get("url"), (target.get("checksum") or "").lower()
        if url and url.lower().endswith(".zip") and CHECKSUM.fullmatch(checksum):
            found.append((url, checksum))
    return found


def local_dependencies(dump: dict, package: Path) -> list[Path]:
    """The path dependencies a dump-package JSON declares, as absolute directories. Swift 6.2's dump-package
    writes `{"fileSystem": [{"identity": ..., "path": ...}]}` (PackageDependency's enum coding; run
    41076235054 seeded WebRTC and GhosttyNextKit, which only local packages declare); a flat
    `{"kind": "fileSystem", "location"|"path": ...}` is read too, should a later SwiftPM write that."""
    found = []
    for dependency in dump.get("dependencies") or []:
        if not isinstance(dependency, dict):
            continue
        entries = dependency.get("fileSystem")
        if not isinstance(entries, list):
            entries = [dependency] if dependency.get("kind") == "fileSystem" else []
        for entry in entries:
            path = (entry.get("path") or entry.get("location")) if isinstance(entry, dict) else None
            if isinstance(path, str) and path:
                found.append((package / path).resolve())
    return found


def remote_pins(package: Path) -> list[tuple[str, str]]:
    """(location, revision) of each remote source-control pin in the package's Package.resolved."""
    resolved = package / "Package.resolved"
    if not resolved.is_file():
        return []
    data = json.loads(resolved.read_text())
    pins = data.get("pins") or (data.get("object") or {}).get("pins") or []
    found = []
    for pin in pins:
        location = pin.get("location") or pin.get("repositoryURL")
        revision = (pin.get("state") or {}).get("revision")
        if location and revision and pin.get("kind", "remoteSourceControl") == "remoteSourceControl":
            found.append((location, revision))
    return found


def dump_package(path: Path, swift: str = "swift", env: dict[str, str] | None = None) -> dict:
    done = subprocess.run([swift, "package", "dump-package", "--package-path", str(path)],
                          capture_output=True, text=True, timeout=600, env={**os.environ, **(env or {})})
    if done.returncode != 0:
        raise RuntimeError(f"dump-package {path} exited {done.returncode}: {done.stderr.strip()[-400:]}")
    return json.loads(done.stdout)


def pin_manifests(location: str, revision: str, into: Path) -> None:
    """Write the pin's root Package*.swift files at `revision` into `into` (one-commit, blob-less fetch)."""
    git = ["git", "-C", str(into)]
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    subprocess.run(git + ["init", "-q"], check=True, env=env, timeout=60)
    subprocess.run(git + ["fetch", "-q", "--depth=1", "--filter=blob:none", "--no-tags", location, revision],
                   check=True, env=env, timeout=600, capture_output=True)
    names = subprocess.run(git + ["ls-tree", "--name-only", "FETCH_HEAD"], check=True, env=env, timeout=120,
                           capture_output=True, text=True).stdout.split()
    manifests = [name for name in names if MANIFEST.fullmatch(name)]
    if "Package.swift" not in manifests:
        raise RuntimeError(f"{location}@{revision} has no Package.swift")
    for name in manifests:
        body = subprocess.run(git + ["show", f"FETCH_HEAD:{name}"], check=True, env=env, timeout=300,
                              capture_output=True).stdout
        (into / name).write_bytes(body)


def pin_artifacts(location: str, revision: str, store: Path, swift: str = "swift") -> list[tuple[str, str]]:
    """The pin's binary artifacts, from the store when an earlier run evaluated this location@revision."""
    record = store / "pins" / f"{hashlib.sha256(f'{PIN_CACHE_VERSION} {location} {revision}'.encode()).hexdigest()}.json"
    if record.is_file():
        try:
            return [tuple(item) for item in json.loads(record.read_text())["artifacts"]]
        except (ValueError, KeyError, TypeError):
            pass
    with tempfile.TemporaryDirectory(prefix="swiftpm-pin-") as scratch:
        pin_manifests(location, revision, Path(scratch))
        found = binary_artifacts(dump_package(Path(scratch), swift))
    record.parent.mkdir(parents=True, exist_ok=True)
    tmp = record.with_suffix(".tmp")
    tmp.write_text(json.dumps({"location": location, "revision": revision, "artifacts": found}))
    tmp.replace(record)
    return found


def graph_artifacts(root: Path, store: Path, swift: str = "swift", env: dict[str, str] | None = None,
                    jobs: int = 8) -> list[tuple[str, str]]:
    """Every remote zip binary target of root's package graph: its local packages and its pins. Pins are
    evaluated without `env`: a dependency's manifest at a fixed revision does not read cmux's variables."""
    found: dict[str, str] = {}
    seen: set[Path] = set()
    frontier = [root.resolve()]
    try:
        resolved = remote_pins(root)
    except (OSError, ValueError, AttributeError) as error:
        warn(f"skipped {root}/Package.resolved: {error}")
        resolved = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        pins = {pool.submit(pin_artifacts, location, revision, store, swift): location
                for location, revision in resolved}
        while frontier:
            batch = [path for path in dict.fromkeys(frontier) if path not in seen]
            seen.update(batch)
            frontier = []
            for path, future in [(path, pool.submit(dump_package, path, swift, env)) for path in batch]:
                try:
                    dump = future.result()
                except Exception as error:  # noqa: BLE001 - reported, and SwiftPM fetches what is missed
                    warn(f"skipped {path}: {error}")
                    continue
                found.update(binary_artifacts(dump))
                frontier.extend(local_dependencies(dump, path))
        for future, location in pins.items():
            try:
                found.update(future.result())
            except Exception as error:  # noqa: BLE001
                warn(f"skipped pin {location}: {error}")
    return sorted(found.items())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def curl_download(url: str, destination: Path) -> None:
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4",
                    "--retry-all-errors", "--connect-timeout", "30", "--output", str(destination), url],
                   check=True, timeout=1800)


def stored_artifact(url: str, checksum: str, store: Path, download=curl_download) -> Path:
    """The store's file for `checksum`, downloaded from `url` when missing; ValueError on a mismatch."""
    blob = store / "sha256" / f"{checksum}.zip"
    if blob.is_file():
        if sha256(blob) == checksum:
            return blob
        blob.unlink()
    blob.parent.mkdir(parents=True, exist_ok=True)
    partial = blob.with_name(f".{checksum}.{os.getpid()}.partial")
    try:
        download(url, partial)
        actual = sha256(partial)
        if actual != checksum:
            raise ValueError(f"{url} has checksum {actual}, the manifest says {checksum}")
        partial.replace(blob)
    finally:
        partial.unlink(missing_ok=True)
    return blob


def link_into_cache(blob: Path, cache: Path, url: str) -> Path:
    """Put `blob` at SwiftPM's cache name for `url` (a hard link when the store shares its file system)."""
    cache.mkdir(parents=True, exist_ok=True)
    entry = cache / swiftpm_cache_key(url)
    if entry.is_file() and not entry.is_symlink() and entry.stat().st_size == blob.stat().st_size \
            and os.path.samefile(entry, blob):
        return entry
    tmp = entry.with_name(f".{entry.name}.{os.getpid()}.tmp")
    tmp.unlink(missing_ok=True)
    try:
        os.link(blob, tmp)
    except OSError:
        shutil.copyfile(blob, tmp)
    tmp.replace(entry)
    return entry


def seed(packages: list[Path], store: Path, cache: Path, swift: str = "swift", download=curl_download,
         collect=graph_artifacts, env: dict[str, str] | None = None) -> int:
    """Seed the cache for every package; returns how many artifacts did not make it (warned, not fatal)."""
    artifacts: dict[str, str] = {}
    for package in packages:
        if not (package / "Package.swift").is_file():
            say(f"{package} has no Package.swift; nothing to seed")
            continue
        try:
            artifacts.update(collect(package, store, swift, env))
        except Exception as error:  # noqa: BLE001 - SwiftPM fetches whatever is not seeded
            warn(f"could not list {package}'s binary artifacts: {error}")
    missed = 0
    for url, checksum in sorted(artifacts.items()):
        try:
            entry = link_into_cache(stored_artifact(url, checksum, store, download), cache, url)
            say(f"cached {url} ({checksum[:12]}) at {entry}")
        except Exception as error:  # noqa: BLE001 - SwiftPM downloads it as before
            missed += 1
            warn(f"left {url} for SwiftPM to download: {error}")
    say(f"{len(artifacts) - missed} of {len(artifacts)} binary artifacts are in {cache}")
    return missed


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--store", required=True, type=Path, help="persistent store (checksum-keyed)")
    parser.add_argument("--package-path", action="append", default=[])
    parser.add_argument("--command", help="the shell command about to run; seeds only for swift build|test")
    parser.add_argument("--directory", default=".", help="the directory --command runs in")
    parser.add_argument("--cache", type=Path, help="SwiftPM artifact cache (default: SwiftPM's own)")
    parser.add_argument("--swift", default=os.environ.get("SWIFT", "swift"))
    args = parser.parse_args(argv)
    paths = list(args.package_path)
    env: dict[str, str] = {}
    cache_path = None
    if args.command is not None:
        paths += package_paths(args.command, args.directory)
        env = command_env(args.command)
        cache_path = command_cache_path(args.command, args.directory)
    if not paths:
        return 0
    if shutil.which(args.swift) is None:
        warn(f"{args.swift} is not on PATH; nothing seeded")
        return 0
    try:
        # The cache SwiftPM will read: the command's own HOME/XDG_CACHE_HOME assignments and --cache-path win.
        cache = args.cache or swiftpm_artifact_cache({**os.environ, **env}, cache_path)
        seed([Path(path) for path in paths], args.store, cache, args.swift, env=env)
    except Exception as error:  # noqa: BLE001 - never fail the run: SwiftPM downloads what is missing
        warn(f"stopped early: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

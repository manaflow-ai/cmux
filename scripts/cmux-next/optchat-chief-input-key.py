#!/usr/bin/env python3
"""Print a key for everything an optchat-chief release build reads.

build-optchat-chief.sh keys its cache by commit, so a nightly-next build
rebuilt the Chief on every push (about 90 s of the warm build slot) although
most pushes change none of its sources. With CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1
it keys the cache by this instead. The key covers:

- every local crate the binary links (the path-dependency closure of
  Native/OptChat/optchat-chief, through `workspace = true` entries too), as
  its committed tree plus the content of any file that differs from it
  (the inspector page is committed; build-web-bundles.sh only checks it);
- the Cargo.toml of each workspace those crates inherit from, and every
  .cargo/config(.toml) cargo reads from the crate or those workspaces;
- every file those crates compile in with include_str!/include_bytes! from
  outside them (the Chief's schemas/chief-profile tool specs);
- the build scripts, the Rust toolchain, the architectures, the Xcode
  developer dir, SDK and clang, and the environment cargo, cc or build.rs read.

Dev-dependencies are left out: a release build of the binary does not link
them. Exits 3, printing nothing, when the inputs cannot be read (no git, an
unparsable manifest); the caller then keys by commit as before.

Usage: optchat-chief-input-key.py --archs "arm64 x86_64" --toolchain CHANNEL [--portable|--environment]
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import posixpath
import re
import subprocess
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11: key by commit, as before.
    print("optchat-chief-input-key: python3 has no tomllib (3.11+); keying by commit", file=sys.stderr)
    sys.exit(3)

ROOT = Path(__file__).resolve().parents[2]
CRATE = "Native/OptChat/optchat-chief"
SCRIPTS = ("scripts/cmux-next/build-optchat-chief.sh", "scripts/cmux-next/optchat-chief-input-key.py")
# Variables cargo, rustc or build.rs read that change the binary. The build
# script sets OPTCHAT_BUILD_COMMIT and OPTCHAT_REQUIRE_INSPECTOR_PAGE itself.
ENV_EXACT = ("CC", "CXX", "AR", "CFLAGS", "CXXFLAGS", "LDFLAGS", "CPPFLAGS", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC", "RUSTC_WRAPPER", "MACOSX_DEPLOYMENT_TARGET", "SDKROOT", "DEVELOPER_DIR")
ENV_PREFIXES = ("CC_", "CXX_", "AR_", "CFLAGS_", "CXXFLAGS_", "TARGET_CC", "TARGET_CFLAGS", "CARGO_PROFILE_", "CARGO_BUILD_", "CARGO_TARGET_AARCH64_APPLE_DARWIN_", "CARGO_TARGET_X86_64_APPLE_DARWIN_")
ENV_SKIP_PREFIX = ("OPTCHAT_BUILD_COMMIT", "OPTCHAT_REQUIRE_INSPECTOR_PAGE")
# The committed inspector page is left out of the portable key, which keys its
# generator's sources instead, so a change to the page's inputs still misses.
# The exact Mac key hashes the page bytes themselves (environment_lines).
PORTABLE_PATHS = (
    "webviews/src/optchat-inspector",
    "webviews/package.json",
    "webviews/bun.lock",
    "scripts/check-webviews-bun-version.sh",
    "scripts/cmux-next/build-optchat-inspector-web.sh",
)
GENERATED_INSPECTOR = "Native/OptChat/optchat-chief/inspector/index.html"


class InputError(Exception):
    pass


def git(*args: str) -> str:
    try:
        return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise InputError(f"git {' '.join(args)}: {error}") from None


def manifest(directory: str) -> dict:
    path = ROOT / directory / "Cargo.toml"
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise InputError(f"{path}: {error}") from None


def workspace_root(directory: str) -> str | None:
    """The nearest strict ancestor whose Cargo.toml declares [workspace]."""
    parts = directory.split("/")
    for end in range(len(parts) - 1, 0, -1):
        candidate = "/".join(parts[:end])
        path = ROOT / candidate / "Cargo.toml"
        if path.is_file() and "workspace" in manifest(candidate):
            return candidate
    return None


def dependency_tables(data: dict) -> list[dict]:
    tables = [data.get("dependencies", {}), data.get("build-dependencies", {})]
    for target in data.get("target", {}).values():
        tables += [target.get("dependencies", {}), target.get("build-dependencies", {})]
    return tables


def path_closure() -> tuple[list[str], list[str]]:
    """Local crates the binary builds from, and the workspace roots they inherit from."""
    crates: set[str] = set()
    workspaces: set[str] = set()
    stack = [CRATE]
    while stack:
        directory = stack.pop()
        if directory in crates:
            continue
        crates.add(directory)
        data = manifest(directory)
        root = None if "workspace" in data else workspace_root(directory)
        inherited: dict = {}
        if root is not None:
            workspaces.add(root)
            inherited = manifest(root).get("workspace", {}).get("dependencies", {})
        tables = dependency_tables(data)
        if directory == CRATE:
            # [patch.<registry>] and [replace] apply from the root workspace only.
            tables += list(data.get("patch", {}).values()) + [data.get("replace", {})]
        for table in tables:
            for name, spec in table.items():
                if not isinstance(spec, dict):
                    continue
                base, path = directory, spec.get("path")
                if path is None and spec.get("workspace") is True and root is not None:
                    entry = inherited.get(spec.get("package", name), inherited.get(name))
                    if isinstance(entry, dict):
                        base, path = root, entry.get("path")
                if path is not None:
                    resolved = posixpath.normpath(posixpath.join(base, path))
                    if resolved.startswith("../") or not (ROOT / resolved / "Cargo.toml").is_file():
                        raise InputError(f"{directory}: path dependency {name} -> {resolved} is not a crate in this checkout")
                    stack.append(resolved)
    return sorted(crates), sorted(workspaces)


def cargo_configs(directories: list[str]) -> list[str]:
    """Every .cargo/config(.toml) cargo reads from these directories upward."""
    found: set[str] = set()
    for directory in directories:
        parts = directory.split("/")
        for end in range(len(parts), -1, -1):
            for name in ("config", "config.toml"):
                candidate = posixpath.join(*parts[:end], ".cargo", name) if end else posixpath.join(".cargo", name)
                if (ROOT / candidate).is_file():
                    found.add(candidate)
    return sorted(found)


def file_digest(relative: str) -> str:
    path = ROOT / relative
    if not path.exists():
        return "absent"
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_state(directory: str, *, omit: set[str] | None = None) -> list[str]:
    """The committed tree, plus every file the working tree changed under it."""
    lines = [f"tree {directory} {git('rev-parse', f'HEAD:{directory}').strip()}"]
    # -z keeps odd file names intact; ignored files (target/) are not inputs.
    status = git("status", "--porcelain=v1", "-z", "--untracked-files=all", "--", directory)
    entries = status.split("\0")
    index = 0
    changed: set[str] = set()
    while index < len(entries):
        entry = entries[index]
        index += 1
        if not entry:
            continue
        code, path = entry[:2], entry[3:]
        if code[0] in "RC":
            index += 1  # the rename's source follows; its content is gone from the tree
        changed.add(path)
    for path in sorted(changed):
        if omit and path in omit:
            continue
        lines.append(f"changed {path} {file_digest(path)}")
    return lines


def portable_path_state(path: str) -> list[str]:
    """Hash a portable source path without requiring it to be a crate."""
    target = ROOT / path
    if target.is_dir():
        try:
            tree = git("rev-parse", f"HEAD:{path}").strip()
        except InputError:
            tree = "absent"
        lines = [f"portable-tree {path} {tree}"]
        for child in sorted(target.rglob("*")):
            if child.is_file() and ".git" not in child.parts:
                rel = child.relative_to(ROOT).as_posix()
                lines.append(f"portable-file {rel} {file_digest(rel)}")
        return lines
    return [f"portable-file {path} {file_digest(path)}"]


# include_str!/include_bytes! of a literal path, or of
# concat!(env!("CARGO_MANIFEST_DIR"), "/path"). Any other include form cannot
# be resolved here, so it fails the key and the commit keys the cache.
INCLUDE = re.compile(r'\binclude(?:_str|_bytes)?!\s*\(')
INCLUDE_LITERAL = re.compile(r'\binclude(?:_str|_bytes)?!\s*\(\s*"([^"]+)"\s*\)')
# OUT_DIR is the crate's own build.rs output, already keyed through its inputs.
INCLUDE_OUT_DIR = re.compile(r'\binclude(?:_str|_bytes)?!\s*\(\s*concat!\s*\(\s*env!\s*\(\s*"OUT_DIR"\s*\)')
INCLUDE_MANIFEST = re.compile(r'\binclude(?:_str|_bytes)?!\s*\(\s*concat!\s*\(\s*env!\s*\(\s*"CARGO_MANIFEST_DIR"\s*\)\s*,\s*"([^"]+)"\s*\)\s*\)')


def outside_includes(crates: list[str]) -> list[str]:
    """Files compiled in with include_str!/include_bytes! from outside the hashed crates."""
    found: set[str] = set()
    for crate in crates:
        for source in sorted((ROOT / crate).rglob("*.rs")):
            relative_parts = source.relative_to(ROOT / crate).parts
            # Test, bench and example targets are not linked into the binary.
            if relative_parts and relative_parts[0] in ("target", "tests", "benches", "examples"):
                continue
            text = source.read_text(encoding="utf-8", errors="replace")
            total = len(INCLUDE.findall(text))
            resolved = [posixpath.normpath(posixpath.join(posixpath.dirname(source.relative_to(ROOT).as_posix()), path))
                        for path in INCLUDE_LITERAL.findall(text)]
            resolved += [posixpath.normpath(posixpath.join(crate, path.lstrip("/"))) for path in INCLUDE_MANIFEST.findall(text)]
            if len(resolved) + len(INCLUDE_OUT_DIR.findall(text)) != total:
                raise InputError(f"{source.relative_to(ROOT)}: an include_str!/include_bytes! this key cannot resolve")
            for path in resolved:
                if path.startswith("../"):
                    raise InputError(f"{source.relative_to(ROOT)}: includes {path} outside the checkout")
                if not any(path == crate_dir or path.startswith(crate_dir + "/") for crate_dir in crates):
                    found.add(path)
    return sorted(found)


def sdk_identity() -> str:
    try:
        return subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], check=True,
                              capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "none"


def environment_lines(archs: str, toolchain: str) -> list[str]:
    """Return the Mac-local identity which must match a cached binary."""
    lines = [f"archs {archs}", f"toolchain {toolchain}", f"sdk {sdk_identity()}"]
    try:
        clang = subprocess.run(["xcrun", "clang", "--version"], check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        clang = "none"
    lines.append(f"clang {clang}")
    for label, command in (
        ("rustc", ["rustup", "run", toolchain, "rustc", "-Vv"]),
        ("cargo", ["rustup", "run", toolchain, "cargo", "-V"]),
        ("macos", ["sw_vers", "-productVersion"]),
        ("macos-build", ["sw_vers", "-buildVersion"]),
        ("xcode", ["xcodebuild", "-version"]),
        ("developer-dir", ["xcode-select", "-p"]),
    ):
        try:
            value = subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            value = "none"
        lines.append(f"{label} {value}")
    # The bytes build.rs compiles in. They are the checkout's: the page is
    # committed and no nightly step rewrites it in-tree (build-web-bundles.sh
    # and its --from install only compare it), so hashing it before the web
    # bundle step records what the binary embeds. tests/test_nightly_chief_cache_repair.py
    # keeps that true.
    lines.append(f"inspector {file_digest(GENERATED_INSPECTOR)}")
    for name in sorted(os.environ):
        if name.startswith(ENV_SKIP_PREFIX):
            continue
        if name in ENV_EXACT or name.startswith(ENV_PREFIXES):
            lines.append(f"env {name}={os.environ[name]}")
    try:
        crates, workspaces = path_closure()
        for config in cargo_configs(crates + workspaces):
            lines.append(f"cargo-config {config} {file_digest(config)}")
        cargo_home = Path(os.environ.get("CARGO_HOME") or Path.home() / ".cargo")
        for name in ("config", "config.toml"):
            path = cargo_home / name
            if path.is_file():
                lines.append(f"cargo-home-config {name} {hashlib.sha256(path.read_bytes()).hexdigest()}")
    except InputError:
        # The main source key will report an actionable fallback; the
        # environment digest remains usable for an already resolved source.
        pass
    return lines


def environment_key(archs: str, toolchain: str) -> str:
    lines = environment_lines(archs, toolchain)
    for label in ("sdk", "clang", "rustc", "cargo", "macos", "macos-build", "xcode", "developer-dir"):
        value = next(line[len(label) + 1:] for line in lines if line.startswith(label + " "))
        if not value or value == "none":
            raise InputError(f"cannot identify {label}; remote cache reuse is unavailable")
    for parent in ROOT.parents:
        for name in ("config", "config.toml"):
            path = parent / ".cargo" / name
            if path.is_file():
                lines.append(f"ancestor-config {path} {hashlib.sha256(path.read_bytes()).hexdigest()}")
    return hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


def key(archs: str, toolchain: str, *, portable: bool = False) -> str:
    crates, workspaces = path_closure()
    lines = ["optchat-chief-inputs v2-portable" if portable else "optchat-chief-inputs v1", f"archs {archs}", f"toolchain {toolchain}"]
    if portable:
        lines.append("sdk portable")
    else:
        lines.append(f"sdk {sdk_identity()}")
    for directory in crates:
        lines += tree_state(directory, omit={GENERATED_INSPECTOR} if portable else None)
    for path in outside_includes(crates):
        lines.append(f"include {path} {file_digest(path)}")
    if portable:
        lines.append("clang portable")
    else:
        lines.append(f"clang {next(line for line in environment_lines(archs, toolchain) if line.startswith('clang '))[6:]}")
    for root in workspaces:
        lines.append(f"workspace {root}/Cargo.toml {file_digest(f'{root}/Cargo.toml')}")
    for config in cargo_configs(crates + workspaces):
        lines.append(f"cargo-config {config} {file_digest(config)}")
    cargo_home = Path(os.environ.get("CARGO_HOME") or Path.home() / ".cargo")
    if not portable:
        for name in ("config", "config.toml"):
            path = cargo_home / name
            if path.is_file():
                lines.append(f"cargo-home-config {name} {hashlib.sha256(path.read_bytes()).hexdigest()}")
    for script in SCRIPTS:
        lines.append(f"script {script} {file_digest(script)}")
    if portable:
        for path in PORTABLE_PATHS:
            lines += portable_path_state(path)
    if not portable:
        lines += [line for line in environment_lines(archs, toolchain) if line.startswith("env ")]
    if os.environ.get("CMUX_NEXT_OPTCHAT_CHIEF_KEY_DEBUG") == "1":
        print("\n".join(lines), file=sys.stderr)
    return hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--archs", required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--portable", action="store_true", help="omit Mac-local SDK and environment identity")
    parser.add_argument("--environment", action="store_true", help="print the Mac-local environment identity")
    args = parser.parse_args(argv)
    try:
        if args.portable and args.environment:
            parser.error("--portable and --environment are mutually exclusive")
        print(environment_key(args.archs, args.toolchain) if args.environment else key(args.archs, args.toolchain, portable=args.portable))
    except InputError as error:
        print(f"optchat-chief-input-key: {error}; keying by commit", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

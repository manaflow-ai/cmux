#!/usr/bin/env python3
"""Source-keyed nightly iPhone host reuse, with the compiler identity checked on the builder.

The portable key is computed at the resolved build revision before allocating a
Mac. The builder adds its actual Rust, SDK, clang and Cargo configuration to the
key. Only a digest-verified binary under that exact key skips the build.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[2]
BINARY = "cmux-mobile-host"
RECIPE = "nightly-mobile-host-v1"
# Conservative trees cover transitive path dependencies and files included by
# their build scripts. Root/ancestor Cargo configuration is included as well.
INPUTS = (
    "cmux-next-ios/rust", "cmux-tui", ".cargo", "cmux-next-ios/.cargo",
    "rust-toolchain", "rust-toolchain.toml", "scripts/cmux-next/build-mobile-host.sh",
    "scripts/ci/nightly_mobile_host_reuse.py",
)
ENV_EXACT = {"CC", "CXX", "AR", "CFLAGS", "CXXFLAGS", "LDFLAGS", "CPPFLAGS",
             "SDKROOT", "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET"}
ENV_PREFIXES = ("CARGO_", "RUST", "CC_", "CXX_", "AR_", "CFLAGS_", "CXXFLAGS_", "TARGET_")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def archs(raw: str) -> str:
    values = set(raw.replace(",", " ").split())
    if not values or values - {"arm64", "x86_64"}:
        raise ValueError(f"unsupported architectures: {raw!r}")
    return " ".join(sorted(values))


def source_key(revision: str, architectures: str) -> str:
    # ls-tree reads git objects, so the resolver need not change its checkout
    # from the candidate tip to the older resolved build revision.
    tree = run("git", "ls-tree", "-r", revision, "--", *INPUTS)
    if not tree or not run("git", "ls-tree", revision, "--", "cmux-next-ios/rust"):
        raise ValueError("the build revision has no iPhone host sources")
    return digest(f"{RECIPE}\n{archs(architectures)}\n{tree}\n".encode())


def identity(source: str, architectures: str) -> dict:
    if not re.fullmatch(r"[0-9a-f]{64}", source):
        raise ValueError("invalid source key")
    if source_key("HEAD", architectures) != source:
        raise ValueError("builder sources differ from the resolved source key")
    # Never give a modified tree a committed-source key.
    if run("git", "status", "--porcelain", "--untracked-files=all", "--", *INPUTS):
        raise ValueError("iPhone host inputs are modified")
    rust_root = ROOT / "cmux-next-ios/rust"
    channel = tomllib.loads((rust_root / "rust-toolchain.toml").read_text())["toolchain"]["channel"]
    data = {
        "recipe": RECIPE, "source": source, "archs": archs(architectures),
        "rustc": run("rustc", f"+{channel}", "-Vv", cwd=rust_root),
        "cargo": run("cargo", f"+{channel}", "-V", cwd=rust_root),
        "xcode": run("xcodebuild", "-version"),
        "macos": run("sw_vers", "-productVersion"),
        "macos_build": run("sw_vers", "-buildVersion"),
        "developer_dir": run("xcode-select", "-p"),
        "sdk": run("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "clang": run("xcrun", "clang", "--version"),
        "environment": {name: value for name, value in os.environ.items()
                        if name in ENV_EXACT or name.startswith(ENV_PREFIXES)},
        "configs": {},
    }
    # Cargo searches ancestors above the checkout too, including CARGO_HOME.
    directories = [*ROOT.parents, Path(os.environ.get("CARGO_HOME", str(Path.home() / ".cargo")))]
    for directory in directories:
        config_root = directory if directory == directories[-1] else directory / ".cargo"
        for name in ("config", "config.toml"):
            path = config_root / name
            data["configs"][str(path)] = digest(path.read_bytes()) if path.is_file() else "absent"
    return data


def identity_key(data: dict) -> str:
    return digest(json.dumps(data, sort_keys=True, separators=(",", ":")).encode())


def toolchain_key(data: dict) -> str:
    return identity_key({name: value for name, value in data.items() if name != "source"})


def reusable(cache: Path, key: str) -> bool:
    try:
        record = json.loads((cache / "manifest.json").read_text())
        binary, ref = cache / BINARY, cache / f"{BINARY}.ref"
        return (isinstance(record, dict) and record.get("key") == key and binary.is_file() and not binary.is_symlink()
                and ref.is_file() and not ref.is_symlink()
                and digest(binary.read_bytes()) == record.get("sha256")
                and digest(ref.read_bytes()) == record.get("ref_sha256"))
    except (OSError, ValueError):
        return False


def build(cache: Path, output: Path, key: str, compiler_key: str, architectures: str) -> None:
    if not all(re.fullmatch(r"[0-9a-f]{64}", value) for value in (key, compiler_key)):
        raise ValueError("invalid build key")
    if reusable(cache, key):
        print("Reusing the published iPhone host")
    else:
        cache.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        env["CMUX_NEXT_MOBILE_HOST_ARCHS"] = archs(architectures)
        # The older local binary cache lacks compiler/SDK identity. A miss must
        # not relabel a binary from that cache as having this build identity.
        env["CMUX_NEXT_MOBILE_HOST_CACHE"] = str(cache / "build-cache" / key)
        env["CMUX_NEXT_MOBILE_HOST_TARGET_DIR"] = str(ROOT / "cmux-next-ios/rust/target/nightly-reuse" / compiler_key)
        subprocess.run([str(ROOT / "scripts/cmux-next/build-mobile-host.sh"),
                        "--output", str(cache / BINARY)], check=True, env=env)
        binary, ref = cache / BINARY, cache / f"{BINARY}.ref"
        (cache / "manifest.json").write_text(json.dumps({
            "key": key, "sha256": digest(binary.read_bytes()),
            "ref_sha256": digest(ref.read_bytes()),
        }, sort_keys=True) + "\n")
        # Publish only the binary and its provenance, never compiler state.
        shutil.rmtree(cache / "build-cache")
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(cache / BINARY, output)
    shutil.copyfile(cache / f"{BINARY}.ref", output.with_name(output.name + ".ref"))
    output.chmod(0o755)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    source = sub.add_parser("source-key")
    source.add_argument("--revision", default="HEAD")
    source.add_argument("--archs", required=True)
    host = sub.add_parser("builder-key")
    host.add_argument("--source-key", required=True)
    host.add_argument("--archs", required=True)
    build_parser = sub.add_parser("build")
    build_parser.add_argument("--key", required=True)
    build_parser.add_argument("--toolchain-key", required=True)
    build_parser.add_argument("--archs", required=True)
    build_parser.add_argument("--cache", type=Path, required=True)
    build_parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "source-key":
        print(source_key(args.revision, args.archs))
    elif args.command == "builder-key":
        data = identity(args.source_key, args.archs)
        print(f"key={identity_key(data)}")
        print(f"toolchain={toolchain_key(data)}")
    else:
        build(args.cache, args.output, args.key, args.toolchain_key, args.archs)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"iPhone host reuse unavailable: {error}", file=sys.stderr)
        sys.exit(3)

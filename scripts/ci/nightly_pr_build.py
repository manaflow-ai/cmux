#!/usr/bin/env python3
"""The NIGHTLY's own app compile and Rust helper builds, on a pull request (.github/workflows/nightly-pr-build.yml).

Why: on 2026-11-25 a direct push (a3b465f1367) broke the cmux NEXT Nightly's app compile and the
NIGHTLY went over 5 hours without publishing. The pull request checks compile the app in Debug or a
plain Release; the Nightly compiles it with -DCMUX_BLOCKING_CHECKS, -Osize (hot targets at -O) and for
arm64 and x86_64, and it builds its Rust helpers in release with their own features. Code that only
those settings reject reached the Nightly first. This runs the Nightly's settings on the pull request,
advisory: no rule requires its checks.

  route --base B --rev R
                    print `swift=true|false` and `helpers=true|false`: whether the commits
                    B..R change what the app compile (SWIFT_INPUTS) or a helper (HELPER_INPUTS)
                    is built from.
  keys --rev SHA    print `keys=<json>` for $GITHUB_OUTPUT: one input key per Swift arch
                    (scripts/ci/job_input_fingerprint.py job nightly-pr-build) and one for the
                    helpers. A pass saves its key as an actions/cache entry; a later run whose
                    inputs are the same finds it and skips the build.
  helpers           cargo check --release --locked each helper the Nightly bundles, with the
                    features and profile its build script passes (HELPERS), on this host's target.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import job_input_fingerprint  # noqa: E402

ARCHS = ("arm64", "x86_64")
WORKFLOW = ".github/workflows/nightly-pr-build.yml"

# Each Rust helper the Nightly bundles (scripts/ci/nightly-steps/app-build-mobile-host.sh and
# chief-build.sh), as its build script builds it: the working directory, the cargo arguments past
# `build --locked --release --target T`, and the release profile it sets. tests/test_nightly_pr_build.py
# reads the build scripts and fails when one of these no longer matches them.
HELPERS = (
    {
        "name": "cmux-rd (Screen Sharing helper)",
        "script": "scripts/cmux-next/build-screen-sharing-helper.sh",
        "dir": "cmux-tui/crates/cmux-rd-host",
        "args": ["--no-default-features", "--features", "link computer-use", "--bin", "cmux-rd"],
        "profile": {"CARGO_PROFILE_RELEASE_LTO": "fat", "CARGO_PROFILE_RELEASE_CODEGEN_UNITS": "1",
                    "CARGO_PROFILE_RELEASE_DEBUG": "0"},
    },
    {
        "name": "cmux-mobile-host",
        "script": "scripts/cmux-next/build-mobile-host.sh",
        "dir": "cmux-next-ios/rust",
        "args": ["--package", "cmux-mobile-host", "--bin", "cmux-mobile-host"],
        "profile": {"CARGO_PROFILE_RELEASE_LTO": "fat", "CARGO_PROFILE_RELEASE_CODEGEN_UNITS": "1",
                    "CARGO_PROFILE_RELEASE_PANIC": "abort"},
    },
    {
        "name": "optchat-chief",
        "script": "scripts/cmux-next/build-optchat-chief.sh",
        "dir": "Native/OptChat/optchat-chief",
        "args": ["--bin", "optchat-chief"],
        "profile": {},
    },
)

# What the helpers compile from: their trees, the cmux-tui crates they use by path, the toolchain pins
# and this check itself. The key is these paths' object ids at the commit.
HELPER_INPUTS = (
    "cmux-tui", "cmux-next-ios/rust", "Native/OptChat", "Native/DiffSidecar", ".cargo",
    "scripts/ci/nightly_pr_build.py", WORKFLOW,
)


# What the app compile reads, as fnmatch patterns ("*" spans folders): the packages and what they
# vendor, the app resources, the Xcode pin and check-release-compile.sh with what it sources
# (cmux_next_route.MAC_RELEASE_INPUTS), and this check. Test targets never count
# (job_input_fingerprint.PRODUCT_EXCLUDES).
SWIFT_INPUTS = (
    "Packages/*", "vendor/*", "ghostty", "ghostty-next", ".gitmodules", ".xcode-version", "Resources/*",
    "scripts/cmux-next/check-release-compile.sh", "scripts/cmux-next/lib/*", "scripts/ci/xcode-pins.txt",
    "scripts/select-ci-xcode.sh", "scripts/ci/nightly_pr_build.py", "scripts/ci/job_input_fingerprint.py",
    WORKFLOW,
)


def excluded(path: str) -> bool:
    parts = path.split("/")
    return any(job_input_fingerprint.product_excluded("/".join(parts[:n])) for n in range(1, len(parts) + 1))


def swift_input(path: str) -> bool:
    if excluded(path) and path != WORKFLOW:
        return False
    return (any(fnmatch.fnmatchcase(path, pattern) for pattern in SWIFT_INPUTS)
            or job_input_fingerprint.route.mac_release_input(path))


def helper_input(path: str) -> bool:
    return any(path == root or path.startswith(root + "/") for root in HELPER_INPUTS)


def route(paths: list[str]) -> dict[str, bool]:
    return {"swift": any(map(swift_input, paths)), "helpers": any(map(helper_input, paths))}


def git(*args: str, root: Path = ROOT) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def helper_key(rev: str, root: Path = ROOT) -> str:
    ids = {}
    for path in HELPER_INPUTS:
        try:
            ids[path] = git("rev-parse", "--verify", "-q", f"{rev}:{path}", root=root)
        except subprocess.CalledProcessError:
            ids[path] = ""
    raw = json.dumps({"job": "nightly-pr-build-helpers", "inputs": ids, "helpers": HELPERS}, sort_keys=True)
    return "nightly-pr-build-helpers-" + hashlib.sha256(raw.encode()).hexdigest()


def keys(rev: str, root: Path = ROOT) -> dict[str, str]:
    out = {}
    for arch in ARCHS:
        key, _ = job_input_fingerprint.fingerprint(str(root), rev, "nightly-pr-build", [f"arch={arch}"])
        out[arch] = f"nightly-pr-build-{arch}-{key}"
    out["helpers"] = helper_key(rev, root)
    return out


def run_helpers(root: Path = ROOT) -> int:
    failed = []
    for helper in HELPERS:
        command = ["cargo", "check", "--locked", "--release", *helper["args"]]
        print(f"::group::{helper['name']}: {' '.join(command)} (in {helper['dir']})", flush=True)
        env = {**os.environ, **helper["profile"]}
        status = subprocess.run(command, cwd=root / helper["dir"], env=env).returncode
        print("::endgroup::", flush=True)
        if status != 0:
            failed.append(helper["name"])
            print(f"::error title=nightly helper build::{helper['name']} does not build the way the Nightly "
                  f"builds it ({helper['script']}): cargo exited {status}", flush=True)
    if failed:
        return 1
    print(f"OK: {len(HELPERS)} Nightly Rust helpers build in release with the Nightly's features.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("route")
    r.add_argument("--base", required=True)
    r.add_argument("--rev", default="HEAD")
    k = sub.add_parser("keys")
    k.add_argument("--rev", default="HEAD")
    sub.add_parser("helpers")
    args = parser.parse_args(argv)
    if args.command == "route":
        paths = git("diff", "--name-only", "--no-renames", args.base, args.rev).splitlines()
        for name, value in route(paths).items():
            print(f"{name}={'true' if value else 'false'}")
        return 0
    if args.command == "keys":
        print("keys=" + json.dumps(keys(args.rev), sort_keys=True, separators=(",", ":")))
        return 0
    return run_helpers()


if __name__ == "__main__":
    sys.exit(main())

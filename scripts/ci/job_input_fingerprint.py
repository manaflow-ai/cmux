#!/usr/bin/env python3
"""The inputs of a cmux-next job as one key, so a pass can be reused.

With `vars.CI_NEXT_JOB_REUSE == '1'`, cmux-next.yml's fast-tier and
fast-tier-cargo jobs look up a pass recorded under `job-pass-<job>-<key>`
(actions/cache) before they build. A hit skips the build and the tests and
names the run that passed; a job that passes records its own.

The key covers:

- the commit's full tree hash (`git rev-parse <rev>^{tree}`), so a pass is
  reused only on an identical tree: a rerun, or a re-push of the same tree;
- the blob hash of the whole .github/workflows/cmux-next.yml;
- the toolchain the workflow step names with `--extra`: Xcode (the
  `xcodebuild -version` output), the macOS version and build, arch and the
  runner pool (owned, Blacksmith or hosted) for fast-tier; the runner,
  `rustc -Vv`, `cargo -V`, the Zig version and the clang that bindgen uses for
  fast-tier-cargo; and the runner image (`image`) when the runner names one.

When a required toolchain value is missing or empty, or git cannot read the
revision, it prints no key, and the job runs as without reuse. Prints `key=` and `fingerprint=` lines for $GITHUB_OUTPUT
and the inputs on stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys

VERSION = 2  # 1 keyed a per-job file closure; no key of it may match.
WORKFLOW = ".github/workflows/cmux-next.yml"
TOOLCHAIN = {
    "fast-tier": ("xcode", "macos", "macos_build", "arch", "pool"),
    "fast-tier-cargo": ("runner", "rustc", "cargo", "zig", "clang"),
}
# Keyed when given; not every runner image sets ImageOS/ImageVersion.
OPTIONAL = ("image",)


class Unresolved(Exception):
    """The key cannot name one of the job's inputs."""


def git(root: str, *args: str) -> str:
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=True,
                          timeout=120).stdout.strip()


def fingerprint(root: str, rev: str, job: str, extra: list[str]) -> tuple[str, dict]:
    toolchain: dict[str, str] = {}
    for item in extra:
        name, sep, value = item.partition("=")
        if not sep:
            raise Unresolved(f"--extra {item!r} is not NAME=VALUE")
        toolchain[name] = " ".join(value.split())
    unknown = sorted(set(toolchain) - set(TOOLCHAIN[job]) - set(OPTIONAL))
    if unknown:
        raise Unresolved(f"unknown toolchain value {', '.join(unknown)}")
    missing = [name for name in TOOLCHAIN[job] if not toolchain.get(name)]
    if missing:
        raise Unresolved(f"no toolchain value for {', '.join(missing)}")
    try:
        tree = git(root, "rev-parse", "--verify", f"{rev}^{{tree}}")
        workflow = git(root, "rev-parse", "--verify", f"{rev}:{WORKFLOW}")
    except subprocess.CalledProcessError as error:
        raise Unresolved(error.stderr.strip() or str(error)) from error
    value = {"version": VERSION, "job": job, "tree": tree, "workflow": workflow, "toolchain": toolchain}
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode()).hexdigest(), value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("job", choices=sorted(TOOLCHAIN))
    parser.add_argument("--root", default=".")
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--extra", action="append", default=[], help="NAME=VALUE of the toolchain (repeatable)")
    args = parser.parse_args(argv)
    try:
        digest, value = fingerprint(args.root, args.rev, args.job, args.extra)
    except Unresolved as why:
        print(f"::notice title=No reuse for {args.job}::{why}", file=sys.stderr)
        return 0
    print(f"tree {value['tree']}", file=sys.stderr)
    print(f"workflow {value['workflow']} {WORKFLOW}", file=sys.stderr)
    for name, text in sorted(value["toolchain"].items()):
        print(f"{name} {text}", file=sys.stderr)
    print(f"key=job-pass-{args.job}-{digest[:40]}")
    print(f"fingerprint={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Route and key .github/workflows/classic-pr-build.yml.

The classic NIGHTLY (.github/workflows/nightly.yml) compiles the app in Release
for arm64 and builds the cmux-tui client in release. A pull request
into main runs neither: ci.yml's release-build job needs the full suite, and
pull requests run compile-only. A change that breaks only the Release compile
then shows up hours later as a NIGHTLY that does not publish.

  route --base B --head H   swift=true|false, helpers=true|false
  keys --rev H              keys={"arm64": ..., "helpers": ...}

Swift routing is detect_ci_change_areas.py's release_build area, the same
decision ci.yml uses for its Release compile, so the two cannot disagree.
The keys hash git tree ids of the inputs at the head, so a push that changes
no input (a docs or web edit, a rerun) finds the earlier pass in the cache.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ".github/workflows/classic-pr-build.yml"
COMPILE_SCRIPT = "scripts/ci/classic-nightly-release-compile.sh"
ARCHS = ("arm64",)

# Top-level entries the app's Release compile never reads. Everything else at
# the top level is part of the Swift key, so a miss only costs a rebuild.
SWIFT_KEY_IGNORED = frozenset(
    {
        ".github",
        "docs",
        "plans",
        "design",
        "tests",
        "tests_v2",
        "web",
        "workers",
        "services",
        "experiments",
        "Prototypes",
        "homebrew-cmux",
    }
)

# The cmux-tui client the NIGHTLY builds (`cargo build -p cmux-tui --bin
# cmux-tui --release --locked` in cmux-tui) and what that build reads.
HELPER_INPUTS = (
    "cmux-tui",
    "ghostty",
    ".cargo",
    ".gitmodules",
    "scripts/ghostty-zig-version.sh",
    ".github/actions/setup-cmux-tui-rust",
    ".github/actions/ghostty-zig-packages",
    ".github/actions/runner-cargo-home",
    ".github/actions/cache-restore",
    ".github/actions/cache-save",
    "scripts/ci/fetch-ghostty-zig-packages.sh",
    "scripts/ci/cache_restore_receipt.py",
    "scripts/ci/r2-cache.sh",
    WORKFLOW,
    "scripts/ci/classic_nightly_pr_build.py",
)
HELPER_CRATE = "cmux-tui"
HELPER_ARGS = ("-p", "cmux-tui", "--bin", "cmux-tui", "--release", "--locked")


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, text=True, stdout=subprocess.PIPE
    ).stdout


def helper_change(path: str) -> bool:
    return any(path == item or path.startswith(item.rstrip("/") + "/") for item in HELPER_INPUTS)


def swift_change(changed: list[str], root: Path = ROOT) -> bool:
    with tempfile.TemporaryDirectory() as tmp:
        files = Path(tmp) / "files.txt"
        out = Path(tmp) / "out.txt"
        files.write_text("".join(f"{path}\n" for path in changed))
        subprocess.run(
            [
                sys.executable,
                str(root / "scripts/ci/detect_ci_change_areas.py"),
                "--event-name",
                "pull_request",
                "--files-from",
                str(files),
                "--github-output",
                str(out),
            ],
            cwd=root,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        outputs = dict(
            line.split("=", 1) for line in out.read_text().splitlines() if "=" in line
        )
    own = {WORKFLOW, COMPILE_SCRIPT, "scripts/ci/classic_nightly_pr_build.py"}
    return outputs.get("release_build") == "true" or bool(own & set(changed))


def route(changed: list[str], root: Path = ROOT) -> dict[str, bool]:
    return {
        "swift": swift_change(changed, root),
        "helpers": any(helper_change(path) for path in changed),
    }


def tree_ids(rev: str, paths: list[str] | None = None, root: Path = ROOT) -> list[str]:
    args = ["ls-tree", rev, "--"]
    if paths is not None:
        args += paths
    return sorted(line for line in git(*args, cwd=root).splitlines() if line)


def digest(parts: list[str]) -> str:
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()[:32]


def keys(rev: str, root: Path = ROOT) -> dict[str, str]:
    top = [
        line
        for line in tree_ids(rev, None, root)
        if line.split("\t", 1)[1] not in SWIFT_KEY_IGNORED
        and not line.split("\t", 1)[1].endswith(".md")
    ]
    own = tree_ids(rev, [WORKFLOW], root)
    out = {arch: f"classic-nightly-pr-build-v1-{arch}-{digest(top + own + [arch])}" for arch in ARCHS}
    out["helpers"] = "classic-nightly-pr-build-v1-helpers-" + digest(
        tree_ids(rev, list(HELPER_INPUTS), root)
    )
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    route_parser = sub.add_parser("route")
    route_parser.add_argument("--base", required=True)
    route_parser.add_argument("--head", required=True)
    keys_parser = sub.add_parser("keys")
    keys_parser.add_argument("--rev", required=True)
    args = parser.parse_args(argv)
    if args.command == "route":
        changed = [p for p in git("diff", "--no-renames", "--name-only", "-z", args.base, args.head).split("\0") if p]
        for name, value in route(changed).items():
            print(f"{name}={'true' if value else 'false'}")
        return 0
    print("keys=" + json.dumps(keys(args.rev), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

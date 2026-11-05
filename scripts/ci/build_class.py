#!/usr/bin/env python3
"""Which build a change needs: none, a blaze (Rust) build of cmux-tui, or the app build.

Leo, 2026-11-05: "Can't we deterministically say 'these types of changes only need a blaze
compile/build'". Every changed file gets one class, and the change takes the heaviest:

  no-compile  a doc or image (DOC_SUFFIXES, or a WEB_ONLY text file outside Packages/): no
              compiler reads it.
  blaze       a file inside a cmux-tui crate that no Swift compile and no app build phase reads:
              the cmux-tui workspace build (blaze, or cargo) is the whole build. No Xcode build,
              Swift compile or app build can change, because the only cmux-tui files they read
              are the CCmuxAppFFI crates and what they reach through Cargo path dependencies
              (cmux_next_route.app_ffi_inputs, read from the Cargo manifests) and the files the
              app scheme's build phases name (scheme_phase_rust_inputs, read from
              cmux.xcodeproj; the workspace Cargo.toml and Cargo.lock are among them).
  app         anything else: the Swift compiles and the app build can change. A file this script
              cannot place is `app`, so an unknown input never skips a build.

The rules are the CI router's (scripts/ci/cmux_next_route.py), which already drops the Swift
compile tiers for the same files ("Rust the daemon tier builds"). The class is about compiles
and builds only: a daemon change still runs the daemon tier's live-daemon suites, which test
what the new binary does.

Usage: build_class.py [--base REF] [--changed-files FILE] [--json]
Prints the class, then one line per file with its class and reason. Exit 0.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmux_next_route as route_mod  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CLASSES = ("no-compile", "blaze", "app")


def crate_dir(root: Path, path: str) -> str | None:
    """The cmux-tui crate (a directory below cmux-tui/ with a Cargo.toml) that holds path."""
    parent = Path(path).parent
    while parent.as_posix().startswith(route_mod.CMUX_TUI):
        if (root / parent / "Cargo.toml").is_file():
            return parent.as_posix()
        parent = parent.parent
    return None


def classify_path(root: Path, path: str) -> tuple[str, str]:
    if path.endswith(route_mod.DOC_SUFFIXES) or (
            any(fnmatch.fnmatch(path, p) for p in route_mod.WEB_ONLY)
            and path.endswith((".md", ".mdx", ".txt")) and not path.startswith("Packages/")):
        return "no-compile", "a doc no compiler reads"
    if not path.startswith(route_mod.CMUX_TUI):
        return "app", "outside cmux-tui: the app build's rules (cmux_next_route.py) place it"
    if any(route_mod.matches(path, prefix) for prefix in route_mod.app_ffi_inputs(root)):
        return "app", "a CCmuxAppFFI source: the Swift compiles link it"
    if any(route_mod.matches(path, prefix) for prefix in route_mod.scheme_phase_rust_inputs(root)):
        return "app", "an input of the app scheme's build phases (cmux.xcodeproj)"
    crate = crate_dir(root, path)
    if crate is None:
        return "app", "in cmux-tui but in no crate: no rule proves the app build skips it"
    return "blaze", f"crate {crate}: only the cmux-tui workspace build reads it"


def classify(root: Path, changed: list[str]) -> dict:
    files = [{"path": p, "class": c, "reason": r} for p in changed for c, r in [classify_path(root, p)]]
    # No file is no-compile too: an empty change needs no build.
    cls = max((f["class"] for f in files), key=CLASSES.index, default="no-compile")
    return {"class": cls, "files": files}


def changed_files(base: str) -> list[str]:
    merge_base = subprocess.run(["git", "-C", str(ROOT), "merge-base", base, "HEAD"],
                                check=True, capture_output=True, text=True).stdout.strip()
    diff = subprocess.run(["git", "-C", str(ROOT), "diff", "--name-only", "--no-renames", merge_base],
                          check=True, capture_output=True, text=True).stdout
    return [p for p in diff.splitlines() if p]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default="origin/feat-cmux-next",
                        help="compare the working tree with its merge base with this ref (default: %(default)s)")
    parser.add_argument("--changed-files", help="a file of changed paths, one per line, instead of --base")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.changed_files:
        changed = [p.strip() for p in Path(args.changed_files).read_text(encoding="utf-8").splitlines() if p.strip()]
    else:
        changed = changed_files(args.base)
    result = classify(ROOT, changed)
    if args.json:
        print(json.dumps(result, indent=2))
        return 0
    print(result["class"])
    for item in result["files"]:
        print(f"  {item['class']:<10} {item['path']}: {item['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

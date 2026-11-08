#!/usr/bin/env python3
"""Fingerprint reusable app-host product inputs before allocating a Mac.

This is the cheap Linux-side admission key. It deliberately shares the same
repository-owned product identity used by macOS artifact reuse, then binds any
runtime selector the Linux router knows (currently the selected Xcode app).

CI orchestration changes may rerun admission logic without invalidating a
previously compiled product. Product source, product-producing helpers, retained
macOS admission recipe controls, the identity algorithm, or the selected Xcode
still change the fingerprint.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from typing import Optional

import product_input_identity as product_inputs


def fingerprint(
    tree_lines: list[str],
    workflow: str,
    extra: list[str],
    e2e_workflow: Optional[str] = None,
) -> str:
    value = {
        "product_inputs": product_inputs.identity_from_tree_lines(
            tree_lines,
            workflow,
            e2e_workflow,
        ),
        "extra": list(extra),
    }
    raw = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def local_fingerprint(revision: str, extra: list[str]) -> str:
    tree_lines = subprocess.check_output(
        ["git", "-c", "core.quotepath=off", "ls-tree", "-r", revision],
        text=True,
    ).splitlines()
    workflow = subprocess.check_output(
        ["git", "show", f"{revision}:{product_inputs.CI_WORKFLOW}"],
        text=True,
    )
    e2e_workflow = subprocess.check_output(
        ["git", "show", f"{revision}:{product_inputs.E2E_WORKFLOW}"],
        text=True,
    )
    return fingerprint(tree_lines, workflow, extra, e2e_workflow)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--extra", action="append", default=[])
    args = parser.parse_args(argv)
    print(local_fingerprint(args.revision, args.extra))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

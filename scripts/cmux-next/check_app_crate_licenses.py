#!/usr/bin/env python3
"""App-linked crate license gate (plans/cmux-next/remote-desktop-c7.md 3).

For each root crate the macOS app links (cmux-app-ffi) or that a shipped
first-party binary links without the GPL host (cmux-remote-browser), walk
the normal-dependency closure from `cargo metadata` and fail when:
  - a banned crate is in it: anything x264, cmux-rd-host (the GPL desktop
    host), or OpenH264 built from source (Mac uses VideoToolbox; shipped
    OpenH264 is Cisco's prebuilt binary loaded at first use);
  - a crate's license is not on the allowlist (MIT, Apache-2.0, BSD,
    ISC, Unicode, Zlib) and the crate is not one of the six named
    first-party GPL crates.
Build and dev dependencies are not linked into the app and are skipped.

Usage: check_app_crate_licenses.py [--manifest PATH --root NAME]...
(defaults: the two roots above under cmux-tui/crates). Needs cargo; the
unit tests (tests/test_app_crate_licenses.py) feed synthetic metadata.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

ALLOWED = {
    "MIT",
    "Apache-2.0",
    "Apache-2.0 WITH LLVM-exception",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "Unicode-3.0",
    "Unicode-DFS-2016",
    "Zlib",
    "0BSD",
    "CC0-1.0",
}

# First-party crates that still declare GPL-3.0-or-later. Named exactly, by
# coordinator decision 2026-10-05: no relicense now; Lawrence's open license
# question (are the app-linked first-party crates MIT?) decides, and the
# license lane removes these entries in its push.
FIRST_PARTY_GPL = {
    "cmux-rd-ffi",
    "cmux-app-ffi",
    "cmux-rd-core",
    "cmux-rd-proto",
    "cmux-layout-reducer",
    "cmux-layout-reducer-ffi",
}

BANNED = [
    (re.compile(r"x264"), "x264 is GPL and stays in the cmux-rd host binary"),
    (re.compile(r"^cmux-rd-host$"), "the GPL desktop host never links into the app"),
    (re.compile(r"^openh264(-sys2)?$"), "OpenH264 from source is for tests and the bench only"),
]

# cmux-remote-browser joins when its own license is decided: it declares
# GPL-3.0-or-later today and is not one of the six named crates (D-RT-RD2
# requires its dependencies to be MIT/Apache; pass it with --manifest/--root
# to check that closure).
DEFAULT_ROOTS = [
    ("cmux-tui/crates/cmux-app-ffi/Cargo.toml", "cmux-app-ffi"),
]


def _terms(expression):
    """Splits an SPDX expression into its OR alternatives, each a list of AND terms."""
    expr = expression.replace("/", " OR ").replace("(", " ").replace(")", " ")
    return [
        [t.strip() for t in re.split(r"\s+AND\s+", alt) if t.strip()]
        for alt in re.split(r"\s+OR\s+", expr)
    ]


def license_allowed(expression):
    """True when some OR alternative consists only of allowed licenses."""
    if not expression:
        return False
    # Parenthesized groups like "(MIT OR Apache-2.0) AND Unicode-3.0": every
    # AND operand must have one allowed alternative.
    operands = [o.strip() for o in re.split(r"\s+AND\s+(?![^()]*\))", expression)]
    if len(operands) > 1:
        return all(license_allowed(o.strip("() ")) for o in operands)
    return any(all(term in ALLOWED for term in alt) for alt in _terms(expression))


def closure(metadata, root_name):
    """Names of the root and every crate it links (normal dependencies)."""
    by_id = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    root = next(pid for pid, p in by_id.items() if p["name"] == root_name)
    seen, stack = set(), [root]
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes.get(pid, {}).get("deps", []):
            kinds = [k.get("kind") for k in dep.get("dep_kinds", [{"kind": None}])]
            if any(k is None for k in kinds):
                stack.append(dep["pkg"])
    return [by_id[pid] for pid in sorted(seen)]


def check(metadata, root_name):
    problems = []
    for pkg in closure(metadata, root_name):
        name = pkg["name"]
        for pattern, why in BANNED:
            if pattern.search(name):
                problems.append(f"{root_name}: {name} is banned ({why})")
        if name in FIRST_PARTY_GPL:
            continue
        if not license_allowed(pkg.get("license")):
            problems.append(f"{root_name}: {name} has license {pkg.get('license')!r}, not on the allowlist")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", action="append")
    parser.add_argument("--root", action="append")
    args = parser.parse_args()
    roots = list(zip(args.manifest, args.root)) if args.manifest else DEFAULT_ROOTS
    repo = pathlib.Path(__file__).resolve().parents[2]
    problems = []
    for manifest, root in roots:
        out = subprocess.run(
            ["cargo", "metadata", "--locked", "--format-version", "1", "--manifest-path", str(repo / manifest)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        problems += check(json.loads(out), root)
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    if problems:
        return 1
    print(f"app crate licenses: ok ({', '.join(r for _, r in roots)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

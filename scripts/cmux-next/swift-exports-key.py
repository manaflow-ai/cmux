#!/usr/bin/env python3
"""The source key and output digest of the cmux-next Swift exports.

regenerate-swift-exports.sh writes these files from Swift tests on a Mac: the
settings schema, the MDM manifests, the action surfaces, links and daemon
capabilities, and the CI target graph. A job that only reads them (the web
bundles read the settings schema) can restore them from a cache keyed by
`--source` instead of building the package.

The source key hashes every file git sees (tracked and untracked, not ignored)
under the inputs below, minus the exports and the web bundles (the app's
`.copy` resources, which no export test reads), with the CI's Xcode pin. The
output digest hashes the exports.

Usage: swift-exports-key.py ROOT [--stamp | --source | --outputs | --list]
"""
import hashlib
import os
import subprocess
import sys

# What the export tests compile and read: the packages (CmuxNext and the local
# packages it uses), the plans the action catalog checks, the generators and the
# Xcode the CI builds them with.
INPUTS = [
    "Packages",
    "plans/cmux-next",
    "scripts/cmux-next/regenerate-swift-exports.sh",
    "scripts/cmux-next/ci-target-graph.py",
    "scripts/cmux-next/swift-exports-key.py",
    "scripts/ci/xcode-pins.txt",
]

# What the export tests and ci-target-graph.py write. actions.md is the action
# section of a hand-written page; the whole file counts as an export.
OUTPUTS = [
    "Packages/macOS/CmuxNext/ci-target-graph.json",
    "plans/cmux-next/action-surfaces.json",
    "plans/cmux-next/actions.md",
    "plans/cmux-next/daemon-capabilities.json",
    "plans/cmux-next/links.json",
    "schemas/settings/settings-schema.json",
    "docs/mdm/com.manaflow.cmux.json",
    "docs/mdm/com.manaflow.cmux.plist",
    "docs/mdm/com.manaflow.cmux.intune.plist",
    "docs/mdm/managed-preferences.md",
]

# The web bundles (scripts/cmux-next/web-bundle-key.py OUTPUTS), so a web-only
# change keeps the key.
WEB_BUNDLES = [
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js",
]


def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def source_key(root):
    excluded = [f":(exclude){path}" for path in OUTPUTS + WEB_BUNDLES]
    listed = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *INPUTS, *excluded],
        check=True, capture_output=True).stdout.split(b"\0")
    h = hashlib.sha256()
    for rel in sorted({p for p in listed if p}):
        path = os.path.join(root, os.fsdecode(rel))
        # A tracked file deleted in the worktree is listed but absent.
        if os.path.isfile(path) and not os.path.islink(path):
            h.update(rel + b"\0" + file_digest(path).encode() + b"\n")
    return h.hexdigest()


def output_digest(root):
    h = hashlib.sha256()
    for rel in OUTPUTS:
        path = os.path.join(root, rel)
        digest = file_digest(path) if os.path.isfile(path) else "missing"
        h.update(f"{rel}\0{digest}\n".encode())
    return h.hexdigest()


def main(argv):
    if len(argv) < 2 or len(argv) > 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    root, mode = argv[1], (argv[2] if len(argv) == 3 else "--stamp")
    if mode == "--source":
        print(source_key(root))
    elif mode == "--outputs":
        print(output_digest(root))
    elif mode == "--stamp":
        print(f"{source_key(root)} {output_digest(root)}")
    elif mode == "--list":
        print("\n".join(OUTPUTS))
    else:
        print(f"unknown mode {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

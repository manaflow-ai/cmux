#!/usr/bin/env python3
"""The source key and output digest of the cmux-next web bundles.

build-web-bundles.sh stores `--stamp` in .web-bundles.key after a build and
skips the next build while it still matches. The stamp is three fields: the
source key (every file git sees, tracked and untracked but not ignored, under
the inputs below), the output digest (every file the build wrote) and the
version of bun on PATH. A changed input, an edited or deleted output or
another bun therefore makes it differ. `--verify-stamp` prints the first two
fields only: the Xcode verify phase runs with a PATH that may lack bun.

Usage: web-bundle-key.py ROOT [--stamp | --verify-stamp | --source | --outputs]
"""
import hashlib
import os
import subprocess
import sys

# What the builders read. webviews/ includes its scripts, lockfile and the
# generated strings tables; schemas/settings is imported by the settings page;
# the xcstrings catalogs feed gen-strings.mjs; marked.min.js is inlined into the
# webviews app's agent-session.html.
INPUTS = [
    "webviews",
    "schemas/settings",
    "Resources/markdown-viewer/marked.min.js",
    "scripts/build-webviews-app.sh",
    "scripts/check-webviews-bun-version.sh",
    "scripts/cmux-next/build-agent-pane-web.sh",
    "scripts/cmux-next/build-agent-activity-web.sh",
    "scripts/cmux-next/build-pages-web.sh",
    "scripts/cmux-next/build-palette-ranker.sh",
    "scripts/cmux-next/build-optchat-inspector-web.sh",
    "scripts/cmux-next/build-web-bundles.sh",
    "scripts/cmux-next/web-bundle-key.py",
    ":(glob)Packages/macOS/CmuxNext/Sources/**/*.xcstrings",
]

# What the builders write (build-web-bundles.sh). The palette ranker is one file
# in a resource directory that holds other files.
OUTPUTS = [
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js",
    "Resources/markdown-viewer/webviews-app",
    "Native/OptChat/optchat-chief/inspector/index.html",
]

IGNORED_NAMES = {".DS_Store"}


def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def source_key(root):
    listed = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *INPUTS],
        check=True, capture_output=True).stdout.split(b"\0")
    h = hashlib.sha256()
    for rel in sorted({p for p in listed if p}):
        path = os.path.join(root, os.fsdecode(rel))
        # A tracked file deleted in the worktree is listed but absent.
        if os.path.isfile(path) and not os.path.islink(path):
            h.update(rel + b"\0" + file_digest(path).encode() + b"\n")
    return h.hexdigest()


def bun_version():
    try:
        return subprocess.run(["bun", "--version"], capture_output=True, text=True).stdout.strip() or "none"
    except FileNotFoundError:
        return "none"


def output_digest(root):
    h = hashlib.sha256()
    for top in OUTPUTS:
        base = os.path.join(root, top)
        if os.path.isfile(base):
            files = [base]
        elif os.path.isdir(base):
            files = []
            for d, dirs, names in os.walk(base):
                dirs.sort()
                files += [os.path.join(d, n) for n in sorted(names) if n not in IGNORED_NAMES]
        else:
            h.update(f"missing {top}\n".encode())
            continue
        if not files:
            h.update(f"empty {top}\n".encode())
        for path in files:
            rel = os.path.relpath(path, root)
            h.update(f"{rel}\0{file_digest(path)}\n".encode())
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
        print(f"{source_key(root)} {output_digest(root)} bun-{bun_version()}")
    elif mode == "--verify-stamp":
        print(f"{source_key(root)} {output_digest(root)}")
    else:
        print(f"unknown mode {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

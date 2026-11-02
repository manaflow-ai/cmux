#!/usr/bin/env python3
"""Vendored CmuxAgentCursor: sync from the cmux-cua pin and verify the copy.

The package's owner is manaflow-ai/cmux-cua (libs/cmux-cua/swift/CmuxAgentCursor).
cmux-next vendors it verbatim into Packages/Shared/CmuxAgentCursor; never edit
the copy by hand, change cmux-cua first and re-sync (plans/cmux-next/agent-cursor.md).

  cmux_agent_cursor_vendor.py sync    copy the package at CMUX_CUA_PINNED_SHA, apply PATCHES, write SOURCE
  cmux_agent_cursor_vendor.py check   exit 1 unless the copy matches SOURCE and SOURCE names the pin
                                      and the current PATCHES
"""
import hashlib
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEST = REPO / "Packages" / "Shared" / "CmuxAgentCursor"
UPSTREAM_URL = "https://github.com/manaflow-ai/cmux-cua.git"
UPSTREAM_PATH = "libs/cmux-cua/swift/CmuxAgentCursor"
SOURCE_NAME = "SOURCE"
# cmux-side patches applied, in order, to the package at the pin, as
# build-cmux-cua.sh does for the helper. Each one is the exact diff (under
# UPSTREAM_PATH) of a merged cmux-cua PR the pin does not carry yet; the pin bump
# to a release that includes it deletes the patch here.
#   linux: manaflow-ai/cmux-cua#80 (merged as 97def85c7f49), CoreAnimation and
#     CFGetTypeID gated so the package builds and tests on Linux
#     (scripts/ci/swift-linux-packages.txt); the Darwin code is unchanged.
#   vendored-edits: manaflow-ai/cmux-cua#81 (merged as 3b6166ff1f16), the two
#     edits cmux had made to this copy by hand: GlideMotion.follow (the agent
#     mouse's traced path) and AgentCursorPalette's force unwrap removed.
PATCHES = [
    "scripts/cmux-agent-cursor-linux.patch",
    "scripts/cmux-agent-cursor-vendored-edits.patch",
]


def pinned_sha() -> str:
    text = (REPO / "scripts" / "build-cmux-cua.sh").read_text()
    m = re.search(r'^CMUX_CUA_PINNED_SHA="([0-9a-f]{40})"$', text, re.M)
    if not m:
        sys.exit("CMUX_CUA_PINNED_SHA not found in scripts/build-cmux-cua.sh")
    return m.group(1)


def git_tree_hash(directory: Path, skip: frozenset = frozenset()) -> str:
    """The git tree object id of `directory` (same as `git rev-parse <commit>:<path>`)."""
    entries = []
    for entry in os.scandir(directory):
        if entry.name in skip:
            continue
        path = Path(entry.path)
        if entry.is_symlink():
            data = os.readlink(path).encode()
            mode, sha = "120000", _object("blob", data)
        elif entry.is_dir():
            mode, sha = "40000", git_tree_hash(path)
        else:
            data = path.read_bytes()
            mode = "100755" if os.access(path, os.X_OK) else "100644"
            sha = _object("blob", data)
        sort_key = entry.name + "/" if mode == "40000" else entry.name
        entries.append((sort_key.encode(), f"{mode} {entry.name}".encode() + b"\0" + bytes.fromhex(sha)))
    body = b"".join(raw for _, raw in sorted(entries))
    return _object("tree", body)


def _object(kind: str, body: bytes) -> str:
    return hashlib.sha1(f"{kind} {len(body)}".encode() + b"\0" + body).hexdigest()


def read_source() -> dict:
    path = DEST / SOURCE_NAME
    if not path.exists():
        sys.exit(f"{path} is missing; run scripts/cmux_agent_cursor_vendor.py sync")
    fields = {}
    for line in path.read_text().splitlines():
        if line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()
    return fields


def patch_lines() -> list[str]:
    """One `NAME SHA256` per patch, in order, as SOURCE records them."""
    return [f"{name} {hashlib.sha256((REPO / name).read_bytes()).hexdigest()}" for name in PATCHES]


def recorded_patches() -> list[str]:
    path = DEST / SOURCE_NAME
    return [line.split(":", 1)[1].strip() for line in path.read_text().splitlines() if line.startswith("patch:")]


def check() -> int:
    source = read_source()
    problems = []
    if recorded_patches() != patch_lines():
        problems.append(f"SOURCE patches {recorded_patches()} are not PATCHES {patch_lines()}; run sync")
    if source.get("sha") != pinned_sha():
        problems.append(f"SOURCE sha {source.get('sha')} is not CMUX_CUA_PINNED_SHA {pinned_sha()}; run sync")
    if source.get("path") != UPSTREAM_PATH:
        problems.append(f"SOURCE path {source.get('path')} is not {UPSTREAM_PATH}")
    actual = git_tree_hash(DEST, frozenset({SOURCE_NAME}))
    if source.get("tree") != actual:
        problems.append(f"vendored tree {actual} differs from SOURCE tree {source.get('tree')}: "
                        "the copy was edited by hand; change cmux-cua and re-sync instead")
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


def sync() -> int:
    sha = pinned_sha()
    with tempfile.TemporaryDirectory() as tmp:
        run = lambda *args: subprocess.run(["git", "-C", tmp, *args], check=True, capture_output=True, text=True).stdout
        run("init", "-q")
        run("fetch", "-q", "--depth", "1", UPSTREAM_URL, sha)
        tree = run("rev-parse", f"{sha}:{UPSTREAM_PATH}").strip()
        archive = Path(tmp) / "pkg.tar"
        run("archive", "--format=tar", "-o", str(archive), sha, UPSTREAM_PATH)
        if DEST.exists():
            subprocess.run(["rm", "-rf", str(DEST)], check=True)
        DEST.mkdir(parents=True)
        prefix = UPSTREAM_PATH + "/"
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                if not member.name.startswith(prefix):
                    continue
                member.name = member.name[len(prefix):]
                tar.extract(member, DEST, filter="tar")
    for name in PATCHES:
        subprocess.run(["git", "apply", f"--directory={DEST.relative_to(REPO)}", str(REPO / name)],
                       cwd=REPO, check=True)
    patched = git_tree_hash(DEST, frozenset({SOURCE_NAME}))
    (DEST / SOURCE_NAME).write_text(
        "# Vendored verbatim from manaflow-ai/cmux-cua, plus the patches listed below\n"
        "# (PATCHES in scripts/cmux_agent_cursor_vendor.py). Do not edit files in this directory:\n"
        "# change cmux-cua first, then run scripts/cmux_agent_cursor_vendor.py sync (the pin\n"
        "# bump script scripts/bump-cmux-cua-pin.sh does this in the same commit).\n"
        f"repo: manaflow-ai/cmux-cua\nsha: {sha}\npath: {UPSTREAM_PATH}\nupstream-tree: {tree}\n"
        + "".join(f"patch: {line}\n" for line in patch_lines())
        + f"tree: {patched}\n"
    )
    actual = git_tree_hash(DEST, frozenset({SOURCE_NAME}))
    if actual != patched:
        sys.exit(f"synced copy hashes to {actual}, SOURCE tree is {patched}")
    print(f"vendored {UPSTREAM_PATH} at {sha} (tree {tree}, {len(PATCHES)} patches -> {patched})")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("sync", "check"):
        sys.exit(__doc__)
    sys.exit(sync() if sys.argv[1] == "sync" else check())

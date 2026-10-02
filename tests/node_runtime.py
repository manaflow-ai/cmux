"""Locate a usable Node.js runtime for tests whose fake binaries `exec node`.

CI macOS runner images have dropped `node` from the default PATH before
(2026-07-10 warp-macos-15 image), which made every wrapper test fail with
`exec: node: not found` on all branches. Tests that need node call
`ensure_node_on_path()` first: it repairs PATH when node exists but is not
reachable, and lets the caller SKIP (like the existing `bun` skip in
test_pi_extension_install.py) when node is genuinely absent.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path


def _candidate_nodes() -> list[Path]:
    candidates = [
        Path("/opt/homebrew/bin/node"),
        Path("/usr/local/bin/node"),
        Path("/usr/bin/node"),
        Path.home() / ".volta" / "bin" / "node",
    ]
    nvm_versions = Path.home() / ".nvm" / "versions" / "node"
    if nvm_versions.is_dir():
        for version_dir in sorted(nvm_versions.iterdir(), reverse=True):
            candidates.append(version_dir / "bin" / "node")
    return candidates


def ensure_node_on_path() -> str | None:
    """Return a node executable path, prepending its directory to PATH.

    Returns None when no node runtime can be found on this machine.
    """
    node = shutil.which("node")
    if node is None:
        for candidate in _candidate_nodes():
            if candidate.is_file() and os.access(candidate, os.X_OK):
                node = str(candidate)
                break
    if node is None:
        return None
    node_dir = str(Path(node).parent)
    path = os.environ.get("PATH", "")
    if node_dir not in path.split(os.pathsep):
        os.environ["PATH"] = f"{node_dir}{os.pathsep}{path}" if path else node_dir
    return node

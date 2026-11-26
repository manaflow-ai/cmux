"""The build-done beacon a `cmux live` loop writes once a swap lands (cmuxterm-hq RFD 0152).

acpmux looks at this file while a chat's turn runs (cmux-tui/crates/acpmux/src/hub/live_builds.rs)
and takes a `build` frame of each turn that worked in `tree`, so the turn's frames show the swapped
build, not the one before it. The path must match live_builds.rs's `beacon_path`:
$CMUX_LIVE_BUILD_BEACON, else ~/Library/Caches/cmux-next/live-build-done.json on macOS and
${XDG_CACHE_HOME:-~/.cache}/cmux-next/live-build-done.json elsewhere.

Never raises: a frame is a nicety, the swap already happened.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path


def beacon_path() -> Path | None:
    if os.environ.get("CMUX_LIVE_BUILD_BEACON"):
        return Path(os.environ["CMUX_LIVE_BUILD_BEACON"])
    home = os.environ.get("HOME")
    if sys.platform == "darwin":
        return Path(home) / "Library/Caches/cmux-next/live-build-done.json" if home else None
    cache = os.environ.get("XDG_CACHE_HOME") or (str(Path(home) / ".cache") if home else None)
    return Path(cache) / "cmux-next/live-build-done.json" if cache else None


def built(surface: str, tree: str | Path) -> bool:
    """Record that `surface`'s loop swapped in a build of `tree`. Whether the beacon was written."""
    path = beacon_path()
    if path is None:
        return False
    entry = {"at": int(time.time() * 1000), "surface": surface, "tree": str(Path(tree).resolve())}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        staged = path.with_name(f".{path.name}.{os.getpid()}")
        staged.write_text(json.dumps(entry) + "\n")
        os.replace(staged, path)  # one rename: acpmux never reads half a beacon
        return True
    except OSError:
        return False

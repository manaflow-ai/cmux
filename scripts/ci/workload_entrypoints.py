#!/usr/bin/env python3
"""Scripts a workflow `run:` reaches through `cmux_workload_profile.py run <id>`.

A workload profile step names only the profile runner, but it executes the
profile's checked-in entrypoint and everything that script runs. Guard routing
and the test execution registry both need to see through that indirection, so
they share this one reader of scripts/ci/cmux-workload-profiles.json.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROFILES = Path("scripts/ci/cmux-workload-profiles.json")
PROFILE_RUN = re.compile(r"scripts/ci/cmux_workload_profile\.py\s+run\s+([A-Za-z0-9_.-]+)")


def entrypoints(run: str, root: Path = ROOT) -> list[tuple[str, str]]:
    """(entrypoint path, entrypoint text) for each profile `run` executes.

    Raises OSError, ValueError or KeyError when a named profile cannot be
    resolved; callers that route decide whether that fails open.
    """
    ids = PROFILE_RUN.findall(run)
    if not ids:
        return []
    registry = json.loads((root / PROFILES).read_text(encoding="utf-8"))
    by_id = {profile["id"]: profile["entrypoint"] for profile in registry["profiles"]}
    result = []
    for profile_id in ids:
        entrypoint = by_id[profile_id]
        result.append((entrypoint, (root / entrypoint).read_text(encoding="utf-8")))
    return result

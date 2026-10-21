#!/usr/bin/env python3
"""Whether a pull request gets cmux-next-media.yml's native tour.

The tour holds an owned Mac's gui runner (one per mini) for up to two hours, so it
cannot run for every UI pull request (32 queued, 8 running on 2026-10-14). It runs:
  - with the `media-tour` label, always (a draft too);
  - without it, when the pull request changes cmux-next Swift UI
    (Packages/macOS/CmuxNext/Sources/) that a specific tour covers: path_map.py
    maps it to any tour other than the catch-all `core`. Web-only changes get the gallery advisory instead, and drafts wait.
  - never with the `no-media-tour` label.

    LABELS='["a","b"]' ACTION=synchronize DRAFT=false media_auto_tour.py --changed FILE

Writes `wanted` (true/false) and `reason` to $GITHUB_OUTPUT and prints them.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cmux-next/media"))
import path_map  # noqa: E402

LABEL = "media-tour"
OPT_OUT = "no-media-tour"
SWIFT_UI = "Packages/macOS/CmuxNext/Sources/"


def decide(*, labels: list[str], action: str, draft: bool, paths: list[str]) -> tuple[bool, str]:
    """(wanted, reason)."""
    if OPT_OUT in labels:
        return False, f"the `{OPT_OUT}` label is set"
    if LABEL in labels:
        return True, f"the `{LABEL}` label is set"
    if draft:
        return False, f"a draft gets a tour only with the `{LABEL}` label"
    swift = [path for path in paths if path.startswith(SWIFT_UI)]
    tours = [tour for tour in path_map.map_paths(swift)["tours"] if tour != "core"]
    if tours:
        return True, f"its Swift UI change is covered by the {', '.join(tours)} tour"
    return False, f"no tour covers a Swift UI change here; add the `{LABEL}` label for one"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--changed", type=Path, required=True, help="the pull request's paths, one per line")
    args = parser.parse_args(argv)
    try:
        labels = [str(label) for label in json.loads(os.environ.get("LABELS") or "[]")]
    except ValueError:
        labels = []
    paths = [line.strip() for line in args.changed.read_text().splitlines() if line.strip()]
    wanted, reason = decide(labels=labels, action=os.environ.get("ACTION", ""),
                            draft=os.environ.get("DRAFT", "false") == "true", paths=paths)
    print(f"wanted={'true' if wanted else 'false'}: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as handle:
            handle.write(f"wanted={'true' if wanted else 'false'}\nreason={reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

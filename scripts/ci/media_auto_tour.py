#!/usr/bin/env python3
"""Whether a pull request event gets cmux-next-media.yml's native tour.

The tour holds an owned Mac's gui runner (one per mini) for up to two hours, so it
runs only on a merge to feat-cmux-next or on demand (Leo, 2026-10-21). For a pull
request that means:
  - the `labeled` event that adds `media-tour` tours the head at that moment (a draft too);
  - nothing else tours: no push, labeled or not, and no tour picked from the changed
    paths. To tour a newer head, remove and re-add the label, or run `cmux-ci capture`.
    `media-tour-mac` only moves a tour to a Mac;
  - never with the `no-media-tour` label.

    LABELS='["a","b"]' ACTION=labeled LABEL=media-tour media_auto_tour.py [--changed FILE]

--changed is accepted and ignored (the route job still lists the files).
Writes `wanted` (true/false) and `reason` to $GITHUB_OUTPUT and prints them.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

LABEL = "media-tour"
OPT_OUT = "no-media-tour"


def decide(*, labels: list[str], action: str, label: str) -> tuple[bool, str]:
    """(wanted, reason) for a pull request event: `action`, and `label` for a label event."""
    if OPT_OUT in labels:
        return False, f"the `{OPT_OUT}` label is set"
    if action == "labeled" and label == LABEL:
        return True, f"the `{LABEL}` label was added"
    if LABEL in labels:
        return False, (f"a pull request tours once, when the `{LABEL}` label is added; "
                       f"remove and re-add it, or run `cmux-ci capture`, to tour this head")
    return False, f"a pull request tours only when the `{LABEL}` label is added"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--changed", type=Path, help="ignored; the tour picks no pull request by its paths")
    parser.parse_args(argv)
    try:
        labels = [str(label) for label in json.loads(os.environ.get("LABELS") or "[]")]
    except ValueError:
        labels = []
    wanted, reason = decide(labels=labels, action=os.environ.get("ACTION", ""), label=os.environ.get("LABEL", ""))
    print(f"wanted={'true' if wanted else 'false'}: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as handle:
            handle.write(f"wanted={'true' if wanted else 'false'}\nreason={reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Decide whether changed paths can alter the app the Nightly publishes.

`detect_ci_change_areas` already answers "can this path change Release app
bytes" for pull requests, including the carve-outs that are easy to get wrong:
the app bundles `skills/cmux-cua` as a folder resource, so skill Markdown
outside that folder is neutral while everything inside it is a build input.
Reusing that classifier keeps one definition of an app build input.

The Nightly is not a pull-request lane, so it differs at both edges. It also
signs, prebuilds Sparkle deltas, generates the appcast, and publishes, and the
helpers that do that are neutral for pull requests only because no pull-request
lane runs them; here every path the Nightly workflow itself runs is an input.
In the other direction the Nightly reads no pull-request CI configuration, so
an edit to `ci.yml` or another reusable workflow cannot change what it ships.

Anything this script cannot classify counts as changed, so the Nightly builds.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import detect_ci_change_areas as detect  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
NIGHTLY_WORKFLOW_PATH = ".github/workflows/nightly.yml"

# Repository paths named by the workflow: `scripts/sign-cmux-bundle.sh`,
# `./.github/actions/cache-restore`, `python3 scripts/ci/upload-r2-object.py`.
_REFERENCED_PATH_RE = re.compile(
    r"(?<![\w.-])\.?/?((?:scripts|\.github/(?:actions|scripts|workflows))"
    r"/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)"
)


def nightly_workflow_inputs(root: Path) -> frozenset[str]:
    """Every repository path the Nightly workflow runs.

    Derived from the workflow text so that adding a step cannot silently leave
    its script invisible to this gate. Publishing helpers the workflow reaches
    indirectly -- the appcast script runs the delta prebuilder -- come from the
    classifier's own publishing-only set.
    """
    text = (root / NIGHTLY_WORKFLOW_PATH).read_text(encoding="utf-8")
    referenced = {match.group(1).rstrip("/") for match in _REFERENCED_PATH_RE.finditer(text)}
    return frozenset({NIGHTLY_WORKFLOW_PATH, *referenced, *detect.CI_PUBLISHING_ONLY})


def runs_in_nightly(path: str, nightly_inputs: frozenset[str]) -> bool:
    # `.github/actions/cache-restore` is a directory reference; its action.yml
    # and any helper beside it are the same input.
    return any(path == entry or path.startswith(f"{entry}/") for entry in nightly_inputs)


def is_pull_request_ci_config(path: str) -> bool:
    """Configuration that only selects pull-request work.

    The Nightly resolves its own jobs and reads none of these files, so editing
    one cannot change the app it publishes.
    """
    return path == detect.CI_WORKFLOW_PATH or detect.is_other_workflow_config(path)


def build_inputs_changed(paths: list[str], root: Path = ROOT) -> tuple[bool, str]:
    """Return whether the Nightly must build, and the reason to report."""
    nightly_inputs = nightly_workflow_inputs(root)
    candidates: list[str] = []
    for raw_path in paths:
        path = detect.normalize_path(raw_path)
        if not path:
            continue
        if runs_in_nightly(path, nightly_inputs):
            return True, f"{path} runs in the Nightly workflow"
        if is_pull_request_ci_config(path):
            continue
        candidates.append(path)
    if not candidates:
        return False, "only pull-request CI configuration changed"
    if not detect.classify_files(candidates).release_build:
        return False, "no changed path is a Release app build input"
    named = next(
        (path for path in candidates if detect.classify_files([path]).release_build),
        None,
    )
    return True, f"{named} is a Release app build input" if named else "a Release app build input changed"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--files-from",
        default="-",
        help="Newline-delimited changed paths; `-` reads standard input.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        text = sys.stdin.read() if args.files_from == "-" else Path(args.files_from).read_text(encoding="utf-8")
        paths = [line for line in text.splitlines() if line.strip()]
        if not paths:
            raise ValueError("no changed paths to classify")
        # The classifier narrates its routing on stdout; keep stdout to the
        # machine-readable result its caller parses.
        with contextlib.redirect_stdout(sys.stderr):
            changed, reason = build_inputs_changed(paths)
    except Exception as error:  # noqa: BLE001 - an unclassifiable change must build
        changed, reason = True, f"could not classify the change: {error}"
    print(reason, file=sys.stderr)
    print(json.dumps({"build_inputs_changed": changed, "reason": reason}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Ready a CI step to write pr-media: the preflight of .github/actions/pr-media-publish.

    pr_media_gate.py --canary CANARY.png

Before the action runs its publisher command, this proves the check it will
run can see what it must refuse:

- the private-terms list ($PR_MEDIA_PRIVATE_TERMS, from the pr-media
  environment) parses and holds at least one term;
- an OCR tool exists: $PR_MEDIA_PRIVACY_OCR (the tesseract tool on Linux) or,
  on macOS, the compiled pr_media_ocr.swift;
- that tool, through scripts/ci/pr_media_privacy.py, refuses the canary, a
  picture of a fleet prompt and Mac mini name. A tool that reads nothing (a
  missing language pack, a broken install) fails here, before any write.

It prints `ocr=<tool>` for $GITHUB_OUTPUT on success, nothing about the terms
but their count, and exits 1 when the step must not publish.
"""

from __future__ import annotations

import argparse
import importlib.util
import io
import os
from pathlib import Path
import sys
from typing import Mapping

PRIVACY_MODULE = Path(__file__).resolve().with_name("pr_media_privacy.py")
# A bot folder: any hit there refuses, with no pull request author to look up.
CANARY_PATH = "nightly-next/pr-media-gate-canary.png"


def load_privacy():
    spec = importlib.util.spec_from_file_location("cmux_pr_media_privacy_gate", PRIVACY_MODULE)
    if not PRIVACY_MODULE.is_file() or spec is None or spec.loader is None:
        raise SystemExit(f"pr-media gate: {PRIVACY_MODULE} is missing; add it to the sparse checkout")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def preflight(canary: Path, env: Mapping[str, str] = os.environ, privacy=None, out=sys.stdout) -> str:
    """The OCR tool to publish with; raises SystemExit when the step must not publish."""
    privacy = privacy or load_privacy()
    raw = env.get("PR_MEDIA_PRIVATE_TERMS", "")
    if not raw.strip():
        raise SystemExit("pr-media gate: no private-terms list; give the job `environment: pr-media` and pass "
                         "secrets.PR_MEDIA_PRIVATE_TERMS as the action's private-terms input")
    try:
        terms = privacy.parse_terms(raw, "PR_MEDIA_PRIVATE_TERMS")
    except privacy.BadInput as error:
        raise SystemExit(f"pr-media gate: {error}") from None
    if not privacy.term_patterns(terms):
        raise SystemExit("pr-media gate: the private-terms list holds no usable term")
    ocr = privacy.ocr_binary(env, out=sys.stderr)
    if not ocr:
        raise SystemExit("pr-media gate: no OCR tool here, so images would go unread")
    # The check's own words go to a buffer: only the verdict below is printed.
    try:
        privacy.check_upload([(CANARY_PATH, canary)], env={**env, "PR_MEDIA_PRIVACY_OCR": ocr},
                             lookup=lambda numbers: {}, out=io.StringIO())
    except privacy.Refused as refused:
        kinds = {kind for item in refused.report["files"] for kind in item["kinds"]}
        # A tool that crashes leaves the canary "unreadable", which also refuses; that is no proof.
        if kinds - {"unreadable"}:
            print(f"pr-media gate: {len(terms)} private term(s); OCR {Path(ocr).name} refused the canary", file=out)
            return ocr
        raise SystemExit(f"pr-media gate: OCR {Path(ocr).name} could not read the canary; nothing is published") \
            from None
    raise SystemExit(f"pr-media gate: OCR {Path(ocr).name} did not catch the canary, so it would miss a real "
                     "private name; nothing is published")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--canary", type=Path, required=True, help="a picture the check must refuse")
    args = parser.parse_args(argv)
    if not args.canary.is_file():
        raise SystemExit(f"pr-media gate: no canary at {args.canary}")
    ocr = preflight(args.canary, out=sys.stderr)
    print(f"ocr={ocr}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Judge a gallery before/after against its baseline and post the `cmux/visual-baseline` commit status.

The gallery receipt (.github/workflows/gallery-advisory.yml) renders each touched state on the PR's base (the
baseline) and on its head. This script turns that receipt into a pass/fail check:

- `measure` (capture job, next to the images): runs `cmux-shotdiff compare` on every changed base/head pair and
  writes `visual-baseline.json` (one verdict per image: changed_ratio, mean SSIM, worst 32x32 tile SSIM, reasons).
- `judge` (comment job, base-branch code): reads those metrics, the review and the PR body. An image fails when
  cmux-shotdiff fails it at its defaults (1% of pixels past channel tolerance 16, or mean SSIM < 0.98) or, for a
  state the PR did not set out to change (picked by a shared file, not its own source), when its worst tile is
  below 0.9: a thin bar or a skeleton on another component's state is a few hundred pixels, under 1%. A
  `Visual-change: <state, entry or *>: <why>` line in the PR body (gallery_select.visual_changes) clears a
  state. Anything still failing reddens the status.
- `post`: writes the status on the head commit.

It fails open: no receipt, no rendered pair, a new or removed state, or a measuring error is success with the reason
in the description (Leo, 2026-10-31: missing screenshots never block a UI PR). Calibration on 13 gallery PR runs of
2026-11-27 (runs 46045196687..46070603670): raw `changed` would fail 12 of 13; this rule fails 2 (cmux-shotdiff
defaults), each on the PR's own component, each cleared by one Visual-change line. The tile floor applied to every
state would fail 6, all own states, which is why it is kept to collateral ones.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gallery_select import verdict, visual_changes  # noqa: E402

STATUS_CONTEXT = "cmux/visual-baseline"
SCHEMA = "cmux.visual-baseline.v1"
# Worst 32x32 tile SSIM floor for states the PR did not pick by its own source.
COLLATERAL_TILE_SSIM = 0.9
OWN = "own"
DESCRIPTION_LIMIT = 140


def measure(review: dict, root: Path, shotdiff: str, timeout: int = 60) -> dict:
    """One cmux-shotdiff verdict per changed image whose base and head both rendered."""
    images = []
    for image in review.get("images") or []:
        if image.get("status") != "changed":
            continue
        base, head = root / str(image.get("base_image") or ""), root / str(image.get("head_image") or "")
        row = {"state": image.get("state"), "theme": image.get("theme"), "base_image": image.get("base_image")}
        if not (image.get("base_image") and image.get("head_image") and base.is_file() and head.is_file()):
            row["error"] = "missing render"
        else:
            try:
                out = subprocess.run([shotdiff, "compare", str(base), str(head), "--json", "/dev/stdout"],
                                     capture_output=True, text=True, timeout=timeout)
                cmp = json.loads(out.stdout)
                row.update(passed=bool(cmp["pass"]), reasons=cmp.get("reasons") or [],
                           changed_ratio=cmp.get("changed_ratio"), ssim=cmp.get("ssim"),
                           tile_ssim=(cmp.get("worst_tile") or {}).get("ssim"))
            except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError) as err:
                row["error"] = f"shotdiff: {type(err).__name__}"
        images.append(row)
    return {"schema": SCHEMA, "head_sha": review.get("head_sha"), "images": images}


def failure(image: dict, row: dict) -> str:
    """Why this measured image fails its baseline, or "" when it passes."""
    if row.get("error"):
        return ""
    if not row.get("passed", True):
        return "; ".join(row.get("reasons") or ["differs"])
    collateral = (image.get("selected_by") or {}).get("why") != OWN
    tile = row.get("tile_ssim")
    if collateral and isinstance(tile, (int, float)) and tile < COLLATERAL_TILE_SSIM:
        return f"worst tile ssim {tile:.3f} < {COLLATERAL_TILE_SSIM} on a state the PR did not set out to change"
    return ""


def judge(review: dict | None, metrics: dict | None, body: str | None, head_sha: str) -> dict:
    """{state, description, failing[]} for the head. Fails only on a measured, unjustified difference."""
    if not review or review.get("head_sha") != head_sha:
        return {"state": "success", "description": "No gallery receipt for this head; not judged.", "failing": []}
    if not metrics or metrics.get("head_sha") != head_sha:
        return {"state": "success", "description": "Gallery pairs were not measured; not judged.", "failing": []}
    justified = visual_changes(body)
    by_key = {(r.get("state"), r.get("theme")): r for r in metrics.get("images") or []}
    failing, cleared, measured = [], [], 0
    for image in review.get("images") or []:
        row = by_key.get((image.get("state"), image.get("theme")))
        if image.get("status") != "changed" or row is None:
            continue
        measured += not row.get("error")
        why = failure(image, row)
        if not why:
            continue
        if verdict(image["state"], "changed", justified) == "unjustified":
            failing.append({"state": image["state"], "theme": image.get("theme"), "why": why,
                            "base_image": image.get("base_image"), "head_image": image.get("head_image")})
        else:
            cleared.append(image["state"])
    states = list(dict.fromkeys(f["state"] for f in failing))
    if states:
        names = ", ".join(states[:3]) + (f" +{len(states) - 3}" if len(states) > 3 else "")
        desc = f"{len(states)} unexplained visual change(s): {names}. Add Visual-change: <state>: <why>"
        return {"state": "failure", "description": desc[:DESCRIPTION_LIMIT], "failing": failing}
    if cleared:
        desc = f"{len(set(cleared))} changed state(s), each with a Visual-change line"
    else:
        desc = f"{measured} changed image(s) within the baseline" if measured else "No state differs from its baseline"
    return {"state": "success", "description": desc[:DESCRIPTION_LIMIT], "failing": []}


def post(repo: str, sha: str, state: str, description: str, target_url: str = "") -> int:
    args = ["gh", "api", "-X", "POST", f"repos/{repo}/statuses/{sha}", "-f", f"state={state}",
            "-f", f"context={STATUS_CONTEXT}", "-f", f"description={description[:DESCRIPTION_LIMIT]}"]
    if target_url:
        args += ["-f", f"target_url={target_url}"]
    return subprocess.run(args, stdout=subprocess.DEVNULL).returncode


def _load(path: str | None) -> dict | None:
    try:
        return json.loads(Path(path).read_text()) if path else None
    except (OSError, ValueError):
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("measure")
    m.add_argument("--review", required=True)
    m.add_argument("--root", required=True)
    m.add_argument("--shotdiff", required=True)
    m.add_argument("--out", required=True)
    j = sub.add_parser("judge")
    j.add_argument("--review")
    j.add_argument("--metrics")
    j.add_argument("--head-sha", required=True)
    j.add_argument("--body-env", default="PR_BODY", help="environment variable holding the PR body (read as data)")
    j.add_argument("--out", required=True)
    p = sub.add_parser("post")
    p.add_argument("--repo", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--verdict")
    p.add_argument("--state", choices=("pending", "success", "failure", "error"))
    p.add_argument("--description", default="")
    p.add_argument("--target-url", default="")
    args = parser.parse_args(argv)
    if args.cmd == "measure":
        review = _load(args.review) or {}
        Path(args.out).write_text(json.dumps(measure(review, Path(args.root), args.shotdiff), indent=2) + "\n")
        return 0
    if args.cmd == "judge":
        result = judge(_load(args.review), _load(args.metrics), os.environ.get(args.body_env), args.head_sha)
        Path(args.out).write_text(json.dumps(result, indent=2) + "\n")
        print(f"{result['state']}: {result['description']}")
        for f in result["failing"]:
            print(f"  {f['state']} ({f['theme']}): {f['why']}")
        return 0
    doc = _load(args.verdict) or {}
    state = args.state or doc.get("state") or "success"
    return post(args.repo, args.sha, state, args.description or doc.get("description", ""), args.target_url)


if __name__ == "__main__":
    sys.exit(main())

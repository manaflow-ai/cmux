#!/usr/bin/env python3
"""Refit the warm-distance model's compile estimates from recent admissions; propose it only when they drifted.

    warm_model_refit.py --out DIR (--rows FILE... | --hosts HOST...) [--days 14] [--token-file FILE]

Nothing fed compile actuals back into scripts/ci/warm-distance-model.json:
its tier p50s were fitted by hand once, and a near compile from a kept build
ran at about 0.7x the tier while one from a seed ran at about 1.1-1.6x. This
job reads the admissions of the last DAYS (warm_distance.py `admission`
lines: ci-dash's estimates.jsonl, or each mini's log over SSH), refits the
tiers and the (tier, start kind) cells (warm_distance.refit()), and compares
them with the committed model (warm_distance.drift(): a p50 with at least 20
compiles more than 20% off). Without drift it stops. With drift it writes to
OUT:

    warm-distance-model.json   the refit model
    refit.patch                `git apply`-able change to scripts/ci/warm-distance-model.json
    summary.md                 the drift, the cells, and errors before and after (a replay, too)
    status.json                {"drift": [...], "rows": N, "pull_request": URL or null}

and, with --token-file (a token that may write contents and pull requests
of manaflow-ai/cmux and nothing else), force-resets the branch
REFIT_BRANCH to the checkout's HEAD, commits the refit model there, and
opens or updates one pull request against main. It never writes any other
branch, so a person merges every change; the next run replaces an unmerged
branch. Without the token, OUT is the result (the patch and summary to
apply by hand).

Where it runs: cmuxs-mac-mini-6, beside ci-dash (cmuxterm-hq
build-fleet/ci-dash), as `_cidash`. That host already collects every mini's
admission lines and runs no GitHub runners, so no pull request's code can
read the token (hq#595). A GitHub-hosted runner cannot reach the minis, and
an owned runner holds only its own mini's log and runs pull request code.
Run it from a checkout of main, updated first, daily:

    git -C "$CHECKOUT" fetch -q origin main && git -C "$CHECKOUT" checkout -q --detach FETCH_HEAD &&
      /usr/bin/python3 "$CHECKOUT/scripts/ci/warm_model_refit.py" --rows "$CI_DASH_STATE/estimates.jsonl" \\
        --out "$CI_DASH_STATE/warm-model-refit" --token-file "$CI_DASH_STATE/warm-model-refit.token"

The admission lines are written by jobs, pull requests' included, so they
are data to review, not to trust: the refit uses medians and plausible
compile times only, and a person merges the result.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import difflib
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Mapping, Sequence
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import warm_distance as wd  # noqa: E402

REPO = "manaflow-ai/cmux"
MODEL_FILE = "scripts/ci/warm-distance-model.json"
REFIT_BRANCH = "ci/warm-model-refit"
API = "https://api.github.com"
TITLE = "ci: refit the warm-distance compile estimates"


def summary(old: Mapping[str, Any], new: Mapping[str, Any], moved: Sequence[Mapping[str, Any]],
            rows: Sequence[Mapping[str, Any]], now: dt.datetime, days: float) -> str:
    recent = [row for row in wd.calibration_rows(rows) if wd.parse_at(row) >= now - dt.timedelta(days=days)]
    committed = [{"tier": r["tier"], "start": r["start"], "actual": r["actual"], "model": r["model"],
                  "calibrated": wd.tier_seconds(r["tier"], r["start"], new)}
                 for r in ({"tier": wd.row_tier(row, old), "start": wd.start_kind(row), "actual": row["compile_seconds"],
                            "model": wd.tier_seconds(wd.row_tier(row, old), wd.start_kind(row), old)} for row in recent)]
    calibrated = new.get("calibrated") or {}
    return "\n".join([
        f"The warm-distance model's compile estimates drifted: refit from {calibrated.get('rows')} owned compile "
        f"admissions ({calibrated.get('from')} to {calibrated.get('to')}, the last {days:g} days), these p50s moved "
        f"more than {wd.DRIFT_SHARE:.0%} with at least {wd.DRIFT_MIN_ROWS} compiles. Written by "
        "`scripts/ci/warm_model_refit.py`; only the tiers and tiers_by_start change (hot files, start_classes and "
        "job_seconds stay as committed).", "",
        wd.drift_table(moved), "",
        "### Refit cells", "",
        f"A cell predicts once it has {wd.MIN_START_ROWS} compiles; below that its tier does.", "",
        wd.cells_table(new), "",
        "### Errors on these admissions, committed model against the refit", "",
        "In sample for the refit, so an upper bound on its gain; the replay below is not.", "",
        wd.backtest_table(committed, label="refit"), "",
        "### Replay: the committed tiers against a model refit daily from the admissions before each", "",
        wd.backtest_table(wd.backtest(rows, old, every=dt.timedelta(hours=24), days=days), label="refit daily"), "",
    ])


def patch(old_text: str, new_text: str) -> str:
    return "".join(difflib.unified_diff(old_text.splitlines(keepends=True), new_text.splitlines(keepends=True),
                                        f"a/{MODEL_FILE}", f"b/{MODEL_FILE}"))


def call(token: str, method: str, path: str, body: Mapping[str, Any] | None = None) -> Any:
    request = urllib.request.Request(f"{API}{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                                              "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-warm-model-refit"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404 and method == "GET":
            return None
        raise RuntimeError(f"{method} {path}: HTTP {error.code} {error.read()[:300]!r}") from None
    return json.loads(text) if text else None


def open_pull_request(token: str, base_sha: str, model_text: str, body: str) -> str:
    """Reset REFIT_BRANCH to BASE_SHA, commit MODEL_TEXT there, and open or update its pull request."""
    branch = REFIT_BRANCH
    if branch in ("main", "master") or not branch.startswith("ci/"):
        raise RuntimeError(f"refusing to write {branch}")
    ref = f"refs/heads/{branch}"
    if call(token, "GET", f"/repos/{REPO}/git/ref/heads/{branch}") is None:
        call(token, "POST", f"/repos/{REPO}/git/refs", {"ref": ref, "sha": base_sha})
    else:
        call(token, "PATCH", f"/repos/{REPO}/git/refs/heads/{branch}", {"sha": base_sha, "force": True})
    current = call(token, "GET", f"/repos/{REPO}/contents/{MODEL_FILE}?ref={branch}")
    call(token, "PUT", f"/repos/{REPO}/contents/{MODEL_FILE}", {
        "message": "ci: refit the warm-distance compile estimates", "branch": branch,
        "content": base64.b64encode(model_text.encode()).decode(), "sha": current["sha"]})
    owner = REPO.split("/")[0]
    existing = call(token, "GET", f"/repos/{REPO}/pulls?state=open&head={owner}:{branch}") or []
    if existing:
        call(token, "PATCH", f"/repos/{REPO}/pulls/{existing[0]['number']}", {"body": body, "title": TITLE})
        return existing[0]["html_url"]
    return call(token, "POST", f"/repos/{REPO}/pulls", {"title": TITLE, "head": branch, "base": "main",
                                                         "body": body})["html_url"]


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--rows", nargs="+", help="admission lines (this schema or ci-dash's estimates.jsonl)")
    source.add_argument("--hosts", nargs="+", help="minis to read admissions.jsonl from over SSH")
    parser.add_argument("--out", required=True)
    parser.add_argument("--days", type=float, default=wd.REFIT_DAYS)
    parser.add_argument("--token-file", help="a token that may write this repository's contents and pull requests")
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    checkout = Path(__file__).resolve().parents[2]
    old_text = (checkout / MODEL_FILE).read_text()
    old = json.loads(old_text)
    rows = wd.read_rows(args.rows) if args.rows else wd.collect_rows(args.hosts)
    new = wd.refit(rows, old, now=now, days=args.days)
    moved = wd.drift(old, new)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    status: dict[str, Any] = {"at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "rows": new["rows"], "drift": moved,
                              "pull_request": None}
    if moved:
        new_text = json.dumps(new, indent=2, sort_keys=True) + "\n"
        body = summary(old, new, moved, rows, now, args.days)
        (out / "warm-distance-model.json").write_text(new_text)
        (out / "refit.patch").write_text(patch(old_text, new_text))
        (out / "summary.md").write_text(body)
        if args.token_file:
            token = Path(args.token_file).read_text().strip()
            base = subprocess.run(["git", "-C", str(checkout), "rev-parse", "HEAD"], capture_output=True, text=True,
                                  check=True).stdout.strip()
            status["pull_request"] = open_pull_request(token, base, new_text, body)
    (out / "status.json").write_text(json.dumps(status, indent=2, sort_keys=True) + "\n")
    if not moved:
        print(f"no drift over {new['rows']} admissions")
    else:
        print(f"drift in {len(moved)} p50s over {new['rows']} admissions: "
              + (status["pull_request"] or f"{out / 'refit.patch'} (no token: apply by hand)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

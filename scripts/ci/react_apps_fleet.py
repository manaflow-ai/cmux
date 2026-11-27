#!/usr/bin/env python3
"""Where a pull request's react-apps-check runs: on the fleet, or on ci-web.yml's Actions shards.

    react_apps_fleet.py decide --class C --matrix JSON --direct F [--routed]   prints `fleet` or `actions`, why on stderr
    react_apps_fleet.py decide --before-pick                                   only the rules that need no pick
    react_apps_fleet.py tests --direct F                                       the touched tests, one a line

Leo, 2026-11-25: "as for jobs, i need us to be defo making sure it runs on our scheduler, which has far more
capabilities than github actions. github actions is just there at the start and end or whatever maybe i guess, but we
own the in-between. all of it". A feat-cmux-next pull request whose shard pick (webviews_pr_shards.py) runs only
touched tests runs react-apps-check as the ci/steps.toml step `react-apps-check` (pr-pipeline.yml's web-browser job,
scripts/ci/react-apps-check-fleet.sh): one warm runner, no per-shard checkout, install, bundle build and engines.
Both sides ask this one function with the same pick, so they agree on every head:

  - fleet: a pull request into feat-cmux-next whose pick class is `fast` (no test file), or `sampled` with an entry
    in --direct for every picked shard (only touched tests, no shard's whole share);
  - actions, the full run: any other event (a push to the base, a dispatch, the post-merge batch), another base, the
    docs-only fallback, the `full-ci` label, a pick that runs whole shards (a build or runner input, a sampled
    ci-web.yml edit, the classes off, a failed pick), the audit sample (one head in CI_REACT_APPS_FLEET_AUDIT, 16 by
    default, by its sha: those keep the 8-shard matrix and its base check, so the two routes stay compared), and
    the repository variable CI_REACT_APPS_FLEET=0 (the off switch: every head runs on Actions, as before);
  - --routed (ci-web.yml's side): also actions when this change routes no web-browser `react-apps-check` step, so a
    path the step's globs miss never leaves the check unrun.

The environment: GITHUB_EVENT_NAME, CI_PR_BASE_REF, CI_FULL_CI (true for the label), CI_PR_HEAD_SHA, GITHUB_WORKFLOW,
CI_REACT_APPS_FLEET, CI_REACT_APPS_FLEET_AUDIT.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = "feat-cmux-next"
STEP = "react-apps-check"
JOB = "web-browser"
AUDIT_DEFAULT = 16


def load_direct(path: Path | None) -> dict[str, list[str]] | None:
    if path is None:
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def audited(sha: str, every: int) -> bool:
    """One head in EVERY by its sha (0 or 1: none)."""
    if every <= 1:
        return False
    try:
        return int(sha, 16) % every == 0
    except ValueError:
        return False


def step_routed(root: Path) -> bool | None:
    """Whether the change (HEAD^1..HEAD) routes the fleet step; None when unknown."""
    sys.path.insert(0, str(root / "scripts" / "ci"))
    try:
        import ci_steps  # noqa: PLC0415
        diff = subprocess.run(["git", "-C", str(root), "diff", "--name-only", "--no-renames", "HEAD^1", "HEAD"],
                              capture_output=True, text=True, check=True, timeout=60).stdout
        table = ci_steps.load(root / "ci" / "steps.toml")
        return STEP in ci_steps.route(table, [p for p in diff.splitlines() if p]).get(JOB, [])
    except Exception:  # noqa: BLE001 - unknown routes to actions
        return None


def decide(cls: str | None, matrix: str, direct: dict[str, list[str]] | None, env: dict[str, str],
           routed: bool | None = True) -> tuple[str, str]:
    """(`fleet` or `actions`, why). CLS None asks only the rules that need no pick (the fleet step, before it picks)."""
    if env.get("CI_REACT_APPS_FLEET", "1") == "0":
        return "actions", "the repository variable CI_REACT_APPS_FLEET is 0"
    if env.get("GITHUB_EVENT_NAME") != "pull_request":
        return "actions", f"a {env.get('GITHUB_EVENT_NAME') or 'local'} run, not a pull request: the full run"
    if env.get("CI_PR_BASE_REF") != BASE:
        return "actions", f"a pull request into {env.get('CI_PR_BASE_REF') or '?'}, not {BASE}"
    if env.get("GITHUB_WORKFLOW") == "docs-only fallback":
        return "actions", "the docs-only fallback runs no pr-pipeline.yml"
    if env.get("CI_FULL_CI") == "true":
        return "actions", "the full-ci label: the full run"
    try:
        every = int(env.get("CI_REACT_APPS_FLEET_AUDIT") or AUDIT_DEFAULT)
    except ValueError:
        every = AUDIT_DEFAULT
    sha = env.get("CI_PR_HEAD_SHA", "")
    if audited(sha, every):
        return "actions", f"head {sha[:12]} is the audit sample (one in {every}): the full run"
    if cls is None:
        return "fleet", "no rule before the pick sends it to Actions"
    if routed is None:
        return "actions", "the step table's route for this change is unknown"
    if not routed:
        return "actions", f"this change routes no {JOB} step {STEP}"
    try:
        shards = [int(entry["shard"]) for entry in json.loads(matrix or "[]")]
    except (ValueError, TypeError, KeyError):
        return "actions", "the shard pick is unreadable"
    if cls == "fast":
        return "fleet", "a fast change (no test file runs)"
    if cls != "sampled":
        return "actions", f"the pick's class is {cls or 'none (classes off or a failed pick)'}: whole shards run"
    if direct is None:
        return "actions", "the pick wrote no touched-test list"
    whole = [s for s in shards if str(s) not in direct]
    if whole:
        return "actions", f"the pick runs whole shards {','.join(map(str, whole))}"
    count = len({f for files in direct.values() for f in files})
    return "fleet", f"{count} touched test{'' if count == 1 else 's'}"


def touched(direct: dict[str, list[str]] | None) -> list[str]:
    return sorted({f for files in (direct or {}).values() for f in files})


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--class", dest="cls", default="")
    d.add_argument("--matrix", default="[]")
    d.add_argument("--direct", type=Path)
    d.add_argument("--routed", action="store_true", help="also require the change to route the fleet step")
    d.add_argument("--repo", type=Path, default=ROOT)
    d.add_argument("--before-pick", action="store_true", help="only the event, base, label, audit and switch rules")
    t = sub.add_parser("tests")
    t.add_argument("--direct", type=Path, required=True)
    args = ap.parse_args(argv)
    if args.command == "tests":
        sys.stdout.write("".join(f + "\n" for f in touched(load_direct(args.direct))))
        return 0
    routed = step_routed(args.repo) if args.routed else True
    where, why = decide(None if args.before_pick else args.cls.strip(), args.matrix, load_direct(args.direct), dict(os.environ), routed)
    print(f"react-apps-check runs on {'the fleet' if where == 'fleet' else 'Actions'}: {why}", file=sys.stderr)
    print(where)
    return 0


if __name__ == "__main__":
    sys.exit(main())

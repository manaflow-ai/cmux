#!/usr/bin/env python3
"""A same-tree run dispatched to report a failed tree reads the tree's publish record first.

cmux_next_tree_notify.py --state failed dispatches cmux-next.yml in same-tree mode with
same_tree_state=failed when an artifacts run ends without publishing a tree. Its job
same-tree-cmux-tui posts the tiers' `(same-tree)` statuses red on the tested commit. A re-run
of that run keeps its dispatch inputs, so before this script it read the old verdict again and
went red again even after a later artifacts run had published the tree; only a fresh push
cleared it (2026-11-11, cmux#40449 at ec4a30d2: run 43009515785 left `cmux app scheme compile
(Debug) (same-tree)` red after the tree was published).

So the failed report reads, at run time, the tree's publish record: its completion.json on R2,
which publish-cmux-tui-tree.py writes last and once (the record cmux_next_tree_notify.py trusts
too). The key is the one the run was dispatched for: notify's reason names it (`tree <key>`).

check: the tree is published. The run dispatches its own same-tree run again on its ref with
  same_tree_state=ready (the same commit, status commit, tiers and run name), marks the tiers'
  statuses pending and exits 0. That ready run's jobs post the real verdicts.
check: the tree is not published (or the key is unknown). Exits 1 and, with --marker, writes a
  tree wait marker for this run's commit and tiers marked `reported`: the caller uploads it as
  `cmux-next-tree-wait-<key>`, so the key's next publication re-dispatches every tier this run
  reported red, even when the marker that started it is gone (deleted, expired, or past
  notify's marker cap), and a failed notify does not report it red again.

usage: cmux_next_same_tree_failed.py --repo OWNER/NAME --ref REF --reason TEXT --commit SHA
       --status-sha SHA --tiers daemon,scheme --origin push|dispatch [--origin-run ID]
       [--ref-kind heads|tags] [--dev-daily-sha SHA] [--tip-suite daemon|base] [--marker PATH]
       [--output PATH]
Needs GH_TOKEN with actions: write and statuses: write.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmux_next_tree_notify as notify  # noqa: E402

SHA = notify.SHA
KEY_IN_REASON = re.compile(r"\btree ([0-9a-f]{40})\b")
# A ready dispatch's reason (cmux_next_tree_notify.py's ready reason names the record).
READY_REASON = "tree {key} is published ({base}/{key}/completion.json); re-dispatched by failed run {run}"


def key_of(reason: str, key: str = "") -> str:
    """The tree key: KEY when given, else the one the failed reason names, else ''."""
    if SHA.match(key):
        return key
    found = KEY_IN_REASON.search(reason or "")
    return found.group(1) if found else ""


def contexts(tiers: list[str], dev_daily: bool) -> list[str]:
    """The `(same-tree)` statuses the failed report posts for TIERS (cmux-next.yml same-tree-cmux-tui)."""
    names = []
    for tier in tiers:
        if tier == "daemon":
            names.append("cmux-next daemon tests (same-tree)")
        elif tier == "scheme":
            names.append("cmux NEXT DEV Release compile (same-tree)" if dev_daily
                         else "cmux app scheme compile (Debug) (same-tree)")
    return names


def ready_inputs(args: argparse.Namespace, key: str, run_id: str) -> dict:
    """This run's dispatch inputs with the state ready: the run name and every tier stay the same."""
    inputs = {
        "same_tree_sha": args.commit,
        "same_tree_status_sha": args.status_sha,
        "same_tree_tiers": ",".join(args.tiers),
        "same_tree_state": "ready",
        "same_tree_reason": READY_REASON.format(key=key, base=notify.TREE_BASE, run=run_id or "?")[:900],
        "same_tree_origin": args.origin,
        "same_tree_origin_run": args.origin_run,
    }
    if args.dev_daily_sha:
        inputs.update(dev_daily="true", dev_daily_sha=args.dev_daily_sha)
    if args.tip_suite:
        inputs[notify.TIP_SUITE_INPUTS[args.tip_suite]] = "true"
    return inputs


def reported_marker(args: argparse.Namespace, key: str, run_id: str) -> dict:
    """The tree wait marker of this run's commit and tiers, as path_route writes it, marked reported."""
    marker = {"version": 1, "key": key, "sha": args.commit, "status_sha": args.status_sha,
              "tiers": list(args.tiers), "run_id": int(args.origin_run) if args.origin_run.isdigit() else 0,
              "origin": args.origin, "branch": args.ref, "reported": True,
              "reported_run": int(run_id) if run_id.isdigit() else 0}
    if args.origin == "dispatch":
        marker["ref_kind"] = args.ref_kind
    if args.dev_daily_sha:
        marker.update(dev_daily=True, dev_daily_sha=args.dev_daily_sha)
    if args.tip_suite:
        marker["tip_suite"] = args.tip_suite
    return marker


def check(api: notify.Api, args: argparse.Namespace, *, run_id: str = "", target_url: str = "",
          fetch_completion: Callable[[str], object | None] = notify.fetch_completion,
          log: Callable[[str], None] = print) -> tuple[bool, str]:
    """(healed, key). Healed: the tree is published and this run's ready same-tree run was dispatched."""
    key = key_of(args.reason, args.key)
    if not key:
        log("the failed reason names no tree key; the tree's publish record cannot be read")
        return False, ""
    if not notify.completion_attests(fetch_completion(key), key):
        log(f"tree {key} has no completion.json on R2: it is still unpublished")
        return False, key
    inputs = ready_inputs(args, key, run_id)
    status = api.post(f"repos/{args.repo}/actions/workflows/{notify.WORKFLOW}/dispatches",
                      {"ref": args.ref, "inputs": inputs})
    if status != 204:
        log(f"::warning::tree {key} is published, but the ready same-tree dispatch on {args.ref} was refused "
            f"(HTTP {status})")
        return False, key
    log(f"tree {key} is published ({notify.TREE_BASE}/{key}/completion.json): dispatched {notify.WORKFLOW} "
        f"same-tree mode (ready) on {args.ref} for {args.commit[:12]}, tiers {inputs['same_tree_tiers']}")
    if SHA.match(args.status_sha):
        for context in contexts(args.tiers, bool(args.dev_daily_sha)):
            body = {"state": "pending", "context": context,
                    "description": "same-tree cmux-tui published; the tree jobs were dispatched"}
            if target_url:
                body["target_url"] = target_url
            if api.post(f"repos/{args.repo}/statuses/{args.status_sha}", body) != 201:
                log(f"::warning::could not mark {context} pending on {args.status_sha[:12]}")
    return True, key


def parse(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--ref", required=True, help="the ref this run is on (github.ref_name)")
    parser.add_argument("--ref-kind", choices=("heads", "tags"), default="heads")
    parser.add_argument("--reason", default="")
    parser.add_argument("--key", default="", help="the tree key, when known; else read from --reason")
    parser.add_argument("--commit", required=True)
    parser.add_argument("--status-sha", required=True)
    parser.add_argument("--tiers", required=True, type=lambda raw: [t for t in raw.split(",") if t])
    parser.add_argument("--origin", required=True, choices=("push", "dispatch"))
    parser.add_argument("--origin-run", default="")
    parser.add_argument("--dev-daily-sha", default="")
    parser.add_argument("--tip-suite", choices=tuple(notify.TIP_SUITES), default=None)
    parser.add_argument("--marker", default="", help="where to write the reported marker when not healed")
    parser.add_argument("--output", default="", help="GITHUB_OUTPUT: key=<key> is appended")
    args = parser.parse_args(argv)
    if not SHA.match(args.commit) or any(tier not in notify.TIERS for tier in args.tiers) or not args.tiers:
        parser.error("--commit must be a 40-hex commit and --tiers daemon and/or scheme")
    return args


def main(argv: list[str]) -> int:
    args = parse(argv)
    token = os.environ.get("GH_TOKEN", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    target_url = f"{server}/{args.repo}/actions/runs/{run_id}" if run_id else ""
    api = notify.GitHub(token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    try:
        healed, key = check(api, args, run_id=run_id, target_url=target_url,
                            fetch_completion=notify.fetch_completion)
    except (RuntimeError, OSError, ValueError) as error:
        print(f"::warning::could not read or act on the tree's publish record: {error}")
        healed, key = False, key_of(args.reason, args.key)
    if args.output and key:
        with open(args.output, "a", encoding="utf-8") as stream:
            stream.write(f"key={key}\n")
    if healed:
        return 0
    if args.marker and key:
        Path(args.marker).parent.mkdir(parents=True, exist_ok=True)
        Path(args.marker).write_text(json.dumps(reported_marker(args, key, run_id)), encoding="utf-8")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

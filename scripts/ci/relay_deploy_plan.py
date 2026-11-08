#!/usr/bin/env python3
"""What a carrier relay run deploys, and the two rules that keep it safe (.github/workflows/cloudflare-relay.yml).

`plan` prints GitHub output lines (mode, sha, version, staging, production, journeys, migrations_changed).
`guard` runs in a deploy job right before it deploys, so a re-run of an old job is checked again.

Ordering: a deploy (push, or dispatch action=deploy) ships only a commit equal to, or a descendant of,
the commit each target relay serves (its GET /version). A re-run of an older push after a newer deploy
is refused. Only action=rollback may go back, and only to a commit on feat-cmux-next.

Migrations: a Durable Object migration cannot be rolled back, so the run waits on relay-migrations
approval when the commit's [[migrations]] differ from what any target relay serves, and also whenever
that cannot be established (a relay reports no commit, or one this checkout lacks). Comparing with the
push's previous commit is not enough: a failed earlier push leaves its migrations unshipped behind it.

Served commits come in as arguments (the workflow reads /version), so the git rules are testable
(tests/test_ci_relay_deploy_plan.py).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tomllib

SHA = re.compile(r"[0-9a-f]{40}")
VERSION_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
WRANGLER = "cmux-tui/relays/cloudflare-do/wrangler.toml"
SOURCE = ("cmux-tui/relays/cloudflare-do", "cmux-tui/crates/cmux-remote-protocol")


class Refused(Exception):
    pass


def git(repo: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def known(repo: str, rev: str) -> bool:
    return bool(SHA.fullmatch(rev or "")) and git(repo, "cat-file", "-e", f"{rev}^{{commit}}").returncode == 0


def ancestor(repo: str, older: str, newer: str) -> bool:
    return git(repo, "merge-base", "--is-ancestor", older, newer).returncode == 0


def migrations(repo: str, rev: str) -> str | None:
    shown = git(repo, "show", f"{rev}:{WRANGLER}")
    if shown.returncode != 0:
        return None
    return json.dumps(tomllib.loads(shown.stdout).get("migrations", []), sort_keys=True)


def check_order(repo: str, worker: str, served: str, source: str) -> None:
    """A deploy never moves a relay to an older or unrelated commit."""
    if known(repo, served) and not ancestor(repo, served, source):
        raise Refused(
            f"{worker} serves {served}, which {source} does not descend from: an older or unrelated source "
            "is refused (a re-run of an old push?); go back only with action=rollback"
        )


def plan(args: argparse.Namespace) -> dict[str, str]:
    repo, tip = args.repo, args.tip
    if args.ref != "refs/heads/feat-cmux-next":
        raise Refused(f"deploys and rollbacks run only from feat-cmux-next, not {args.ref}")
    targets = {"both": ("staging", "production"), "staging": ("staging",), "production": ("production",)}.get(args.target)
    if targets is None:
        raise Refused(f"unknown target {args.target!r}")
    served = {"staging": args.served_staging, "production": args.served_production}
    out = {"mode": "deploy", "sha": tip, "version": "", "journeys": "true", "migrations_changed": "false"}
    rollback = args.event == "workflow_dispatch" and args.action == "rollback"
    if rollback:
        out["journeys"] = "false"
        if SHA.fullmatch(args.rollback_to):
            sha = args.rollback_to
            if not known(repo, sha):
                raise Refused(f"commit {sha} is not in this repository")
            if not ancestor(repo, sha, tip):
                raise Refused(f"commit {sha} is not on feat-cmux-next")
            if migrations(repo, sha) is None:
                raise Refused(f"commit {sha} has no relay")
            out.update(mode="sha", sha=sha)
        elif VERSION_ID.fullmatch(args.rollback_to):
            if args.target == "both":
                raise Refused("a version id names one Worker: pick target staging or production")
            out.update(mode="version", version=args.rollback_to)
        else:
            raise Refused(f"rollback_to must be a Worker version id or a 40-hex commit, got {args.rollback_to!r}")
    elif args.event == "workflow_dispatch" and args.action != "deploy":
        raise Refused(f"unknown action {args.action!r}")
    elif targets == ("production",):
        raise Refused("a deploy reaches production only through staging (target both); roll back with action=rollback")

    if out["mode"] == "deploy":
        for env in targets:
            check_order(repo, env, served[env], out["sha"])
        unchanged = all(
            known(repo, served[env])
            and git(repo, "diff", "--quiet", served[env], out["sha"], "--", *SOURCE).returncode == 0
            for env in ("staging", "production")
        )
        if args.event == "push" and unchanged:
            print("both relays already serve this relay source; nothing to deploy", file=sys.stderr)
            out.update(mode="skip", journeys="false")
            targets = ()

    if out["mode"] in ("deploy", "sha") and targets:
        want = migrations(repo, out["sha"])
        for env in targets:
            if not known(repo, served[env]):
                print(f"relay migrations: {env} reports no known commit; approval required", file=sys.stderr)
                out["migrations_changed"] = "true"
            elif migrations(repo, served[env]) != want:
                print(f"relay migrations: differ from {env}'s {served[env]}; approval required", file=sys.stderr)
                out["migrations_changed"] = "true"

    out["staging"] = "true" if "staging" in targets else "false"
    out["production"] = "true" if "production" in targets else "false"
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--repo", default=".")
    p.add_argument("--tip", required=True, help="the run's commit (github.sha), the feat-cmux-next tip")
    p.add_argument("--event", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--action", default="deploy")
    p.add_argument("--target", default="both")
    p.add_argument("--rollback-to", default="")
    p.add_argument("--served-staging", default="")
    p.add_argument("--served-production", default="")
    g = sub.add_parser("guard")
    g.add_argument("--repo", default=".")
    g.add_argument("--worker", required=True)
    g.add_argument("--mode", required=True)
    g.add_argument("--source", required=True)
    g.add_argument("--served", default="")
    args = parser.parse_args(argv)
    try:
        if args.command == "guard":
            if args.mode == "deploy":
                check_order(args.repo, args.worker, args.served, args.source)
            print(f"{args.worker}: {args.mode} of {args.source or 'a version'} admitted (serving {args.served or 'unknown'})")
            return 0
        for key, value in plan(args).items():
            print(f"{key}={value}")
        return 0
    except Refused as refused:
        print(f"::error title=Cloudflare relay::{refused}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

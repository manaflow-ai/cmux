#!/usr/bin/env python3
"""The cheapest build that shows a change, per app: what a dev-build request should ask the fleet for.

Leo, 2026-11-24: "i guess if he's complaining, we can also examine if his recent prs have actually needed
dev builds? examine better architecture potentially. more hot swapping whether it be gui or phone."

    build_select.py [--repo DIR] [--json] BASE HEAD

Reads `git diff BASE HEAD` (no GitHub API, no fleet) and prints one line per app, or one JSON object:

  mac   none    nothing the Mac app builds or bundles changed: any build of BASE is this head's Mac app
                (review.sh asks for BASE's build with --any-tag, which a build the fleet already made answers)
        swap    only what a copy of the NIGHTLY takes live (web UI, string catalogs, the daemon):
                `cmux app try` (docs/handbook/swap-before-dev-build.md); a build still works, it is only slower
        build   a new Mac app: Swift outside a function body, a manifest, resource, entitlement, or a helper
                the app bundles (cmux-mobile-host builds from cmux-next-ios/rust, so an iPhone link change is a
                Mac change too)
  ios   none    nothing the iPhone app builds changed (the ios-kit step's inputs in ci/steps.toml, the
                same filter that starts the iPhone try build-ahead)
        build   the iPhone app changed

The Mac side is live_apply.py's verdict (what a running app takes without a build) floored by hot-apply.py's
bundled_inputs (what the app bundle builds or copies beside bin/: Xcode $(SRCROOT) inputs and
cmux-mobile-host's own inputs), so a path live_apply calls ios-only or no-app but the Mac bundles still builds.
Advice for the caller: nothing here refuses or skips a build by itself.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "scripts/ci"))
import live_apply  # noqa: E402

IOS_WORKFLOW = ".github/workflows/cmux-next-ios-kit.yml"
# live_apply kinds a copy of the NIGHTLY takes with no build (try-pr.sh's web-live, strings and daemon paths).
SWAP_KINDS = ("web-live", "strings", "daemon")
# live_apply kinds that change the Mac app; ios-only and no-app do not, unless the bundle builds them.
MAC_KINDS = ("rebuild", "swift-live", *SWAP_KINDS)


def _hot_apply():
    spec = importlib.util.spec_from_file_location("hot_apply", HERE / "hot-apply.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("hot_apply", module)
    spec.loader.exec_module(module)
    return module


def bundled_inputs(repo: Path) -> list[str]:
    """hot-apply.py's list of what the Mac bundle builds or copies beside bin/."""
    return _hot_apply().bundled_inputs(repo)


def _glob_regex(pattern: str) -> re.Pattern:
    """A GitHub `paths:` glob: `**` crosses folders, `*` and `?` do not."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z")


def path_filter(patterns: list[str]):
    """GitHub's rule: the last pattern that matches a path decides, and a `!` pattern excludes it."""
    compiled = [(p.startswith("!"), _glob_regex(p.lstrip("!"))) for p in patterns]

    def matches(path: str) -> bool:
        hit = False
        for negated, regex in compiled:
            if regex.match(path):
                hit = not negated
        return hit
    return matches


def ios_filter(repo: Path):
    """What the iPhone app builds: the `ios-kit` step's inputs less its `ignore` (ci/steps.toml; a feat-cmux-next
    pull request runs the kit there, CI v2 step 11, and cmux-next-ios-kit.yml no longer has a pull_request filter)."""
    import ci_steps
    step = ci_steps.load(repo / "ci/steps.toml").steps.get("ios-kit")
    if step is None or not step.inputs:
        raise SystemExit("build_select: ci/steps.toml has no ios-kit step with inputs")
    included, dropped = path_filter(list(step.inputs)), path_filter(list(step.ignore))
    return lambda path: included(path) and not dropped(path)


def _under(path: str, roots: list[str]) -> bool:
    return any(path == r or path.startswith(r + "/") for r in roots)


def select(result: dict, changed: list[str], bundled: list[str], ios_matches) -> dict:
    """result: live_apply.classify's; changed: every changed path; bundled: bundled_inputs(); ios_matches: a path
    predicate. Returns {"mac", "ios", "why": {app: {reason: [paths]}}, "live_apply"}."""
    files = result["files"]
    why_mac: dict[str, list[str]] = {}
    for kind in MAC_KINDS:
        if files.get(kind):
            why_mac[kind] = files[kind]
    helpers = sorted(p for kind in ("ios-only", "no-app") for p in files.get(kind, []) if _under(p, bundled))
    if helpers:
        why_mac["bundled by the Mac app"] = helpers
    if not why_mac:
        mac = "none"
    elif set(why_mac) <= set(SWAP_KINDS) and not any(_under(p, bundled) for p in files.get("daemon", [])):
        mac = "swap"
    else:
        mac = "build"
        for reason, paths in result.get("reasons", {}).items():
            why_mac.setdefault(f"rebuild: {reason}", paths)
    ios_paths = sorted(p for p in changed if ios_matches(p))
    return {"mac": mac, "ios": "build" if ios_paths else "none",
            "why": {"mac": why_mac, "ios": {"iPhone app input": ios_paths} if ios_paths else {}},
            "live_apply": result["verdict"]}


def select_range(repo: Path, base: str, head: str) -> dict:
    result = live_apply.classify_range(str(repo), base, head)
    changed = sorted({p for paths in result["files"].values() for p in paths})
    return select(result, changed, bundled_inputs(repo), ios_filter(repo))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--json", action="store_true")
    parser.add_argument("base")
    parser.add_argument("head")
    args = parser.parse_args(argv)
    try:
        out = select_range(Path(args.repo), args.base, args.head)
    except subprocess.CalledProcessError as err:
        print(f"build_select: git failed: {(err.stderr or '').strip()}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(out, indent=2))
        return 0
    for app in ("mac", "ios"):
        print(f"{app}\t{out[app]}")
        for reason, paths in sorted(out["why"][app].items()):
            print(f"  {reason}: {', '.join(paths[:5])}{' ...' if len(paths) > 5 else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

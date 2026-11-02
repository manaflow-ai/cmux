#!/usr/bin/env python3
"""Replays recent pull requests' changed files through the base router and this tree's router.

The checks job runs it when a pull request changes the router: the old router is the merge
commit's base parent (HEAD^1), the new one is the working tree. A tier change is explained only
when the new router drops tiers or narrows the Swift test targets and says why: its "(no Mac
tier)" reason (a fast tier, or a doc no test reads), or, for the Mac fast tier alone, its "(no Mac
fast tier)" reason. Any other change (an added tier, a widened or unexplained target set, a dropped
tier without such a reason) is unexplained and fails. A base router without the fast_tier output
ran the fast tier on every pull request with a Mac tier, so its fast_tier is its macos.

Usage: cmux_next_route_replay.py [--base HEAD^1] [--limit 30] [--repo manaflow-ai/cmux]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_pages  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TIERS = ("native", "macos", "scheme", "generated", "swift", "daemon", "full", "fast_tier")
FAST_REASON = "(no Mac tier)"
NO_FAST_TIER_REASON = "(no Mac fast tier)"
# The router imports these from scripts/ci; the old router gets its own copies.
ROUTER_FILES = ("cmux_next_route.py", "select_package_tests.py")

Router = Callable[[list[str]], tuple[dict[str, str], list[str]]]


@dataclass
class Verdict:
    kind: str  # same, explained, unexplained
    detail: str = ""


def tier(outputs: dict[str, str], name: str) -> str:
    # A router from before the fast_tier output ran the Mac fast tier whenever it ran any Mac tier.
    return outputs.get(name, outputs.get("macos", "false")) if name == "fast_tier" else outputs[name]


def compare(old: dict[str, str], new: dict[str, str], new_reasons: list[str]) -> Verdict:
    added = [t for t in TIERS if tier(old, t) == "false" and tier(new, t) == "true"]
    dropped = [t for t in TIERS if tier(old, t) == "true" and tier(new, t) == "false"]
    before, after = set(old.get("swift_targets", "").split()), set(new.get("swift_targets", "").split())
    widened = bool(after - before) and "all" not in before
    narrowed = before != after and not widened
    if not added and not dropped and before == after:
        return Verdict("same")
    if added or widened or (narrowed and not dropped and not any(FAST_REASON in r for r in new_reasons)):
        return Verdict("unexplained", f"added {', '.join(added) or 'none'}; swift targets "
                                      f"{old.get('swift_targets') or '-'} -> {new.get('swift_targets') or '-'}")
    change = ", ".join(dropped) if dropped else f"swift targets {old.get('swift_targets') or '-'} -> {new.get('swift_targets') or '-'}"
    if any(FAST_REASON in reason for reason in new_reasons):
        return Verdict("explained", f"dropped {change}: {next(r for r in new_reasons if FAST_REASON in r)}")
    if dropped == ["fast_tier"] and before == after and any(NO_FAST_TIER_REASON in r for r in new_reasons):
        return Verdict("explained", f"dropped fast_tier: {next(r for r in new_reasons if NO_FAST_TIER_REASON in r)}")
    return Verdict("unexplained", f"dropped {change} with no fast-tier reason")


# A cmux-tui path no Swift compile reads (the router's NO_SWIFT_COMPILE_REASON) drops only the Swift
# compiles: native and scheme, nothing else, and the same Swift test targets.
NO_SWIFT_COMPILE_REASON = "(no Swift compile reads it)"
SWIFT_COMPILE_TIERS = frozenset(("native", "scheme"))


def explain(old: dict[str, str], new: dict[str, str], new_reasons: list[str]) -> Verdict:
    """compare(), and a drop of the Swift compiles alone is explained by the router's no-Swift-compile reason."""
    verdict = compare(old, new, new_reasons)
    if verdict.kind != "unexplained":
        return verdict
    added = [t for t in TIERS if tier(old, t) == "false" and tier(new, t) == "true"]
    dropped = {t for t in TIERS if tier(old, t) == "true" and tier(new, t) == "false"}
    reason = next((r for r in new_reasons if NO_SWIFT_COMPILE_REASON in r), None)
    if (reason and dropped and dropped <= SWIFT_COMPILE_TIERS and not added
            and old.get("swift_targets", "") == new.get("swift_targets", "")):
        return Verdict("explained", f"dropped {', '.join(sorted(dropped))}: {reason}")
    return verdict


def replay(prs: list[tuple[int, list[str]]], old: Router, new: Router) -> tuple[list[str], bool]:
    lines, failed = [], False
    for number, files in prs:
        before, _ = old(files)
        after, reasons = new(files)
        verdict = explain(before, after, reasons)
        failed |= verdict.kind == "unexplained"
        label = "UNEXPLAINED" if verdict.kind == "unexplained" else verdict.kind
        lines.append(f"#{number} {label} ({len(files)} files){': ' + verdict.detail if verdict.detail else ''}")
    return lines, failed


def _load(directory: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, directory / "cmux_next_route.py")
    module = sys.modules[name] = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(directory))
    try:
        sys.modules.pop("select_package_tests", None)
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(directory))
        sys.modules.pop("select_package_tests", None)
    return module


def _router(module, root: Path) -> Router:
    def route(files: list[str]) -> tuple[dict[str, str], list[str]]:
        result = module.route(root, "pull_request", files, set())
        return module.outputs(result), list(result.reasons)
    return route


def load_router(root: Path, ref: str | None) -> Router:
    """The router at a git ref (copied out of git), or the working tree's when ref is None."""
    if ref is None:
        return _router(_load(root / "scripts" / "ci", "cmux_next_route_new"), root)
    directory = Path(tempfile.mkdtemp(prefix="route-"))
    for name in ROUTER_FILES:
        text = subprocess.run(["git", "show", f"{ref}:scripts/ci/{name}"], cwd=root, check=True,
                              capture_output=True, text=True).stdout
        (directory / name).write_text(text)
    return _router(_load(directory, "cmux_next_route_old"), root)


def recent_prs(repo: str, limit: int) -> list[tuple[int, list[str]]]:
    """The last `limit` merged pull requests into feat-cmux-next and their changed files."""
    pulls = json.loads(subprocess.run(
        ["gh", "api", f"repos/{repo}/pulls?state=closed&base=feat-cmux-next&sort=updated&direction=desc&per_page=100"],
        check=True, capture_output=True, text=True).stdout)
    merged = [p["number"] for p in pulls if p.get("merged_at")][:limit]
    out = []
    for number in merged:
        # One bounded page per call (scripts/ci/gh_pages.py): the gh quota wrapper refuses an
        # unbounded paginating call. A list at GitHub's 3000-file cap may be incomplete: skip it.
        try:
            files = [entry["filename"] for entry in gh_pages.items(gh_pages.gh_json, f"repos/{repo}/pulls/{number}/files")]
        except gh_pages.PageCapError:
            continue
        if files and len(files) < 3000:
            out.append((number, files))
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default="HEAD^1", help="git ref of the old router")
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--repo", default="manaflow-ai/cmux")
    a = parser.parse_args(argv)
    prs = recent_prs(a.repo, a.limit)
    lines, failed = replay(prs, load_router(ROOT, a.base), load_router(ROOT, None))
    print(f"Routing replay: {len(prs)} merged PRs, base router {a.base} vs this tree")
    print("\n".join(lines))
    if failed:
        print("::error::The router changes tiers it does not explain; see the UNEXPLAINED lines.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

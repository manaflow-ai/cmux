#!/usr/bin/env python3
"""Plan which webview test shard a pull request actually needs.

The workflow keeps a fixed matrix so push runs retain their duration history. For a pull request,
webviews_affected selects the tests reachable from the diff, then this planner assigns those files
with the same duration manifest and lane widths as run-webviews-tests.sh. A shard with no selected
files skips setup only with cached green file verdicts at the exact merge parent. Missing history
preserves the affected-test selection and runs setup. Shard 1 always runs shared checks.

The JSON output contains ``run`` (whether this shard has tests), ``setup`` (whether it must install
the shared web checks), ``mode`` (``focused`` or ``full``), and ``files`` (newline-separated paths
relative to webviews/).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import webviews_affected  # noqa: E402
import webviews_test_shards  # noqa: E402
import webviews_test_history  # noqa: E402

TEST_GLOBS = (
    "*.test.ts", "*.test.tsx", "*.test.js", "*.test.jsx", "*.test.mjs",
    "*_test.ts", "*_test.tsx", "*.spec.ts", "*.spec.tsx", "*_spec.ts", "*_spec.tsx",
)
DEV_SERVERS = re.compile(
    r"vite\.config\.(acpmux-pane\.mjs|gallery-dev\.ts)|\"dev\",|"
    r"configFile: path\.join\(webviews, \"vite\.config"
)


def test_files(root: Path) -> list[str]:
    """The runner's tracked test list, relative to the webviews directory."""
    args = ["git", "-C", str(root / "webviews"), "ls-files", "-z", "--cached", "--", *TEST_GLOBS]
    raw = subprocess.run(args, check=True, capture_output=True).stdout
    return [item.decode() for item in raw.split(b"\0") if item]


def assign(root: Path, files: list[str], manifest: Path, shard: int, count: int) -> list[str]:
    """Return files assigned to the one-based shard, matching run-webviews-tests.sh."""
    web = root / "webviews"
    serial = {name for name in files if DEV_SERVERS.search((web / name).read_text(encoding="utf-8", errors="replace"))}
    durations = webviews_test_shards.load_durations(manifest)
    # webviews_test_shards classifies browser/dev-server files by reading the path from the
    # runner's webviews/ working directory. Keep that same boundary while planning from repo root.
    old_cwd = Path.cwd()
    try:
        import os
        os.chdir(web)
        targets = webviews_test_shards.assign(
            files,
            serial,
            durations,
            count,
            widths=(6, 2, 4),  # CMUX_WEB_TEST_JOBS=8, sized for the 16-vCPU split.
            head_start={0: 120},
        )
    finally:
        os.chdir(old_cwd)
    return [name for name, target in zip(files, targets) if target == shard - 1]


def plan(root: Path, base: str, head: str, manifest: Path, shard: int, count: int,
         pull_request: bool, full_ci: bool, history: Path | None = None) -> dict[str, object]:
    files = test_files(root)
    if not pull_request or full_ci:
        return {"run": True, "setup": True, "mode": "full", "files": ""}
    changed = webviews_affected.changed(root, base, head)
    selected, _ = webviews_affected.Selector(root).select(changed)
    if selected is None:
        return {"run": True, "setup": True, "mode": "full", "files": ""}
    wanted = sorted(path.removeprefix("webviews/") for path in selected)
    assigned = assign(root, wanted, manifest, shard, count)
    # Missing history must not turn the existing affected-test selection into the
    # full suite. It only prevents skipping setup on an empty shard. Shard 1
    # always does the shared checks, whether or not it has test files.
    cached_green = False
    if history is not None:
        base_sha = subprocess.run(["git", "-C", str(root), "rev-parse", base],
                                  check=True, capture_output=True, text=True).stdout.strip()
        runs = [run for run in webviews_test_history.load(history) if run["sha"] == base_sha]
        if runs:
            latest = max(runs, key=lambda run: (run["time"], run.get("attempt", 1)))
            if all(isinstance(name, str) for name in latest["files"] + latest["red"]):
                covered = set(latest["files"])
                red = {name.split(" > ", 1)[0] for name in latest["red"]}
                cached_green = set(files) - set(wanted) <= covered - red
    return {"run": bool(assigned), "setup": bool(assigned) or shard == 1 or not cached_green,
            "mode": "focused", "files": "\n".join(assigned)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--history", type=Path)
    parser.add_argument("--shard", type=int, required=True)
    parser.add_argument("--shard-count", type=int, required=True)
    parser.add_argument("--pull-request", action="store_true")
    parser.add_argument("--full-ci", action="store_true")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    if not 1 <= args.shard <= args.shard_count:
        parser.error("--shard must be in 1..--shard-count")
    try:
        result = plan(args.root.resolve(), args.base, args.head, args.manifest, args.shard, args.shard_count,
                      args.pull_request, args.full_ci, args.history)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        # Shards plan independently. Falling back on only one would mix two
        # assignments and could omit a selected test. Do not emit a result.
        print(f"webview shard scope: cannot plan this shard: {error}", file=sys.stderr)
        return 2
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

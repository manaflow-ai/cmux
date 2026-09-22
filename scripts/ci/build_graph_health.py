#!/usr/bin/env python3
"""Report edit-weighted Swift source ownership for build-graph work."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True)


def classify_path(path: str) -> tuple[str, str]:
    if path.startswith("Sources/"):
        rest = path[len("Sources/"):]
        directory = rest.split("/", 1)[0] if "/" in rest else "<root>"
        return ("app", directory)
    if path.startswith("CLI/"):
        return ("cli", "CLI")
    parts = path.split("/")
    if len(parts) >= 4 and parts[0] == "Packages" and parts[1] in {"macOS", "iOS", "Shared"}:
        return ("package", f"{parts[1]}/{parts[2]}")
    return ("other", path.split("/", 1)[0])


def tracked_swift_files() -> list[str]:
    output = git("ls-files", "-z", "*.swift")
    return [path for path in output.split("\0") if path]


def parse_touch_log(output: str) -> tuple[int, Counter[str]]:
    commits = 0
    touches: Counter[str] = Counter()
    seen_this_commit: set[str] = set()
    for raw in output.split("\0"):
        token = raw.removeprefix("\n")
        if not token:
            continue
        if token.startswith("commit:"):
            commits += 1
            seen_this_commit = set()
            continue
        if not token.endswith(".swift") or token in seen_this_commit:
            continue
        seen_this_commit.add(token)
        touches[token] += 1
    return commits, touches


def recent_touch_counts(days: int) -> tuple[int, Counter[str]]:
    output = git(
        "log",
        "--first-parent",
        f"--since={days}.days",
        "--format=commit:%H%x00",
        "--name-only",
        "-z",
        "--no-renames",
        "--",
        "Sources",
        "Packages",
        "CLI",
    )
    return parse_touch_log(output)


def summarize(files: list[str], touches: Counter[str], commits: int, days: int, top: int) -> dict[str, object]:
    current_by_owner: Counter[str] = Counter()
    current_by_group: Counter[str] = Counter()
    for path in files:
        owner, group = classify_path(path)
        current_by_owner[owner] += 1
        current_by_group[f"{owner}:{group}"] += 1

    touches_by_owner: Counter[str] = Counter()
    touches_by_group: Counter[str] = Counter()
    for path, count in touches.items():
        owner, group = classify_path(path)
        touches_by_owner[owner] += count
        touches_by_group[f"{owner}:{group}"] += count

    total_touches = sum(touches.values())
    app_touches = touches_by_owner["app"]

    def top_rows(counter: Counter[str]) -> list[dict[str, object]]:
        return [{"name": name, "touches": count} for name, count in counter.most_common(top)]

    return {
        "schema_version": 1,
        "window_days": days,
        "first_parent_commits": commits,
        "current_swift_files": {
            "total": len(files),
            "by_owner": dict(sorted(current_by_owner.items())),
            "by_group": dict(sorted(current_by_group.items())),
        },
        "recent_swift_file_touches": {
            "total": total_touches,
            "app": app_touches,
            "app_share": (app_touches / total_touches) if total_touches else 0.0,
            "by_owner": dict(sorted(touches_by_owner.items())),
            "top_groups": top_rows(touches_by_group),
            "top_files": [
                {"path": path, "touches": count}
                for path, count in touches.most_common(top)
            ],
        },
    }


def print_summary(data: dict[str, object]) -> None:
    touches = dict(data["recent_swift_file_touches"])
    files = dict(data["current_swift_files"])
    print(f"Build graph health ({data['window_days']}d)")
    print(f"  first-parent commits: {data['first_parent_commits']}")
    print(f"  tracked Swift files: {files['total']}")
    print(f"  Swift file touches: {touches['total']}")
    print(f"  app Sources/ touches: {touches['app']} ({touches['app_share']:.1%})")
    print("  top edit groups:")
    for row in list(touches["top_groups"])[:10]:
        print(f"    {row['name']}: {row['touches']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    if args.days <= 0 or args.top <= 0:
        parser.error("--days and --top must be positive")

    files = tracked_swift_files()
    commits, touches = recent_touch_counts(args.days)
    data = summarize(files, touches, commits, args.days, args.top)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print_summary(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

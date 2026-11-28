#!/usr/bin/env python3
"""Report edit-weighted Swift source ownership for build-graph work."""

from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import json
from pathlib import Path
import subprocess


def git(*args: str) -> str:
    """Run Git and preserve its textual output exactly."""
    return subprocess.check_output(["git", *args], text=True)


def resolve_ref(ref: str) -> tuple[str, int]:
    """Resolve one revision to an immutable commit and its committer timestamp."""
    commit = git(
        "rev-parse",
        "--verify",
        "--end-of-options",
        f"{ref}^{{commit}}",
    ).strip()
    timestamp = int(git("show", "-s", "--format=%ct", commit).strip())
    return commit, timestamp


def classify_path(path: str) -> tuple[str, str]:
    """Classify a Swift path into the broad owner and edit-report group."""
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


def tracked_swift_files(ref: str) -> list[str]:
    """List Swift files from one immutable tree, independent of the worktree index."""
    output = git("ls-tree", "-r", "-z", "--name-only", ref, "--", "*.swift")
    return [path for path in output.split("\0") if path]


def parse_touch_log(output: str) -> tuple[int, Counter[str]]:
    """Parse NUL-framed first-parent Git history into per-file touch counts."""
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


def window_start_iso(days: int, window_end_epoch: int) -> str:
    """Return the UTC history-window boundary anchored to a commit timestamp."""
    window_start = dt.datetime.fromtimestamp(
        window_end_epoch,
        tz=dt.timezone.utc,
    ) - dt.timedelta(days=days)
    return window_start.isoformat()


def history_commit_count(days: int, ref: str, window_end_epoch: int) -> int:
    """Count every first-parent commit in the selected history window."""
    return int(
        git(
            "rev-list",
            "--first-parent",
            "--count",
            f"--since={window_start_iso(days, window_end_epoch)}",
            ref,
        ).strip()
    )


def recent_touch_counts(
    days: int,
    ref: str,
    window_end_epoch: int,
) -> tuple[int, Counter[str]]:
    """Count source-root commits and Swift touches in the selected window."""
    output = git(
        "log",
        "--first-parent",
        f"--since={window_start_iso(days, window_end_epoch)}",
        "--format=commit:%H%x00",
        "--name-only",
        "-z",
        "--no-renames",
        ref,
        "--",
        "Sources",
        "Packages",
        "CLI",
    )
    return parse_touch_log(output)


def summarize(
    files: list[str],
    touches: Counter[str],
    source_commits: int,
    history_commits: int,
    days: int,
    top: int,
) -> dict[str, object]:
    """Build the versioned ownership and recent-edit report payload."""
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
        """Render the most active groups in descending edit volume."""
        return [{"name": name, "touches": count} for name, count in counter.most_common(top)]

    return {
        "schema_version": 1,
        "window_days": days,
        "first_parent_commits": history_commits,
        "first_parent_source_commits": source_commits,
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
    """Print a compact human summary beside the machine-readable receipt."""
    touches = dict(data["recent_swift_file_touches"])
    files = dict(data["current_swift_files"])
    source = dict(data["source"])
    print(f"Build graph health ({data['window_days']}d)")
    print(f"  source: {source['ref']} @ {str(source['commit'])[:12]}")
    print(f"  first-parent commits: {data['first_parent_commits']}")
    print(
        "  commits touching Sources/Packages/CLI: "
        f"{data['first_parent_source_commits']}"
    )
    print(f"  tracked Swift files: {files['total']}")
    print(f"  Swift file touches: {touches['total']}")
    print(f"  app Sources/ touches: {touches['app']} ({touches['app_share']:.1%})")
    print("  top edit groups:")
    for row in list(touches["top_groups"])[:10]:
        print(f"    {row['name']}: {row['touches']}")


def main() -> int:
    """Parse CLI arguments, collect one immutable report, and emit it."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ref",
        default="HEAD",
        help="Git revision to report (default: HEAD)",
    )
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    if args.days <= 0 or args.top <= 0:
        parser.error("--days and --top must be positive")

    commit, window_end_epoch = resolve_ref(args.ref)
    files = tracked_swift_files(commit)
    history_commits = history_commit_count(args.days, commit, window_end_epoch)
    source_commits, touches = recent_touch_counts(args.days, commit, window_end_epoch)
    data = summarize(
        files,
        touches,
        source_commits,
        history_commits,
        args.days,
        args.top,
    )
    data["source"] = {
        "ref": args.ref,
        "commit": commit,
        "window_end_commit_time": dt.datetime.fromtimestamp(
            window_end_epoch,
            tz=dt.timezone.utc,
        ).isoformat(),
    }

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print_summary(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""What share of recent NEXT PRs try-pr.sh puts into a running nightly with no app build.

    scripts/measure/try-pr-live-share.py [--count 1000] [--ref origin/feat-cmux-next] [--json]

Reads the last COUNT squash-merged PRs on REF's first-parent history (subjects ending in "(#N)";
base autofixes are left out) offline from git, sorts each with live_apply.py, and counts the PRs
that touch the app by what try-pr.sh does with them on a nightly (no live code build):

  web        web-live: the PR's web UI is served into the app
  daemon     daemon: the PR's daemon is swapped in (hot-apply.py's rule: no Rust the app links)
  daemon-ffi daemon, but it changes Rust the app links through FFI: the dev build
  swift      swift-live: live code needs a live code build, so a nightly takes the dev build
  rebuild    the dev build

`before` is the share try-pr took live before the daemon swap (web), `after` with it (web + daemon).
"""
import argparse
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import live_apply  # noqa: E402

spec = importlib.util.spec_from_file_location("hot_apply", ROOT / "scripts/cmux-next/hot-apply.py")
hot_apply = importlib.util.module_from_spec(spec)
sys.modules["hot_apply"] = hot_apply
spec.loader.exec_module(hot_apply)

PR = re.compile(r"\(#(\d+)\)$")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=1000)
    parser.add_argument("--ref", default="origin/feat-cmux-next")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    log = subprocess.run(["git", "-C", str(ROOT), "log", "--first-parent", "--format=%H %s", args.ref],
                         capture_output=True, text=True, check=True).stdout.splitlines()
    rows = []
    for line in log:
        sha, _, subject = line.partition(" ")
        match = PR.search(subject)
        if not match:
            continue
        result = live_apply.classify_range(str(ROOT), f"{sha}^", sha)
        verdict = result["verdict"]
        kind = {"web-live": "web", "swift-live": "swift", "rebuild": "rebuild", "daemon": "daemon"}.get(verdict, verdict)
        if verdict == "daemon" and hot_apply.linked_rust(ROOT, result["files"].get("daemon", [])):
            kind = "daemon-ffi"
        rows.append({"pr": int(match.group(1)), "sha": sha, "kind": kind})
        if len(rows) == args.count:
            break
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["kind"]] = counts.get(row["kind"], 0) + 1
    app = sum(n for k, n in counts.items() if k not in ("no-app", "ios-only"))
    out = {"prs": len(rows), "first": rows[-1]["pr"] if rows else None, "last": rows[0]["pr"] if rows else None,
           "counts": counts, "app_prs": app,
           "before": round(100 * counts.get("web", 0) / app, 1) if app else None,
           "after": round(100 * (counts.get("web", 0) + counts.get("daemon", 0)) / app, 1) if app else None}
    if args.json:
        out["rows"] = rows
    print(json.dumps(out, indent=None if args.json else 2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

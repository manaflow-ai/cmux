#!/usr/bin/env python3
"""Merge-to-served time of the web updates a NIGHTLY took (plans/cmux-next/web-ota.md).

Reads one app's web-updates state (read-only) and prints, for its active and previous update:
when the commit merged (`committed_at`), when CI published its signed pointer (`published_at`),
and when this app unpacked the tree (the mtime of trees/<key>), with the publish-side and
app-side gaps. No app call, no network; safe on Leo's own NIGHTLY.

Run on the Mac that runs the app:
  python3 scripts/measure/web-ota-pickup.py [--bundle com.cmuxterm.app.nightly[.<tag>]] [--json]
Another Mac, with no checkout there:
  reach air-blue 'python3 - --json' < scripts/measure/web-ota-pickup.py
"""

import argparse
import datetime
import json
import os
import sys


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", default="com.cmuxterm.app.nightly")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    root = os.path.expanduser(f"~/Library/Application Support/{args.bundle}/web-updates")
    try:
        with open(os.path.join(root, "state.json")) as f:
            state = json.load(f)
    except FileNotFoundError:
        print(f"no web update state at {root}", file=sys.stderr)
        return 1
    rows = []
    for slot in ("active", "previous"):
        p = state.get(slot)
        if not p:
            continue
        tree = os.path.join(root, "trees", p["key"])
        taken = os.stat(tree).st_mtime if os.path.isdir(tree) else None
        rows.append({
            "slot": slot,
            "commit": p["commit"][:9],
            "channel": p.get("channel"),
            "merged": iso(p["committed_at"]),
            "published": iso(p["published_at"]),
            "taken": iso(taken) if taken else None,
            "publish_s": p["published_at"] - p["committed_at"],
            "app_s": round(taken - p["published_at"]) if taken else None,
            "merge_to_served_s": round(taken - p["committed_at"]) if taken else None,
        })
    if args.json:
        print(json.dumps({"bundle": args.bundle, "now": iso(datetime.datetime.now().timestamp()), "updates": rows}))
        return 0
    for r in rows:
        print(f"{r['slot']:8} {r['commit']} merged {r['merged']} published {r['published']} (+{r['publish_s']} s) "
              f"taken {r['taken']} (+{r['app_s']} s) merge-to-served {r['merge_to_served_s']} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())

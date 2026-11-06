#!/usr/bin/env python3
"""nightly.yml: the published build that the post-publication jobs describe.

nightly-next has one push group (nightly-build-nightly-next-push): one run builds and the newest
pushed head waits for the whole run, including what follows the feed. Those jobs (GitHub release,
deltas, dSYMs, release notes, reel) held the group 17 to 35 minutes after the feed went live on
the 7 runs before 2026-11-06, so a new push waited for them (run 42149108998: 20 of its 43 queued
minutes). Now the push run ends at publish-nightly. dispatch-published-in packs this record into a
dispatched nightly.yml run (nightly_next_post_publish), whose published-build job hands it to those
jobs, outside the push group. Main's nightly and RC run the same jobs in their own run, from the
same record of that run's own jobs.

    nightly_published_build.py pack
        NEEDS (toJSON(needs)), RUN_ID, RUN_ATTEMPT, SHA: prints the dispatch input.
    nightly_published_build.py outputs
        SOURCE (the dispatch input; empty in the run that published), else NEEDS, RUN_ID,
        RUN_ATTEMPT, SHA: writes the record to GITHUB_OUTPUT.

A dispatch input without "tail" came from a push run that ran those jobs itself: only its PR
comments are left (comment=true), and the rest stay empty, so every other job skips.
"""
from __future__ import annotations

import json
import os
import re
import sys

# job -> (output prefix, outputs the post-publication jobs read)
FIELDS = {
    "decide": ("", ("track", "release_name", "release_tag", "channel", "dmg_prefix", "feeds",
                    "fast_build", "should_publish", "variants", "feed_base", "no_publish", "published_sha",
                    "head_sha", "app_name", "notary_test")),
    "publish-nightly": ("publish_", ("already_published", "behind", "behind_hours", "build", "build_sha",
                                     "downloads", "refused", "source", "source_archive", "tag_status",
                                     "tested_pattern", "tip_sha", "variant_pattern")),
    "build-nightly-app": ("", ("daemon_build", "daemon_version")),
    "resolve-nightly-cmux-tui-client": ("resolve_", ("build_sha",)),
}
# push_clean: no job this one needs failed or was cancelled. In the dispatched run, close-nightly-failure-issue
# cannot see the run that published, whose own failed build (a recovered build published after it) reports.
RUN_FIELDS = ("source_run", "source_attempt", "source_sha", "publish_result", "push_clean")
NAMES = RUN_FIELDS + tuple(prefix + name for prefix, names in FIELDS.values() for name in names)
SHA = re.compile(r"[0-9a-f]{40}")


def record(needs: dict, run_id: str, attempt: str, sha: str) -> dict[str, str]:
    out = {"source_run": run_id, "source_attempt": attempt, "source_sha": sha,
           "publish_result": str((needs.get("publish-nightly") or {}).get("result") or ""),
           "push_clean": "false" if any((job or {}).get("result") in ("failure", "cancelled")
                                        for job in needs.values()) else "true"}
    for job, (prefix, names) in FIELDS.items():
        outputs = (needs.get(job) or {}).get("outputs") or {}
        for name in names:
            out[prefix + name] = str(outputs.get(name) or "")
    return out


def comments(rec: dict[str, str]) -> bool:
    """published-in's old dispatch condition: a new build of this run, not a recovered or already published one."""
    return (rec["track"] == "nightly-next" and rec["should_publish"] == "true" and rec["no_publish"] != "true"
            and rec["published_sha"] != "" and rec["publish_result"] == "success"
            and rec["publish_already_published"] != "true" and rec["publish_refused"] != "true"
            and rec["publish_source"] != "recovered")


def valid(rec: dict) -> bool:
    return (isinstance(rec, dict) and set(rec) == set(NAMES) and all(isinstance(v, str) for v in rec.values())
            and rec["source_run"].isdigit() and rec["source_attempt"].isdigit() and bool(SHA.fullmatch(rec["source_sha"])))


def from_env() -> dict[str, str]:
    return record(json.loads(os.environ.get("NEEDS") or "{}"), os.environ["RUN_ID"], os.environ["RUN_ATTEMPT"],
                  os.environ["SHA"])


def pack() -> int:
    rec = from_env()
    print(json.dumps({"source_run": rec["source_run"], "version": rec["daemon_version"],
                      "head_sha": rec["resolve_build_sha"], "published_sha": rec["published_sha"], "tail": rec},
                     separators=(",", ":"), sort_keys=True))
    return 0


def write_outputs() -> int:
    source = os.environ.get("SOURCE", "")
    if source:
        tail = json.loads(source).get("tail")
        if tail is None:
            rec, cross_run, comment = {}, "", True
        elif not valid(tail) or tail["track"] != "nightly-next":
            # Only nightly-next dispatches this run; its environment is release-next (decide's, by ref).
            print("published-build: the dispatch input's tail record is malformed or not nightly-next", file=sys.stderr)
            return 1
        else:
            rec, cross_run, comment = tail, "true", comments(tail)
    else:
        rec, cross_run = from_env(), ""
        comment = False
    lines = [f"{name}={rec.get(name, '')}" for name in NAMES]
    lines += [f"cross_run={cross_run}", f"comment={'true' if comment else 'false'}"]
    if any("\n" in line or "\r" in line for line in lines):
        print("published-build: an output holds a newline", file=sys.stderr)
        return 1
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
        handle.write("".join(line + "\n" for line in lines))
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode == "pack":
        sys.exit(pack())
    if mode == "outputs":
        sys.exit(write_outputs())
    print(__doc__, file=sys.stderr)
    sys.exit(2)

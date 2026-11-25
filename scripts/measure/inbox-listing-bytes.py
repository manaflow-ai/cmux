#!/usr/bin/env python3
"""What an `inbox_read` thread listing spends on what it says twice.

A listing row names its thread under two keys (`threadId` and `key`), carries the whole sender
record the chat pane reads (`threads[].sender`, 13 fields of which most are null) beside the
shown name already in `from`, repeats the reading chat's own `sessionId`, and keeps a flag that
is off and a count that is none. `acpmux_mcp.rs`'s `trim_threads` drops exactly those on the MCP
path; the daemon's own `_acpmux/inbox_threads` answer, which the chat pane reads, is unchanged.

This script replays the agent's real answers through the same rules and prices the difference:

    python3 -I scripts/measure/inbox-listing-bytes.py [--transcripts GLOB] [--files N]

It reads nothing but the transcripts and prints one JSON object, so a lane can paste the number
into a pull request without a fixture.
"""

from __future__ import annotations

import argparse
import glob
import json
import os

TOOL = "mcp__acpmux__inbox_read"
# The row fields a listing leaves at their default: absence says the same in no bytes.
OFF = {"surgeHeld": False, "needYou": False}
NONE = ("new", "unread")


def trimmed(doc: object) -> object:
    """The answer as `trim_threads` leaves it. A thread's own read is not a listing."""
    if not isinstance(doc, dict) or "threads" not in doc:
        return doc
    doc.pop("sessionId", None)
    for row in doc.get("threads") or []:
        if not isinstance(row, dict):
            continue
        if row.get("key") == row.get("threadId"):
            row.pop("key", None)
        row.pop("sender", None)
        for key, off in OFF.items():
            if row.get(key) is off:
                del row[key]
        for key in NONE:
            if row.get(key) == 0:
                del row[key]
    return doc


def answers(path: str):
    """Every `inbox_read` result in one transcript, parsed."""
    names: dict[str, str] = {}
    with open(path, errors="replace") as handle:
        for line in handle:
            if TOOL not in line and "tool_result" not in line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            for block in (record.get("message") or {}).get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    names[block.get("id")] = block.get("name")
                    continue
                if block.get("type") != "tool_result":
                    continue
                if names.get(block.get("tool_use_id")) != TOOL:
                    continue
                body = block.get("content")
                if isinstance(body, list):
                    body = "".join(c.get("text", "") for c in body if isinstance(c, dict))
                if not isinstance(body, str):
                    continue
                try:
                    yield json.loads(body)
                except ValueError:
                    continue


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcripts", default="~/.claude/projects/*/*.jsonl")
    ap.add_argument("--files", type=int, default=40, help="the newest N transcripts")
    args = ap.parse_args()

    paths = sorted(
        glob.glob(os.path.expanduser(args.transcripts)), key=os.path.getmtime, reverse=True
    )[: args.files]

    out = {"files": len(paths), "calls": 0, "rows": 0, "before": 0, "after": 0}
    for path in paths:
        for doc in answers(path):
            out["calls"] += 1
            if isinstance(doc, dict):
                out["rows"] += len(doc.get("threads") or [])
            out["before"] += len(json.dumps(doc, separators=(",", ":")))
            out["after"] += len(json.dumps(trimmed(doc), separators=(",", ":")))
    calls = max(out["calls"], 1)
    out["mean_before"] = out["before"] // calls
    out["mean_after"] = out["after"] // calls
    before = max(out["before"], 1)
    out["cut"] = round((out["before"] - out["after"]) / before, 3)
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""What acpmux's capacity continuations do once they wake a chat (`hub/auto_resume.rs`).

A turn a capacity error cut (HTTP 529, the gateway's 503) goes on by itself: acpmux sends the chat
"Your previous turn was cut off by a capacity error ...". Each one is a wake. This sorts those
turns by what the agent did in them:
  - `work`: it called at least one tool (`acted`: an edit, push, send, GitHub write or test run;
    `read_only`: reads alone);
  - `no_tool`: it answered in words and stopped (no news);
  - `failed_again`: the attempt hit the outage again (an API error row and no tool call).
It also says whether the turn the error cut had called any tool before it failed
(`cut_turn_no_tools`: the cut came before any work, so the continuation is the first real answer
to its prompt) and how many continuations followed another continuation (`chained`).

It reads this host's own Claude transcripts and prints one JSON object, so a change to the
continuation can be measured before and after on real traffic.

Run: python3 -I scripts/measure/capacity-resume-outcomes.py [--hours 168] [--projects DIR]
(no network, no repo state: transcripts are untrusted data, so run it with -I.)
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import time

MARK = "Your previous turn was cut off by a capacity error"
ANY_CUT = "Your previous turn was cut off"
NO_TURN = ("<command-name>", "<local-command", "[Request interrupted")
ACTS = re.compile(r"git (commit|push)|gh pr (create|merge|comment|edit)|lane-gh|cmux-ci|cargo ")


def text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def is_tool_result(content):
    return isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)


def turns_of(path):
    """The file's main-thread turns: each real prompt and the rows up to the next one."""
    turns = []
    with open(path, errors="replace") as f:
        for line in f:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("isSidechain"):
                continue
            content = (row.get("message") or {}).get("content")
            if row.get("type") == "user" and not row.get("isMeta") and not is_tool_result(content):
                prompt = text(content).strip()
                if prompt and not prompt.startswith(NO_TURN):
                    turns.append({"prompt": prompt, "ts": row.get("timestamp"), "rows": []})
                    continue
            if turns:
                turns[-1]["rows"].append(row)
    return turns


def tool_uses(turn):
    for row in turn["rows"]:
        if row.get("type") == "assistant" and not row.get("isApiErrorMessage"):
            for block in (row.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    yield block


def acted(block):
    name = block.get("name", "")
    if name in ("Edit", "Write", "NotebookEdit", "SendMessage") or name.startswith("mcp__github__"):
        return True
    if "send" in name or "reply" in name:
        return True
    return name == "Bash" and bool(ACTS.search(json.dumps(block.get("input", ""))))


def epoch(value):
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=168)
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    args = ap.parse_args()
    since = time.time() - args.hours * 3600
    out = collections.Counter()
    for path in glob.glob(os.path.join(args.projects, "**/*.jsonl"), recursive=True):
        if os.path.getmtime(path) < since:
            continue
        turns = turns_of(path)
        for i, turn in enumerate(turns):
            if not turn["prompt"].startswith(MARK) or (epoch(turn["ts"]) or 0) < since:
                continue
            uses = list(tool_uses(turn))
            api_error = any(r.get("isApiErrorMessage") for r in turn["rows"])
            out["continuations"] += 1
            if uses:
                out["work"] += 1
                out["work_acted" if any(acted(b) for b in uses) else "work_read_only"] += 1
            else:
                out["failed_again" if api_error else "no_tool"] += 1
            if i > 0:
                out["cut_turn_tools" if any(tool_uses(turns[i - 1])) else "cut_turn_no_tools"] += 1
                out["chained"] += turns[i - 1]["prompt"].startswith(ANY_CUT)
    print(json.dumps({"hours": args.hours, **out}, sort_keys=True))


if __name__ == "__main__":
    main()

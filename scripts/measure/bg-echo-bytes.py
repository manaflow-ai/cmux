#!/usr/bin/env python3
"""How many characters a bg_* result echoes back to the agent that made the call.

Two wastes, both in the agent's context window for nothing:
  - `data`: bg_output's base64 copy of the bytes `text` already carries (1.33x the bytes, unread);
  - `command`: the task's whole command, sent by this same caller moments earlier;
  - a start's `command`, `description` and `sessionId`: a start answer is read in the very turn
    that wrote the call, so every one of those words is already beside it (`start_*` below).

It reads this host's own Claude transcripts (every `bg-` tool result since --since) and prints one
JSON line of character totals, so a cut can be measured before and after on real traffic.

Run: python3 -I scripts/measure/bg-echo-bytes.py [--since YYYY-MM-DD] [--projects GLOB]
(no network, no repo state: transcripts are untrusted data, so run it with -I.)
"""
import argparse
import glob
import json
import os


def totals(paths, since):
    tot = {"calls": 0, "data": 0, "text": 0, "command": 0, "tail": 0,
           "start_calls": 0, "start_bytes": 0, "start_command": 0, "start_description": 0,
           "start_session_id": 0}
    for path in paths:
        try:
            handle = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with handle:
            started = set()
            for line in handle:
                # A start's own call names no task yet: its line carries the tool name instead.
                if "bg-" not in line and "bg_start" not in line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if str(record.get("timestamp", ""))[:10] < since:
                    continue
                message = record.get("message") or {}
                content = message.get("content")
                for block in content if isinstance(content, list) else []:
                    if not isinstance(block, dict):
                        continue
                    # Which answers are a start's: the call it answers, by its id.
                    if block.get("type") == "tool_use":
                        if str(block.get("name", "")).endswith("bg_start"):
                            started.add(block.get("id"))
                        continue
                    if block.get("type") != "tool_result":
                        continue
                    is_start = block.get("tool_use_id") in started
                    body, texts = block.get("content"), []
                    if isinstance(body, str):
                        texts.append(body)
                    elif isinstance(body, list):
                        texts += [b["text"] for b in body
                                  if isinstance(b, dict) and isinstance(b.get("text"), str)]
                    text = "\n".join(texts)
                    if '"id": "bg-' not in text and '"id":"bg-' not in text:
                        continue
                    try:
                        result = json.loads(text)
                    except ValueError:
                        continue
                    if not isinstance(result, dict) or not ("data" in result or "command" in result):
                        continue
                    tot["calls"] += 1
                    for key in ("data", "text", "command", "tail"):
                        value = result.get(key)
                        if isinstance(value, str):
                            tot[key] += len(value)
                    if not is_start:
                        continue
                    tot["start_calls"] += 1
                    tot["start_bytes"] += len(json.dumps(result))
                    for key, into in (("command", "start_command"),
                                      ("description", "start_description"),
                                      ("sessionId", "start_session_id")):
                        value = result.get(key)
                        if isinstance(value, str):
                            # What the answer costs for that word, key and punctuation included.
                            tot[into] += len(json.dumps({key: value})) - 2
    return tot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="1970-01-01", help="skip records before this date (UTC)")
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects/*/*.jsonl"),
                    help="transcript glob to read")
    args = ap.parse_args()
    tot = totals(sorted(glob.glob(args.projects)), args.since)
    # ~4 characters a token, the figure every other measurement here quotes.
    tot["echo_tokens"] = (tot["data"] + tot["command"]) // 4
    own = tot["start_command"] + tot["start_description"] + tot["start_session_id"]
    tot["start_own_words"] = own
    tot["start_own_share"] = round(own / tot["start_bytes"], 3) if tot["start_bytes"] else 0.0
    print(json.dumps(tot, indent=1))


if __name__ == "__main__":
    main()

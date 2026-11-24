#!/usr/bin/env python3
"""A scripted stand-in for `claude -p --output-format stream-json`, for the demo's tests.

It keeps a session file where Claude Code keeps its own (so the copy carries it), remembers
earlier prompts across resumes, and acts by the prompt's words:

- `slow:SECS` writes step1.txt, starts a "tool" that takes SECS seconds, then writes step2.txt.
- A resume whose session file ends in a tool with no result finishes the job: it writes
  step2.txt and resumed.txt (naming $AUTO_FAKE_HOST).
- Anything else appends the prompt to notes.txt.
"""
import json
import os
import re
import sys
import time


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    args = sys.argv[1:]
    sid, resume, model = None, False, None
    prompt = args[-1]
    for i, a in enumerate(args):
        if a == "--session-id":
            sid = args[i + 1]
        elif a == "--resume":
            sid, resume = args[i + 1], True
    cwd = os.path.realpath(os.getcwd())
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    path = os.path.join(config, "projects", re.sub(r"[^a-zA-Z0-9]", "-", cwd), sid + ".jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = []
    if os.path.exists(path):
        with open(path) as f:
            lines = [json.loads(l) for l in f if l.strip()]
    elif resume:
        sys.stderr.write("No conversation found with session ID: %s\n" % sid)
        sys.exit(1)
    host = os.environ.get("AUTO_FAKE_HOST", "somewhere")

    def record(obj):
        with open(path, "a") as f:
            f.write(json.dumps(obj) + "\n")
        lines.append(obj)

    def say(text):
        for word in re.findall(r"\S+\s*", text):
            out({"type": "stream_event", "event": {"type": "content_block_delta",
                                                   "delta": {"type": "text_delta", "text": word}}})
            time.sleep(0.01)
        out({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
        record({"type": "assistant", "text": text})

    out({"type": "system", "subtype": "init", "session_id": sid, "cwd": cwd, "model": "fake"})
    earlier = [l["text"] for l in lines if l.get("type") == "user"]
    open_tool = bool(lines) and lines[-1].get("type") == "tool_use"
    record({"type": "user", "text": prompt})
    slow = re.search(r"slow:(\d+(?:\.\d+)?)", prompt)
    tag = re.search(r"tag:(\S+)", prompt)

    def stamp():
        if tag:
            with open("log.txt", "a") as f:
                f.write(tag.group(1) + "\n")
    if open_tool:
        say("A tool call was cut off before its result. Finishing on %s." % host)
        with open("step2.txt", "w") as f:
            f.write("finished on %s\n" % host)
        with open("resumed.txt", "w") as f:
            f.write("resumed on %s with %d earlier messages\n" % (host, len(earlier)))
        record({"type": "tool_result", "text": "finished after a cut"})
        stamp()
        say("Done: step2.txt written on %s. I remember %d earlier messages." % (host, len(earlier)))
    elif slow:
        say("Starting the long job on %s." % host)
        with open("step1.txt", "w") as f:
            f.write("started on %s\n" % host)
        out({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "tool_1", "name": "Bash", "input": {"command": "sleep %s" % slow.group(1)}}]}})
        record({"type": "tool_use", "text": "sleep"})
        time.sleep(float(slow.group(1)))
        with open("step2.txt", "w") as f:
            f.write("finished on %s\n" % host)
        out({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "tool_1", "content": "slept"}]}})
        record({"type": "tool_result", "text": "slept"})
        stamp()
        say("The long job finished on %s." % host)
    else:
        stamp()
        with open("notes.txt", "a") as f:
            f.write("%s: %s\n" % (host, prompt.strip().split("\n")[-1]))
        say("Noted on %s. I remember %d earlier messages." % (host, len(earlier)))
    out({"type": "result", "subtype": "success", "is_error": False, "result": "ok", "session_id": sid})


if __name__ == "__main__":
    main()

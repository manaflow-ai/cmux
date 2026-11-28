#!/usr/bin/env python3
"""Subagent model mix: which model each Claude Code subagent ran, and its tokens (RFD 0158 §6).

measure: for every `Agent`/`Task` call in this machine's Claude transcripts since a date, its
subagent kind and whether it named a model; and per model, the subagent runs and their input,
cache-read, cache-write and output tokens. Before/after for harness magic `router`: with it on,
`Explore` calls with no model show up as sonnet runs instead of the lead's model.
Run: python3 -I scripts/measure/subagent-model-mix.py [SINCE, e.g. 2026-11-20] [--json]
(local only: it reads ~/.claude/projects; no cmux-ci run, the transcripts are on this machine).
"""
import collections
import glob
import json
import os
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
since = args[0] if args else ""
root = os.path.expanduser("~/.claude/projects")

calls = collections.Counter()
for path in glob.glob(f"{root}/*/*.jsonl"):
    with open(path, errors="replace") as f:
        for line in f:
            if '"tool_use"' not in line or ('"Agent"' not in line and '"Task"' not in line):
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("timestamp", "") < since:
                continue
            for c in (d.get("message") or {}).get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") in ("Agent", "Task"):
                    i = c.get("input") or {}
                    calls[(i.get("subagent_type") or "(none)", i.get("model") or "(lead's)")] += 1

usage = collections.defaultdict(lambda: {"runs": 0, "input": 0, "cacheRead": 0, "cacheWrite": 0, "output": 0})
for path in glob.glob(f"{root}/*/*/subagents/agent-*.jsonl"):
    first = True
    with open(path, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            m = d.get("message") or {}
            u = m.get("usage")
            if d.get("type") != "assistant" or not u or d.get("timestamp", "") < since:
                continue
            model = m.get("model") or "?"
            if model == "<synthetic>":
                continue
            r = usage[model]
            r["input"] += u.get("input_tokens", 0)
            r["cacheRead"] += u.get("cache_read_input_tokens", 0)
            r["cacheWrite"] += u.get("cache_creation_input_tokens", 0)
            r["output"] += u.get("output_tokens", 0)
            if first:
                r["runs"] += 1
                first = False

if "--json" in sys.argv:
    print(json.dumps({"since": since,
                      "calls": [{"kind": k, "model": m, "n": n} for (k, m), n in calls.most_common()],
                      "byModel": usage}, indent=1))
else:
    print(f"Agent/Task calls since {since or 'the start'} (kind, model asked):")
    for (k, m), n in calls.most_common():
        print(f"  {n:5}  {k:20} {m}")
    print("subagent runs by model: runs, input, cache read, cache write, output tokens")
    for model, r in sorted(usage.items(), key=lambda x: -x[1]["output"]):
        print(f"  {model:22} {r['runs']:5} {r['input']:9} {r['cacheRead']:12} {r['cacheWrite']:11} {r['output']:10}")
